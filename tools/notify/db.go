package main

import (
	"context"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TripRow holds the data returned from the trips view for a single drive.
type TripRow struct {
	VIN         string
	TripID      int
	Started     time.Time
	Ended       time.Time
	Duration    time.Duration
	DistanceKM  float64
	KWhUsed     float64
	WhPerKM     *float64 // NULL for very short trips
	SocStartPct float64
	SocEndPct   float64
	MaxSpeedMPH float64
	AvgSpeedMPH float64
	StartLat    float64
	StartLon    float64
	EndLat      float64
	EndLon      float64
}

// GPSPoint is a single latitude/longitude sample from the telemetry table.
type GPSPoint struct {
	Lat float64
	Lon float64
}

// ChargeInfo holds the car's charging state immediately after a trip ends.
type ChargeInfo struct {
	State    string   // DetailedChargeState without prefix: "Charging", "Complete", ...; "" if never reported
	TTFHours *float64 // TimeToFullCharge in hours; nil if not charging
}

// fetchUnnotifiedTrips returns completed trips for the given VIN that have
// not yet been recorded in telegram_notifications.
//
// A trip counts as completed only after 12 minutes of GPS silence — this must
// stay above the 10-minute sessionization gap in the trips view (002_views.sql),
// otherwise a mid-trip stop of 5-10 min gets notified as a finished trip and
// the dedup row masks the real end-of-trip notification.
// Dedup is keyed on (vin, started): the positional trip_id shifts when late
// telemetry reflows trip boundaries, the start timestamp does not.
func fetchUnnotifiedTrips(ctx context.Context, pool *pgxpool.Pool, vin string) ([]TripRow, error) {
	const q = `
		SELECT
			vin, trip_id,
			started, ended,
			ended - started AS duration,
			distance_km,
			COALESCE(kwh_used, 0),
			wh_per_km,
			COALESCE(soc_start_pct, 0), COALESCE(soc_end_pct, 0),
			COALESCE(max_speed_mph, 0), COALESCE(avg_speed_mph, 0),
			COALESCE(start_lat, 0), COALESCE(start_lon, 0),
			COALESCE(end_lat, 0),   COALESCE(end_lon, 0)
		FROM trips
		WHERE vin = $1
		  AND ended < NOW() - INTERVAL '12 minutes'
		  AND NOT EXISTS (
			SELECT 1 FROM telegram_notifications n
			WHERE n.vin = trips.vin AND n.started = trips.started
		  )
		ORDER BY ended ASC`

	rows, err := pool.Query(ctx, q, vin)
	if err != nil {
		return nil, fmt.Errorf("query unnotified trips: %w", err)
	}
	defer rows.Close()

	var trips []TripRow
	for rows.Next() {
		var t TripRow
		var dur time.Duration
		if err := rows.Scan(
			&t.VIN, &t.TripID,
			&t.Started, &t.Ended, &dur,
			&t.DistanceKM, &t.KWhUsed, &t.WhPerKM,
			&t.SocStartPct, &t.SocEndPct,
			&t.MaxSpeedMPH, &t.AvgSpeedMPH,
			&t.StartLat, &t.StartLon,
			&t.EndLat, &t.EndLon,
		); err != nil {
			return nil, fmt.Errorf("scan trip: %w", err)
		}
		t.Duration = dur
		trips = append(trips, t)
	}
	return trips, rows.Err()
}

// fetchTripByID fetches a single trip by ID, regardless of notification state.
// Used for the --trip-id manual/debug flag.
func fetchTripByID(ctx context.Context, pool *pgxpool.Pool, vin string, tripID int) (TripRow, error) {
	const q = `
		SELECT
			vin, trip_id,
			started, ended,
			ended - started AS duration,
			distance_km,
			COALESCE(kwh_used, 0),
			wh_per_km,
			COALESCE(soc_start_pct, 0), COALESCE(soc_end_pct, 0),
			COALESCE(max_speed_mph, 0), COALESCE(avg_speed_mph, 0),
			COALESCE(start_lat, 0), COALESCE(start_lon, 0),
			COALESCE(end_lat, 0),   COALESCE(end_lon, 0)
		FROM trips
		WHERE vin = $1 AND trip_id = $2`

	var t TripRow
	var dur time.Duration
	err := pool.QueryRow(ctx, q, vin, tripID).Scan(
		&t.VIN, &t.TripID,
		&t.Started, &t.Ended, &dur,
		&t.DistanceKM, &t.KWhUsed, &t.WhPerKM,
		&t.SocStartPct, &t.SocEndPct,
		&t.MaxSpeedMPH, &t.AvgSpeedMPH,
		&t.StartLat, &t.StartLon,
		&t.EndLat, &t.EndLon,
	)
	if err != nil {
		return TripRow{}, fmt.Errorf("fetch trip %d: %w", tripID, err)
	}
	t.Duration = dur
	return t, nil
}

// fetchGPSTrack returns ordered GPS points for a trip window.
func fetchGPSTrack(ctx context.Context, pool *pgxpool.Pool, vin string, from, to time.Time) ([]GPSPoint, error) {
	const q = `
		SELECT
			ST_Y(geo_value::geometry) AS lat,
			ST_X(geo_value::geometry) AS lon
		FROM telemetry
		WHERE vin = $1
		  AND field = 'Location'
		  AND ts BETWEEN $2 AND $3
		ORDER BY ts`

	rows, err := pool.Query(ctx, q, vin, from, to)
	if err != nil {
		return nil, fmt.Errorf("query GPS track: %w", err)
	}
	defer rows.Close()

	var pts []GPSPoint
	for rows.Next() {
		var p GPSPoint
		if err := rows.Scan(&p.Lat, &p.Lon); err != nil {
			return nil, fmt.Errorf("scan GPS point: %w", err)
		}
		pts = append(pts, p)
	}
	return pts, rows.Err()
}

// fetchAvgEfficiency returns the rolling 30-day average efficiency in Wh/km,
// excluding the current trip. Returns nil if not enough data.
func fetchAvgEfficiency(ctx context.Context, pool *pgxpool.Pool, vin string, excludeTripID int) (*float64, error) {
	const q = `
		SELECT round(avg(wh_per_km)::numeric, 0)
		FROM trips
		WHERE vin = $1
		  AND wh_per_km IS NOT NULL
		  AND wh_per_km > 0
		  AND trip_id != $2
		  AND ended > NOW() - INTERVAL '30 days'`

	var avg *float64
	err := pool.QueryRow(ctx, q, vin, excludeTripID).Scan(&avg)
	if err != nil {
		return nil, fmt.Errorf("query avg efficiency: %w", err)
	}
	return avg, nil
}

// fetchChargeState returns the most recent charging state for the VIN.
//
// DetailedChargeState, not ChargeState: ChargeState is the charger state
// machine (Idle/Enable/Startup/...) and never reads "Charging". Values are
// stored with their proto prefix, which normalizeChargeState strips. Both
// columns are scanned as nullable: a vehicle that has never reported the
// field returns NULL, which used to fail the whole scan.
func fetchChargeState(ctx context.Context, pool *pgxpool.Pool, vin string) (ChargeInfo, error) {
	const q = `
		SELECT
			(SELECT str_value  FROM telemetry WHERE vin=$1 AND field='DetailedChargeState' ORDER BY ts DESC LIMIT 1),
			(SELECT num_value  FROM telemetry WHERE vin=$1 AND field='TimeToFullCharge'    ORDER BY ts DESC LIMIT 1)`

	var raw *string
	var ci ChargeInfo
	err := pool.QueryRow(ctx, q, vin).Scan(&raw, &ci.TTFHours)
	if err != nil {
		return ChargeInfo{}, fmt.Errorf("query charge state: %w", err)
	}
	ci.State = normalizeChargeState(raw)
	return ci, nil
}

// tripNotifyLock is a session-scoped PostgreSQL advisory lock held for the
// duration of one trip-notification pass.
//
// fetchUnnotifiedTrips → send → markNotified is not atomic: two runners (the
// daemon's trip watcher and a leftover cron entry, or two daemons) can fetch
// the same trip, both send it, and both then insert the same key with
// ON CONFLICT DO NOTHING. The lock makes the pass mutually exclusive per VIN
// without adding a failure mode where a crash between claiming and sending
// loses the notification entirely.
type tripNotifyLock struct {
	conn *pgxpool.Conn
}

// acquireTripNotifyLock returns a held lock, or nil if another runner has it.
// The caller must call release on a non-nil result.
func acquireTripNotifyLock(ctx context.Context, pool *pgxpool.Pool, vin string) (*tripNotifyLock, error) {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("acquire connection for trip lock: %w", err)
	}
	var got bool
	// Session-scoped rather than transaction-scoped: the lock has to outlive
	// the individual statements that make up the pass.
	if err := conn.QueryRow(ctx,
		`SELECT pg_try_advisory_lock(hashtext('notify:trips:' || $1)::bigint)`, vin,
	).Scan(&got); err != nil {
		conn.Release()
		return nil, fmt.Errorf("take trip lock: %w", err)
	}
	if !got {
		conn.Release()
		return nil, nil
	}
	return &tripNotifyLock{conn: conn}, nil
}

func (l *tripNotifyLock) release(ctx context.Context, vin string) {
	if l == nil || l.conn == nil {
		return
	}
	if _, err := l.conn.Exec(ctx,
		`SELECT pg_advisory_unlock(hashtext('notify:trips:' || $1)::bigint)`, vin); err != nil {
		// Releasing the connection drops the session and with it the lock, so
		// this is only worth logging.
		log.Printf("warn: release trip lock: %v", err)
	}
	l.conn.Release()
	l.conn = nil
}

// markNotified records that a trip notification has been sent successfully.
// Keyed on (vin, started); trip_id is stored for reference only and may go
// stale when trip boundaries reflow.
func markNotified(ctx context.Context, pool *pgxpool.Pool, vin string, started time.Time, tripID int) error {
	_, err := pool.Exec(ctx,
		`INSERT INTO telegram_notifications (vin, started, trip_id) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
		vin, started, tripID)
	return err
}

// SummaryStats holds aggregated trip metrics for a time window.
type SummaryStats struct {
	TripCount  int
	TotalKM    float64
	TotalKWh   float64
	AvgWhPerKM float64
	LongestKM  float64
}

// fetchSummaryStats returns aggregated trip metrics for the given VIN over the
// last `days` days.
func fetchSummaryStats(ctx context.Context, pool *pgxpool.Pool, vin string, days int) (SummaryStats, error) {
	const q = `
		SELECT
			COUNT(*)::int,
			COALESCE(SUM(distance_km), 0),
			COALESCE(SUM(kwh_used), 0),
			COALESCE(AVG(wh_per_km) FILTER (WHERE wh_per_km > 0), 0),
			COALESCE(MAX(distance_km), 0)
		FROM trips
		WHERE vin = $1
		  AND ended > NOW() - ($2 * INTERVAL '1 day')
		  AND ended < NOW()`

	var s SummaryStats
	err := pool.QueryRow(ctx, q, vin, days).Scan(
		&s.TripCount, &s.TotalKM, &s.TotalKWh, &s.AvgWhPerKM, &s.LongestKM,
	)
	if err != nil {
		return SummaryStats{}, fmt.Errorf("query summary stats: %w", err)
	}
	return s, nil
}

// ChargingEnergy is the charging energy over a window, as the two vehicle
// counters actually measure it.
//
// ACChargingEnergyIn counts energy drawn from an AC supply (wall box, outlet):
// the input side of the onboard charger. DCChargingEnergyIn counts DC energy
// delivered into the battery, both from the onboard charger during AC charging
// and directly from a DC fast charger. In an AC session both counters rise
// (AC slightly more: the difference is the onboard charger's loss); in a DC
// fast-charge session only DCChargingEnergyIn does. They are not "AC charging"
// and "DC charging" totals, and adding them double-counts AC sessions.
type ChargingEnergy struct {
	FromACSupply float64 // kWh drawn from AC supplies (ACChargingEnergyIn)
	IntoBattery  float64 // kWh into the battery from any charger (DCChargingEnergyIn)
	DCFast       float64 // part of IntoBattery delivered while DC charging power was flowing
}

// IntoBatteryFromAC is the battery-side energy of AC sessions.
func (e ChargingEnergy) IntoBatteryFromAC() float64 {
	if v := e.IntoBattery - e.DCFast; v > 0 {
		return v
	}
	return 0
}

// ACLossPct is the onboard-charger loss of AC charging in percent, or false
// when there is too little AC energy to say.
func (e ChargingEnergy) ACLossPct() (float64, bool) {
	fromAC := e.IntoBatteryFromAC()
	if e.FromACSupply < 0.5 || fromAC <= 0 || fromAC > e.FromACSupply {
		return 0, false
	}
	return (e.FromACSupply - fromAC) / e.FromACSupply * 100, true
}

// chargingEnergySQL sums counter increases over the window. Both counters are
// per-session and reset when a session starts. Only a fall to less than half
// the previous value counts as a reset: DCChargingEnergyIn also sags by
// 0.02-0.4 kWh at a time while the car is parked, and treating each of those
// dips as a new session re-added the whole counter every time (193 kWh
// reported for a week that added about 20). The first sample in the window
// contributes nothing (its value accumulated before the window opened).
// A battery-side increase counts as DC fast charging when DCChargingPower was
// above zero within 10 minutes of it.
const chargingEnergySQL = `
	WITH vals AS (
		SELECT field, ts, num_value,
		       LAG(num_value) OVER (PARTITION BY field ORDER BY ts) AS prev
		FROM telemetry
		WHERE vin = $1
		  AND field IN ('ACChargingEnergyIn', 'DCChargingEnergyIn')
		  AND ts > NOW() - ($2 * INTERVAL '1 day')
		  AND num_value IS NOT NULL
	), inc AS (
		SELECT field, ts,
		       CASE
		         WHEN prev IS NULL           THEN 0
		         WHEN num_value < prev * 0.5 THEN num_value
		         WHEN num_value < prev       THEN 0
		         ELSE num_value - prev
		       END AS kwh
		FROM vals
	)
	SELECT
	  COALESCE(SUM(kwh) FILTER (WHERE field = 'ACChargingEnergyIn'), 0),
	  COALESCE(SUM(kwh) FILTER (WHERE field = 'DCChargingEnergyIn'), 0),
	  COALESCE(SUM(kwh) FILTER (WHERE field = 'DCChargingEnergyIn' AND kwh > 0 AND EXISTS (
	    SELECT 1 FROM telemetry p
	    WHERE p.vin = $1 AND p.field = 'DCChargingPower' AND p.num_value > 0
	      AND p.ts BETWEEN inc.ts - INTERVAL '10 minutes' AND inc.ts + INTERVAL '10 minutes')), 0)
	FROM inc`

// fetchChargingEnergy returns the charging energy over the last `days` days.
func fetchChargingEnergy(ctx context.Context, pool *pgxpool.Pool, vin string, days int) (ChargingEnergy, error) {
	var e ChargingEnergy
	if err := pool.QueryRow(ctx, chargingEnergySQL, vin, days).Scan(&e.FromACSupply, &e.IntoBattery, &e.DCFast); err != nil {
		return ChargingEnergy{}, fmt.Errorf("query charging energy: %w", err)
	}
	return e, nil
}

// formatChargingLine renders a ChargingEnergy for the summary message.
func formatChargingLine(e ChargingEnergy) string {
	if e.IntoBattery <= 0 && e.FromACSupply <= 0 {
		return "🔋 No charging in this period"
	}
	line := fmt.Sprintf("🔋 %.1f kWh into the battery", e.IntoBattery)
	var parts []string
	if e.DCFast > 0.05 {
		parts = append(parts, fmt.Sprintf("%.1f kWh DC fast charging", e.DCFast))
	}
	if e.FromACSupply > 0.05 {
		ac := fmt.Sprintf("%.1f kWh from AC (%.1f kWh drawn from the supply", e.IntoBatteryFromAC(), e.FromACSupply)
		if loss, ok := e.ACLossPct(); ok {
			ac += fmt.Sprintf(", %.0f%% charger loss", loss)
		}
		parts = append(parts, ac+")")
	}
	if len(parts) > 0 {
		line += "\n    " + strings.Join(parts, " · ")
	}
	return line
}

// fetchCurrentOdometer returns the most recent odometer reading in kilometres
// for the VIN.  Returns nil if no reading is available.
//
// IMPORTANT: the Tesla fleet-telemetry proto reports Odometer in miles
// (this is consistent with the rest of the Tesla API surface and with
// deploy/sql/013_regen_brake_diagnostics.sql which divides by 50000.0
// miles for the brake-wear model).  We convert to kilometres here so
// downstream callers can treat the value uniformly and so service_log
// can persist it under the existing `odometer_km` column.
func fetchCurrentOdometer(ctx context.Context, pool *pgxpool.Pool, vin string) (*float64, error) {
	const q = `
		SELECT num_value FROM telemetry
		WHERE vin = $1 AND field = 'Odometer'
		  AND num_value IS NOT NULL
		ORDER BY ts DESC LIMIT 1`

	var rawMiles *float64
	if err := pool.QueryRow(ctx, q, vin).Scan(&rawMiles); err != nil {
		return nil, fmt.Errorf("query odometer: %w", err)
	}
	if rawMiles == nil {
		return nil, nil
	}
	km := *rawMiles * 1.60934
	return &km, nil
}

// insertServiceLog writes a completed service log session to the database and
// returns the new row's ID. When the user picked a scheduled service item, a
// service_completions row is written in the same transaction, so
// service_interval_status counts the interval from this service.
func insertServiceLog(ctx context.Context, pool *pgxpool.Pool, vin string, sess *ServiceLogSession) (int, error) {
	const q = `
		INSERT INTO service_log (vin, logged_at, odometer_km, description, photo_paths, service_lat, service_lon)
		VALUES ($1, now(), $2, $3, $4, $5, $6)
		RETURNING id`

	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin service log: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var id int
	if err := tx.QueryRow(ctx, q, vin, sess.OdometerKM, sess.Description, sess.PhotoPaths,
		sess.ServiceLat, sess.ServiceLon).Scan(&id); err != nil {
		return 0, fmt.Errorf("insert service log: %w", err)
	}

	if sess.ServiceItem != "" {
		// service_completions keeps odometer in miles; the session holds km.
		var odoMi *float64
		if sess.OdometerKM != nil {
			v := *sess.OdometerKM / 1.60934
			odoMi = &v
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO service_completions (vin, item, completed_at, odometer_mi, notes)
			VALUES ($1, $2, now(), $3, $4)`,
			vin, sess.ServiceItem, odoMi, fmt.Sprintf("service_log #%d", id)); err != nil {
			return 0, fmt.Errorf("insert service completion: %w", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("commit service log: %w", err)
	}
	return id, nil
}

// fetchServiceItems lists the scheduled service items the bot offers when a
// service is logged.
func fetchServiceItems(ctx context.Context, pool *pgxpool.Pool) ([]string, error) {
	rows, err := pool.Query(ctx, `SELECT item FROM service_intervals ORDER BY item`)
	if err != nil {
		return nil, fmt.Errorf("query service items: %w", err)
	}
	defer rows.Close()
	var items []string
	for rows.Next() {
		var it string
		if err := rows.Scan(&it); err != nil {
			return nil, fmt.Errorf("scan service item: %w", err)
		}
		items = append(items, it)
	}
	return items, rows.Err()
}

// fetchLastGPS returns the most recent GPS fix for the VIN.
func fetchLastGPS(ctx context.Context, pool *pgxpool.Pool, vin string) (GPSPoint, error) {
	const q = `
		SELECT ST_Y(geo_value::geometry), ST_X(geo_value::geometry)
		FROM telemetry
		WHERE vin = $1 AND field = 'Location'
		ORDER BY ts DESC LIMIT 1`

	var p GPSPoint
	err := pool.QueryRow(ctx, q, vin).Scan(&p.Lat, &p.Lon)
	if err != nil {
		return GPSPoint{}, fmt.Errorf("query last GPS: %w", err)
	}
	return p, nil
}
