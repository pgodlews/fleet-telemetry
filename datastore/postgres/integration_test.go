//go:build integration

// Integration tests for the postgres dispatcher.
//
// These tests require a Postgres+PostGIS+TimescaleDB instance with the
// schema in deploy/sql/{001,002}*.sql already loaded. Set TEST_PG_DSN to
// a libpq URL pointing at the test database, then:
//
//	go test -tags=integration ./datastore/postgres/...
//
// Recommended local setup:
//
//	docker compose -f deploy/docker-compose.yml up -d timescaledb
//	export TEST_PG_DSN='postgres://postgres:postgres@localhost:5432/tesla?sslmode=disable'
//	go test -tags=integration ./datastore/postgres/...
package postgres

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/types/known/timestamppb"

	logrus "github.com/teslamotors/fleet-telemetry/logger"
	"github.com/teslamotors/fleet-telemetry/metrics"
	"github.com/teslamotors/fleet-telemetry/protos"
	"github.com/teslamotors/fleet-telemetry/server/airbrake"
	"github.com/teslamotors/fleet-telemetry/telemetry"
)

func dsn(t *testing.T) string {
	t.Helper()
	d := os.Getenv("TEST_PG_DSN")
	if d == "" {
		t.Skip("TEST_PG_DSN not set; skipping integration test")
	}
	return d
}

func newTestProducer(t *testing.T) *Producer {
	t.Helper()
	logger, _ := logrus.NewBasicLogrusLogger("test")
	mc := metrics.NewCollector(nil, logger)
	ack := make(chan *telemetry.Record, 16)
	p, err := NewProducer(context.Background(), &Config{ConnString: dsn(t)}, mc, &airbrake.Handler{}, ack, nil, logger)
	if err != nil {
		t.Fatalf("NewProducer: %v", err)
	}
	t.Cleanup(func() { _ = p.Close() })
	return p.(*Producer)
}

func cleanVin(t *testing.T, vin string) {
	t.Helper()
	pool, err := pgxpool.New(context.Background(), dsn(t))
	if err != nil {
		t.Fatalf("clean pool: %v", err)
	}
	defer pool.Close()
	if _, err := pool.Exec(context.Background(), `DELETE FROM telemetry WHERE vin=$1`, vin); err != nil {
		t.Fatalf("clean delete: %v", err)
	}
}

func TestProducer_PingsDB(t *testing.T) {
	_ = newTestProducer(t)
}

func TestProducer_WritesPayload(t *testing.T) {
	const vin = "INTEG_TESTVIN_001"
	cleanVin(t, vin)
	p := newTestProducer(t)

	ts := time.Now().UTC().Truncate(time.Second)
	payload := &protos.Payload{
		Vin:       vin,
		CreatedAt: timestamppb.New(ts),
		Data: []*protos.Datum{
			{Key: protos.Field_BatteryLevel, Value: &protos.Value{Value: &protos.Value_FloatValue{FloatValue: 73.4}}},
			{Key: protos.Field_VehicleSpeed, Value: &protos.Value{Value: &protos.Value_IntValue{IntValue: 65}}},
			{Key: protos.Field_Gear, Value: &protos.Value{Value: &protos.Value_StringValue{StringValue: "D"}}},
			{Key: protos.Field_Locked, Value: &protos.Value{Value: &protos.Value_BooleanValue{BooleanValue: true}}},
			{Key: protos.Field_Location, Value: &protos.Value{Value: &protos.Value_LocationValue{LocationValue: &protos.LocationValue{Latitude: 51.5, Longitude: -0.13}}}},
		},
	}

	if err := p.insertPayload(payload, vin); err != nil {
		t.Fatalf("insertPayload: %v", err)
	}

	pool, _ := pgxpool.New(context.Background(), dsn(t))
	defer pool.Close()

	var n int
	if err := pool.QueryRow(context.Background(),
		`SELECT COUNT(*) FROM telemetry WHERE vin=$1 AND ts=$2`, vin, ts).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 5 {
		t.Fatalf("expected 5 rows, got %d", n)
	}

	var soc float64
	if err := pool.QueryRow(context.Background(),
		`SELECT num_value FROM telemetry WHERE vin=$1 AND field='BatteryLevel'`, vin).Scan(&soc); err != nil {
		t.Fatalf("soc: %v", err)
	}
	if soc < 73.39 || soc > 73.41 {
		t.Fatalf("soc round-trip: got %v", soc)
	}

	var gear string
	if err := pool.QueryRow(context.Background(),
		`SELECT str_value FROM telemetry WHERE vin=$1 AND field='Gear'`, vin).Scan(&gear); err != nil {
		t.Fatalf("gear: %v", err)
	}
	if gear != "D" {
		t.Fatalf("gear round-trip: got %q", gear)
	}

	var locked string
	if err := pool.QueryRow(context.Background(),
		`SELECT str_value FROM telemetry WHERE vin=$1 AND field='Locked'`, vin).Scan(&locked); err != nil {
		t.Fatalf("locked: %v", err)
	}
	if locked != "true" {
		t.Fatalf("locked round-trip: got %q", locked)
	}

	// PostGIS round-trip — verify ST_Y/ST_X return our lat/lng.
	var lat, lng float64
	if err := pool.QueryRow(context.Background(),
		`SELECT ST_Y(geo_value::geometry), ST_X(geo_value::geometry) FROM telemetry WHERE vin=$1 AND field='Location'`, vin).Scan(&lat, &lng); err != nil {
		t.Fatalf("geo: %v", err)
	}
	if lat < 51.499 || lat > 51.501 || lng < -0.131 || lng > -0.129 {
		t.Fatalf("geo round-trip: lat=%v lng=%v", lat, lng)
	}
}

func TestProducer_DoorValueExpands(t *testing.T) {
	const vin = "INTEG_TESTVIN_002"
	cleanVin(t, vin)
	p := newTestProducer(t)

	ts := time.Now().UTC().Truncate(time.Second)
	payload := &protos.Payload{
		Vin:       vin,
		CreatedAt: timestamppb.New(ts),
		Data: []*protos.Datum{
			{Key: protos.Field_DoorState, Value: &protos.Value{Value: &protos.Value_DoorValue{DoorValue: &protos.Doors{
				DriverFront: true, PassengerFront: false,
				DriverRear: false, PassengerRear: true,
				TrunkFront: false, TrunkRear: false,
			}}}},
		},
	}

	if err := p.insertPayload(payload, vin); err != nil {
		t.Fatalf("insertPayload: %v", err)
	}

	pool, _ := pgxpool.New(context.Background(), dsn(t))
	defer pool.Close()

	rows, err := pool.Query(context.Background(),
		`SELECT field, str_value FROM telemetry WHERE vin=$1 ORDER BY field`, vin)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()

	got := map[string]string{}
	for rows.Next() {
		var f, v string
		if err := rows.Scan(&f, &v); err != nil {
			t.Fatalf("scan: %v", err)
		}
		got[f] = v
	}
	want := map[string]string{
		"DoorState_DriverFront":    "true",
		"DoorState_PassengerFront": "false",
		"DoorState_DriverRear":     "false",
		"DoorState_PassengerRear":  "true",
		"DoorState_TrunkFront":     "false",
		"DoorState_TrunkRear":      "false",
	}
	if len(got) != len(want) {
		t.Fatalf("row count: got %d want %d", len(got), len(want))
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: got %q want %q", k, got[k], v)
		}
	}
}
