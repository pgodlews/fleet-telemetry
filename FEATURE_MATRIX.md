# Tesla Fleet Telemetry — Feature Matrix by Model & Configuration

This matrix defines exactly which predictive diagnostics are relevant for each Tesla model and variant.  
All features are **automatically enabled/disabled** in SQL views and Grafana dashboards using the `vehicle_metadata` table (populated via VIN decoder + `CarType` field).

## Feature Matrix

| Feature / Diagnostic                                      | Model 3 SR+/RWD | Model 3 LR AWD | Model 3 Performance | Model Y RWD/Base | Model Y LR AWD | Model Y Performance | Cybertruck (Std) | Cybertruck Cyberbeast (Tri-Motor) | SQL / Grafana Enforcement |
|-----------------------------------------------------------|-----------------|----------------|---------------------|------------------|----------------|---------------------|------------------|------------------------------------|---------------------------|
| ~~**Anomaly Detection Foundation**~~ (removed by `039`, unused) | — | — | — | — | — | — | — | — | Removed |
| **PCS (Onboard Charger Module Failure)**                  | ✅              | ✅             | ✅                  | ✅               | ✅             | ✅                  | ✅               | ✅                                 | Always on |
| **Heat Pump / Octovalve Degradation**                    | ✅              | ✅             | ✅                  | ✅               | ✅             | ✅                  | ✅               | ✅                                 | Always on (post-2021) |
| **12V Battery / DC-DC Wake-up Monitoring**                | ✅              | ✅             | ✅                  | ✅               | ✅             | ✅                  | ✅               | ✅                                 | Always on |
| **HV Battery Health** (rest-capacity snapshots)           | ✅              | ✅             | ✅                  | ✅               | ✅             | ✅                  | ✅ (4680)        | ✅ (4680)                          | Always on (battery_type adjusted) |
| **Suspension & Alignment** (UI_a006 + lateral accel)      | ✅              | ✅             | ✅                  | ✅               | ✅             | ✅                  | ✅               | ✅                                 | Always on |
| **Dual-Motor Balancing** (front/rear temp & axle delta)   | ❌              | ✅             | ✅                  | ❌               | ✅             | ✅                  | ✅               | ✅                                 | `WHERE motor_config IN ('Dual Motor', 'Performance', 'Tri Motor')` |
| **Regen & Power Limit Degradation** (tighter thresholds) | Baseline        | ✅ (tighter)   | ✅ (aggressive)     | Baseline         | ✅ (tighter)   | ✅ (aggressive)     | ✅ (tighter)     | ✅ (tighter)                       | Model-aware thresholds |
| **Performance Thermal Throttling Detection**              | N/A             | N/A            | ✅ (aggressive)     | N/A              | N/A            | ✅ (aggressive)     | N/A              | ✅ (aggressive)                    | `WHERE motor_config LIKE '%Performance%' OR motor_config = 'Tri Motor'` |
| **Tonneau Cover Health** (position, motor, stuck)         | ❌              | ❌             | ❌                  | ❌               | ❌             | ❌                  | ✅               | ✅                                 | `WHERE model = 'CT'` |
| **V2L (Vehicle-to-Load) Export Monitoring**               | ❌              | ❌             | ❌                  | ❌               | ❌             | ❌                  | ✅               | ✅                                 | `WHERE model = 'CT'` |
| **4680 Structural Battery Baselines**                     | N/A             | N/A            | N/A                 | N/A              | N/A            | N/A                 | ✅               | ✅                                 | `WHERE battery_type = '4680'` |
| **Tri-Motor Specific Balancing**                          | ❌              | ❌             | ❌                  | ❌               | ❌             | ❌                  | ❌               | ✅                                 | `WHERE motor_config = 'Tri Motor'` |
| **Cybertruck Predictive Health** (tonneau, V2L, 4680, tri-motor) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | `WHERE model = 'CT'` |

> **November 2026 (`045`, `051`).** Air-suspension diagnostics and the steering-offset check were removed: `AirSuspensionHeight*`, `AirSuspensionCompressorState`, `AirSuspensionMode` and `SteeringAngle` are not sent by any Tesla through Fleet Telemetry (not in the vehicle proto, upstream's current proto, or Tesla's published field list). A subsystem that does not apply to the vehicle (✗ / N/A below) or has no recent evidence now scores NULL and is left out of the weighted total, instead of counting as a healthy 5.

### Legend
- **✅** = Fully enabled and relevant  
- **❌** = Disabled / no rows returned / panels hidden  
- **Baseline** = Uses generic thresholds (still useful)  
- **N/A** = Not applicable for this configuration

### How Enforcement Works
All predictive views (`dual_motor_diagnostics`, `cybertruck_diagnostics`, etc.) join on `vehicle_metadata` and use `WHERE` clauses or `CASE` statements based on the columns above.

Grafana dashboards use variables `$model` and `$motor_config` + panel visibility overrides so irrelevant panels are automatically hidden.
---
