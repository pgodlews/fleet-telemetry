# Predictive Telemetry Architecture — Rationale & Design Decisions

This document explains the **why** behind each predictive maintenance feature in the Tesla Fleet Telemetry project. All logic is implemented 100% in SQL on the existing EAV hypertable, Continuous Aggregates (CAGGs), and views — no external ML, no stateful Go code.

## 1. TimescaleDB & SQL-Native Anomaly Detection (Foundation)

**Problem it solves**  
Raw 30-second telemetry is too noisy and voluminous for every dashboard query. Owners need fast, reliable baselines to detect subtle degradation before it becomes a service visit.

**Rationale**  
- TimescaleDB CAGGs are purpose-built for this exact use case (high-frequency time-series → hourly/daily materialized views).
- Rolling Z-scores and Median Absolute Deviation (MAD) via window functions are mathematically robust, deterministic, and require zero external dependencies.
- Early anomaly detection catches **everything** else in this architecture before it escalates.

**Why it works with 30 s sampling**  
Statistical baselines over days/weeks are far more valuable than sub-second resolution for long-term trends.

**Owner value**  
Per-field anomaly scores (z-score + MAD) with a "Current Risk Score" Stat panel. This is the statistical foundation that feeds into the unified Master Predictive Health dashboard (see §10).

## 2. Power Conversion System (PCS) Diagnostics

**Problem it solves**  
The onboard AC charger uses three independent 16 A power modules. Failure of one (or two) is extremely common on 2021+ Model 3/Y and reduces max AC charging from 48 A → 32 A → 16 A. Owners often only notice when it’s already severe.

**Rationale**  
Tesla’s telemetry exposes `ChargeCurrentRequestMax` vs actual delivered current (`ChargeAmps` / `ACChargingPower`). A mathematically perfect and persistent deficit of **exactly 16 A or 32 A** is a deterministic smoking gun — no statistics needed.

**Why it works with 30 s sampling**  
Charging sessions last minutes to hours; a consistent deficit across multiple samples and multiple sessions is conclusive.

**Owner value**  
Catches the failure at the first module instead of waiting for the “Charge rate reduced” message or 16 A limit. Huge cost/time savings vs waiting for Tesla service.

## 3. Heat Pump & Thermal Management (Octovalve)

**Problem it solves**  
2021 Model 3 heat-pump vehicles had widespread PT (pressure/temperature) sensor drift, compressor fatigue, and Octovalve issues, leading to poor heating performance, higher power draw, and eventual failure (multiple service bulletins and recalls).

**Rationale**  
COP (Coefficient of Performance) degradation is a classic early indicator. By tracking HVAC power draw vs temperature delta (`InsideTemp - OutsideTemp`) over weeks, we detect the “needs more power for the same ΔT” pattern before the car throws an overt fault.

**Why it works with 30 s sampling**  
Trends are multi-week; 30-second data is more than sufficient for rolling averages.

**Owner value**  
Early warning before winter leaves you without heat or before the compressor fails completely.

## 4. Low-Voltage (12V) System Degradation

**Problem it solves**  
Failing 12 V batteries are one of the most common Tesla issues. They cause random wake-ups, phantom alerts, “car won’t wake”, and cascading faults. High-frequency voltage sags are invisible at 30 s, but the **symptom** is not.

**Rationale**  
A dying 12 V battery forces the DC-DC converter (`DCDCEnable`) to wake the car repeatedly to keep it charged. We count these sleep/wake cycles during parked periods and look for sudden spikes vs baseline.

**Why it works with 30 s sampling**  
The frequency of DC-DC activations is the reliable proxy — exactly what the 30-second stream captures well.

**Owner value**  
Prevents the dreaded “dead car in the garage” scenario and avoids unnecessary 12 V replacements.

## 5. High-Voltage Battery Health

**Problem it solves**  
Battery capacity fade, brick imbalances, and early cell degradation are hard to track without Scan My Tesla or service visits.

**Rationale**  
- Derived capacity (`EnergyRemaining / (BatteryLevel/100)`) captured only during true thermal rest (>4 h parked, low power draw < 500 W) gives accurate long-term degradation curves. No direct `nominal_full_pack_energy` field is streamed.
- Direct BMS alerts (`BMS_u018` = SOC imbalance, `BMS_f064` = brick voltage imbalance, `UI_a006`, etc.) are streamed and deterministic.

**Why it works with 30 s sampling**  
Rest-period snapshots and alert codes are low-frequency events.

**Owner value**  
Quantified % degradation over time + immediate alerts for serious cell issues — the #1 thing owners worry about.

## 6. Suspension and Alignment

**Problem it solves**  
Upper control arms, lateral link bushings, and ball joints wear faster than expected (common at 40–80 k miles). Early detection prevents uneven tire wear and expensive alignment jobs.

**Rationale**  
- Primary: `UI_a006` chassis/alignment alert is a direct factory diagnostic.
- Secondary: Correlation of `LateralAcceleration` + steering angle at steady highway speeds reveals increasing mechanical drag.

**Why it works with 30 s sampling**  
Highway segments are long; progressive offset trends appear clearly in aggregates.

**Owner value**  
Catch bushing wear before it causes noise, vibration, or tire wear.

## 7. Drivetrain / Motor & Inverter Health (Addition)

**Problem it solves**  
Inverter and motor temperatures, power/regen limits, and gradual performance loss are early signs of thermal or mechanical degradation.

**Rationale**  
Monitor max inverter/stator temps during sustained load and track reductions in available regen/power limits against historical baselines.

**Owner value**  
Early warning before the car starts throttling power on the highway.

## 8. Comprehensive Alert Parser & Historical Trends (Addition)

**Problem it solves**  
Tesla streams dozens of cryptic alert codes (`BMS_*`, `PCS_*`, `UI_*`, `CC_*`, etc.) that most owners never see until it’s too late.

**Rationale**  
Structured parsing + CAGGs for frequency, recurrence, and subsystem trends turns raw alert strings into actionable history.

**Owner value**  
A single “Active Critical Alerts” panel with human-readable explanations and trend graphs.

## 9. Regen & Brake Health + Efficiency Anomalies (Addition)

**Problem it solves**  
Progressive loss of regen capability and hidden brake wear (because most braking is done by regen).

**Rationale**  
- Track max available regen vs baseline under identical conditions.
- Estimate brake pad life with a linear wear model: `wear_pct = (odometer / 50 000 mi) × (1 – regen_ratio) × 100`. Heavy regen users (> 30 %) see 70 000–100 000 mi pad life; light regen users (< 10 %) may see only 35 000 mi.

**Owner value**  
Know when regen is degrading **and** when the friction brakes will actually need service.

## 10. Master Predictive Health Dashboard & Unified Risk Score (Addition)

**Problem it solves**
Ten separate views are powerful but overwhelming.

**Rationale**
A single `predictive_health_summary` view that weights all subsystems into one 0–100 risk score. Weights below sum to **exactly 1.00** following the May-2026 review (see §11):

| Subsystem | Weight |
|-----------|--------|
| Battery Health | 22 % |
| Alerts | 15 % |
| Drivetrain | 14 % |
| 12V Battery | 10 % |
| Heat Pump | 10 % |
| Regen / Brake | 7 % |
| Dual Motor | 5 % |
| PCS | 5 % |
| Suspension | 4 % |
| Air Suspension | 4 % |
| Cybertruck | 4 % |
| **Total** | **100 %** |

Scores: 0–30 = Healthy (green), 31–60 = Caution (yellow), 61–80 = Warning (orange), 81–100 = Critical (red). Composite "Powertrain" (Drivetrain+Regen+PCS) and "Thermal" (Heat Pump+Battery brick imbalance) scores are also provided for the top-level dashboard Stat row.

> **Note on the weights:** air-suspension and Cybertruck were trimmed from
> 5 % → 4 % (rather than trimming a non-optional subsystem) because they
> default to a neutral 5 on non-equipped vehicles, so the rebalance has no
> effect on the typical Model 3.

**Owner value**
At-a-glance “Your car is healthy / yellow / red” with one-click drill-down. This is what turns the project from “cool telemetry” into the definitive owner tool.

---

## 11. Review Fixes (May 2026)

The original predictive stack (005–017) accumulated three classes of
problem over development: weight-arithmetic drift, scale-mixing in
composite formulas, and silently-frozen materialized views.  These were
identified during a full code review and addressed in
`deploy/sql/025_pm_review_fixes.sql` — purely additive, no rewrites.

### Bugs fixed in-place

| ID | Where | Symptom before | Fix |
|----|-------|----------------|-----|
| **B1** | 014 `predictive_health_summary` | weights summed to 1.02, so `overall_risk_score` could reach 102 | weights rebalanced to 1.00; expression hoisted into a `ranked` CTE so it is computed exactly once |
| **B2** | tools/notify | `Odometer` stored in `service_log.odometer_km` as raw miles | `fetchCurrentOdometer` now converts miles → km at the boundary; user-facing strings honour `cfg.Units` via `formatOdometer()` |
| **B3** | 006 / 007 / 008 / 009 | five matviews demoted from CAGGs and left without any refresh policy | `refresh_predictive_matviews()` introduced; auto-scheduled hourly via pg_cron, or callable from external cron |
| **B4** | 014 `predictive_health_summary` | missing-subsystem rows defaulted to 5 (NORMAL) — indistinguishable from "no data" | view now exposes `telemetry_last_ts` and `telemetry_age_h`; dashboards can grey-out tiles older than e.g. 24 h |

### Risks addressed

| ID | Where | Fix |
|----|-------|-----|
| **R1** | 014 `thermal_risk` | replaced the two-valued `CASE … 5 vs 50` step with a continuous `LEAST(100, GREATEST(0, brick_delta × 200))` mapping |
| **R2** | 007 heat-pump | `n_7d >= 3` → `n_7d >= 8`, `n_30d >= 10` → `n_30d >= 24`; the previous floors allowed a single drive in unusual weather to trip the ratio test |
| **R3** | 009 `battery_capacity_1d` | the 5-line "rest hour" predicate is now computed once as an `is_rest` boolean in a CTE rather than inlined into five separate `FILTER` clauses |
| **R6** | 025 (new) | `service_intervals` + `service_completions` + `service_interval_status` view: calendar-based maintenance items (cabin filter, brake fluid, A/C desiccant, tire rotation, S/X coolant) finally tracked |
| **R7** | 025 (new) | `pm_alert_ack` table + `ack_pm_alert()` helper: a known alert can be muted for N days while service is being scheduled |
| **R8** | 025 (new) | `pm_status_dictionary` table backing `subsystem_risk_score` so new status strings can be registered without editing the function body |

### Nits addressed

| ID | Where | Fix |
|----|-------|-----|
| **N1** | 013 `brake_wear_estimate` | `wear_pct` clamped to `[0, 100]` |
| **N4** | 014 `recommended_action` | added a `WHEN heat_pump_score >= 75 THEN 'Schedule HVAC inspection …'` branch so heat-pump degradation actually triggers a service recommendation |
| **N6** | 025 (new) | `isolation_resistance_diagnostics` promoted from anomaly z-score to a dedicated safety-critical indicator; `< 100 kΩ` triggers `ISOLATION_RESISTANCE_LOW` (score 95 via the dictionary) |

### Honest things that remain unchanged

The deeper rationale issues called out by the review are **not** silently
papered over by 025.  They are intentionally left as documented limitations
so a future contributor can prioritise them:

- **Brake-pad linear model** (`50 000 mi × (1 − regen_ratio)`) is still
  uncited and has no validation cohort.  The clamp in N1 prevents nonsense
  values from leaking into composites; it does not improve the model.
- **Heat-pump 1.15× / 3 °C thresholds** remain ad hoc.  Only the sample-
  count floor was raised.
- **Drivetrain absolute temperature limits** (85 °C inverter, 90 °C
  heatsink, 120 °C stator) still lack an OEM citation.
- **Suspension `lat_accel_stddev` proxy** when `SteeringAngle` is absent
  is still an unvalidated correlation.
- **Master-score weights** are still chosen by feel; the rebalance in
  B1 only ensured they sum to 1.00.

---

**Overall Design Philosophy**
- **Deterministic where possible** (PCS deficit, specific BMS codes, UI_a006, isolation resistance threshold)
- **Statistical elsewhere** (anomalies, trends) — with sample-count floors
- **Acknowledgeable** — owners can mute a known alert while service is scheduled
- **Calendar-aware** — service intervals (filters, fluids, rotation) live alongside statistical anomalies
- **Zero external services** — everything lives in TimescaleDB + Grafana
- **Simulator-first testing** — every view can be validated with synthetic failures

This architecture gives owners **earlier, more precise, and cheaper** visibility into the exact failure modes that actually plague 2021+ Model 3/Y vehicles — all while staying completely self-hosted and open-source.

---

## 12. Dual Motor Diagnostics

**Problem it solves**  
Dual-motor configurations (AWD, Performance, Tri-Motor) can develop front-vs-rear imbalances in the differential, half-shaft wear, or uneven thermal degradation that single-motor tracking misses.

**Rationale**  
Compares `DiInverterTF` vs `DiInverterTR` (temperatures) and `DiAxleSpeedF` vs `DiAxleSpeedR` (imbalance) at highway speeds. It applies tighter thresholds for Performance variants (e.g., 2.5% vs 3% allowable imbalance).

**Owner value**  
Detects half-shaft binding or differential drag before it causes audible vibration or total failure.

## 13. Cybertruck Diagnostics

**Problem it solves**  
The Cybertruck introduces unique hardware: the power tonneau cover, V2L (Powershare), 4680 structural packs, and tri-motor Cyberbeast vectoring, which standard Tesla telemetry models do not cover.

**Rationale**  
- **Tonneau:** Tracks `TonneauOpenPercent` and flags stuck motor events before complete failure.
- **V2L:** Monitors sustained high-load exports (> 5 kW for 4+ hours) and associated inverter thermal stress.
- **4680:** Establishes CT-specific battery degradation baselines (flagging > 7% as early degradation).
- **Tri-Motor:** Monitors rear-left vs rear-right inverter deltas.

**Owner value**  
The definitive self-hosted tool for Cybertruck owners, catching known failure modes (tonneau, V2L overheating) before they impact utility.
