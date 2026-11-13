# Predictive Maintenance — Implementation Reference

This document is the **companion** to `PREDICTIVE_MAINTENANCE_RATIONALE.md`. It contains the exact SQL objects, thresholds, telemetry fields, and dashboard files for every predictive subsystem so that developers can debug, extend, or replicate the stack without re-reading 5 000 lines of SQL.

All files live under `deploy/sql/005_*.sql` → `017_*.sql` (the original predictive stack) plus `deploy/sql/025_pm_review_fixes.sql` (the May-2026 review fixes) and `deploy/grafana/dashboards/0[5-9]_*.json` / `1[0-4]_*.json`.

> **May 2026 review:** several bugs and risks identified in
> `PREDICTIVE_MAINTENANCE_RATIONALE.md → "Review fixes"` were addressed —
> weight rebalance (now sums to exactly 1.00), de-duplicated overall score,
> continuous thermal-risk mapping, heat-pump alert routing, brake-wear
> clamp, tightened heat-pump n-floor, refactored rest-hour predicate.
> Additive features in 025: hourly matview refresh function, calendar-based
> service intervals, alert acknowledgement, status dictionary, dedicated
> isolation-resistance indicator.  See **Section 11** below.

> **November 2026 changes (`034`–`042`)** — read these before the sections below:
>
> - **Anomaly layer removed (`039`).** `telemetry_anomaly_1h/_1d`,
>   `telemetry_rolling_stats`, `telemetry_anomalies`, `telemetry_anomaly_latest`
>   and `calculate_anomaly_score()` had no reader and their refresh policy failed
>   hundreds of times; `039` drops them. Section 1 describes what `005` still
>   creates on a fresh install before `039` removes it. It is not part of the
>   running stack.
> - **Stored scores (`041`).** `predictive_health_score_1d` and
>   `predictive_health_summary` are now thin views over
>   `predictive_health_score_1d_mat` / `predictive_health_summary_mat`, refreshed
>   hourly by the TimescaleDB job `refresh_predictive_matviews_job` (`040`, logged
>   in `matview_refresh_log`). The full bodies live in `*_live` views. Scores are
>   up to an hour old; `telemetry_age_h` is computed on read.
> - **Scoring (`038`).** `subsystem_risk_score()` reads `pm_status_dictionary`
>   first and falls back to the LIKE chain; `HEAT_PUMP_DEGRADATION_LIKELY` now
>   scores 65 as the dictionary says. The 12V text asks for a diagnosis, the
>   suspension severity has a CRITICAL band, brake `remaining_pct` is clamped,
>   and HV isolation is a row in `predictive_health_recommendations`
>   (thresholds unvalidated).
> - **Scoring v2 (`051`, plan item S1).** A subsystem scores NULL when it does
>   not apply to the vehicle or its newest evidence is older than
>   `subsystem_evidence_limit()` (battery 45 d, suspension 30 d, others 14 d);
>   the overall score is renormalised over the scored subsystems; the headline
>   severity is the worst of the weighted band, any single subsystem's band and
>   any active critical alert; `highest_risk_subsystem` is NULL below 40.
>   Battery is scored on the full-charge estimator the headline shows (`049`);
>   PCS on requested-vs-actual current (`047`); 12 V and battery rest hours use
>   carried-forward vehicle state, and the brick spread uses simultaneous samples
>   (`046`); acknowledgements are per alert instance (`048`).
> - **Removed (`045`).** Air suspension (all of 015 and the Cybertruck
>   air-suspension subsystem) and the steering-offset check: their fields are not
>   sent by any Tesla through Fleet Telemetry. Sections below that describe them
>   are historical.
> - **HV isolation (`050`).** `IsolationResistance` is in kΩ (Tesla documents no
>   unit; values around 5,000); thresholds 100 / 250 kΩ.
> - **Alerts (`034`).** One row per alert instance; an alert counts as active
>   only if not ended and started within `alert_active_window()` (7 days).

---

## Table of Contents

1. [Anomaly Detection (005) — removed by 039](#1-anomaly-detection-005--removed-by-039)
2. [PCS Diagnostics (006)](#2-pcs-diagnostics-006)
3. [Heat Pump Diagnostics (007)](#3-heat-pump-diagnostics-007)
4. [12V Battery Diagnostics (008)](#4-12v-battery-diagnostics-008)
5. [Battery Health (009)](#5-battery-health-009)
6. [Suspension Diagnostics (010)](#6-suspension-diagnostics-010)
7. [Drivetrain Diagnostics (011)](#7-drivetrain-diagnostics-011)
8. [Alert Parser (012)](#8-alert-parser-012)
9. [Regen & Brake Diagnostics (013)](#9-regen--brake-diagnostics-013)
10. [Master Predictive Health (014)](#10-master-predictive-health-014)
11. [Review Fixes (025)](#11-review-fixes-025)
12. [Dual Motor Diagnostics (016)](#12-dual-motor-diagnostics-016)
13. [Cybertruck Diagnostics (017)](#13-cybertruck-diagnostics-017)

---

## 1. Anomaly Detection (005) — removed by `039`

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

## 2. PCS Diagnostics (006) — comparison replaced by `047`

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
| `pcs_session_summary` (dropped in `047`; see `pcs_charge_sessions`) | Per-session aggregation: max deficit, failure sample count, streak count, `BOOL_OR(pcs_module_failure_likely)`. |
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
  - `n_7d >= 8` and `n_30d >= 24` *(tightened in 025 — was 3 / 10; three valid hours could be a single drive in unusual weather, so the 7-day ratio was unstable)*
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

## 6. Suspension Diagnostics (010) — steering parts removed by `045`

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
| `brake_wear_estimate` | Pad record (original pads confirmed, last replacement, last inspection, miles on the set) plus a mileage model kept for compatibility: `wear_pct = (pad_miles / 50 000) × (1 – regen_ratio) × 100`, an assumed pad life, not a measurement. Since `056` no dashboard or recommendation presents it as wear; the Brakes recommendation is INFO only (telemetry has no pad-wear signal; pad condition is checked at the periodic safety inspection). |
| `regen_brake_summary` | Latest snapshot: status, `regen_ratio_pct`, `brake_remaining_pct`, `eff_trend_pct`, `regen_torque_trend_pct`. |

### Key thresholds
- **Regen degradation:** `REGEN_DEGRADATION_LIKELY` when `regen_torque_mag_7d < regen_torque_mag_30d * 0.90` OR `regen_7d < regen_30d * 0.90`
- **Efficiency anomaly:** `EFFICIENCY_ANOMALY` when `eff_7d > eff_30d * 1.15`
- Confidence: `n_drive_7d >= 3`, `n_drive_30d >= 10`
- `brake_wear_estimate.wear_pct` is clamped to `[0, 100]` (025 — N1 fix) so
  very-high-odometer vehicles don't return raw values like 320 %.

---

## 10. Master Predictive Health (014) — superseded by `051` (see the November 2026 notes above)

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

Weights sum to exactly **1.00** after the May-2026 review fix (see 025).
The expression appears in exactly one place — the `ranked` CTE inside
`predictive_health_summary` — and every downstream consumer references the
named `overall_risk_score` column rather than re-summing the weights.

```
overall_risk_score =
  battery_score        × 0.22 +
  drivetrain_score     × 0.14 +
  alert_score          × 0.15 +
  low_voltage_score    × 0.10 +
  heat_pump_score      × 0.10 +
  regen_brake_score    × 0.07 +
  suspension_score     × 0.04 +
  air_suspension_score × 0.04 +
  dual_motor_score     × 0.05 +
  cybertruck_score     × 0.04 +
  pcs_score            × 0.05
                       -------
                          1.00
```

Air-suspension and Cybertruck were trimmed from 5 % → 4 % (rather than
trimming a non-optional subsystem) because they default to a neutral 5 on
non-equipped vehicles, so the change has no effect on the typical Model 3.

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
4. **Heat-pump score ≥ 75 → "Schedule HVAC inspection …"** *(added in 025)*
5. Air-suspension score ≥ 75 → "Schedule air-suspension inspection …"
6. Dual-motor score ≥ 75 → "Schedule dual-motor inspection …"
7. Cybertruck score ≥ 75 → "Schedule Cybertruck-specific inspection …"
8. Alert score ≥ 75 with urgent alerts → "Schedule service — Urgent: …"
9. Overall ≥ 60 → "Monitor closely …"
10. Overall ≥ 40 → "Plan preventive maintenance …"
11. Else → "All systems nominal …"

### Composite scores

```
powertrain_risk = drivetrain × 0.60 + regen_brake × 0.25 + pcs × 0.15
thermal_risk    = heat_pump  × 0.60 + brick_delta_score × 0.40
```

`brick_delta_score` is a continuous mapping of the latest day's
`brick_delta_max` (V) onto 0–100 via `LEAST(100, GREATEST(0, delta × 200))`.
Before the 025 fix, `thermal_risk` blended the heat-pump score with a
two-valued step (`5` or `50`), which was effectively a step function
dressed up as a weighted blend.

### Telemetry freshness columns *(added in 025)*

`predictive_health_summary` exposes `telemetry_last_ts` and
`telemetry_age_h` so dashboards can distinguish "healthy" from "no data".
Subsystem scores default to 5 (NORMAL) when a diagnostic view returns
no rows; with these columns a panel can hide or grey-out a tile whose
underlying telemetry is older than e.g. 24 h.

### Dashboard panels (`14_predictive_health.json`)
| Row | Panel | Type | Query target |
|-----|-------|------|--------------|
| 🏥 Overview | Overall Health | Stat | `predictive_health_summary` |
| 🏥 Overview | Battery Risk | Stat | `predictive_health_summary` |
| 🏥 Overview | Powertrain Risk | Stat | `predictive_health_summary` |
| 🏥 Overview | Thermal Risk | Stat | `predictive_health_summary` |
| 🏥 Overview | **Data Freshness** *(025 — B4)* | Stat | `predictive_health_summary.telemetry_age_h` |
| 📈 Trend | Subsystem Risk Scores Over Time | Time series | `predictive_health_score_1d` |
| 🚨 Alerts | Active Alerts | Table | `parsed_alerts` ⟂ `pm_alert_ack_active` *(025 — R7: acknowledged alerts hidden)* |
| 🔧 Service | Recommended Actions | Table | `predictive_health_recommendations` |
| 📅 Service Intervals *(025 — R6)* | Service Interval Status | Table | `service_interval_status` |
| ⚡ HV Isolation *(025 — N6)* | Isolation Resistance (latest daily min) | Stat | `isolation_resistance_diagnostics` |
| ⚡ HV Isolation *(025 — N6)* | Isolation Resistance Trend | Time series | `isolation_resistance_diagnostics` |

> The overview-row stat tiles were narrowed from `w=6` to `w=5` to make
> room for the Data Freshness tile (`w=4`).  The Active Alerts panel now
> `NOT EXISTS`-filters against `pm_alert_ack_active` on
> `alert_key = alert_code`, so an acknowledged code stays hidden until its
> TTL expires.

---

## 11. Review Fixes (025)

**File:** `deploy/sql/025_pm_review_fixes.sql` — added after the May-2026
review documented in `PREDICTIVE_MAINTENANCE_RATIONALE.md`.  This file is
**purely additive**: nothing in 005–017 is dropped.

### Objects created

| Object | Type | Purpose |
|--------|------|---------|
| `refresh_predictive_matviews()` | Function | Refreshes the demoted matviews `battery_capacity_1d`, `pcs_health_1d`, `pcs_health_1w`, `heat_pump_cop_1d`, `low_voltage_wakeups_1d`.  Auto-scheduled hourly via `pg_cron` if the extension is installed; otherwise the operator must invoke it externally.  Each matview is wrapped in its own `BEGIN … EXCEPTION` so one bad refresh doesn't block the others. |
| `service_intervals` | Table | Calendar-based items (cabin filter 24 mo, brake fluid 24 mo, tire rotation 10 000 mi, A/C desiccant 72 mo, S/X coolant 48 mo).  Per-VIN overrides supported via the `applies_to` column. |
| `service_completions` | Table | Per-VIN log of "this item was done on date X at odometer Y mi". |
| `service_interval_status` | View | Computes `due_at` / `due_odometer_mi` / `status ∈ {OK, DUE_SOON, OVERDUE}` per `(vin, item)`. |
| `pm_alert_ack` | Table | Suppression entries keyed by `(vin, subsystem, alert_key)` with a TTL. |
| `pm_alert_ack_active` | View | The currently-active acknowledgements (TTL not yet expired). |
| `ack_pm_alert()` | Function | Helper that inserts a 30-day acknowledgement (or any custom TTL). |
| `pm_status_dictionary` | Table | `(status, base_score)` lookup.  New status strings can be added without editing `subsystem_risk_score()`. |
| `isolation_resistance_diagnostics` | View | Daily aggregate of `IsolationResistance` per VIN.  `< 100 kΩ` → `ISOLATION_RESISTANCE_LOW` (safety-critical via `pm_status_dictionary`). |

### Operator notes

- **Hourly refresh:** if pg_cron is not available, add a system cron entry:
  ```
  7 * * * *  psql "$NOTIFY_CONN" -c "SELECT refresh_predictive_matviews();"
  ```
- **Service-item completions** are inserted manually or via the notify bot
  (the `/logservice` flow can optionally insert into `service_completions`
  for known items).
- **Acknowledging an alert:**
  ```sql
  SELECT ack_pm_alert(
    p_vin       => 'YOUR_VIN',
    p_subsystem => 'Battery',
    p_alert_key => 'BMS_u018',
    p_days      => 30,
    p_reason    => 'Scheduled with SC on 2026-06-12'
  );
  ```

### Verification

```sql
-- B3: refresh function exists and lists every demoted matview
\df refresh_predictive_matviews
SELECT refresh_predictive_matviews();

-- B1: weights sum to 1.00
SELECT MAX(overall_risk_score) <= 100 AS sane FROM predictive_health_summary;

-- B4: freshness columns present
SELECT vin, telemetry_age_h FROM predictive_health_summary LIMIT 1;

-- R6: calendar items visible
SELECT vin, item, status, due_at FROM service_interval_status WHERE status <> 'OK';

-- N6: isolation resistance dedicated view
SELECT * FROM isolation_resistance_diagnostics WHERE status <> 'NORMAL';
```

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

---

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
… (018–024: telegram bot, user prefs, service log) …
025_pm_review_fixes.sql        ← May 2026 review fixes
```

## Appendix B: Refresh Policy Summary

| Object | Kind | Refresh | Window |
|--------|------|---------|--------|
| `*_samples_1h` | CAGG | hourly policy | last 7 days |
| `suspension_samples_1m` | CAGG | every 5 min | last 3 days |
| `alert_frequency_1d` | CAGG | hourly policy | last 30 days |
| `battery_capacity_1d`, `pcs_health_1d`, `pcs_health_1w`, `heat_pump_cop_1d`, `low_voltage_wakeups_1d` | **matview** | `refresh_predictive_matviews()` hourly via pg_cron or external cron *(installed by 025; previously these had NO automatic refresh — B3)* | full table |

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
