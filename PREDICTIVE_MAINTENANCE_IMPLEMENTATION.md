# Predictive Maintenance — Implementation Reference

This document is the **companion** to `PREDICTIVE_MAINTENANCE_RATIONALE.md`. It contains the exact SQL objects, thresholds, telemetry fields, and dashboard files for every predictive subsystem so that developers can debug, extend, or replicate the stack without re-reading 5 000 lines of SQL.

All files live under `deploy/sql/005_*.sql` → `014_*.sql` and `deploy/grafana/dashboards/0[5-9]_*.json` / `1[0-4]_*.json`.

---

## Table of Contents

1. [Anomaly Detection (005)](#1-anomaly-detection-005)
2. [PCS Diagnostics (006)](#2-pcs-diagnostics-006)
3. [Heat Pump Diagnostics (007)](#3-heat-pump-diagnostics-007)
4. [12V Battery Diagnostics (008)](#4-12v-battery-diagnostics-008)
5. [Battery Health (009)](#5-battery-health-009)
6. [Suspension Diagnostics (010)](#6-suspension-diagnostics-010)
7. [Drivetrain Diagnostics (011)](#7-drivetrain-diagnostics-011)
8. [Alert Parser (012)](#8-alert-parser-012)
9. [Regen & Brake Diagnostics (013)](#9-regen--brake-diagnostics-013)
10. [Master Predictive Health (014)](#10-master-predictive-health-014)
11. [Air Suspension Diagnostics (015)](#11-air-suspension-diagnostics-015)
12. [Dual Motor Diagnostics (016)](#12-dual-motor-diagnostics-016)
13. [Cybertruck Diagnostics (017)](#13-cybertruck-diagnostics-017)

---

## 1. Anomaly Detection (005)

**File:** `deploy/sql/005_predictive_anomalies.sql
005_vehicle_metadata.sql`  
**Dashboard:** none (feeds into `00_overview.json` and `14_predictive_health.json`)

### Telemetry fields (15)
`PackVoltage`, `PackCurrent`, `ModuleTempMax`, `ModuleTempMin`, `IsolationResistance`, `TpmsPressureFl`, `TpmsPressureFr`, `TpmsPressureRl`, `TpmsPressureRr`, `Soc`, `VehicleSpeed`, `DiStatorTempR`, `DiInverterTR`, `LateralAcceleration`, `LongitudinalAcceleration`

### CAGGs
| CAGG | Grain | Source | Refresh |
|------|-------|--------|---------|
| `telemetry_anomaly_1h` | 1 hour | `telemetry` hypertable | hourly, last 7 d |
| `telemetry_anomaly_1d` | 1 day | `telemetry` hypertable | daily, last 30 d |

### Functions
```sql
CREATE OR REPLACE FUNCTION calculate_anomaly_score(
  val DOUBLE PRECISION,
  avg_v DOUBLE PRECISION,
  stddev_v DOUBLE PRECISION,
  median_v DOUBLE PRECISION,
  mad_v DOUBLE PRECISION
)
RETURNS TABLE(z_score DOUBLE PRECISION, mad_score DOUBLE PRECISION)
```

### Views
| View | Purpose |
|------|---------|
| `telemetry_rolling_stats` | 7-day & 30-day rolling mean, stddev, median, MAD per `(vin, field)` using window functions over `telemetry_anomaly_1h`. |
| `telemetry_anomalies` | Flags any hourly observation where `\|z_score\| > 3` **or** `\|mad_score\| > 3`. Severity = `critical` when max > 4, `warning` when > 3. Requires `n_7d >= 24` (~1 day of samples) before scoring. |
| `telemetry_anomaly_latest` | `DISTINCT ON (vin, field)` — latest anomaly row per field for quick "Current Risk" panels. |

### Thresholds
- `anomaly_type`: `z_score` | `mad` | `both` | `normal`
- `severity`: `critical` (> 4σ) | `warning` (> 3σ) | `normal`

---

## 2. PCS Diagnostics (006)

**File:** `deploy/sql/006_pcs_diagnostics.sql`  
**Dashboard:** `05_powertrain.json`

### Telemetry fields
`ChargeAmps`, `ChargeCurrentRequestMax`, `ChargeCurrentRequest`, `ACChargingPower`

### CAGGs
| CAGG | Grain | Source | Refresh |
|------|-------|--------|---------|
| `pcs_samples_1h` | 1 hour | `telemetry` | hourly, last 7 d |
| `pcs_health_1d` | 1 day | `pcs_samples_1h` | daily, last 30 d |
| `pcs_health_1w` | 7 days | `pcs_health_1d` | daily, last 90 d |

### Views
| View | Purpose |
|------|---------|
| `pcs_diagnostics` | Sample-level deficit detection. Detects AC charging sessions (gap > 10 min = new session). A "failure streak" = ≥ 3 consecutive samples (gap ≤ 2 min) where `ROUND(request - actual) IN (16, 32)`. |
| `pcs_session_summary` | Per-session aggregation: max deficit, failure sample count, streak count, `BOOL_OR(pcs_module_failure_likely)`. |
| `pcs_status_summary` | Latest session per VIN. Status = `PCS_MODULE_FAILURE_LIKELY` or `NORMAL`. Also shows `sessions_affected / total_sessions`. |

### Key thresholds
- Module failure: persistent deficit of exactly **16 A** (1 module) or **32 A** (2 modules).
- Streak minimum: **3 consecutive samples** within 2-minute gaps.

---

## 3. Heat Pump Diagnostics (007)

**File:** `deploy/sql/007_heat_pump_diagnostics.sql`  
**Dashboard:** `06_climate.json`

### Telemetry fields
`InsideTemp`, `OutsideTemp`, `PackCurrent`, `PackVoltage`, `HvacPower`, `VehicleSpeed`, `Gear`, `ACChargingPower`, `DCChargingPower`

### CAGGs
| CAGG | Grain | Source | Refresh |
|------|-------|--------|---------|
| `heat_pump_samples_1h` | 1 hour | `telemetry` | hourly, last 7 d |
| `heat_pump_cop_1d` | 1 day | `heat_pump_samples_1h` | daily, last 90 d |

### Views
| View | Purpose |
|------|---------|
| `heat_pump_diagnostics` | Daily power-per-degree (PPD = `\|PackCurrent×PackVoltage\| / \|InsideTemp-OutsideTemp\|` in W/°C) with 7-day and 30-day rolling averages. |
| `heat_pump_status` | Latest snapshot per VIN: `status`, `latest_ppd`, `trend_pct`. |

### Key thresholds
- **Degradation flag:** `HEAT_PUMP_DEGRADATION_LIKELY` when:
  - `n_7d >= 3` and `n_30d >= 10`
  - `ppd_7d > ppd_30d * 1.15` (7-day average > 15 % worse than 30-day)
  - `ABS(delta_7d - delta_30d) <= 3` °C (temperature load hasn't shifted)
- Power window for valid hours: **100 W – 5 kW** (excludes phantom drain and driving loads).
- Minimum temperature delta: **≥ 3 °C**.

---

## 4. 12V Battery Diagnostics (008)

**File:** `deploy/sql/008_low_voltage_diagnostics.sql`  
**Dashboard:** none (feeds into `14_predictive_health.json`)

### Telemetry fields
`DCDCEnable`, `VehicleSpeed`, `Gear`, `ACChargingPower`, `DCChargingPower`

### CAGGs
| CAGG | Grain | Source | Refresh |
|------|-------|--------|---------|
| `low_voltage_samples_1h` | 1 hour | `telemetry` | hourly, last 7 d |
| `low_voltage_wakeups_1d` | 1 day | `low_voltage_samples_1h` | daily, last 90 d |

### Views
| View | Purpose |
|------|---------|
| `low_voltage_diagnostics` | Daily cycling sleep hours with 7-day / 30-day rolling averages. Wake-up rate = `cycling_sleep_hours / sleep_hours`. |
| `low_voltage_status` | Latest snapshot: `status`, `cycling_7d_avg`, `cycling_30d_avg`, `trend_pct`. |

### Key thresholds
- **Degradation flag:** `LOW_VOLTAGE_BATTERY_DEGRADATION_LIKELY` when:
  - `cycling_7d > cycling_30d * 2.0` (7-day average more than doubles 30-day baseline), **or**
  - `cycling_30d = 0` and `cycling_7d >= 2` (sudden onset from perfect sleep)
  - Confidence: `n_7d >= 3`, `n_30d >= 10`
- Sleep-hour criteria: `vehicle_speed_max <= 0`, `gear IN ('P', 'ShiftStateP', 'invalid', '')`, `AC/DC power <= 0`, at least one `DCDCEnable` sample present.

---

## 5. Battery Health (009)

**File:** `deploy/sql/009_battery_health.sql`  
**Dashboard:** `09_battery_health.json`

### Telemetry fields
`EnergyRemaining`, `BatteryLevel`, `IdealBatteryRange`, `RatedRange`, `BrickVoltageMax`, `BrickVoltageMin`, `PackCurrent`, `PackVoltage`, `VehicleSpeed`, `Gear`, `ACChargingPower`, `DCChargingPower`

### CAGGs
| CAGG | Grain | Source | Refresh |
|------|-------|--------|---------|
| `battery_samples_1h` | 1 hour | `telemetry` | hourly, last 7 d |

> **Note:** `battery_capacity_1d` is implemented as a standard Materialized View (refreshed daily), not a CAGG, to support complex rest-hour gaps-and-islands detection.

### Views
| View | Purpose |
|------|---------|
| `battery_rest_capacity` | Gaps-and-islands detection of **4+ hour** rest blocks. Extracts the LAST hour of each block as the thermally-equilibrated reading. Rest criteria: parked, not charging, `\|I·V\| < 500 W`. |
| `battery_alerts` | Filtered `vehicle_alerts` for BMS/DI/UI/CP codes with inferred severity. |
| `battery_health_diagnostics` | Daily derived capacity (`EnergyRemaining / (BatteryLevel/100)`) with degradation % vs first recorded value, plus 30-day / 90-day rolling averages and brick-delta trends. |
| `battery_health_summary` | Combined snapshot: latest rest capacity, capacity fade %, brick imbalance, active alerts, and overall status. |

### Key thresholds
- **Overall status** (in priority order):
  1. `BATTERY_SERVICE_REQUIRED` — active CRITICAL alert (`BMS_f*`, etc.)
  2. `BATTERY_SERVICE_RECOMMENDED` — active URGENT alert
  3. `BATTERY_CAPACITY_DEGRADED` — capacity fade > **10 %**
  4. `BATTERY_IMBALANCE_DETECTED` — `brick_delta_max > 0.5 V`
  5. `NORMAL`

---

## 6. Suspension Diagnostics (010)

**File:** `deploy/sql/010_suspension_diagnostics.sql`  
**Dashboard:** `10_suspension.json`

### Telemetry fields
`VehicleSpeed`, `LateralAcceleration`, `SteeringAngle`, `GpsHeading`

> **Note:** `SteeringAngle` is not in the production vehicle_data protobuf by default; it was added to `tools/simulator/fields.json` for end-to-end testing. The SQL is NULL-safe — when absent, the drift-proxy (`lat_accel_stddev`) still works.

### CAGGs
| CAGG | Grain | Source | Refresh |
|------|-------|--------|---------|
| `suspension_samples_1m` | 1 minute | `telemetry` | every 5 min, last 3 d |
| `suspension_steering_1d` | 1 day | `suspension_samples_1m` | daily, last 90 d |

### Views
| View | Purpose |
|------|---------|
| `suspension_trip_offsets` | Per-trip highway segment analysis using the existing `trips` view. Computes median steering offset during straight-line driving. |
| `suspension_diagnostics` | Daily rolling 7d/30d/90d steering-offset trends with degradation flags. |
| `suspension_alerts` | `UI_a006` (CRITICAL) and `CH_*` (WARNING) alerts from `vehicle_alerts`. |
| `suspension_summary` | Combined snapshot: latest offset, trend %, active alerts, overall status. |

### Key thresholds
- Highway filter: `speed_avg > 50 mph` and `\|lat_accel_avg\| < 0.05 g`
- **Alignment flag:** `SUSPENSION_ALIGNMENT_LIKELY` when:
  - `offset_abs_30d > offset_abs_90d * 1.5` AND `offset_abs_30d > 3.0°`, **or**
  - `offset_abs_30d > baseline_offset_abs * 2.0`
- **Looseness flag:** `SUSPENSION_LOOSENESS_LIKELY` when `lat_accel_stddev > 0.03` and `lat_std_30d > lat_std_90d * 1.5`
- **Overall status** priority: CRITICAL alert (`UI_a006`) > URGENT > alignment > looseness > NORMAL

---

## 7. Drivetrain Diagnostics (011)

**File:** `deploy/sql/011_drivetrain_diagnostics.sql`  
**Dashboard:** `11_drivetrain.json`

### Telemetry fields
`DiHeatsinkTF/TR/TREL/TRER`, `DiInverterTF/TR/TREL/TRER`, `DiStatorTempF/R/REL/RER`, `DiTorqueActualF/R/REL/RER`, `DiSlaveTorqueCmd`, `DiTorquemotor`, `DiMotorCurrentF/R`, `VehicleSpeed`

### CAGGs
| CAGG | Grain | Source | Refresh |
|------|-------|--------|---------|
| `drivetrain_samples_1h` | 1 hour | `telemetry` | hourly, last 7 d |
| `drivetrain_highway_1d` | 1 day | `drivetrain_samples_1h` | daily, last 90 d |

### Views
| View | Purpose |
|------|---------|
| `drivetrain_trip_analysis` | Per-trip worst-case temps and peak torques for trips reaching highway speeds. |
| `drivetrain_diagnostics` | Daily rolling 7d/30d/90d temperature and torque trends. Dynamic 95th-percentile proxy = `avg_90d + 2*stddev_90d`. |
| `drivetrain_summary` | Latest snapshot with `overall_status`. |

### Key thresholds
- **Overheat flag:** `INVERTER_OVERHEAT_RISK` when:
  - `inv_temp_7d > inv_temp_90d + 2*stddev` (or same for heatsink / stator), **or**
  - Absolute thresholds: inverter > **85 °C**, heatsink > **90 °C**, stator > **120 °C**
- **Degradation flag:** `DRIVE_UNIT_DEGRADATION_LIKELY` when:
  - `regen_mag_30d < regen_mag_90d * 0.90` (regen torque drops > 10 %), **or**
  - `accel_mag_30d < accel_mag_90d * 0.90` (accel torque drops > 10 %)
- Confidence: `n_90d >= 20` for temps, `n_30d >= 10 && n_90d >= 20` for torque.

---

## 8. Alert Parser (012)

**File:** `deploy/sql/012_alert_parser.sql`  
**Dashboard:** `12_alerts.json`

### Source table
`vehicle_alerts` (side-channel table, not EAV)

### CAGGs
| CAGG | Grain | Source | Refresh |
|------|-------|--------|---------|
| `alert_frequency_1d` | 1 day | `vehicle_alerts` | hourly, last 30 d |
| `alert_frequency_1w` | 7 days | `alert_frequency_1d` | daily, last 90 d |

### Views
| View | Purpose |
|------|---------|
| `parsed_alerts` | Structured alert view: subsystem, severity, human-readable description (+ service bulletin refs), `is_active` flag, and nearest telemetry context (speed, gear, SOC, AC/DC power at alert time). |
| `alert_history_summary` | Per-code lifecycle: `first_seen`, `last_seen`, `recurrence_count`, `active_count`. |
| `alert_critical_active` | Fast snapshot: counts of active critical / urgent / warning alerts + concatenated codes. |
| `alert_subsystem_trends` | 7d/30d rolling alert rates per subsystem. Flags `ALERT_SPIKE` when 7-day rate > 3× 30-day baseline, or `PERSISTENT_ISSUES` when ≥ 3 active alerts in 7 days. |

### Severity mapping
| Prefix | Severity |
|--------|----------|
| `*_f*` (fault) | CRITICAL |
| `*_u*` (urgent) | URGENT |
| `*_a*` (alert) | WARNING |
| else | INFO |

Explicit overrides: `UI_a006`, `BMS_f064`, `PCS_f001`, `DI_f001` → CRITICAL. `BMS_u018` → URGENT.

### Subsystem mapping
`BMS_*`, `DI_*`, `UI_a*`, `PCS_*`, `CH_*`, `CC_*`, `CP_*`, `TP_*`, `AT_*`, `Other`

---

## 9. Regen & Brake Diagnostics (013)

**File:** `deploy/sql/013_regen_brake_diagnostics.sql`  
**Dashboard:** `13_regen_brake.json`

### Telemetry fields
`LifetimeEnergyUsed`, `LifetimeEnergyUsedDrive`, `LifetimeEnergyGainedRegen`, `Odometer`, `BrakePedal`, `BrakePedalPos`, `VehicleSpeed`, `BatteryLevel`, `DiTorqueActualF/R/REL/RER`

> **Simulator note:** The simulator Go code tracks cumulative energy counters monotonically. Re-build after fields.json changes: `cd tools/simulator && go build -o simulator .`

### CAGGs
| CAGG | Grain | Source | Refresh |
|------|-------|--------|---------|
| `regen_brake_samples_1h` | 1 hour | `telemetry` | hourly, last 7 d |
| `regen_brake_daily_1d` | 1 day | `regen_brake_samples_1h` | daily, last 90 d |

### Views
| View | Purpose |
|------|---------|
| `regen_brake_diagnostics` | Daily deltas from cumulative counters (using `LAG()` with `GREATEST(0, …)` to handle counter resets). Computes efficiency (Wh/mi), regen energy per mile, regen ratio %, and 7-day / 30-day rolling averages. |
| `brake_wear_estimate` | Linear model: `wear_pct = (odometer_mi / 50 000) × (1 – regen_ratio) × 100`. Uses lifetime regen ratio, or recent 30-day ratio if available. |
| `regen_brake_summary` | Latest snapshot: status, `regen_ratio_pct`, `brake_remaining_pct`, `eff_trend_pct`, `regen_torque_trend_pct`. |

### Key thresholds
- **Regen degradation:** `REGEN_DEGRADATION_LIKELY` when `regen_torque_mag_7d < regen_torque_mag_30d * 0.90` OR `regen_7d < regen_30d * 0.90`
- **Efficiency anomaly:** `EFFICIENCY_ANOMALY` when `eff_7d > eff_30d * 1.15`
- Confidence: `n_drive_7d >= 3`, `n_drive_30d >= 10`

---

## 10. Master Predictive Health (014)

**File:** `deploy/sql/014_predictive_health.sql`  
**Dashboard:** `14_predictive_health.json`

### Objects created
| Object | Type | Purpose |
|--------|------|---------|
| `subsystem_risk_score()` | Function | Maps any status text + severity + numeric modifier to a 0–100 integer. |
| `predictive_health_score_1d` | View | Daily time-series of all 8 subsystem scores + weighted overall score. Built by `UNION ALL`-ing each subsystem diagnostic view, then `GROUP BY ts, vin`. |
| `predictive_health_summary` | View | Current snapshot per VIN. Computes composite `powertrain_risk` (Drivetrain 60 % + Regen/Brake 25 % + PCS 15 %) and `thermal_risk` (Heat Pump 60 % + Battery thermal 40 %). |
| `predictive_health_recommendations` | View | Per-subsystem actionable text for the "Next Service Recommendations" table panel. |

### Scoring formula
```
overall_risk_score =
  battery_score        × 0.22 +
  drivetrain_score     × 0.14 +
  alert_score          × 0.15 +
  low_voltage_score    × 0.10 +
  heat_pump_score      × 0.10 +
  regen_brake_score    × 0.07 +
  air_suspension_score × 0.05 +
  dual_motor_score     × 0.05 +
  cybertruck_score     × 0.05 +
  pcs_score            × 0.05 +
  suspension_score     × 0.04
```

### Base score mapping
| Status keyword | Base score |
|----------------|-----------|
| CRITICAL / FAILURE / OVERHEAT_RISK / SERVICE_REQUIRED / DEGRADATION_LIKELY / ALIGNMENT_LIKELY / ALERT_SPIKE / PERSISTENT_ISSUES | 90 |
| DEGRADED / RECOMMENDED / ANOMALY / IMBALANCE_DETECTED / LOOSENESS_LIKELY | 65 |
| WARNING / SPIKE / PERSISTENT | 40 |
| NORMAL / HEALTHY | 5 |
| unknown | 10 |

### Severity override
- CRITICAL → max(95, base)
- URGENT → max(75, base)
- WARNING → max(40, base)

### Numeric modifier
- `degradation_pct / 3` is added when supplied (callers pass normalised positive values).
- `brick_delta > 0.3 V` adds +15 points.

### Colour scale
| Score | Label | Colour |
|-------|-------|--------|
| 0–30 | Healthy | Green |
| 31–60 | Caution | Yellow |
| 61–80 | Warning | Orange |
| 81–100 | Critical | Red |

### `recommended_action` priority
1. Critical alerts active → "IMMEDIATE SERVICE — Critical: …"
2. Battery score ≥ 85 → "Schedule battery service …"
3. Drivetrain score ≥ 85 → "Schedule drivetrain inspection …"
4. Alert score ≥ 75 with urgent alerts → "Schedule service — Urgent: …"
5. Overall ≥ 60 → "Monitor closely …"
6. Overall ≥ 40 → "Plan preventive maintenance …"
7. Else → "All systems nominal …"

### Dashboard panels (`14_predictive_health.json`)
| Row | Panel | Type | Query target |
|-----|-------|------|--------------|
| 🏥 Overview | Overall Health | Stat | `predictive_health_summary` |
| 🏥 Overview | Battery Risk | Stat | `predictive_health_summary` |
| 🏥 Overview | Powertrain Risk | Stat | `predictive_health_summary` |
| 🏥 Overview | Thermal Risk | Stat | `predictive_health_summary` |
| 📈 Trend | Subsystem Risk Scores Over Time | Time series | `predictive_health_score_1d` |
| 🚨 Alerts | Active Alerts | Table | `parsed_alerts` (`is_active = TRUE`) |
| 🔧 Service | Recommended Actions | Table | `predictive_health_recommendations` |

---

---

## 11. Air Suspension Diagnostics (015)

**File:** `deploy/sql/015_air_suspension_diagnostics.sql`  
**Dashboard:** feeds into `14_predictive_health.json` (visible when `has_air_suspension = true`)

### Telemetry fields
`AirSuspensionHeightFL`, `AirSuspensionHeightFR`, `AirSuspensionHeightRL`, `AirSuspensionHeightRR`, `AirSuspensionCompressorState`, `AirSuspensionMode`

### Views
| View | Purpose |
|------|---------|
| `air_suspension_diagnostics` | Daily rolling 7d/30d/90d compressor duty cycle, cycle counts, and ride-height drift. |
| `air_suspension_summary` | Latest snapshot with overall status, cycling trend, and drift trend. |

### Key thresholds
- **Duty Cycle flag:** `COMPRESSOR_OVERCYCLING_LIKELY` when duty cycle > 15 % (warning) or > 20 % (critical).
- **Drift flag:** `RIDE_HEIGHT_DRIFT_DETECTED` when corner-to-corner drift > 5 mm.

---

## 12. Dual Motor Diagnostics (016)

**File:** `deploy/sql/016_dual_motor_diagnostics.sql`  
**Dashboard:** feeds into `14_predictive_health.json` (visible for Dual Motor / Performance)

### Telemetry fields
`DiInverterTF/TR`, `DiAxleSpeedF/R`, `DiTorqueActualF/R`, `DiMotorCurrentF/R`, `DiVBatF/R`

### Views
| View | Purpose |
|------|---------|
| `dual_motor_diagnostics` | Compares front vs rear inverter temperatures, axle speed imbalance, and thermal throttling. |
| `dual_motor_summary` | Latest snapshot with overall status, temp delta, imbalance %, and regen limit. |

### Key thresholds
- **Imbalance flag:** `DUAL_MOTOR_IMBALANCE_DETECTED` when axle speed delta > 3 % (2.5 % for Performance).
- **Temp Delta:** > 12 °C (10 °C for Performance) between front and rear inverters.
- **Regen Degradation:** > 10 % drop (8 % for Performance).

---

## 13. Cybertruck Diagnostics (017)

**File:** `deploy/sql/017_cybertruck_diagnostics.sql`  
**Dashboard:** feeds into `14_predictive_health.json` (visible when `model = 'CT'`)

### Telemetry fields
`TonneauOpenPercent/Position`, `PowershareInstantaneousPowerKW/Status`, `DiInverterTREL/TRER`

### Views
| View | Purpose |
|------|---------|
| `cybertruck_diagnostics` | Tracks tonneau stuck events, V2L thermal stress, tri-motor imbalance, and 4680 degradation. |
| `cybertruck_summary` | Latest snapshot with overall severity and subsystem statuses. |

### Key thresholds
- **Tonneau flag:** `TONNEAU_STUCK_OR_MOTOR_FAILURE` when stuck for multiple hours.
- **V2L flag:** `V2L_HIGH_LOAD_SUSTAINED` when export > 5 kW for 4+ hours.
- **4680 Degradation:** `CT_4680_EARLY_DEGRADATION` at > 7 % capacity loss.

## Appendix A: Deployment Order

```
001_schema.sql
002_views.sql
003_grafana_role.sql
004_field_catalog.sql
005_predictive_anomalies.sql
005_vehicle_metadata.sql
006_pcs_diagnostics.sql
007_heat_pump_diagnostics.sql
008_low_voltage_diagnostics.sql
009_battery_health.sql
010_suspension_diagnostics.sql
011_drivetrain_diagnostics.sql
012_alert_parser.sql
013_regen_brake_diagnostics.sql
014_predictive_health.sql
015_air_suspension_diagnostics.sql
016_dual_motor_diagnostics.sql
017_cybertruck_diagnostics.sql
```

## Appendix B: Refresh Policy Summary

| CAGG | Schedule | Window |
|------|----------|--------|
| `*_samples_1h` | 1 hour | last 7 days |
| `*_1d` (daily health) | 1 day | last 30–90 days |
| `*_1w` (weekly) | 1 day | last 90 days |
| `suspension_samples_1m` | 5 minutes | last 3 days |
| `alert_frequency_1d` | 1 hour | last 30 days |

## Appendix C: Grafana Dashboard Index

| File | Title | Subsystem |
|------|-------|-----------|
| `00_overview.json` | Tesla — Overview | Cross-cutting |
| `01_summary.json` | Tesla — Summary | Cross-cutting |
| `05_powertrain.json` | Tesla — Powertrain | PCS + drivetrain basics |
| `06_climate.json` | Tesla — Climate | Heat pump |
| `09_battery_health.json` | Tesla — Battery Health | Battery |
| `10_suspension.json` | Tesla — Suspension | Suspension |
| `11_drivetrain.json` | Tesla — Drivetrain | Drivetrain |
| `12_alerts.json` | Tesla — Alerts | Alert parser |
| `13_regen_brake.json` | Tesla — Regen & Brake | Regen / brake |
| `14_predictive_health.json` | Tesla — Predictive Health | **Master unified** |
