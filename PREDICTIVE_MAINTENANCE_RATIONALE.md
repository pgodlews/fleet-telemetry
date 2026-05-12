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
A single `predictive_health_summary` view that weights all subsystems into one 0–100 risk score:

| Subsystem | Weight |
|## 11. Air-Suspension Compressor Health

**Problem it solves**  
Vehicles with adaptive air suspension (Model Y, S, X, CT) are prone to air leaks, failing dryer cartridges, or worn compressor seals. A slow leak in an air spring causes the compressor to cycle repeatedly while parked, eventually leading to a $1,200+ burnout.

**Rationale**  
By monitoring compressor duty cycle and corner-to-corner ride-height drift during parked hours, we flag over-cycling early. The 7-day vs 30-day baseline automatically adjusts for cold weather (which shrinks seals), preventing false alarms in winter.

**Owner value**  
Catch leaks before they strand you in "Entry" mode and avoid catastrophic compressor burnout.

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

-----------|--------|
| Battery Health | 22 % |
| Alerts | 15 % |
| Drivetrain | 14 % |
| 12V Battery | 10 % |
| Heat Pump | 10 % |
| Regen / Brake | 7 % |
| Air Suspension | 5 % |
| Dual Motor | 5 % |
| Cybertruck | 5 % |
| PCS | 5 % |
| Suspension | 4 % |

Scores: 0–30 = Healthy (green), 31–60 = Caution (yellow), 61–80 = Warning (orange), 81–100 = Critical (red). Composite "Powertrain" (Drivetrain+Regen+PCS) and "Thermal" (Heat Pump+Battery thermal) scores are also provided for the top-level dashboard Stat row.

**Owner value**  
At-a-glance “Your car is healthy / yellow / red” with one-click drill-down. This is what turns the project from “cool telemetry” into the definitive owner tool.

---

**Overall Design Philosophy**  
- **Deterministic where possible** (PCS deficit, specific BMS codes, UI_a006)  
- **Statistical elsewhere** (anomalies, trends)  
- **Zero external services** — everything lives in TimescaleDB + Grafana  
- **Simulator-first testing** — every view can be validated with synthetic failures  

This architecture gives owners **earlier, more precise, and cheaper** visibility into the exact failure modes that actually plague 2021+ Model 3/Y vehicles — all while staying completely self-hosted and open-source.

---

