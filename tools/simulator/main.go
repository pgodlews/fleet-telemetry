// Phase-1 simulator: writes synthetic Tesla telemetry directly to TimescaleDB,
// bypassing the mTLS vehicle path. Run alongside the dashboards while the
// real Tesla integration is being set up.
//
// Coverage: all 239 streaming fields from fleet_streaming_fields.xlsx (embedded
// as fields.json). Curated values are produced for the fields that drive the
// dashboards (BatteryLevel, Power, VehicleSpeed, Gear, ChargeState, Location,
// pack temps, TPMS, user prefs, …). Every other field gets a type-appropriate
// synthetic value (sine + jitter for reals, slow toggles for booleans, a stable
// enum string, etc.) so the All Stats dashboard isn't sparse.
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"flag"
	"fmt"
	"hash/fnv"
	"log"
	"math"
	"math/rand"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed fields.json
var fieldsJSON []byte

type fieldDef struct {
	Field    string `json:"field"`
	Category string `json:"category"`
	Type     string `json:"type"`
	Desc     string `json:"desc"`
}

type sample struct {
	field string
	num   *float64
	str   *string
	geo   *[2]float64 // [lng, lat]
}

func numSamp(field string, v float64) sample { f := v; return sample{field: field, num: &f} }
func strSamp(field, v string) sample         { s := v; return sample{field: field, str: &s} }
func geoSamp(field string, lng, lat float64) sample {
	return sample{field: field, geo: &[2]float64{lng, lat}}
}

// scheduleSegment describes one continuous block of time in a day.
type scheduleSegment struct {
	startSec int    // seconds from midnight
	endSec   int    // seconds from midnight
	mode     string // "Sleep" | "Drive" | "Park" | "Charge"
	subType  string // e.g. "morning_commute", "work", "home_charge"
}

// daySchedule holds the pre-computed plan for one 24 h day.
type daySchedule struct {
	dayType  string            // "commute" | "idle" | "trip"
	segments []scheduleSegment
}

// state holds the per-VIN simulation state.
type state struct {
	vin         string
	mode        string    // current mode (may differ from schedule during transitions)
	modeStarted time.Time // when current mode began
	soc         float64   // %
	odo         float64   // km
	speed       float64   // km/h
	power       float64   // kW (positive = discharge, negative = charge/regen)
	headingT    float64   // 0..2π for the location loop
	lastWritten time.Time // last time we emitted a sample
	lastAdvanced time.Time // last time advance() was called (for energy accounting)

	// Cumulative energy counters (kWh)
	lifetimeEnergyUsed        float64
	lifetimeEnergyUsedDrive   float64
	lifetimeEnergyGainedRegen float64

	// Vehicle model (detected from VIN position 4)
	model       string // "3", "Y", "S", "X", "CT", "Semi"
	carType     string // e.g. "CarTypeModel3"
	motorConfig string // "RWD", "Dual Motor", "Performance", "Tri Motor"

	// Schedule
	schedule     daySchedule
	scheduleDay  int // yyyymmdd for which schedule was built
	rng          *rand.Rand
	lastSubType  string // sub-type of the last segment we were in

	// Air-suspension state (only used when has_air_suspension = true)
	suspensionHeightFL   float64 // mm
	suspensionHeightFR   float64 // mm
	suspensionHeightRL   float64 // mm
	suspensionHeightRR   float64 // mm
	suspensionMode       string  // Standard | Comfort | Sport | OffRoad | Entry
	compressorState      string  // On | Off
	compressorCycleCount int     // synthetic counter for failure injection

	// Cybertruck-specific state
	tonneauOpenPct    float64
	tonneauPosition   string // Closed | Open | Moving | Stuck
	tonneauTentMode   string // Off | TentMode
	powersharePowerKW float64
	powershareStatus  string // Inactive | Active | Fault
	powershareType    string // None | HomeBackup | Camp
	powershareHoursLeft float64

	// Tri-motor state (Cyberbeast only)
	invTempREL      float64
	invTempRER      float64
	heatsinkTempREL float64
	heatsinkTempRER float64
	statorTempREL   float64
	statorTempRER   float64
	axleSpeedREL    float64
	axleSpeedRER    float64
	regenTorqueREL  float64
	regenTorqueRER  float64
	accelTorqueREL  float64
	accelTorqueRER  float64
	motorCurrentREL float64
	motorCurrentRER float64
	vBatREL         float64
	vBatRER         float64

	// Dual-motor state (only used when motor_config != "RWD")
	invTempF      float64
	invTempR      float64
	heatsinkTempF float64
	heatsinkTempR float64
	statorTempF   float64
	statorTempR   float64
	axleSpeedF    float64
	axleSpeedR    float64
	regenTorqueF  float64
	regenTorqueR  float64
	accelTorqueF  float64
	accelTorqueR  float64
	torqueCmd     float64
	motorCurrentF float64
	motorCurrentR float64
	vBatF         float64
	vBatR         float64
}

// ------------------------------------------------------------------
// VIN helpers
// ------------------------------------------------------------------

func detectModelFromVin(vin string) (model, carType string) {
	if len(vin) >= 4 {
		switch vin[3] {
		case 'S':
			return "S", "CarTypeModelS"
		case 'X':
			return "X", "CarTypeModelX"
		case '3':
			return "3", "CarTypeModel3"
		case 'Y':
			return "Y", "CarTypeModelY"
		case 'C':
			return "CT", "CarTypeCybertruck"
		case 'T':
			return "Semi", "CarTypeSemiTruck"
		}
	}
	return "3", "CarTypeModel3"
}

func detectMotorConfigFromVin(vin string) string {
	if len(vin) >= 8 {
		switch vin[7] {
		case 'A', 'B':
			return "RWD"
		case 'C', 'D', 'E':
			return "Dual Motor"
		case 'F', 'G':
			return "Performance"
		case 'H', 'J':
			return "Tri Motor"
		}
	}
	return "RWD"
}

// vinDaySeed returns a deterministic int64 seed from a VIN and a calendar day.
func vinDaySeed(vin string, day time.Time) int64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(vin))
	_, _ = h.Write([]byte(day.Format("20060102")))
	return int64(h.Sum64())
}

// ------------------------------------------------------------------
// Daily schedule builder
// ------------------------------------------------------------------

func buildSchedule(vin string, day time.Time) daySchedule {
	seed := vinDaySeed(vin, day)
	rng := rand.New(rand.NewSource(seed))

	// Determine day type (deterministic from seed)
	r := rng.Float64()
	var dayType string
	switch {
	case r < 0.60:
		dayType = "commute"
	case r < 0.90:
		dayType = "idle"
	default:
		dayType = "trip"
	}

	var segs []scheduleSegment
	switch dayType {
	case "commute":
		// Wake ~06:30-07:30, morning drive ~30-60 min, work ~8-10 h,
		// evening drive ~30-60 min, charge ~1-2 h, sleep.
		wake := 6*3600 + rng.Intn(3600)
		morningDrive := wake + 15*60 + rng.Intn(30*60)
		eveningStart := morningDrive + 8*3600 + rng.Intn(2*3600)
		eveningDrive := eveningStart + 15*60 + rng.Intn(45*60)
		chargeEnd := eveningDrive + 45*60 + rng.Intn(75*60)
		if chargeEnd > 24*3600 {
			chargeEnd = 24*3600
		}

		segs = append(segs, scheduleSegment{0, wake, "Sleep", "night"})
		segs = append(segs, scheduleSegment{wake, morningDrive, "Drive", "morning_commute"})
		segs = append(segs, scheduleSegment{morningDrive, eveningStart, "Park", "work"})
		segs = append(segs, scheduleSegment{eveningStart, eveningDrive, "Drive", "evening_commute"})
		segs = append(segs, scheduleSegment{eveningDrive, chargeEnd, "Charge", "home_charge"})
		segs = append(segs, scheduleSegment{chargeEnd, 24 * 3600, "Sleep", "night"})

	case "idle":
		// Mostly asleep; maybe 1-2 short errands (10-30 min each)
		wake1 := 9*3600 + rng.Intn(3*3600)
		err1End := wake1 + 10*60 + rng.Intn(20*60)
		wake2 := err1End + 3*3600 + rng.Intn(4*3600)
		err2End := wake2 + 10*60 + rng.Intn(20*60)
		if err2End > 24*3600 {
			err2End = 24 * 3600
		}

		segs = append(segs, scheduleSegment{0, wake1, "Sleep", "night"})
		segs = append(segs, scheduleSegment{wake1, err1End, "Drive", "errand"})
		segs = append(segs, scheduleSegment{err1End, wake2, "Sleep", "midday"})
		if wake2 < 24*3600 {
			segs = append(segs, scheduleSegment{wake2, err2End, "Drive", "errand"})
			if err2End < 24*3600 {
				segs = append(segs, scheduleSegment{err2End, 24 * 3600, "Sleep", "night"})
			}
		}

	case "trip":
		// Long driving day with 1-2 DC fast-charge stops
		wake := 5*3600 + rng.Intn(2*3600)
		leg1 := wake + 3*3600 + rng.Intn(2*3600)
		charge1 := leg1 + 20*60 + rng.Intn(25*60)
		leg2 := charge1 + 2*3600 + rng.Intn(2*3600)
		charge2 := leg2 + 20*60 + rng.Intn(25*60)
		leg3End := charge2 + 2*3600 + rng.Intn(2*3600)
		if leg3End > 24*3600 {
			leg3End = 24 * 3600
		}

		segs = append(segs, scheduleSegment{0, wake, "Sleep", "night"})
		segs = append(segs, scheduleSegment{wake, leg1, "Drive", "trip_leg"})
		segs = append(segs, scheduleSegment{leg1, charge1, "Charge", "dc_fast"})
		segs = append(segs, scheduleSegment{charge1, leg2, "Drive", "trip_leg"})
		if charge2 <= 24*3600 {
			segs = append(segs, scheduleSegment{leg2, charge2, "Charge", "dc_fast"})
			if leg3End <= 24*3600 {
				segs = append(segs, scheduleSegment{charge2, leg3End, "Drive", "trip_leg"})
				if leg3End < 24*3600 {
					segs = append(segs, scheduleSegment{leg3End, 24 * 3600, "Sleep", "night"})
				}
			}
		}
	}

	// Coalesce adjacent same-mode segments (e.g. Sleep + Sleep)
	var coalesced []scheduleSegment
	for _, seg := range segs {
		if len(coalesced) > 0 && coalesced[len(coalesced)-1].mode == seg.mode {
			coalesced[len(coalesced)-1].endSec = seg.endSec
		} else {
			coalesced = append(coalesced, seg)
		}
	}
	return daySchedule{dayType: dayType, segments: coalesced}
}

// segmentAt returns the schedule segment covering the given time-of-day.
func (ds daySchedule) segmentAt(t time.Time) scheduleSegment {
	sec := t.Hour()*3600 + t.Minute()*60 + t.Second()
	for _, seg := range ds.segments {
		if sec >= seg.startSec && sec < seg.endSec {
			return seg
		}
	}
	// Fallback to last segment if exactly on boundary
	if len(ds.segments) > 0 {
		return ds.segments[len(ds.segments)-1]
	}
	return scheduleSegment{mode: "Sleep"}
}

// nextTransition returns the next time after t when the schedule changes.
func (ds daySchedule) nextTransition(t time.Time) time.Time {
	sec := t.Hour()*3600 + t.Minute()*60 + t.Second()
	for _, seg := range ds.segments {
		if sec < seg.endSec {
			// Transition at endSec
			base := t.Truncate(24 * time.Hour)
			return base.Add(time.Duration(seg.endSec) * time.Second)
		}
	}
	// After last segment -> next day first transition
	return t.Truncate(24*time.Hour).Add(24 * time.Hour)
}

// ------------------------------------------------------------------
// State advance
// ------------------------------------------------------------------

func (s *state) ensureSchedule(t time.Time) {
	day := t.Year()*10000 + int(t.Month())*100 + t.Day()
	if s.scheduleDay != day {
		s.schedule = buildSchedule(s.vin, t)
		s.scheduleDay = day
		s.rng = rand.New(rand.NewSource(vinDaySeed(s.vin, t)))
	}
}

func (s *state) advance(t time.Time) {
	s.ensureSchedule(t)

	dtHours := 30.0 / 3600.0 // default 30 s tick
	if !s.lastAdvanced.IsZero() {
		dtHours = t.Sub(s.lastAdvanced).Seconds() / 3600.0
	}
	if dtHours <= 0 {
		dtHours = 30.0 / 3600.0
	}
	defer func() { s.lastAdvanced = t }()

	seg := s.schedule.segmentAt(t)
	s.mode = seg.mode

	switch seg.mode {
	case "Drive":
		dur := t.Sub(s.modeStarted)
		if s.modeStarted.IsZero() || seg.subType != s.lastSubType {
			s.modeStarted = t
			dur = 0
			s.lastSubType = seg.subType
		}

		// Speed profile depends on sub-type
		baseSpeed := 30.0
		amp := 20.0
		switch seg.subType {
		case "morning_commute", "evening_commute":
			baseSpeed = 45.0
			amp = 25.0
		case "trip_leg":
			baseSpeed = 70.0
			amp = 20.0
		case "errand":
			baseSpeed = 25.0
			amp = 15.0
		}
		s.speed = baseSpeed + amp*math.Sin(float64(dur.Seconds())/120) + s.rng.Float64()*5
		if s.speed < 0 {
			s.speed = 0
		}
		if s.speed > 130 {
			s.speed = 130
		}

		// Power = speed-based drag + accel oscillation
		// ~150 Wh/km at city, ~200 Wh/km at highway
		drag := 0.002 * s.speed * s.speed
		accel := 2*math.Sin(float64(dur.Seconds())/45) + s.rng.Float64()*2
		s.power = drag + accel
		if s.power < -30 {
			s.power = -30 // regen limit
		}

		// Energy accounting
		if s.power > 0 {
			s.lifetimeEnergyUsedDrive += s.power * dtHours
			s.lifetimeEnergyUsed += s.power * dtHours * 1.15
		} else {
			s.lifetimeEnergyGainedRegen += math.Abs(s.power) * dtHours * 0.6
		}

		// SoC change: 75 kWh pack, power in kW
		s.soc -= (s.power * dtHours) / 75.0 * 100.0
		s.odo += s.speed / 3600.0 * dtHours * 3600.0 // km
		s.headingT += 0.01

	case "Park":
		s.speed = 0
		s.power = -0.05 // phantom drain ~50 W
		s.soc -= (s.power * dtHours) / 75.0 * 100.0

	case "Charge":
		s.speed = 0
		if seg.subType == "dc_fast" {
			// DC fast charge taper: 250 kW at 0%, 50 kW at 90%
			s.power = -math.Max(50, 250*(1-s.soc/100.0))
		} else {
			// Home AC: 7-11 kW
			s.power = -(7.0 + s.rng.Float64()*4.0)
		}
		s.soc += (math.Abs(s.power) * dtHours) / 75.0 * 100.0

	case "Sleep":
		s.speed = 0
		s.power = -0.02 // deep sleep phantom ~20 W
		s.soc -= (s.power * dtHours) / 75.0 * 100.0
	}

	// Clamp SoC to realistic bounds
	if s.soc > 100 {
		s.soc = 100
	}
	if s.soc < 0 {
		s.soc = 0
	}
}

// writeIntensity decides how much data to emit for a given timestamp.
//   "full"    = all curated + fallback fields (driving, charging, transitions)
//   "medium"  = curated only (parked but awake)
//   "heartbeat" = tiny subset (asleep)
func (s *state) writeIntensity(t time.Time) string {
	seg := s.schedule.segmentAt(t)
	switch seg.mode {
	case "Drive", "Charge":
		return "full"
	case "Park":
		if s.lastWritten.IsZero() || t.Sub(s.lastWritten) >= 15*time.Minute {
			return "medium"
		}
		return "skip"
	case "Sleep":
		if s.lastWritten.IsZero() || t.Sub(s.lastWritten) >= 4*time.Hour {
			return "heartbeat"
		}
		return "skip"
	}
	return "skip"
}

// nextEvent returns the next timestamp after 'from' when this VIN needs to write.
func (s *state) nextEvent(from time.Time) time.Time {
	s.ensureSchedule(from)

	seg := s.schedule.segmentAt(from)
	var next time.Time
	switch seg.mode {
	case "Drive", "Charge":
		// Write every 30-60 s while active
		next = from.Add(30*time.Second + time.Duration(s.rng.Intn(30))*time.Second)
	case "Park":
		next = from.Add(15 * time.Minute)
	case "Sleep":
		next = from.Add(4*time.Hour + time.Duration(s.rng.Intn(120))*time.Minute)
	}

	// Never overshoot the next schedule transition
	trans := s.schedule.nextTransition(from)
	if trans.Before(next) || trans.Equal(next) {
		next = trans
	}
	return next
}

// nextBackfillEvent returns the next timestamp for backfill mode.
// It uses coarse jumps (2 min active, 15 min parked, 4 h asleep)
// to minimize loop iterations while preserving schedule fidelity.
func (s *state) nextBackfillEvent(from time.Time) time.Time {
	s.ensureSchedule(from)

	seg := s.schedule.segmentAt(from)
	var next time.Time
	switch seg.mode {
	case "Drive", "Charge":
		next = from.Add(2 * time.Minute)
	case "Park":
		next = from.Add(15 * time.Minute)
	case "Sleep":
		next = from.Add(4 * time.Hour)
	}

	trans := s.schedule.nextTransition(from)
	if trans.Before(next) || trans.Equal(next) {
		next = trans
	}
	if next.Equal(from) {
		next = from.Add(2 * time.Minute) // safety: never loop on same instant
	}
	return next
}

// ------------------------------------------------------------------
// Location
// ------------------------------------------------------------------

func (s *state) location() (lng, lat float64) {
	const cLng, cLat = -0.1278, 51.5074
	const r = 0.04
	return cLng + r*math.Cos(s.headingT), cLat + r*math.Sin(s.headingT)
}

// ------------------------------------------------------------------
// Sample generation
// ------------------------------------------------------------------

// curatedSamples produces the values that drive the dashboards.
func (s *state) curatedSamples(t time.Time, intensity string) []sample {
	var out []sample

	// Always emit these core fields
	out = append(out,
		numSamp("BatteryLevel", s.soc),
		numSamp("Soc", s.soc),
		numSamp("VehicleSpeed", s.speed),
		numSamp("Power", s.power),
		numSamp("Odometer", s.odo),
		strSamp("CarType", s.carType),
		numSamp("RatedRange", s.soc*4.5),
		numSamp("EstBatteryRange", s.soc*4.3),
		numSamp("IdealBatteryRange", s.soc*4.6),
		numSamp("EnergyRemaining", s.soc*0.75),
	)

	if intensity == "heartbeat" {
		// Minimal awake fields for asleep heartbeats
		out = append(out,
			numSamp("OutsideTemp", 12+5*math.Sin(float64(t.Unix())/3600)),
			strSamp("Locked", "true"),
			strSamp("SentryMode", "Off"),
		)
		lng, lat := s.location()
		out = append(out, geoSamp("Location", lng, lat))
		return out
	}

	// medium & full: common fields
	out = append(out,
		numSamp("LifetimeEnergyUsed", s.lifetimeEnergyUsed),
		numSamp("LifetimeEnergyUsedDrive", s.lifetimeEnergyUsedDrive),
		numSamp("LifetimeEnergyGainedRegen", s.lifetimeEnergyGainedRegen),
		numSamp("OutsideTemp", 12+5*math.Sin(float64(t.Unix())/3600)),
		numSamp("InsideTemp", 21+1*math.Sin(float64(t.Unix())/600)),
		numSamp("BatteryTempMin", 18+5*rand.Float64()),
		numSamp("BatteryTempMax", 22+5*rand.Float64()),
		numSamp("ModuleTempMin", 18+5*rand.Float64()),
		numSamp("ModuleTempMax", 22+5*rand.Float64()),
		numSamp("HvacLeftTemperatureRequest", 21.0),
		numSamp("HvacRightTemperatureRequest", 21.0),
		numSamp("PackVoltage", 380+20*rand.Float64()),
		numSamp("PackCurrent", -s.power*1000/400),
		numSamp("TpmsPressureFl", 2.7+0.05*rand.Float64()),
		numSamp("TpmsPressureFr", 2.7+0.05*rand.Float64()),
		numSamp("TpmsPressureRl", 2.7+0.05*rand.Float64()),
		numSamp("TpmsPressureRr", 2.7+0.05*rand.Float64()),
		strSamp("Locked", "true"),
		strSamp("SentryMode", "Off"),
		strSamp("DisplayState", "DisplayStateNormal"),
		strSamp("Trim", "PERFORMANCE"),
		strSamp("VehicleName", "Telemetron"),
		strSamp("Version", "2026.4.5"),
		strSamp("SettingDistanceUnit", "DistanceUnitKm"),
		strSamp("SettingTemperatureUnit", "Celsius"),
		strSamp("SettingChargeUnit", "ChargeUnitKilometers"),
		strSamp("SettingTirePressureUnit", "PressureUnitBar"),
		strSamp("Setting24HourTime", "true"),
		strSamp("SpeedLimitWarning", "SpeedAssistLevelDisplay"),
		strSamp("ForwardCollisionWarning", "Unknown"),
		strSamp("LaneDepartureAvoidance", "LaneDepartureAvoidanceAssist"),
		strSamp("BlindSpotCollisionWarningChime", "BlindSpotCollisionWarningChimeOn"),
		strSamp("AutomaticEmergencyBrakingOff", "false"),
	)

	if intensity != "full" {
		lng, lat := s.location()
		out = append(out, geoSamp("Location", lng, lat))
		return out
	}

	// Full intensity: add charge-specific and model-specific fields
	out = append(out,
		numSamp("DCChargingPower", math.Max(0, -s.power)),
		numSamp("ACChargingPower", math.Max(0, -s.power*0.4)),
		numSamp("ChargerVoltage", 230+5*rand.Float64()),
		numSamp("ChargeAmps", math.Max(0, -s.power*1000/230)),
		numSamp("ChargeLimitSoc", 90),
		numSamp("ChargeRateMilePerHour", math.Max(0, -s.power*3.5)),
		numSamp("TimeToFullCharge", math.Max(0, (90-s.soc)/30)),
		numSamp("EstimatedHoursToChargeTermination", math.Max(0, (90-s.soc)/30)),
	)

	// Model-specific fields
	switch s.model {
	case "CT":
		if s.mode == "Parked" && rand.Float64() < 0.05 {
			if s.tonneauPosition == "Closed" {
				s.tonneauPosition = "Open"
				s.tonneauOpenPct = 100
			} else {
				s.tonneauPosition = "Closed"
				s.tonneauOpenPct = 0
			}
		}
		if s.mode == "Driving" && s.tonneauPosition == "Open" {
			s.tonneauPosition = "Closed"
			s.tonneauOpenPct = 0
		}
		if s.mode == "Parked" && rand.Float64() < 0.002 {
			s.tonneauPosition = "Stuck"
		}
		if s.mode == "Parked" && rand.Float64() < 0.10 {
			s.powershareStatus = "Active"
			s.powershareType = "HomeBackup"
			s.powersharePowerKW = 2.5 + rand.Float64()*3.0
			s.powershareHoursLeft = 12 + rand.Float64()*24
		} else {
			s.powershareStatus = "Inactive"
			s.powershareType = "None"
			s.powersharePowerKW = 0
			s.powershareHoursLeft = 0
		}
		out = append(out,
			strSamp("TonneauPosition", s.tonneauPosition),
			strSamp("TonneauTentMode", s.tonneauTentMode),
			numSamp("TonneauOpenPercent", s.tonneauOpenPct),
			strSamp("OffroadLightbarPresent", "true"),
			numSamp("PowershareInstantaneousPowerKW", s.powersharePowerKW),
			strSamp("PowershareStatus", s.powershareStatus),
			strSamp("PowershareType", s.powershareType),
			numSamp("PowershareHoursLeft", s.powershareHoursLeft),
		)
		if s.mode == "Driving" && s.speed > 30 && s.suspensionMode == "Extract" {
			s.suspensionMode = "Standard"
		}
	case "Semi":
		out = append(out,
			numSamp("PowershareInstantaneousPowerKW", 0),
			strSamp("PowershareStatus", "PowershareStatusInactive"),
			strSamp("PowershareType", "PowershareTypeNone"),
		)
	}

	// Air-suspension telemetry
	if s.model == "S" || s.model == "X" || s.model == "Y" || s.model == "CT" {
		s.suspensionHeightFL += (rand.Float64() - 0.5) * 0.2
		s.suspensionHeightFR += (rand.Float64() - 0.5) * 0.2
		s.suspensionHeightRL += (rand.Float64() - 0.5) * 0.2
		s.suspensionHeightRR += (rand.Float64() - 0.5) * 0.2
		for _, h := range []*float64{&s.suspensionHeightFL, &s.suspensionHeightFR, &s.suspensionHeightRL, &s.suspensionHeightRR} {
			if *h < 135 { *h = 135 }
			if *h > 155 { *h = 155 }
		}
		if s.mode == "Parked" && rand.Float64() < 0.15 {
			s.compressorState = "On"
		} else {
			s.compressorState = "Off"
		}
		out = append(out,
			numSamp("AirSuspensionHeightFL", s.suspensionHeightFL),
			numSamp("AirSuspensionHeightFR", s.suspensionHeightFR),
			numSamp("AirSuspensionHeightRL", s.suspensionHeightRL),
			numSamp("AirSuspensionHeightRR", s.suspensionHeightRR),
			strSamp("AirSuspensionCompressorState", s.compressorState),
			strSamp("AirSuspensionMode", s.suspensionMode),
		)
	}

	// Dual-motor telemetry
	if s.motorConfig != "RWD" {
		s.invTempF += (rand.Float64() - 0.5) * 1.5
		s.invTempR += (rand.Float64() - 0.5) * 1.5
		s.heatsinkTempF = s.invTempF - 5 - rand.Float64()*3
		s.heatsinkTempR = s.invTempR - 5 - rand.Float64()*3
		s.statorTempF += (rand.Float64() - 0.5) * 2.0
		s.statorTempR += (rand.Float64() - 0.5) * 2.0
		baseRPM := s.speed * 25.0
		s.axleSpeedF = baseRPM + (rand.Float64()-0.5)*3.0
		s.axleSpeedR = baseRPM + (rand.Float64()-0.5)*3.0
		perfMult := 1.0
		if s.motorConfig == "Performance" || s.motorConfig == "Tri Motor" {
			perfMult = 1.25
		}
		if s.mode == "Driving" {
			s.accelTorqueF = (180 + rand.Float64()*60) * perfMult
			s.accelTorqueR = (180 + rand.Float64()*60) * perfMult
			s.regenTorqueF = (-50 - rand.Float64()*20) * perfMult
			s.regenTorqueR = (-50 - rand.Float64()*20) * perfMult
			s.torqueCmd = (220 + rand.Float64()*50) * perfMult
		} else if s.mode == "Charging" {
			s.accelTorqueF = 0
			s.accelTorqueR = 0
			s.regenTorqueF = (-200 - rand.Float64()*50) * perfMult
			s.regenTorqueR = (-200 - rand.Float64()*50) * perfMult
			s.torqueCmd = 0
		} else {
			s.accelTorqueF = 0
			s.accelTorqueR = 0
			s.regenTorqueF = 0
			s.regenTorqueR = 0
			s.torqueCmd = 0
		}
		s.motorCurrentF = math.Abs(s.accelTorqueF)*0.5 + math.Abs(s.regenTorqueF)*0.3
		s.motorCurrentR = math.Abs(s.accelTorqueR)*0.5 + math.Abs(s.regenTorqueR)*0.3
		s.vBatF = 300 + s.soc*1.2 + (rand.Float64()-0.5)*4
		s.vBatR = 300 + s.soc*1.2 + (rand.Float64()-0.5)*4
		for _, t := range []*float64{&s.invTempF, &s.invTempR} {
			if *t < 25 { *t = 25 }
			if *t > 95 { *t = 95 }
		}
		for _, t := range []*float64{&s.statorTempF, &s.statorTempR} {
			if *t < 35 { *t = 35 }
			if *t > 130 { *t = 130 }
		}
		out = append(out,
			numSamp("DiInverterTF", s.invTempF),
			numSamp("DiInverterTR", s.invTempR),
			numSamp("DiHeatsinkTF", s.heatsinkTempF),
			numSamp("DiHeatsinkTR", s.heatsinkTempR),
			numSamp("DiStatorTempF", s.statorTempF),
			numSamp("DiStatorTempR", s.statorTempR),
			numSamp("DiAxleSpeedF", s.axleSpeedF),
			numSamp("DiAxleSpeedR", s.axleSpeedR),
			numSamp("DiTorqueActualF", s.regenTorqueF),
			numSamp("DiTorqueActualR", s.regenTorqueR),
			numSamp("DiSlaveTorqueCmd", s.torqueCmd),
			numSamp("DiMotorCurrentF", s.motorCurrentF),
			numSamp("DiMotorCurrentR", s.motorCurrentR),
			numSamp("DiVBatF", s.vBatF),
			numSamp("DiVBatR", s.vBatR),
		)
		if s.motorConfig == "Tri Motor" {
			s.invTempREL += (rand.Float64() - 0.5) * 1.5
			s.invTempRER += (rand.Float64() - 0.5) * 1.5
			s.heatsinkTempREL = s.invTempREL - 5 - rand.Float64()*3
			s.heatsinkTempRER = s.invTempRER - 5 - rand.Float64()*3
			s.statorTempREL += (rand.Float64() - 0.5) * 2.0
			s.statorTempRER += (rand.Float64() - 0.5) * 2.0
			baseRPM := s.speed * 25.0
			s.axleSpeedREL = baseRPM + (rand.Float64()-0.5)*3.0
			s.axleSpeedRER = baseRPM + (rand.Float64()-0.5)*3.0
			if s.mode == "Driving" {
				s.accelTorqueREL = (180 + rand.Float64()*60) * 1.25
				s.accelTorqueRER = (180 + rand.Float64()*60) * 1.25
				s.regenTorqueREL = (-50 - rand.Float64()*20) * 1.25
				s.regenTorqueRER = (-50 - rand.Float64()*20) * 1.25
			} else if s.mode == "Charging" {
				s.accelTorqueREL = 0
				s.accelTorqueRER = 0
				s.regenTorqueREL = (-200 - rand.Float64()*50) * 1.25
				s.regenTorqueRER = (-200 - rand.Float64()*50) * 1.25
			} else {
				s.accelTorqueREL = 0
				s.accelTorqueRER = 0
				s.regenTorqueREL = 0
				s.regenTorqueRER = 0
			}
			s.motorCurrentREL = math.Abs(s.accelTorqueREL)*0.5 + math.Abs(s.regenTorqueREL)*0.3
			s.motorCurrentRER = math.Abs(s.accelTorqueRER)*0.5 + math.Abs(s.regenTorqueRER)*0.3
			s.vBatREL = 300 + s.soc*1.2 + (rand.Float64()-0.5)*4
			s.vBatRER = 300 + s.soc*1.2 + (rand.Float64()-0.5)*4
			for _, t := range []*float64{&s.invTempREL, &s.invTempRER} {
				if *t < 25 { *t = 25 }
				if *t > 95 { *t = 95 }
			}
			for _, t := range []*float64{&s.statorTempREL, &s.statorTempRER} {
				if *t < 35 { *t = 35 }
				if *t > 130 { *t = 130 }
			}
			out = append(out,
				numSamp("DiInverterTREL", s.invTempREL),
				numSamp("DiInverterTRER", s.invTempRER),
				numSamp("DiHeatsinkTREL", s.heatsinkTempREL),
				numSamp("DiHeatsinkTRER", s.heatsinkTempRER),
				numSamp("DiStatorTempREL", s.statorTempREL),
				numSamp("DiStatorTempRER", s.statorTempRER),
				numSamp("DiAxleSpeedREL", s.axleSpeedREL),
				numSamp("DiAxleSpeedRER", s.axleSpeedRER),
				numSamp("DiTorqueActualREL", s.regenTorqueREL),
				numSamp("DiTorqueActualRER", s.regenTorqueRER),
				numSamp("DiMotorCurrentREL", s.motorCurrentREL),
				numSamp("DiMotorCurrentRER", s.motorCurrentRER),
				numSamp("DiVBatREL", s.vBatREL),
				numSamp("DiVBatRER", s.vBatRER),
			)
		}
	}

	switch s.mode {
	case "Drive":
		out = append(out,
			strSamp("Gear", "ShiftStateD"),
			strSamp("ChargeState", "Idle"),
			strSamp("DetailedChargeState", "DetailedChargeStateDisconnected"),
			strSamp("DestinationName", "Home"),
			numSamp("MilesToArrival", 5+rand.Float64()*20),
			numSamp("MinutesToArrival", 10+rand.Float64()*30),
			numSamp("RouteTrafficMinutesDelay", rand.Float64()*5),
			numSamp("ExpectedEnergyPercentAtTripArrival", math.Max(0, s.soc-5-rand.Float64()*10)),
			strSamp("RouteLastUpdated", t.UTC().Format(time.RFC3339)),
		)
	case "Park", "Sleep":
		out = append(out,
			strSamp("Gear", "ShiftStateP"),
			strSamp("ChargeState", "Idle"),
			strSamp("DetailedChargeState", "DetailedChargeStateDisconnected"),
		)
	case "Charge":
		out = append(out,
			strSamp("Gear", "ShiftStateP"),
			strSamp("ChargeState", "Enable"),
			strSamp("DetailedChargeState", "DetailedChargeStateCharging"),
			numSamp("ACChargingEnergyIn", math.Abs(s.power)*30/3600),
			numSamp("DCChargingEnergyIn", math.Abs(s.power)*30/3600),
		)
	}
	lng, lat := s.location()
	out = append(out, geoSamp("Location", lng, lat))
	return out
}

// fallbackSamples produces a synthetic value for every field in the catalog
// that isn't already covered by curatedSamples.
func fallbackSamples(catalog []fieldDef, covered map[string]bool, t time.Time) []sample {
	out := make([]sample, 0, len(catalog))
	for _, f := range catalog {
		if covered[f.Field] {
			continue
		}
		s := synth(f, t)
		if s != nil {
			out = append(out, *s)
		}
	}
	return out
}

// synth returns a type-appropriate placeholder value for a non-curated field.
func synth(f fieldDef, t time.Time) *sample {
	seed := fnvSeed(f.Field)
	rng := rand.New(rand.NewSource(int64(seed) + t.Unix()/30))

	switch f.Type {
	case "real":
		base, amp, jitter := bandsFor(f)
		v := base + amp*math.Sin(float64(t.Unix())/120+float64(seed%100)) + jitter*rng.NormFloat64()
		return ptrSamp(numSamp(f.Field, v))
	case "integer", "Integer":
		base, amp, _ := bandsFor(f)
		v := math.Round(base + amp*math.Sin(float64(t.Unix())/180+float64(seed%50)))
		return ptrSamp(numSamp(f.Field, v))
	case "long":
		v := float64(t.Unix() - 1700000000)
		return ptrSamp(numSamp(f.Field, v))
	case "boolean":
		on := (t.Unix()/600+int64(seed))%5 == 0
		return ptrSamp(strSamp(f.Field, boolStr(on)))
	case "enum":
		return ptrSamp(strSamp(f.Field, defaultEnum(f.Field)))
	case "string", "text":
		return ptrSamp(strSamp(f.Field, "—"))
	case "timestamp":
		return ptrSamp(strSamp(f.Field, t.UTC().Format(time.RFC3339)))
	case "location", "Location":
		return nil
	}
	return nil
}

// bandsFor picks a plausible value range based on a field's category/name.
func bandsFor(f fieldDef) (base, amp, jitter float64) {
	n := f.Field
	switch {
	case strings.Contains(n, "Temp"), strings.Contains(n, "Heatsink"):
		return 25, 8, 1.5
	case strings.Contains(n, "Voltage"), strings.Contains(n, "VBat"):
		return 380, 10, 1.5
	case strings.Contains(n, "Current"):
		return 50, 30, 5
	case strings.Contains(n, "Pressure"):
		return 2.7, 0.1, 0.02
	case strings.Contains(n, "Speed"):
		return 60, 30, 5
	case strings.Contains(n, "Torque"):
		return 100, 80, 10
	case strings.Contains(n, "Range"):
		return 300, 50, 5
	case strings.Contains(n, "Power"):
		return 30, 25, 2
	case strings.Contains(n, "Energy"):
		return 50, 20, 1
	case strings.Contains(n, "Acceleration"):
		return 0, 2, 0.3
	case strings.Contains(n, "Heading"):
		return 180, 150, 10
	case strings.Contains(n, "Volume"):
		return 5, 3, 0.5
	case strings.Contains(n, "Soc"), strings.Contains(n, "Limit"), strings.Contains(n, "Percent"):
		return 75, 15, 1
	case strings.Contains(n, "Miles"), strings.Contains(n, "Minutes"):
		return 100, 80, 5
	}
	return 50, 25, 2
}

// defaultEnum picks a safe enum string for an arbitrary field name.
func defaultEnum(field string) string {
	switch {
	case strings.HasPrefix(field, "ChargeState"):
		return "Disconnected"
	case strings.HasPrefix(field, "DetailedChargeState"):
		return "DetailedChargeStateDisconnected"
	case strings.HasPrefix(field, "DefrostMode"):
		return "DefrostModeOff"
	case strings.HasPrefix(field, "ClimateKeeperMode"):
		return "ClimateKeeperModeOff"
	case strings.HasPrefix(field, "HvacAutoMode"):
		return "HvacAutoModeAuto"
	case strings.HasPrefix(field, "HvacPower"):
		return "HvacPowerOff"
	case strings.HasPrefix(field, "TonneauTentMode"):
		return "TonneauTentModeOff"
	case strings.HasPrefix(field, "TonneauPosition"):
		return "TonneauPositionClosed"
	case strings.HasPrefix(field, "DisplayState"):
		return "DisplayStateNormal"
	case strings.HasPrefix(field, "BMSState"), strings.HasPrefix(field, "BmsState"):
		return "BMSStateStandby"
	case strings.HasPrefix(field, "ShiftState"):
		return "ShiftStateP"
	case strings.HasPrefix(field, "ChargePort"):
		return "ChargePortUS"
	case strings.HasPrefix(field, "ChargePortLatch"):
		return "ChargePortLatchDisengaged"
	case strings.HasPrefix(field, "FastCharger"):
		return "FastChargerNone"
	case strings.HasPrefix(field, "Cable"):
		return "CableTypeNone"
	case strings.HasPrefix(field, "FollowDistance"):
		return "FollowDistance3"
	case strings.HasPrefix(field, "ScheduledChargingMode"):
		return "ScheduledChargingModeOff"
	case strings.HasPrefix(field, "DriveInverterState"):
		return "DriveInverterStateUnavailable"
	case strings.HasPrefix(field, "WindowState"):
		return "WindowStateClosed"
	case strings.HasPrefix(field, "SeatFoldPosition"):
		return "SeatFoldPositionUp"
	case strings.HasPrefix(field, "Powershare"):
		return "PowershareTypeNone"
	case strings.HasPrefix(field, "TurnSignalState"):
		return "TurnSignalStateOff"
	case strings.HasPrefix(field, "MediaStatus"):
		return "MediaStatusStopped"
	case strings.HasPrefix(field, "Sunroof"):
		return "SunroofInstalledStateNotInstalled"
	}
	return "Unknown"
}

func fnvSeed(s string) uint32 {
	h := fnv.New32a()
	_, _ = h.Write([]byte(s))
	return h.Sum32()
}

func ptrSamp(s sample) *sample { return &s }

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

// envOr returns the value of env var key, or fallback if unset/empty.
func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	connStr := flag.String("conn",
		envOr("SIMULATOR_CONN", os.Getenv("PG_CONN")),
		"Postgres connection string (env: SIMULATOR_CONN or PG_CONN)")
	vinsCSV := flag.String("vins",
		envOr("SIMULATOR_VINS", "<SIMULATOR_VIN>"),
		"comma-separated VINs to simulate (env: SIMULATOR_VINS)")
	intervalSec := flag.Int("interval", 30, "tick interval in seconds (env: SIMULATOR_INTERVAL)")
	backfillDays := flag.Int("backfill-days", 0,
		"seed N days of synthetic history before starting real-time loop (env: SIMULATOR_BACKFILL_DAYS)")
	flag.Parse()

	if v := os.Getenv("SIMULATOR_INTERVAL"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			*intervalSec = n
		}
	}
	if v := os.Getenv("SIMULATOR_BACKFILL_DAYS"); v != "" && *backfillDays == 0 {
		if n, err := strconv.Atoi(v); err == nil {
			*backfillDays = n
		}
	}

	if *connStr == "" {
		log.Fatal("simulator: missing -conn / SIMULATOR_CONN / PG_CONN")
	}
	rawVins := strings.Split(*vinsCSV, ",")
	vins := make([]string, 0, len(rawVins))
	for _, v := range rawVins {
		if t := strings.TrimSpace(v); t != "" && t != "<SIMULATOR_VIN>" {
			vins = append(vins, t)
		}
	}
	if len(vins) == 0 {
		log.Fatal("simulator: no VINs provided — set -vins or SIMULATOR_VINS")
	}

	var catalog []fieldDef
	if err := json.Unmarshal(fieldsJSON, &catalog); err != nil {
		log.Fatalf("simulator: parse embedded fields.json: %v", err)
	}
	log.Printf("simulator: catalog has %d fields", len(catalog))

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	pool, err := pgxpool.New(ctx, *connStr)
	if err != nil {
		log.Fatalf("simulator: connect: %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("simulator: ping: %v", err)
	}
	log.Printf("simulator: connected; vins=%v interval=%ds", vins, *intervalSec)

	now := time.Now().UTC()
	states := make(map[string]*state, len(vins))
	for _, v := range vins {
		m, ct := detectModelFromVin(v)
		mc := detectMotorConfigFromVin(v)
		st := &state{
			vin:         v,
			mode:        "Sleep",
			modeStarted: now,
			soc:         70 + rand.Float64()*20, // start with realistic SoC
			odo:         50000 + rand.Float64()*10000,
			model:       m,
			carType:     ct,
			motorConfig: mc,
			lastWritten:  time.Time{},
			lastAdvanced: time.Time{},
		}
		if m == "S" || m == "X" || m == "Y" || m == "CT" {
			st.suspensionHeightFL = 145 + rand.Float64()*2
			st.suspensionHeightFR = 145 + rand.Float64()*2
			st.suspensionHeightRL = 145 + rand.Float64()*2
			st.suspensionHeightRR = 145 + rand.Float64()*2
			st.suspensionMode = "Standard"
			st.compressorState = "Off"
		}
		if mc != "RWD" {
			st.invTempF = 45 + rand.Float64()*5
			st.invTempR = 45 + rand.Float64()*5
			st.heatsinkTempF = 38 + rand.Float64()*4
			st.heatsinkTempR = 38 + rand.Float64()*4
			st.statorTempF = 60 + rand.Float64()*8
			st.statorTempR = 60 + rand.Float64()*8
			st.axleSpeedF = 800 + rand.Float64()*50
			st.axleSpeedR = 800 + rand.Float64()*50
			st.regenTorqueF = -200 - rand.Float64()*50
			st.regenTorqueR = -200 - rand.Float64()*50
			st.accelTorqueF = 150 + rand.Float64()*50
			st.accelTorqueR = 150 + rand.Float64()*50
			st.torqueCmd = 200 + rand.Float64()*50
			st.motorCurrentF = 100 + rand.Float64()*30
			st.motorCurrentR = 100 + rand.Float64()*30
			st.vBatF = 360 + rand.Float64()*20
			st.vBatR = 360 + rand.Float64()*20
		}
		if m == "CT" {
			st.tonneauOpenPct = 0
			st.tonneauPosition = "Closed"
			st.tonneauTentMode = "Off"
			st.powersharePowerKW = 0
			st.powershareStatus = "Inactive"
			st.powershareType = "None"
			st.powershareHoursLeft = 0
		}
		if mc == "Tri Motor" {
			st.invTempREL = 45 + rand.Float64()*5
			st.invTempRER = 45 + rand.Float64()*5
			st.heatsinkTempREL = 38 + rand.Float64()*4
			st.heatsinkTempRER = 38 + rand.Float64()*4
			st.statorTempREL = 60 + rand.Float64()*8
			st.statorTempRER = 60 + rand.Float64()*8
			st.axleSpeedREL = 800 + rand.Float64()*50
			st.axleSpeedRER = 800 + rand.Float64()*50
			st.regenTorqueREL = -200 - rand.Float64()*50
			st.regenTorqueRER = -200 - rand.Float64()*50
			st.accelTorqueREL = 150 + rand.Float64()*50
			st.accelTorqueRER = 150 + rand.Float64()*50
			st.motorCurrentREL = 100 + rand.Float64()*30
			st.motorCurrentRER = 100 + rand.Float64()*30
			st.vBatREL = 360 + rand.Float64()*20
			st.vBatRER = 360 + rand.Float64()*20
		}
		states[v] = st
		log.Printf("simulator: vin=%s model=%s carType=%s", v, m, ct)
	}

	// writeTick writes one tick at the given timestamp for all VINs.
	writeTick := func(ts time.Time) {
		for vin, st := range states {
			st.advance(ts)
			intensity := st.writeIntensity(ts)
			if intensity == "skip" {
				continue
			}
			curated := st.curatedSamples(ts, intensity)
			covered := map[string]bool{}
			for _, s := range curated {
				covered[s.field] = true
			}
			var samples []sample
			if intensity == "full" {
				samples = append(curated, fallbackSamples(catalog, covered, ts)...)
			} else {
				samples = curated
			}
			if err := writeBatch(ctx, pool, vin, ts, samples); err != nil {
				log.Printf("simulator: write vin=%s: %v", vin, err)
			}
			st.lastWritten = ts
		}
	}

	// Backfill historical data before starting the real-time loop.
	if *backfillDays > 0 {
		start := time.Now().UTC().Add(-time.Duration(*backfillDays) * 24 * time.Hour)
		end := time.Now().UTC().Add(-2 * time.Minute)
		log.Printf("simulator: backfilling %d days starting %s",
			*backfillDays, start.Format(time.RFC3339))

		for _, st := range states {
			st.lastWritten = time.Time{}
			st.lastAdvanced = time.Time{}
		}

		var totalWrites int64
		backfillStart := time.Now()
		var wg sync.WaitGroup
		for vin, st := range states {
			wg.Add(1)
			go func(vin string, st *state) {
				defer wg.Done()
				vinStart := time.Now()
				var vinWrites int
				for t := start; t.Before(end); {
					select {
					case <-ctx.Done():
						log.Println("simulator: backfill interrupted")
						return
					default:
					}

					st.advance(t)
					intensity := st.writeIntensity(t)
					if intensity != "skip" {
						vinWrites++
						curated := st.curatedSamples(t, intensity)
						covered := map[string]bool{}
						for _, s := range curated {
							covered[s.field] = true
						}
						var samples []sample
						if intensity == "full" {
							samples = append(curated, fallbackSamples(catalog, covered, t)...)
						} else {
							samples = curated
						}
						if err := writeBatch(ctx, pool, vin, t, samples); err != nil {
							log.Printf("simulator: write vin=%s: %v", vin, err)
						}
						st.lastWritten = t
					}

					next := st.nextBackfillEvent(t)
					if !next.After(t) {
						next = t.Add(2 * time.Minute) // safety: always move forward
					}
					t = next
				}
				atomic.AddInt64(&totalWrites, int64(vinWrites))
				log.Printf("simulator: backfill vin=%s done in %s (%d writes)", vin, time.Since(vinStart), vinWrites)
			}(vin, st)
		}
		wg.Wait()
		log.Printf("simulator: backfill complete — %d vins, %d writes, %s",
			len(states), totalWrites, time.Since(backfillStart))
	}

	// Real-time loop.
	tick := time.NewTicker(time.Duration(*intervalSec) * time.Second)
	defer tick.Stop()
	for {
		now := time.Now().UTC()
		writeTick(now)
		fmt.Printf("simulator: tick %s — %d vins\n", now.Format(time.RFC3339), len(states))
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

func writeBatch(ctx context.Context, pool *pgxpool.Pool, vin string, ts time.Time, samples []sample) error {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()

	// Build a single multi-value INSERT — much faster than individual
	// INSERT statements because it needs only one round-trip per batch.
	values := make([]string, 0, len(samples))
	args := make([]any, 0, len(samples)*6)
	argIdx := 1
	for _, s := range samples {
		var geo any
		if s.geo != nil {
			geo = fmt.Sprintf("SRID=4326;POINT(%.7f %.7f)", s.geo[0], s.geo[1])
		}
		values = append(values, fmt.Sprintf("($%d,$%d,$%d,$%d,$%d,$%d::geography)", argIdx, argIdx+1, argIdx+2, argIdx+3, argIdx+4, argIdx+5))
		args = append(args, ts, vin, s.field, s.num, s.str, geo)
		argIdx += 6
	}

	query := "INSERT INTO telemetry (ts, vin, field, num_value, str_value, geo_value) VALUES " +
		strings.Join(values, ",") +
		" ON CONFLICT (ts, vin, field) DO NOTHING"
	_, err = conn.Exec(ctx, query, args...)
	return err
}
