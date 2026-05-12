// Package postgres implements a telemetry.Producer that writes streamed
// records to PostgreSQL + TimescaleDB. It expects the schema in
// deploy/sql/001_schema.sql to be loaded.
package postgres

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	logrus "github.com/teslamotors/fleet-telemetry/logger"
	"github.com/teslamotors/fleet-telemetry/metrics"
	"github.com/teslamotors/fleet-telemetry/metrics/adapter"
	"github.com/teslamotors/fleet-telemetry/protos"
	"github.com/teslamotors/fleet-telemetry/server/airbrake"
	"github.com/teslamotors/fleet-telemetry/telemetry"
)

// Metrics for this dispatcher.
type Metrics struct {
	insertCount      adapter.Counter
	rowCount         adapter.Counter
	errorCount       adapter.Counter
	reliableAckCount adapter.Counter
}

var (
	metricsRegistry Metrics
	metricsOnce     sync.Once
)

// Producer writes records to TimescaleDB.
type Producer struct {
	ctx                context.Context
	pool               *pgxpool.Pool
	logger             *logrus.Logger
	airbrakeHandler    *airbrake.Handler
	ackChan            chan *telemetry.Record
	reliableAckTxTypes map[string]interface{}
	knownVins          sync.Map // vin -> struct{}; prevents repeated vehicle metadata upserts
}

// NewProducer constructs a Producer and verifies it can reach the database.
func NewProducer(
	ctx context.Context,
	cfg *Config,
	metricsCollector metrics.MetricCollector,
	airbrakeHandler *airbrake.Handler,
	ackChan chan *telemetry.Record,
	reliableAckTxTypes map[string]interface{},
	logger *logrus.Logger,
) (telemetry.Producer, error) {
	if cfg == nil || cfg.ConnString == "" {
		return nil, fmt.Errorf("postgres dispatcher: conn_string is required")
	}
	registerMetricsOnce(metricsCollector)

	pgcfg, err := pgxpool.ParseConfig(cfg.ConnString)
	if err != nil {
		return nil, fmt.Errorf("postgres dispatcher: parse conn_string: %w", err)
	}
	if cfg.MaxConns > 0 {
		pgcfg.MaxConns = cfg.MaxConns
	}
	if cfg.MinConns > 0 {
		pgcfg.MinConns = cfg.MinConns
	}

	pool, err := pgxpool.NewWithConfig(ctx, pgcfg)
	if err != nil {
		return nil, fmt.Errorf("postgres dispatcher: connect: %w", err)
	}

	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("postgres dispatcher: ping: %w", err)
	}

	return &Producer{
		ctx:                ctx,
		pool:               pool,
		logger:             logger,
		airbrakeHandler:    airbrakeHandler,
		ackChan:            ackChan,
		reliableAckTxTypes: reliableAckTxTypes,
	}, nil
}

// Close releases the connection pool.
func (p *Producer) Close() error {
	if p.pool != nil {
		p.pool.Close()
		p.pool = nil
	}
	return nil
}

// ReportError to airbrake and logger.
func (p *Producer) ReportError(message string, err error, logInfo logrus.LogInfo) {
	p.airbrakeHandler.ReportLogMessage(logrus.ERROR, message, err, logInfo)
	p.logger.ErrorLog(message, err, logInfo)
}

// ProcessReliableAck signals downstream when reliable_ack is configured for this tx type.
func (p *Producer) ProcessReliableAck(rec *telemetry.Record) {
	if _, ok := p.reliableAckTxTypes[rec.TxType]; ok {
		p.ackChan <- rec
		metricsRegistry.reliableAckCount.Inc(map[string]string{"record_type": rec.TxType})
	}
}

// Produce dispatches a single record to the appropriate table.
func (p *Producer) Produce(rec *telemetry.Record) {
	if p.ctx.Err() != nil {
		return
	}
	labels := map[string]string{"record_type": rec.TxType}

	var err error
	switch rec.TxType {
	case "V":
		err = p.writePayload(rec)
	case "alerts":
		err = p.writeAlerts(rec)
	case "errors":
		err = p.writeErrors(rec)
	case "connectivity":
		err = p.writeConnectivity(rec)
	default:
		// Unknown tx type — log once and acknowledge.
		p.logger.Log(logrus.DEBUG, "postgres_skip_unknown_tx_type", logrus.LogInfo{"tx_type": rec.TxType})
		p.ProcessReliableAck(rec)
		return
	}

	if err != nil {
		metricsRegistry.errorCount.Inc(labels)
		p.ReportError("postgres_dispatch_error", err, logrus.LogInfo{"tx_type": rec.TxType, "vin": rec.Vin})
		return
	}

	metricsRegistry.insertCount.Inc(labels)
	p.ProcessReliableAck(rec)
}

// ============================================================
// Vehicle data ("V")
// ============================================================

type telemetryRow struct {
	ts        time.Time
	vin       string
	field     string
	numValue  *float64
	strValue  *string
	geoLngLat *[2]float64 // [lng, lat]
}

func (p *Producer) writePayload(rec *telemetry.Record) error {
	msg, ok := rec.GetProtoMessage().(*protos.Payload)
	if !ok || msg == nil {
		return fmt.Errorf("expected *protos.Payload, got %T", rec.GetProtoMessage())
	}
	return p.insertPayload(msg, rec.Vin)
}

// insertPayload writes a parsed *protos.Payload to TimescaleDB. Split out
// from writePayload so tests can drive it directly without constructing a
// telemetry.Record (which requires a BinarySerializer).
func (p *Producer) insertPayload(msg *protos.Payload, vinFallback string) error {
	ts := msg.GetCreatedAt().AsTime()
	if ts.IsZero() {
		ts = time.Now().UTC()
	}
	vin := msg.GetVin()
	if vin == "" {
		vin = vinFallback
	}

	rows := make([]telemetryRow, 0, len(msg.GetData()))
	var carType string
	for _, datum := range msg.GetData() {
		if datum == nil || datum.Value == nil {
			continue
		}
		fieldName := protos.Field_name[int32(datum.GetKey().Number())]
		if fieldName == "" {
			continue
		}
		// Capture CarType for vehicle metadata detection.
		if fieldName == "CarType" {
			if s, ok := stringerEnum(datum.Value.Value); ok {
				carType = s
			}
		}
		rows = append(rows, datumToRows(ts, vin, fieldName, datum.Value.Value)...)
	}
	if len(rows) == 0 {
		return nil
	}

	// Detect vehicle metadata once per VIN. CarType is authoritative;
	// VIN parsing is a deterministic fallback handled by the SQL function.
	if _, ok := p.knownVins.Load(vin); !ok {
		p.knownVins.Store(vin, struct{}{})
		if _, err := p.pool.Exec(p.ctx,
			"SELECT upsert_vehicle_from_telemetry($1, $2)", vin, carType,
		); err != nil {
			// Non-fatal: telemetry must still be written even if metadata
			// upsert fails (e.g. function not yet deployed).
			p.logger.Log(logrus.DEBUG, "vehicle_metadata_upsert_skipped",
				logrus.LogInfo{"vin": vin, "err": err.Error()})
		}
	}

	// pgx CopyFrom can't write geography columns from text without a staging
	// table, so use a SendBatch of upserts. For 30-second streaming volumes
	// this is well under a millisecond per row.
	conn, err := p.pool.Acquire(p.ctx)
	if err != nil {
		return err
	}
	defer conn.Release()

	batch := &pgx.Batch{}
	for _, r := range rows {
		var geoArg any
		if r.geoLngLat != nil {
			geoArg = fmt.Sprintf("SRID=4326;POINT(%.7f %.7f)", r.geoLngLat[0], r.geoLngLat[1])
		}
		batch.Queue(`
			INSERT INTO telemetry (ts, vin, field, num_value, str_value, geo_value)
			VALUES ($1, $2, $3, $4, $5, $6::geography)
			ON CONFLICT (ts, vin, field) DO UPDATE SET
				num_value = COALESCE(EXCLUDED.num_value, telemetry.num_value),
				str_value = COALESCE(EXCLUDED.str_value, telemetry.str_value),
				geo_value = COALESCE(EXCLUDED.geo_value, telemetry.geo_value)
		`, r.ts, r.vin, r.field, r.numValue, r.strValue, geoArg)
	}
	br := conn.SendBatch(p.ctx, batch)
	defer br.Close()
	for range rows {
		if _, err := br.Exec(); err != nil {
			return err
		}
	}
	metricsRegistry.rowCount.Add(int64(len(rows)), map[string]string{"record_type": "V"})
	return nil
}

// datumToRows converts a single Datum's oneof value into 1+ telemetry rows.
// Composite values (Door, TireLocation) expand into one row per leaf.
func datumToRows(ts time.Time, vin, field string, v interface{}) []telemetryRow {
	if v == nil {
		return nil
	}
	switch x := v.(type) {

	// numeric
	case *protos.Value_IntValue:
		f := float64(x.IntValue)
		return []telemetryRow{{ts: ts, vin: vin, field: field, numValue: &f}}
	case *protos.Value_LongValue:
		f := float64(x.LongValue)
		return []telemetryRow{{ts: ts, vin: vin, field: field, numValue: &f}}
	case *protos.Value_FloatValue:
		f := float64(x.FloatValue)
		return []telemetryRow{{ts: ts, vin: vin, field: field, numValue: &f}}
	case *protos.Value_DoubleValue:
		f := x.DoubleValue
		return []telemetryRow{{ts: ts, vin: vin, field: field, numValue: &f}}

	// strings & bools
	case *protos.Value_StringValue:
		s := x.StringValue
		return []telemetryRow{{ts: ts, vin: vin, field: field, strValue: &s}}
	case *protos.Value_BooleanValue:
		s := boolStr(x.BooleanValue)
		return []telemetryRow{{ts: ts, vin: vin, field: field, strValue: &s}}
	case *protos.Value_Invalid:
		s := "invalid"
		return []telemetryRow{{ts: ts, vin: vin, field: field, strValue: &s}}

	// location → PostGIS POINT
	case *protos.Value_LocationValue:
		geo := [2]float64{x.LocationValue.GetLongitude(), x.LocationValue.GetLatitude()}
		// Also store a string form for legacy "Location" consumers.
		s := fmt.Sprintf("(%.7f, %.7f)", x.LocationValue.GetLatitude(), x.LocationValue.GetLongitude())
		return []telemetryRow{{ts: ts, vin: vin, field: field, strValue: &s, geoLngLat: &geo}}

	// composite — expand to one row per leaf with a synthetic field name
	case *protos.Value_DoorValue:
		d := x.DoorValue
		return expandBools(ts, vin, field, map[string]bool{
			"DriverFront":    d.DriverFront,
			"PassengerFront": d.PassengerFront,
			"DriverRear":     d.DriverRear,
			"PassengerRear":  d.PassengerRear,
			"TrunkFront":     d.TrunkFront,
			"TrunkRear":      d.TrunkRear,
		})
	case *protos.Value_TireLocationValue:
		t := x.TireLocationValue
		return expandBools(ts, vin, field, map[string]bool{
			"FrontLeft":  t.FrontLeft,
			"FrontRight": t.FrontRight,
			"RearLeft":   t.RearLeft,
			"RearRight":  t.RearRight,
		})

	case *protos.Value_TimeValue:
		s := fmt.Sprintf("%02d:%02d:%02d",
			x.TimeValue.GetHour(), x.TimeValue.GetMinute(), x.TimeValue.GetSecond())
		return []telemetryRow{{ts: ts, vin: vin, field: field, strValue: &s}}
	}

	// All remaining cases are stringer-style enums. Use protoreflect via the
	// concrete types' String() method by routing through fmt.Stringer.
	if s, ok := stringerEnum(v); ok {
		return []telemetryRow{{ts: ts, vin: vin, field: field, strValue: &s}}
	}
	return nil
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func expandBools(ts time.Time, vin, baseField string, m map[string]bool) []telemetryRow {
	out := make([]telemetryRow, 0, len(m))
	for k, b := range m {
		s := boolStr(b)
		out = append(out, telemetryRow{
			ts:       ts,
			vin:      vin,
			field:    baseField + "_" + k,
			strValue: &s,
		})
	}
	return out
}

// stringerEnum extracts the .String() form from any of the many enum-flavored
// oneof wrappers in protos.Value. We use a switch to avoid reflection cost on
// hot path for values we already handled above.
func stringerEnum(v interface{}) (string, bool) {
	switch x := v.(type) {
	case *protos.Value_ChargingValue:
		return x.ChargingValue.String(), true
	case *protos.Value_ShiftStateValue:
		return x.ShiftStateValue.String(), true
	case *protos.Value_LaneAssistLevelValue:
		return x.LaneAssistLevelValue.String(), true
	case *protos.Value_ScheduledChargingModeValue:
		return x.ScheduledChargingModeValue.String(), true
	case *protos.Value_SentryModeStateValue:
		return x.SentryModeStateValue.String(), true
	case *protos.Value_SpeedAssistLevelValue:
		return x.SpeedAssistLevelValue.String(), true
	case *protos.Value_BmsStateValue:
		return x.BmsStateValue.String(), true
	case *protos.Value_BuckleStatusValue:
		return x.BuckleStatusValue.String(), true
	case *protos.Value_CarTypeValue:
		return x.CarTypeValue.String(), true
	case *protos.Value_ChargePortValue:
		return x.ChargePortValue.String(), true
	case *protos.Value_ChargePortLatchValue:
		return x.ChargePortLatchValue.String(), true
	case *protos.Value_DriveInverterStateValue:
		return x.DriveInverterStateValue.String(), true
	case *protos.Value_HvilStatusValue:
		return x.HvilStatusValue.String(), true
	case *protos.Value_WindowStateValue:
		return x.WindowStateValue.String(), true
	case *protos.Value_SeatFoldPositionValue:
		return x.SeatFoldPositionValue.String(), true
	case *protos.Value_TractorAirStatusValue:
		return x.TractorAirStatusValue.String(), true
	case *protos.Value_FollowDistanceValue:
		return x.FollowDistanceValue.String(), true
	case *protos.Value_ForwardCollisionSensitivityValue:
		return x.ForwardCollisionSensitivityValue.String(), true
	case *protos.Value_GuestModeMobileAccessValue:
		return x.GuestModeMobileAccessValue.String(), true
	case *protos.Value_TrailerAirStatusValue:
		return x.TrailerAirStatusValue.String(), true
	case *protos.Value_DetailedChargeStateValue:
		return x.DetailedChargeStateValue.String(), true
	case *protos.Value_HvacAutoModeValue:
		return x.HvacAutoModeValue.String(), true
	case *protos.Value_CabinOverheatProtectionModeValue:
		return x.CabinOverheatProtectionModeValue.String(), true
	case *protos.Value_CabinOverheatProtectionTemperatureLimitValue:
		return x.CabinOverheatProtectionTemperatureLimitValue.String(), true
	case *protos.Value_DefrostModeValue:
		return x.DefrostModeValue.String(), true
	case *protos.Value_ClimateKeeperModeValue:
		return x.ClimateKeeperModeValue.String(), true
	case *protos.Value_HvacPowerValue:
		return x.HvacPowerValue.String(), true
	case *protos.Value_FastChargerValue:
		return x.FastChargerValue.String(), true
	case *protos.Value_CableTypeValue:
		return x.CableTypeValue.String(), true
	case *protos.Value_TonneauTentModeValue:
		return x.TonneauTentModeValue.String(), true
	case *protos.Value_TonneauPositionValue:
		return x.TonneauPositionValue.String(), true
	case *protos.Value_PowershareTypeValue:
		return x.PowershareTypeValue.String(), true
	case *protos.Value_PowershareStateValue:
		return x.PowershareStateValue.String(), true
	case *protos.Value_PowershareStopReasonValue:
		return x.PowershareStopReasonValue.String(), true
	case *protos.Value_DisplayStateValue:
		return x.DisplayStateValue.String(), true
	case *protos.Value_DistanceUnitValue:
		return x.DistanceUnitValue.String(), true
	case *protos.Value_TemperatureUnitValue:
		return x.TemperatureUnitValue.String(), true
	case *protos.Value_PressureUnitValue:
		return x.PressureUnitValue.String(), true
	case *protos.Value_ChargeUnitPreferenceValue:
		return x.ChargeUnitPreferenceValue.String(), true
	case *protos.Value_TurnSignalStateValue:
		return x.TurnSignalStateValue.String(), true
	case *protos.Value_MediaStatusValue:
		return x.MediaStatusValue.String(), true
	case *protos.Value_SunroofInstalledStateValue:
		return x.SunroofInstalledStateValue.String(), true
	}
	return "", false
}

// ============================================================
// Side-channel records: alerts / errors / connectivity
// ============================================================

func (p *Producer) writeAlerts(rec *telemetry.Record) error {
	msg, ok := rec.GetProtoMessage().(*protos.VehicleAlerts)
	if !ok || msg == nil {
		return fmt.Errorf("expected *protos.VehicleAlerts, got %T", rec.GetProtoMessage())
	}
	now := msg.GetCreatedAt().AsTime()
	if now.IsZero() {
		now = time.Now().UTC()
	}
	vin := rec.Vin
	for _, a := range msg.GetAlerts() {
		var startedAt, endedAt *time.Time
		if t := a.GetStartedAt(); t != nil {
			tt := t.AsTime()
			startedAt = &tt
		}
		if t := a.GetEndedAt(); t != nil {
			tt := t.AsTime()
			endedAt = &tt
		}
		_, err := p.pool.Exec(p.ctx, `
			INSERT INTO vehicle_alerts (ts, vin, name, audience, started_at, ended_at)
			VALUES ($1, $2, $3, $4, $5, $6)
		`, now, vin, a.GetName(), audienceList(a), startedAt, endedAt)
		if err != nil {
			return err
		}
	}
	return nil
}

func audienceList(a *protos.VehicleAlert) string {
	if a == nil {
		return ""
	}
	parts := a.GetAudiences()
	if len(parts) == 0 {
		return ""
	}
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += ","
		}
		out += p.String()
	}
	return out
}

func (p *Producer) writeErrors(rec *telemetry.Record) error {
	msg, ok := rec.GetProtoMessage().(*protos.VehicleErrors)
	if !ok || msg == nil {
		return fmt.Errorf("expected *protos.VehicleErrors, got %T", rec.GetProtoMessage())
	}
	now := msg.GetCreatedAt().AsTime()
	if now.IsZero() {
		now = time.Now().UTC()
	}
	for _, e := range msg.GetErrors() {
		var createdAt *time.Time
		if t := e.GetCreatedAt(); t != nil {
			tt := t.AsTime()
			createdAt = &tt
		}
		tagsJSON, _ := json.Marshal(e.GetTags())
		_, err := p.pool.Exec(p.ctx, `
			INSERT INTO vehicle_errors (ts, vin, name, body, tags, created_at)
			VALUES ($1, $2, $3, $4, $5, $6)
		`, now, rec.Vin, e.GetName(), e.GetBody(), string(tagsJSON), createdAt)
		if err != nil {
			return err
		}
	}
	return nil
}

func (p *Producer) writeConnectivity(rec *telemetry.Record) error {
	msg, ok := rec.GetProtoMessage().(*protos.VehicleConnectivity)
	if !ok || msg == nil {
		return fmt.Errorf("expected *protos.VehicleConnectivity, got %T", rec.GetProtoMessage())
	}
	ts := msg.GetCreatedAt().AsTime()
	if ts.IsZero() {
		ts = time.Now().UTC()
	}
	_, err := p.pool.Exec(p.ctx, `
		INSERT INTO vehicle_connectivity (ts, vin, status, network_interface, reason)
		VALUES ($1, $2, $3, $4, $5)
	`, ts, msg.GetVin(), msg.GetStatus().String(), msg.GetNetworkInterface(), "")
	return err
}

// ============================================================
// metrics
// ============================================================

func registerMetrics(c metrics.MetricCollector) {
	metricsRegistry.insertCount = c.RegisterCounter(adapter.CollectorOptions{
		Name:   "postgres_insert_total",
		Help:   "Number of records dispatched to PostgreSQL.",
		Labels: []string{"record_type"},
	})
	metricsRegistry.rowCount = c.RegisterCounter(adapter.CollectorOptions{
		Name:   "postgres_row_total",
		Help:   "Number of telemetry rows written to PostgreSQL.",
		Labels: []string{"record_type"},
	})
	metricsRegistry.errorCount = c.RegisterCounter(adapter.CollectorOptions{
		Name:   "postgres_err",
		Help:   "Number of errors while writing to PostgreSQL.",
		Labels: []string{"record_type"},
	})
	metricsRegistry.reliableAckCount = c.RegisterCounter(adapter.CollectorOptions{
		Name:   "postgres_reliable_ack_total",
		Help:   "Number of reliable acks emitted by the PostgreSQL dispatcher.",
		Labels: []string{"record_type"},
	})
}

func registerMetricsOnce(c metrics.MetricCollector) {
	metricsOnce.Do(func() { registerMetrics(c) })
}
