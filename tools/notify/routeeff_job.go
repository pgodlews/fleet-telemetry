package main

// EXPERIMENTAL frequent-route efficiency monitor (see the routeeff
// package): reads route_trip_observations and the trips' GPS tracks,
// identifies routes, fits the drift and writes route_efficiency_routes,
// route_efficiency_estimate, route_efficiency_points and
// route_efficiency_curve (deploy/sql/058). Daily inside the daemon and on
// demand with --route-efficiency-once. Sends nothing; not part of the
// predictive health score.

import (
	"context"
	"fmt"
	"log"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/teslamotors/fleet-telemetry/tools/notify/routeeff"
)

const routeEffMethod = "routeeff-v1: ln(Wh/km) = route + d*t + covariates; Huber-WLS (k=1.345, MAD); date-clustered bootstrap (packfade engine)"

// routeEffWatcher mirrors packfadeWatcher: recompute when the newest
// estimate is older than packfadeMaxAge, checking hourly.
func routeEffWatcher(ctx context.Context, pool *pgxpool.Pool, cfg *Config) {
	log.Println("route efficiency watcher started (experimental, daily)")
	ticker := time.NewTicker(packfadeCheckInterval)
	defer ticker.Stop()
	for {
		if due, err := routeEffDue(ctx, pool, cfg.VIN); err != nil {
			log.Printf("route efficiency: %v", err)
		} else if due {
			jctx, cancel := context.WithTimeout(ctx, packfadeTimeout)
			summary, err := runRouteEff(jctx, pool, cfg.VIN, false, nil)
			cancel()
			if err != nil {
				log.Printf("route efficiency: %v", err)
			} else {
				log.Printf("route efficiency: %s", firstLine(summary))
			}
		}
		select {
		case <-ctx.Done():
			log.Println("route efficiency watcher stopped")
			return
		case <-ticker.C:
		}
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func routeEffDue(ctx context.Context, pool *pgxpool.Pool, vin string) (bool, error) {
	qctx, cancel := context.WithTimeout(ctx, dbQueryTimeout)
	defer cancel()
	var last *time.Time
	if err := pool.QueryRow(qctx,
		`SELECT max(computed_at) FROM route_efficiency_estimate WHERE vin = $1`, vin).Scan(&last); err != nil {
		return false, fmt.Errorf("last estimate: %w", err)
	}
	return last == nil || time.Since(*last) > packfadeMaxAge, nil
}

func fetchRouteTrips(ctx context.Context, pool *pgxpool.Pool, vin string) ([]routeeff.Trip, error) {
	rows, err := pool.Query(ctx, `
		SELECT trip_id, started, ended, distance_km::float8, start_lat, start_lon, end_lat, end_lon,
		       wh_per_km::float8, outside_temp_c::float8, cabin_minus_outside_start_c::float8,
		       mean_fan_level::float8, hvac_on_at_start, defrost_used, tyre_pressure_bar::float8,
		       hours_since_prev_drive::float8, mean_speed_kmh::float8, duration_min::float8
		FROM route_trip_observations WHERE vin = $1 ORDER BY started`, vin)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []routeeff.Trip
	byID := map[int64]int{}
	for rows.Next() {
		var t routeeff.Trip
		var dist, sla, slo, ela, elo, wh, temp, cab, fan, tyre, prev, speed, dur *float64
		var hvac, defrost *bool
		if err := rows.Scan(&t.ID, &t.Started, &t.Ended, &dist, &sla, &slo, &ela, &elo, &wh, &temp, &cab,
			&fan, &hvac, &defrost, &tyre, &prev, &speed, &dur); err != nil {
			return nil, err
		}
		t.DistanceKm = orNaN(dist)
		if sla != nil && slo != nil && ela != nil && elo != nil {
			t.HasEndpoints = true
			t.Start = routeeff.LatLon{Lat: *sla, Lon: *slo}
			t.End = routeeff.LatLon{Lat: *ela, Lon: *elo}
		}
		t.WhPerKm = orNaN(wh)
		t.OutsideC = orNaN(temp)
		t.CabinMinusOutC = orNaN(cab)
		t.MeanFan = orNaN(fan)
		if hvac != nil {
			t.HasHvac, t.HvacOn = true, *hvac
		}
		t.Defrost = defrost != nil && *defrost
		t.TyreBar = orNaN(tyre)
		t.HoursSincePrev = orNaN(prev)
		t.SpeedKmh = orNaN(speed)
		t.DurationMin = orNaN(dur)
		byID[t.ID] = len(out)
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// GPS tracks, for telling two roads between the same endpoints apart
	trows, err := pool.Query(ctx, `
		SELECT tm.trip_id, ST_Y(x.geo_value::geometry), ST_X(x.geo_value::geometry)
		FROM trips_mat tm
		JOIN telemetry x ON x.vin = tm.vin AND x.field = 'Location'
		 AND x.ts BETWEEN tm.started AND tm.ended AND x.geo_value IS NOT NULL
		WHERE tm.vin = $1
		ORDER BY tm.trip_id, x.ts`, vin)
	if err != nil {
		return nil, fmt.Errorf("tracks: %w", err)
	}
	defer trows.Close()
	for trows.Next() {
		var id int64
		var p routeeff.LatLon
		if err := trows.Scan(&id, &p.Lat, &p.Lon); err != nil {
			return nil, err
		}
		if i, ok := byID[id]; ok {
			out[i].Track = append(out[i].Track, p)
		}
	}
	return out, trows.Err()
}

// runRouteEff computes and, unless dryRun, stores. covariates overrides
// the default list (diagnostics only).
func runRouteEff(ctx context.Context, pool *pgxpool.Pool, vin string, dryRun bool, covariates []string) (string, error) {
	trips, err := fetchRouteTrips(ctx, pool, vin)
	if err != nil {
		return "", fmt.Errorf("read route_trip_observations: %w", err)
	}
	opt := routeeff.DefaultOptions()
	if covariates != nil {
		opt.Covariates = covariates
	}
	res := routeeff.Run(trips, opt)
	summary := routeEffSummary(res, opt)
	if dryRun {
		return summary, nil
	}
	if err := storeRouteEff(ctx, pool, vin, time.Now().UTC(), opt, trips, res); err != nil {
		return "", fmt.Errorf("store: %w", err)
	}
	return summary, nil
}

func routeEffSummary(res routeeff.Result, opt routeeff.Options) string {
	var b strings.Builder
	p := res.Pooled
	fmt.Fprintf(&b, "pooled (%s; %d routes, %d trips, %d days): %s", strings.Join(opt.Covariates, "+"), p.NRoutes, p.NUsed, p.NDays, p.Status)
	if p.Status == routeeff.StatusOK {
		fmt.Fprintf(&b, " drift %.1f %%/yr [%.1f, %.1f], temp %.1f %%/10C, scatter raw %.3f -> residual %.3f",
			p.DriftPctPerYear, p.DriftLo, p.DriftHi, p.TempPctPer10C, p.RawScale, p.ResidualScale)
		for _, c := range opt.Covariates {
			fmt.Fprintf(&b, "; %s %.4f [%.4f, %.4f]", c, p.CovEffects[c], p.CovLo[c], p.CovHi[c])
		}
	}
	b.WriteString(" — " + p.Message)
	for _, r := range res.Routes {
		e := res.PerRoute[r.ID]
		fmt.Fprintf(&b, "\n%s (%s, path %d): %d trips, %.2f km (cv %.3f), median %.0f Wh/km, %s",
			r.Label, r.ID, r.PathIndex, len(r.Trips), r.MedianKm, r.DistanceCV, e.MedianWhPerKm, e.Status)
		if e.Status == routeeff.StatusOK {
			fmt.Fprintf(&b, " drift %.1f %%/yr [%.1f, %.1f], temp %.1f %%/10C, scatter raw %.3f -> residual %.3f",
				e.DriftPctPerYear, e.DriftLo, e.DriftHi, e.TempPctPer10C, e.RawScale, e.ResidualScale)
		} else {
			fmt.Fprintf(&b, " (raw scatter %.3f)", e.RawScale)
		}
	}
	reasons := map[string]int{}
	for _, pt := range res.Points {
		if pt.Used {
			reasons["used"]++
		} else {
			reasons[pt.Reason]++
		}
	}
	keys := make([]string, 0, len(reasons))
	for k := range reasons {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	b.WriteString("\ntrips:")
	for _, k := range keys {
		fmt.Fprintf(&b, " %s=%d", k, reasons[k])
	}
	return b.String()
}

func storeRouteEff(ctx context.Context, pool *pgxpool.Pool, vin string, at time.Time, opt routeeff.Options, trips []routeeff.Trip, res routeeff.Result) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('routeeff:' || $1))`, vin); err != nil {
		return fmt.Errorf("lock: %w", err)
	}
	p := res.Pooled
	ok := p.Status == routeeff.StatusOK
	if _, err := tx.Exec(ctx, `
		INSERT INTO route_efficiency_estimate (vin, computed_at, status, message, n_routes, n_used, n_days,
		  first_obs, last_obs, span_days, drift_pct_per_year, drift_lo_pct_per_year, drift_hi_pct_per_year,
		  temp_effect_pct_per_10c, raw_scale, residual_scale, covariates, n_boot, seed, method)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20)`,
		vin, at, p.Status, p.Message, p.NRoutes, p.NUsed, p.NDays, nullTime(p.First), nullTime(p.Last), num(p.SpanDays),
		cond(ok, p.DriftPctPerYear), cond(ok, p.DriftLo), cond(ok, p.DriftHi), cond(ok, p.TempPctPer10C),
		num(p.RawScale), cond(ok, p.ResidualScale), strings.Join(opt.Covariates, ","), opt.Bootstrap, int64(opt.Seed), routeEffMethod); err != nil {
		return fmt.Errorf("insert estimate: %w", err)
	}
	for _, q := range []string{`DELETE FROM route_efficiency_routes WHERE vin = $1`, `DELETE FROM route_efficiency_points WHERE vin = $1`,
		`DELETE FROM route_efficiency_curve WHERE vin = $1`} {
		if _, err := tx.Exec(ctx, q, vin); err != nil {
			return err
		}
	}
	var rrows [][]any
	for _, r := range res.Routes {
		e := res.PerRoute[r.ID]
		eok := e.Status == routeeff.StatusOK
		rrows = append(rrows, []any{vin, r.ID, at, r.Label, r.PathIndex, r.Start.Lat, r.Start.Lon, r.End.Lat, r.End.Lon,
			r.MedianKm, r.DistanceCV, len(r.Trips), e.NUsed, e.NDays, nullTime(e.First), nullTime(e.Last), e.Status, e.Message,
			num(e.MedianWhPerKm), cond(eok, e.DriftPctPerYear), cond(eok, e.DriftLo), cond(eok, e.DriftHi),
			cond(eok, e.TempPctPer10C), num(e.RawScale), cond(eok, e.ResidualScale)})
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"route_efficiency_routes"},
		[]string{"vin", "route_id", "computed_at", "label", "path_index", "start_lat", "start_lon", "end_lat", "end_lon",
			"median_distance_km", "distance_cv", "n_trips", "n_used", "n_days", "first_trip", "last_trip", "status", "message",
			"median_wh_per_km", "drift_pct_per_year", "drift_lo_pct_per_year", "drift_hi_pct_per_year",
			"temp_effect_pct_per_10c", "raw_scale", "residual_scale"}, pgx.CopyFromRows(rrows)); err != nil {
		return fmt.Errorf("copy routes: %w", err)
	}
	var prows [][]any
	for _, pt := range res.Points {
		t := trips[pt.Trip]
		var route, reason any
		if pt.RouteID != "" {
			route = pt.RouteID
		}
		if pt.Reason != "" {
			reason = pt.Reason
		}
		prows = append(prows, []any{vin, t.ID, t.Started, at, route, num(t.WhPerKm), num(pt.Normalised),
			num(t.OutsideC), num(t.TyreBar), pt.Used, reason, num(pt.Huber)})
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"route_efficiency_points"},
		[]string{"vin", "trip_id", "started", "computed_at", "route_id", "wh_per_km", "normalised_wh_per_km",
			"outside_temp_c", "tyre_pressure_bar", "used", "reject_reason", "huber_weight"}, pgx.CopyFromRows(prows)); err != nil {
		return fmt.Errorf("copy points: %w", err)
	}
	var crows [][]any
	seen := map[string]bool{}
	for _, c := range res.Curve {
		k := c.RouteID + c.T.String()
		if seen[k] {
			continue
		}
		seen[k] = true
		crows = append(crows, []any{vin, c.RouteID, c.T, at, c.Fitted, num(c.Lo), num(c.Hi)})
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"route_efficiency_curve"},
		[]string{"vin", "route_id", "ts", "computed_at", "fitted_wh_per_km", "lo_wh_per_km", "hi_wh_per_km"},
		pgx.CopyFromRows(crows)); err != nil {
		return fmt.Errorf("copy curve: %w", err)
	}
	return tx.Commit(ctx)
}

func cond(ok bool, v float64) any {
	if !ok || math.IsNaN(v) || math.IsInf(v, 0) {
		return nil
	}
	return v
}
