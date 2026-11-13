package postgres

import (
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/teslamotors/fleet-telemetry/protos"
)

func TestDatumToRows_NumericTypes(t *testing.T) {
	ts := time.Unix(1700000000, 0).UTC()
	cases := []struct {
		name  string
		val   interface{}
		want  float64
		field string
	}{
		{"int", &protos.Value_IntValue{IntValue: 42}, 42, "VehicleSpeed"},
		{"long", &protos.Value_LongValue{LongValue: 123456789}, 123456789, "Odometer"},
		{"float", &protos.Value_FloatValue{FloatValue: 3.5}, 3.5, "BatteryLevel"},
		{"double", &protos.Value_DoubleValue{DoubleValue: 99.99}, 99.99, "BatteryLevel"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rows := datumToRows(ts, "5YJ", tc.field, tc.val)
			if len(rows) != 1 {
				t.Fatalf("got %d rows, want 1", len(rows))
			}
			r := rows[0]
			if r.numValue == nil || *r.numValue != tc.want {
				t.Fatalf("num=%v, want %v", r.numValue, tc.want)
			}
			if r.strValue != nil || r.geoLngLat != nil {
				t.Fatalf("expected only numValue set, got str=%v geo=%v", r.strValue, r.geoLngLat)
			}
			if r.field != tc.field || r.vin != "5YJ" || !r.ts.Equal(ts) {
				t.Fatalf("metadata mismatch: %+v", r)
			}
		})
	}
}

func TestDatumToRows_String(t *testing.T) {
	rows := datumToRows(time.Now(), "VIN", "Gear", &protos.Value_StringValue{StringValue: "D"})
	if len(rows) != 1 || rows[0].strValue == nil || *rows[0].strValue != "D" {
		t.Fatalf("string row not produced: %+v", rows)
	}
}

func TestDatumToRows_Bool(t *testing.T) {
	rows := datumToRows(time.Now(), "VIN", "Locked", &protos.Value_BooleanValue{BooleanValue: true})
	if len(rows) != 1 || rows[0].strValue == nil || *rows[0].strValue != "true" {
		t.Fatalf("bool row not produced: %+v", rows)
	}
}

func TestDatumToRows_Location(t *testing.T) {
	loc := &protos.LocationValue{Latitude: 51.5074, Longitude: -0.1278}
	rows := datumToRows(time.Now(), "VIN", "Location", &protos.Value_LocationValue{LocationValue: loc})
	if len(rows) != 1 {
		t.Fatalf("want 1 row, got %d", len(rows))
	}
	r := rows[0]
	if r.geoLngLat == nil {
		t.Fatalf("geoLngLat not set")
	}
	if r.geoLngLat[0] != -0.1278 || r.geoLngLat[1] != 51.5074 {
		t.Fatalf("lng/lat order wrong: %v", r.geoLngLat)
	}
	if r.strValue == nil {
		t.Fatalf("legacy string form should also be present")
	}
}

func TestDatumToRows_Door_Expands(t *testing.T) {
	d := &protos.Doors{
		DriverFront: true, PassengerFront: false,
		DriverRear: true, PassengerRear: false,
		TrunkFront: false, TrunkRear: true,
	}
	rows := datumToRows(time.Now(), "VIN", "DoorState", &protos.Value_DoorValue{DoorValue: d})
	if len(rows) != 6 {
		t.Fatalf("want 6 rows (one per door), got %d", len(rows))
	}
	expect := map[string]string{
		"DoorState_DriverFront":    "true",
		"DoorState_PassengerFront": "false",
		"DoorState_DriverRear":     "true",
		"DoorState_PassengerRear":  "false",
		"DoorState_TrunkFront":     "false",
		"DoorState_TrunkRear":      "true",
	}
	got := map[string]string{}
	for _, r := range rows {
		got[r.field] = *r.strValue
	}
	for k, v := range expect {
		if got[k] != v {
			t.Errorf("%s: got %q, want %q", k, got[k], v)
		}
	}
}

func TestDatumToRows_Enum(t *testing.T) {
	rows := datumToRows(time.Now(), "VIN", "ChargeState",
		&protos.Value_DetailedChargeStateValue{
			DetailedChargeStateValue: protos.DetailedChargeStateValue_DetailedChargeStateCharging,
		})
	if len(rows) != 1 || rows[0].strValue == nil {
		t.Fatalf("enum row not produced: %+v", rows)
	}
	if got := *rows[0].strValue; got != "DetailedChargeStateCharging" {
		t.Fatalf("enum stringer mismatch: %q", got)
	}
}

func TestDatumToRows_NilValueReturnsNil(t *testing.T) {
	if rows := datumToRows(time.Now(), "VIN", "X", nil); rows != nil {
		t.Fatalf("expected nil for nil value, got %+v", rows)
	}
}

func TestBoolStr(t *testing.T) {
	if boolStr(true) != "true" || boolStr(false) != "false" {
		t.Fatal("boolStr broken")
	}
}

// ------------------------------------------------------------------
// Vehicle metadata detection helpers
// ------------------------------------------------------------------

func TestStringerEnum_CarType(t *testing.T) {
	val := &protos.Value_CarTypeValue{
		CarTypeValue: protos.CarTypeValue_CarTypeModelY,
	}
	s, ok := stringerEnum(val)
	if !ok {
		t.Fatal("expected stringerEnum to recognise CarTypeValue")
	}
	if s != "CarTypeModelY" {
		t.Fatalf("got %q, want CarTypeModelY", s)
	}
}

func TestStringerEnum_AllCarTypes(t *testing.T) {
	cases := []struct {
		val    protos.CarTypeValue
		expect string
	}{
		{protos.CarTypeValue_CarTypeModelS, "CarTypeModelS"},
		{protos.CarTypeValue_CarTypeModelX, "CarTypeModelX"},
		{protos.CarTypeValue_CarTypeModel3, "CarTypeModel3"},
		{protos.CarTypeValue_CarTypeModelY, "CarTypeModelY"},
		{protos.CarTypeValue_CarTypeSemiTruck, "CarTypeSemiTruck"},
		{protos.CarTypeValue_CarTypeCybertruck, "CarTypeCybertruck"},
		{protos.CarTypeValue_CarTypeUnknown, "CarTypeUnknown"},
	}
	for _, tc := range cases {
		t.Run(tc.expect, func(t *testing.T) {
			v := &protos.Value_CarTypeValue{CarTypeValue: tc.val}
			s, ok := stringerEnum(v)
			if !ok {
				t.Fatal("expected stringerEnum to recognise CarTypeValue")
			}
			if s != tc.expect {
				t.Fatalf("got %q, want %q", s, tc.expect)
			}
		})
	}
}

func TestKnownVinsCache(t *testing.T) {
	p := &Producer{}
	vin := "5YJ3E1EA8PF000001"

	// First access should miss
	if _, ok := p.knownVins.Load(vin); ok {
		t.Fatal("expected cache miss on first access")
	}

	// Store the VIN
	p.knownVins.Store(vin, struct{}{})

	// Second access should hit
	if _, ok := p.knownVins.Load(vin); !ok {
		t.Fatal("expected cache hit after storing")
	}

	// Different VIN should still miss
	if _, ok := p.knownVins.Load("7SAYGDEE9PF000002"); ok {
		t.Fatal("expected cache miss for different VIN")
	}
}

// ------------------------------------------------------------------
// Ingestion identity and determinism (I1, I3)
// ------------------------------------------------------------------

func TestStoredVin_PrefersCertificate(t *testing.T) {
	cases := []struct {
		cert, payload, want string
	}{
		{"5YJ3E1EA7NF000001", "5YJ3E1EA7NF000002", "5YJ3E1EA7NF000001"},
		{"5YJ3E1EA7NF000001", "", "5YJ3E1EA7NF000001"},
		{"", "5YJ3E1EA7NF000002", "5YJ3E1EA7NF000002"},
		{"", "", ""},
	}
	for _, tc := range cases {
		if got := storedVin(tc.cert, tc.payload); got != tc.want {
			t.Errorf("storedVin(%q, %q) = %q, want %q", tc.cert, tc.payload, got, tc.want)
		}
	}
}

func TestExpandBools_SortedOrder(t *testing.T) {
	ts := time.Unix(1700000000, 0).UTC()
	for i := 0; i < 20; i++ {
		rows := datumToRows(ts, "VIN", "DoorState", &protos.Value_DoorValue{DoorValue: &protos.Doors{DriverFront: true}})
		want := []string{
			"DoorState_DriverFront", "DoorState_DriverRear", "DoorState_PassengerFront",
			"DoorState_PassengerRear", "DoorState_TrunkFront", "DoorState_TrunkRear",
		}
		if len(rows) != len(want) {
			t.Fatalf("got %d rows", len(rows))
		}
		for j, r := range rows {
			if r.field != want[j] {
				t.Fatalf("iteration %d row %d: got %s, want %s", i, j, r.field, want[j])
			}
		}
	}
}

// ------------------------------------------------------------------
// Alert / error idempotency (P3)
// ------------------------------------------------------------------

func TestAlertRows_TsIsStartedAt(t *testing.T) {
	msgTime := time.Unix(1700000600, 0).UTC()
	started := time.Unix(1700000000, 0).UTC()
	msg := &protos.VehicleAlerts{
		CreatedAt: timestamppb.New(msgTime),
		Alerts: []*protos.VehicleAlert{
			{Name: "BMS_a001", StartedAt: timestamppb.New(started)},
			{Name: "NoStart_a001"},
		},
	}
	rows := alertRows(msg)
	if len(rows) != 2 {
		t.Fatalf("got %d rows, want 2", len(rows))
	}
	if !rows[0].ts.Equal(started) {
		t.Errorf("ts = %v, want started_at %v", rows[0].ts, started)
	}
	if rows[0].startedAt == nil || !rows[0].startedAt.Equal(started) {
		t.Errorf("startedAt = %v", rows[0].startedAt)
	}
	if !rows[1].ts.Equal(msgTime) {
		t.Errorf("alert without started_at: ts = %v, want message time %v", rows[1].ts, msgTime)
	}
	if rows[1].startedAt != nil || rows[1].endedAt != nil {
		t.Errorf("absent timestamps must stay nil: %+v", rows[1])
	}
}

func TestAlertRows_ResendIsStable(t *testing.T) {
	started := time.Unix(1700000000, 0).UTC()
	mk := func(msgSec int64) []alertRow {
		return alertRows(&protos.VehicleAlerts{
			CreatedAt: timestamppb.New(time.Unix(msgSec, 0)),
			Alerts:    []*protos.VehicleAlert{{Name: "DI_a005", StartedAt: timestamppb.New(started)}},
		})
	}
	a, b := mk(1700000100), mk(1700009999)
	if !a[0].ts.Equal(b[0].ts) {
		t.Fatalf("resend in a later message must produce the same ts: %v vs %v", a[0].ts, b[0].ts)
	}
}

func TestAlertRows_MergesDuplicatesKeepingEnd(t *testing.T) {
	started := time.Unix(1700000000, 0).UTC()
	ended := time.Unix(1700000300, 0).UTC()
	msg := &protos.VehicleAlerts{
		CreatedAt: timestamppb.New(time.Unix(1700000400, 0)),
		Alerts: []*protos.VehicleAlert{
			{Name: "CP_a007", StartedAt: timestamppb.New(started), EndedAt: timestamppb.New(ended)},
			{Name: "CP_a007", StartedAt: timestamppb.New(started)},
		},
	}
	rows := alertRows(msg)
	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1", len(rows))
	}
	if rows[0].endedAt == nil || !rows[0].endedAt.Equal(ended) {
		t.Fatalf("ended_at lost in merge: %v", rows[0].endedAt)
	}
}

func TestErrorRows_TsIsCreatedAt(t *testing.T) {
	created := time.Unix(1700000000, 0).UTC()
	msgTime := time.Unix(1700000500, 0).UTC()
	rows := errorRows(&protos.VehicleErrors{
		CreatedAt: timestamppb.New(msgTime),
		Errors: []*protos.VehicleError{
			{Name: "err_a", CreatedAt: timestamppb.New(created), Body: "x"},
			{Name: "err_a", CreatedAt: timestamppb.New(created), Body: "y"},
			{Name: "err_b"},
		},
	})
	if len(rows) != 2 {
		t.Fatalf("got %d rows, want 2", len(rows))
	}
	if !rows[0].ts.Equal(created) || rows[0].body != "y" {
		t.Errorf("row 0 = %+v", rows[0])
	}
	if !rows[1].ts.Equal(msgTime) {
		t.Errorf("error without created_at: ts = %v, want %v", rows[1].ts, msgTime)
	}
}

func TestUpsertSQL_ConflictTargets(t *testing.T) {
	// The ON CONFLICT targets must match the unique indexes created by
	// deploy/sql/034_alert_dedup.sql.
	for name, q := range map[string]string{"alerts": alertUpsertSQL, "errors": errorUpsertSQL} {
		if !strings.Contains(q, "ON CONFLICT (vin, name, ts)") {
			t.Errorf("%s upsert lost its conflict target", name)
		}
	}
	if !strings.Contains(alertUpsertSQL, "COALESCE(EXCLUDED.ended_at, vehicle_alerts.ended_at)") {
		t.Error("alert upsert must never reopen a closed alert")
	}
}
