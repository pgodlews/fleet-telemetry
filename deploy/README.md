# Tesla Fleet Telemetry — operator runbook

Production stack on Prod Server (`<SERVER_IP>`). Ingests real-time Model 3 telemetry
via mTLS WebSocket into TimescaleDB + PostGIS. Grafana visualises 15 dashboards
covering every vehicle subsystem.

A parallel **test environment** on <test-machine> runs the same stack with simulated VINs
for dashboard development without touching production data.

---

## Stack at a glance

### Production (Prod Server)

| Component | Where | Details |
|-----------|-------|---------|
| **TimescaleDB** | Prod Server | `timescale/timescaledb-ha:pg16`, data at `/u01/tesla/pgdata` |
| **fleet-telemetry** | Prod Server | Tesla's Go ingest server, `:4443` mTLS WebSocket |
| **Grafana** | Prod Server | `http://<SERVER_IP>:3003`, profile `live` |
| **autossh tunnel** | <test-machine> | `<test-machine>:5433 → prod-server:5432` for local DB access |

Compose file: `deploy/docker-compose.yml`  
Start: `docker compose --profile live up -d`

### Test (<test-machine>)

| Component | Where | Details |
|-----------|-------|---------|
| **TimescaleDB** | <test-machine> | port `5435` (avoids conflict with Prod Server tunnel on 5433) |
| **Grafana** | <test-machine> | `http://<test-machine>:3004`, `admin` / `admin` |
| **Simulator** | <test-machine> | 3 fake VINs + real VIN synced from Prod Server, 90-day backfill |
| **fleet-telemetry** | <test-machine> | optional, profile `ft`, port `4444` |

Compose file: `deploy/docker-compose.test.yml`  
Start: `docker compose -f deploy/docker-compose.test.yml up -d`

Prod Server IP: `<SERVER_IP>`  
Real VIN: `<YOUR_VIN>`

---

## Tesla app credentials

**App (active — `ft.example.com`, created 2026-05-07):**

| Key | Value |
|-----|-------|
| Client ID | `<YOUR_CLIENT_ID>` |
| Client Secret | `<YOUR_CLIENT_SECRET>` |
| Audience | `https://fleet-api.prd.eu.vn.cloud.tesla.com` |
| Partner domain | `ft.example.com` |
| Keypair | `/etc/tesla/` on the production server - **verify which one is live**, see section 5. The served public key currently matches `private-key.pem`, not `private-key-v2.pem`. |
| Telemetry hostname | `tesla.example.com:4443` |

> **Why two domains?**  
> `tesla.example.com` — the fleet-telemetry TLS endpoint (Let's Encrypt cert, nginx).  
> `ft.example.com` — the Tesla partner registration domain (serves the EC public key at
> `/.well-known/appspecific/com.tesla.3p.public-key.pem`). Tesla's "Public key hash
> already taken" error forced a separate subdomain with a new v2 keypair.
>
> 💡 The `ft.example.com` well-known endpoint is only strictly required during initial
> setup (partner registration + virtual key pairing). Leave it up in case you need to
> re-pair in the future.

**Old app (retired — scopes lacked `vehicle_cmds`):** kept for reference only.

---

## Telemetry field config (227 fields, as of 2026-05-07)

The car streams 227 fields at intervals from 10 s (speed, location) to 3600 s
(static vehicle info). The config was pushed via the Vehicle Command HTTP Proxy.

Fields excluded: `Unknown`, `Deprecated_*`, `Experimental_*` (Tesla rejects them),
`Semitruck*`, `Tonneau*` (not fitted).  
`SelfDrivingMilesSinceReset` and other odometer/energy fields require
`minimum_delta: 1.0` — already set.

---

## Database schema (migrations)

SQL migrations live in `deploy/sql/`. They are idempotent, but **filename order
is not dependency order** — `deploy/sql/migrations.txt` is the authoritative
manifest and `deploy/sql-init/00_apply_migrations.sh` is the runner that applies
it. (`014_predictive_health.sql` reads views created by `015`–`017`, so a plain
`for f in sql/*.sql` loop fails on a clean install with
`relation "air_suspension_diagnostics" does not exist`.)

| File | Description |
|------|-------------|
| `001_schema.sql` | Core hypertable: `telemetry`, `vehicle_alerts`, `vehicle_errors`, `vehicle_connectivity`, compression + retention policies |
| `002_views.sql` | `vehicle_prefs`, unit-conversion functions (`to_dist`, `to_temp`, `to_pressure`), `trips`, `charge_sessions` |
| `003_grafana_role.sql` | `grafana_ro` role with SELECT on all public tables |
| `004_field_catalog.sql` | Searchable field metadata |
| `005_predictive_anomalies.sql` | Anomaly detection foundation |
| `005_vehicle_metadata.sql` | Automatically populated model features and attributes |
| `006_pcs_diagnostics.sql` | Power Conversion System health scoring + daily/weekly matviews |
| `007_heat_pump_diagnostics.sql` | Heat pump COP analysis |
| `008_low_voltage_diagnostics.sql` | 12V battery health and wake-up tracking |
| `009_battery_health.sql` | Degradation, IR, DCIR, brick delta, capacity |
| `010_suspension_diagnostics.sql` | Steering wheel angle, G-force, suspension load |
| `011_drivetrain_diagnostics.sql` | Motor temperatures, efficiency, range scoring |
| `012_alert_parser.sql` | `vehicle_alerts` normalisation, severity classification, frequency matview |
| `013_regen_brake_diagnostics.sql` | Regen brake fade, pad wear estimation |
| `014_predictive_health.sql` | `predictive_health_summary` — cross-subsystem risk scores + recommended actions |
| `015_air_suspension_diagnostics.sql` | Air suspension duty cycle, height deviation — removed again by `045` (fields not sent through Fleet Telemetry) |
| `016_dual_motor_diagnostics.sql` | Front/rear motor balance, temperature delta, efficiency split |
| `017_cybertruck_diagnostics.sql` | Cybertruck-specific: tonneau, V2L, tri-motor, 4680 cells |
| `018`–`033` | Notify state, prefs, service log, review fixes (see each file's header) |
| `034_alert_dedup.sql` | One row per alert instance; unique (vin, name, ts); active = not ended and < 7 days old |
| `035_charge_sessions_detailed.sql` | `charge_sessions` from `DetailedChargeState`, ended by the terminating row |
| `036_notify_watchdog.sql` | State for the notify staleness watchdog |
| `037_service_intervals.sql` | Fast `service_interval_status`; token `applies_to`; heat-pump / model-year gates |
| `038_status_dictionary_and_texts.sql` | Scoring reads `pm_status_dictionary`; 12V/suspension/brake texts; HV isolation row |
| `039_drop_anomaly_layer.sql` | Drops the unused anomaly CAGGs/views |
| `040_matview_refresh.sql` | Weekly rollups fixed; unique keys; `matview_refresh_log`; hourly TimescaleDB job |
| `041_health_matviews.sql` | Stores `predictive_health_score_1d` / `_summary` (dashboard 14) |
| `042_roles.sql` | `grafana_ro` password from env; grants |
| `043_vehicle_metadata_override.sql` | `vehicles.manual_override`; fewer guessed features |
| `044_function_search_path.sql` | Scoring function works during `pg_restore` (empty search_path) |
| `045_remove_unsupported_fields.sql` | Removes air suspension and steering angle (fields no Tesla sends) |
| `046_vehicle_state_carry_forward.sql` | `vehicle_state_1h`; rest/sleep hours from last known state; simultaneous brick spread |
| `047_pcs_requested_current.sql` | PCS check against the requested current in force (`pcs_charge_current`, `pcs_charge_sessions`) |
| `048_alert_ack_instances.sql` | Acknowledgements per alert instance (`ack_alert_instance`, `alert_is_acknowledged`) |
| `049_battery_estimator.sql` | One battery estimator; non-overlapping windows; BMS-only battery alerts |
| `050_isolation_units.sql` | `IsolationResistance` thresholds in kΩ |
| `051_health_scoring_v2.sql` | Scores NULL without evidence or applicability; renormalised total; headline severity |
| `052_dashframe_role.sql` | `dashframe_ro` (read-only consumer) created NOLOGIN if missing; its SELECT grants |
| `053_owner_decisions.sql` | Brake row INFO without a pad record (bot item `brake_pads`); UI_a111 INFO; LFP brick spread gated below 90 % SOC and not scored |
| `054_vin_battery_chemistry.sql` | Battery chemistry from VIN position 7 (Model 3/Y: F = LFP, E = NCA/NMC); existing rows re-derived |
| `055_alert_ignore_and_brake_baseline.sql` | Per-vehicle ignored alert codes; original-pads baseline; brake inspection item; Brakes row capped at WARNING |
| `056_brake_info_only.sql` | Brakes row INFO only (no risk score, no wear percentage); brake service items record-only; neutral regen assessment |
| `057_packfade_capacity.sql` | EXPERIMENTAL: `packfade_segments` (per-drive apparent capacity from V×I) and the result tables of the Packfade-method fade estimate |
| `058_route_efficiency.sql` | EXPERIMENTAL: `pack_energy_between`, `route_trip_observations` and the result tables of the frequent-route efficiency monitor |

The authoritative order is `sql/migrations.txt`, not the file numbers.

### Applying migrations

A fresh volume applies the manifest automatically: compose mounts `./sql` at
`/sql` and `./sql-init` into `docker-entrypoint-initdb.d`, so the runner is the
first thing the entrypoint executes.

For an existing database:

```bash
cd deploy && make migrate          # applies whatever is outstanding
make migrate-status                # what has been applied, and when
FORCE=1 make migrate               # re-apply everything (all files are idempotent)
```

The runner records each applied file in `schema_migrations` and skips it next
time. Every file is applied with `ON_ERROR_STOP=1`, so a failure aborts the run
instead of continuing into a half-built schema.

**Existing installs**: databases migrated by hand before this runner existed
have no `schema_migrations` rows, so the first `make migrate` would re-apply
everything. That is safe (the files are idempotent) but slow — `027` repopulates
`trips_mat` from scratch. To adopt the runner without re-applying, mark the
history as already done first:

```bash
docker exec -i tesla-timescaledb psql -U postgres -d tesla -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (
  filename text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());
INSERT INTO schema_migrations (filename)
SELECT unnest(ARRAY[...])   -- every file already applied, e.g. up to 029
ON CONFLICT DO NOTHING;
SQL
```

Directly, without the runner (matches what the manifest does):

```bash
ssh prod-server
cd /u01/fleet-telemetry/deploy
grep -v '^#' sql/migrations.txt | grep -v '^$' | while read -r f; do
  echo "=== $f ==="
  docker exec -i tesla-timescaledb psql -U postgres -d tesla -v ON_ERROR_STOP=1 < "sql/$f" || break
done
```

### grafana_ro access

No manual step. `003` sets default privileges so everything `postgres` creates
later is readable by `grafana_ro`, and `042_roles.sql` (last in the manifest)
re-applies the grants and sets the role's password from `GF_TESLA_DB_PASSWORD`
(passed into the database container as `GRAFANA_RO_PASSWORD`). Changing the
password in `.env` therefore needs `docker compose up -d timescaledb grafana`
followed by `make migrate FORCE=1` (or a manual `ALTER ROLE`).

### Stored values: enum prefixes

Enum values are stored exactly as the proto stringifies them, **with the
prefix**: `ShiftStateP`, `HvacPowerStateOn`, `SentryModeStateArmed`,
`DetailedChargeStateCharging`. `ChargeState` is the charger state machine
(`Idle / Enable / ClearFaults / Shutdown / Startup / QualifyLineConfig`), not the
charging state, and never reads `Charging`. Use `DetailedChargeState` for
"is it charging" (as `charge_sessions` and the notify bot do since `035`).
`Gear` reads `invalid` while the car is parked or asleep (it almost never sends
`P`), and `VehicleSpeed` is NULL then; `046`'s `vehicle_state_1h` treats both as
parked. `PackCurrent` is positive into the battery (charging, regen) and
negative out of it (driving, parked loads). `IsolationResistance` is in kΩ.
`ACChargingEnergyIn` is energy from an AC supply at the charger input,
`DCChargingEnergyIn` energy into the battery from any charger.

### Ignoring an alert code for one vehicle

Some alerts are artefacts of one installation (for example `UI_a111`, the
dashcam USB drive not SuperSpeed, raised by a Raspberry Pi emulating the USB
drive while it enumerates). Ignore the code for that vehicle; it is matched
exactly or with an underscore suffix (`UI_a111` covers
`UI_a111_DashcamUsbDriveNotSuperSpeed`):

```sql
SELECT ignore_alert_code('<VIN>', 'UI_a111', 'why it can be ignored');   -- add or update
SELECT unignore_alert_code('<VIN>', 'UI_a111');                          -- remove
SELECT * FROM pm_alert_ignore;                                           -- list
```

An ignored code is never active: it is left out of `alert_critical_active`
(every count, the alert score and the headline), of the active-alert tables
on dashboards 12 and 14 and of the daily score series. Its history stays;
dashboard 12 marks it "Ignored". A reason is required.

### Brake pads: original set, replacements, inspections

Telemetry has no pad-wear signal, and regen-heavy cars commonly exceed
100k mi on a set, so since `056` the Brakes row in
`predictive_health_recommendations` is information only: no risk score,
severity INFO in every state, and the text states the recorded pad history
without a wear percentage. Pad condition is checked at the periodic safety
inspection. What the row shows:

- nothing recorded: "No pad history recorded (N mi on the odometer)";
- original factory pads confirmed by the owner:
  `SELECT confirm_original_brake_pads('<VIN>', 'owner: pads never replaced');`
  (stored in `brake_pads_baseline`; the date is when it was confirmed, not a
  service date): "Original pads at N mi (owner-confirmed)";
- a pad replacement logged in the bot (service item `brake_pads`): its date,
  odometer and the miles on the set;
- a brake inspection logged in the bot (service item `brake_inspection`,
  "pads checked"): its date; the row is OK while it is under 12 months old.

Both service items are record-only (`applies_to = 'none'`): the bot offers
them, but `service_interval_status` never lists them as due. The mileage
model (`brake_wear_estimate.wear_pct` / `remaining_pct`, 50,000 mi assumed
pad life) is kept as columns for compatibility and is not shown on the
dashboards; dashboard 13 shows the pad record instead. The regen torque and
efficiency trend still feed `regen_brake_score`.


### Experimental: capacity fade (Packfade method)

The method is adapted from Packfade (https://github.com/pgodlews/packfade, MIT
licence) by the same author; the Go fitting routine in `tools/notify/packfade/fit.go`
is a port of Packfade's browser engine and carries its licence notice. It is
experimental and is not part of the predictive health score.

**Observable.** For one drive, apparent capacity = energy that left the pack ÷
(SOC used / 100). The energy is the trapezoidal integral of −PackVoltage ×
PackCurrent (current is positive into the pack, so regen is subtracted) between
the first and last Soc sample of the drive; an interval longer than 90 s is not
integrated and the covered share is reported (`coverage`). `packfade_segments`
also gives mean outside temperature, mean SOC, mean power, distance, hours since
SOC was last ≥ 99 %, the BMS `EnergyRemaining` drop (comparison only), the
largest SOC rise and the charging-counter increase.

**Why per drive.** Measured on production data (Nov 2026, 619 drives): contiguous
discharge between charge sessions (71 segments) is only 10–58 % covered by power
samples, because the car sends nothing while asleep, and its ≥ 20 % segments
scatter about four times more than single drives (IQR 16 % vs 3.5 %).

**Rules** (fixed from the measured noise before any fade was fitted):

| Rule | Value | Why |
|---|---|---|
| Charging inside | AC/DC counter rise > 0.5 kWh or SOC rise > 1 pp | 16 of 619 drives include charging (mostly Supercharger stops) |
| Power coverage | ≥ 90 % | gaps would invent or lose energy |
| SOC used | ≥ 5 pp | below it the robust per-drive scatter is 34–64 % |
| Temperature | required | covariate |
| Insufficient data | < 15 drives, < 8 days or < 90-day span | too little to fit a trend |

**Weights.** Soc steps are about 0.0392 pp, so quantization (delta method:
2·q²/12 ÷ drop²) is negligible; the BMS SOC estimate itself is the error, taken
as 1.0 pp per reading (robust scatter of 2–10 pp drives). Var(ln C) = 0.05² +
2·(q²/12 + 1.0²) ÷ drop², the 0.05 floor as in Packfade.

**Fit.** ln C = b0 − bt·t + γ·temperature (t in years), WLS + Huber IRLS
(k = 1.345, MAD scale of weight-standardised residuals), 500-sample date-clustered
bootstrap (seed 7, Packfade's mulberry32) for the 95 % interval. Mean SOC and mean
power were tried and left out: on the 35 usable drives they are correlated with
time (r = 0.43 and −0.42), moved the fade estimate by tens of %/year, and changed
the residual scale by under 10 %. Temperature stays (it is also correlated with
time, r = −0.65, which is why it must be in the model). Two variants are stored: `all` and `calibrated_start` (drives
starting within 24 h of SOC ≥ 99 %).

**Running.** The notify daemon recomputes when the newest estimate is more than
23 h old (checked hourly). On demand, inside the container:

```bash
docker exec tesla-notify-daemon /app/tesla-notify --config /app/notify-config.json --packfade-once            # store
docker exec tesla-notify-daemon /app/tesla-notify --config /app/notify-config.json --packfade-once --dry-run  # print only
```

It sends no Telegram message. Output tables: `packfade_estimate` (one row per
computation and variant), `packfade_points` and `packfade_curve` (latest
computation). Dashboard 09 shows them in the "Experimental — Packfade method" row.

**Limits.** It relies on the BMS SOC, and an LFP pack's SOC drifts between full
charges; current and voltage are sampled every 30 s, so short peaks are missed;
the V×I energy reads several % below the BMS energy figures, so compare slopes,
not levels. With a few months of data the interval is wide, and the dashboard
says "Not yet distinguishable from no fade" while it includes zero.

### Experimental: route efficiency (frequent routes)

The repeated-route idea comes from Packfade's approach (https://github.com/pgodlews/packfade,
MIT licence, by the same author); the code is in `tools/notify/routeeff` and reuses the
`packfade` package's Huber-WLS and day-clustered bootstrap. Experimental; not part of the
predictive health score.

**Purpose.** On the same route at matched conditions, energy per km should be stable, so a
sustained drift points at the vehicle: tyres and pressures, alignment, a dragging brake, added
load. Pack capacity is the Packfade estimate's job.

**Routes are found in the data** each run (nothing configured):

| Rule | Value |
|---|---|
| Endpoint clusters | leader clustering, densest point first, 300 m |
| Direction | A→B and B→A are separate routes |
| Detours | distance more than 10 % off the pair's median: left out |
| Road taken | GPS tracks grouped within 300 m (symmetric max distance) of the group medoid; another road is another route |
| Qualifies | ≥ 8 trips, median ≥ 1 km, distance CV ≤ 5 % |
| Fit | ≥ 8 trips (pooled 16) on ≥ 5 days over ≥ 60 days, otherwise "insufficient data" |

Route ids are opaque hashes of the rounded endpoints; coordinates stay in the database.
`route_display_name()` names a route from `notify_places` at query time when both endpoints fall
inside saved places, otherwise "Route A", "Route B", ... by trip count.

**Energy.** `route_trip_observations` uses the BMS count: Soc drop × (EnergyRemaining / Soc at
the start), taken at or before the start and at or before the end + 60 s. On the 12 qualifying
routes (Nov 2026) the V×I integral (`pack_energy_between`, 30 s samples) scattered about twice as
much run to run (median CV 0.70) as the BMS figures (Soc-based 0.33, EnergyRemaining 0.35,
trips table 0.41); Soc has 0.02 kWh steps against EnergyRemaining's 0.12 kWh.

**Covariates offered** by the view: outside temperature, cabin minus outside temperature at the
start, HVAC on at the start, mean fan level, defrost, tyre pressure at the start (mean of four),
hours since the previous drive (cold soak), mean speed, duration. Wet or dry roads, wind and load
are not in the telemetry. A covariate is kept in the pooled model when its bootstrap interval
excludes zero, it lowers the residual scatter, and its sign is physically plausible; of two
near-duplicates on a fixed route (speed and duration) the stronger one. On the production data
that gave **temperature, duration and fan level**. Tyre pressure was rejected: its coefficient
has the wrong sign (higher pressure, more energy) because pressure tracks the season (correlation
0.71 with outside temperature, −0.75 with time). Per-route fits use time and temperature only.

**Model.** Pooled `ln(Wh/km) = route + d·t + γ·x`, each route's trips weighted by the inverse of
that route's own raw scatter (floor 0.05), Huber IRLS (k = 1.345), 500-sample day-clustered
bootstrap (seed 7). Drift = (e^d − 1)·100 %/year; positive means more energy per km.

**Running.** Daily in the notify daemon (as the Packfade estimate); on demand:

```bash
docker exec tesla-notify-daemon /app/tesla-notify --config /app/notify-config.json --route-efficiency-once            # store
docker exec tesla-notify-daemon /app/tesla-notify --config /app/notify-config.json --route-efficiency-once --dry-run  # print
```

`--route-covariates temp,fan,...` (with `--dry-run`) tries another covariate list. Results:
`route_efficiency_estimate` (pooled, one row per run), `route_efficiency_routes`,
`route_efficiency_points`, `route_efficiency_curve` (latest run). Dashboard 13 shows them in the
"Experimental — route efficiency" row.

**Limits.** The qualifying routes are mostly about 2 km, where cabin heating or cooling and
stop-start traffic dominate (robust run-to-run scatter 9–76 % per route); with months of data the interval is
wide, and the dashboard says "Not distinguishable from no drift" while it includes zero.

Second-tier diagnostic matviews are regular `MATERIALIZED VIEW`s (not CAGGs)
due to a TimescaleDB hierarchical CAGG bug after DROP+RECREATE. Since `040` they
are refreshed by a TimescaleDB job registered in the database itself
(`refresh_predictive_matviews_job`, hourly at minute 7), `CONCURRENTLY` so
dashboards never wait on a refresh. Each refresh is logged in
`matview_refresh_log`; a failed view does not stop the others, and the job is
marked failed at the end so `timescaledb_information.job_stats` and the weekly
report show it. The list includes the two predictive-health matviews from `041`
(`predictive_health_score_1d_mat`, `predictive_health_summary_mat`), which back
dashboard 14 and are therefore up to an hour old (data freshness is computed
live).

No host crontab is needed; remove any old `refresh_predictive_matviews()` cron
line once the job exists.

`vehicle_state_1h` (046) is rebuilt in full on every run (about 3 s for six
months of one vehicle). Make it incremental, like `trips_mat`, once its refresh
in `matview_refresh_log` exceeds about 30 s.

To refresh by hand:

```bash
docker exec tesla-timescaledb psql -U postgres -d tesla -c "CALL refresh_predictive_matviews_job();"
docker exec tesla-timescaledb psql -U postgres -d tesla -c \
  "SELECT DISTINCT ON (name) name, ok, finished_at, error FROM matview_refresh_log ORDER BY name, started_at DESC;"
```

The older one-by-one form still works but is no longer needed:

```bash
docker exec tesla-timescaledb psql -U postgres -d tesla -c "
  REFRESH MATERIALIZED VIEW battery_capacity_1d;
  REFRESH MATERIALIZED VIEW pcs_health_1d;
  REFRESH MATERIALIZED VIEW pcs_health_1w;
  REFRESH MATERIALIZED VIEW heat_pump_cop_1d;
  REFRESH MATERIALIZED VIEW low_voltage_wakeups_1d;
  REFRESH MATERIALIZED VIEW regen_brake_daily_1d;
  REFRESH MATERIALIZED VIEW drivetrain_highway_1d;
  REFRESH MATERIALIZED VIEW suspension_steering_1d;
  REFRESH MATERIALIZED VIEW dual_motor_highway_1d;
  REFRESH MATERIALIZED VIEW tri_motor_highway_1d;
  REFRESH MATERIALIZED VIEW ct_tonneau_daily_1d;
  REFRESH MATERIALIZED VIEW ct_v2l_daily_1d;
  REFRESH MATERIALIZED VIEW alert_frequency_1w;
"
```

---

## Quick start (Prod Server already running)

```bash
ssh prod-server
cd /u01/fleet-telemetry/deploy

# Status
docker compose ps
docker logs tesla-fleet-telemetry --tail 50

# DB check
docker exec tesla-timescaledb psql -U postgres -d tesla \
  -c "SELECT field, count(*), max(ts) FROM telemetry GROUP BY field ORDER BY 2 DESC;"

# Predictive health
docker exec tesla-timescaledb psql -U postgres -d tesla \
  -c "SELECT vin, overall_risk_score, highest_risk_subsystem, recommended_action FROM predictive_health_summary;"
```

---

## Grafana dashboards

15 dashboards provisioned automatically from `deploy/grafana/dashboards/`:

| File | UID | Title |
|------|-----|-------|
| `00_overview.json` | `tesla-overview` | Overview — SoC, speed, power, range, temp |
| `01_summary.json` | `tesla-summary` | Summary — doors, windows, climate, media, identity |
| `02_all_stats.json` | `tesla-allstats` | All Stats — every field with sparklines |
| `03_map_trips.json` | `tesla-map` | Map & Trips — GPS route + per-trip table |
| `04_energy.json` | `tesla-energy` | Energy — charging sessions, SoC history, efficiency |
| `05_powertrain.json` | `tesla-powertrain` | Powertrain — motor, pack, cell voltages, temperatures |
| `06_climate.json` | `tesla-climate` | Climate & Comfort — HVAC, cabin temp, heat pump |
| `07_safety_autopilot.json` | `tesla-safety` | Safety & Autopilot — FSD, ADAS, collision events |
| `08_security_access.json` | `tesla-security` | Security & Access — locks, sentry, phone key |
| `09_battery_health.json` | `tesla-battery-health` | Battery Health — degradation, IR, DCIR, brick delta |
| `10_suspension.json` | `tesla-suspension` | Suspension & Alignment — G-force, steering angle |
| `11_drivetrain.json` | `tesla-drivetrain` | Drivetrain Health — motor balance, temperatures |
| `12_alerts.json` | `tesla-alerts` | Alert Parser & History — severity timeline |
| `13_regen_brake.json` | `tesla-regen-brake` | Regen & Brake Health — fade, wear estimation |
| `14_predictive_health.json` | `tesla-predictive-health` | Predictive Health — cross-subsystem risk scores |

Browse: `http://<SERVER_IP>:3003/dashboards/browse` (Grafana 11 changed `/dashboards` to show starred only)

### Datasource

Datasource UID `tesla_timescaledb` (Postgres/TimescaleDB).  
Connection is configured via two env vars:

| Env var | Production | Test (<test-machine>) |
|---------|-----------|-------------|
| `GF_TESLA_DB_HOST` | `timescaledb:5432` | `timescaledb-test:5432` |
| `GF_TESLA_DB_PASSWORD` | `<grafana_ro password>` | `grafana_ro` (default) |

> **Note:** Grafana 11 provisioning YAML supports `$VAR` and `${VAR}` but NOT
> the bash-style `${VAR:-default}` fallback syntax. Use plain `$VAR` in the YAML.

### Grafana volume mounts

```yaml
volumes:
  - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
  - ./grafana/provisioning/dashboard-configs:/etc/grafana/provisioning/dashboards:ro   # note: dashboards not dashboard-configs
  - ./grafana/dashboards:/etc/grafana/dashboards:ro
```

The `dashboard-configs/dashboards.yml` provider points to `/etc/grafana/dashboards`.
Nested bind mounts inside a `:ro` parent fail in Docker — hence the separate path.

---

## Test environment (<test-machine>)

### Starting

```bash
cd /home/<your-user>/docker/tesla-test/fleet-telemetry

# First time: create data directory
mkdir -p ~/docker/tesla-test/pgdata

# Start TimescaleDB + Grafana + Simulator
docker compose -f deploy/docker-compose.test.yml up -d

# Optionally also start fleet-telemetry (no real certs needed for simulator path)
docker compose -f deploy/docker-compose.test.yml --profile ft up -d
```

### Applying migrations on <test-machine>

```bash
# Filename order is NOT dependency order; use the manifest runner.
docker exec -e SQL_DIR=/sql tesla-test-timescaledb bash /docker-entrypoint-initdb.d/00_apply_migrations.sh

# grafana_ro grants are applied by 042_roles.sql; no manual step.
```

### Simulator

The simulator (`tools/simulator`) writes synthetic waveforms (SoC, speed, power,
location loop, climate, TPMS, etc.) directly to TimescaleDB on a configurable
cadence. The binary is cross-compiled on Mac and mounted into an Alpine container:

```bash
# Cross-compile on Mac:
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o deploy/simulator-linux-amd64 ./tools/simulator

# Copy to <test-machine> (if binary not already there):
scp deploy/simulator-linux-amd64 user@<test-machine>:/home/<your-user>/docker/tesla-test/fleet-telemetry/deploy/
```

The compose file runs the simulator with 90-day backfill across 3 fake VINs:
- `5YJ3E1EA7NF000001` — simulated Model 3 Standard Range
- `7G2CCFG00PF000001` — simulated Cybertruck
- `5YJ3E7EC1RF000001` — simulated Model 3 Performance

### Syncing real VIN data from Prod Server

The real VIN (`<YOUR_VIN>`) is kept out of the simulator to avoid
overwriting real data. Sync it manually from Prod Server:

```bash
# On <test-machine> — delete any stale simulator rows, then pipe real rows from Prod Server:
docker exec tesla-test-timescaledb psql -U postgres -d tesla \
  -c "DELETE FROM telemetry WHERE vin = '<YOUR_VIN>' AND ts < '$(date -d '7 days ago' +%Y-%m-%d)';"

ssh prod-server "docker exec tesla-timescaledb psql -U postgres -d tesla \
  -c \"COPY (SELECT ts, vin, field, num_value, str_value, geo_value \
             FROM telemetry WHERE vin = '<YOUR_VIN>' \
             ORDER BY ts) TO STDOUT\"" \
  | docker exec -i tesla-test-timescaledb psql -U postgres -d tesla \
    -c "COPY telemetry (ts, vin, field, num_value, str_value, geo_value) FROM STDIN"
```

Run this periodically to keep the real VIN fresh on <test-machine>.

### Vehicle metadata

```sql
INSERT INTO vehicles (vin, model, model_year, battery_type, motor_config, has_heat_pump, has_air_suspension, has_fsd_hardware)
VALUES
  ('<YOUR_VIN>', '3', 2021, 'LFP',  'Long Range AWD', true,  false, 'HW3'),
  ('5YJ3E1EA7NF000001', '3', 2022, 'NCA',  'Standard Range', false, false, 'HW3'),
  ('7G2CCFG00PF000001', 'CT',2024, '4680', 'Dual Motor',     true,  false, 'HW4'),
  ('5YJ3E7EC1RF000001', '3', 2024, 'NCA',  'Performance',    true,  false, 'HW4')
ON CONFLICT (vin) DO UPDATE SET
  model = EXCLUDED.model, model_year = EXCLUDED.model_year,
  battery_type = EXCLUDED.battery_type, motor_config = EXCLUDED.motor_config,
  has_heat_pump = EXCLUDED.has_heat_pump, has_fsd_hardware = EXCLUDED.has_fsd_hardware,
  last_updated = now();
```

---

## Fresh Server wipe — full rebuild procedure

### 1. DNS

| Record | Type | Value |
|--------|------|-------|
| `tesla.example.com` | A | `<SERVER_IP>` |
| `ft.example.com` | A | `<SERVER_IP>` |

### 2. Ubuntu packages

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2 nginx certbot python3-certbot-nginx ufw
sudo systemctl enable docker && sudo usermod -aG docker <your-user>
```

### 3. Firewall

```bash
sudo ufw default deny incoming
sudo ufw allow ssh
sudo ufw allow 4443/tcp   # fleet-telemetry mTLS
sudo ufw allow 80/tcp     # nginx HTTP-01 challenge
sudo ufw allow 443/tcp    # nginx HTTPS
sudo ufw allow 3003/tcp   # Grafana (or restrict to trusted IPs)
sudo ufw enable
# Port 5432 is NOT opened — access only via autossh tunnel
```

### 4. nginx + TLS

```bash
sudo mkdir -p /etc/tesla

# tesla.example.com (fleet-telemetry TLS endpoint)
sudo cp deploy/nginx/tesla.example.com.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/tesla.example.com.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d tesla.example.com

# ft.example.com (partner registration public key)
sudo tee /etc/nginx/sites-available/ft.example.com.conf << 'EOF'
server {
    listen 80;
    server_name ft.example.com;
    location /.well-known/appspecific/com.tesla.3p.public-key.pem {
        root /etc/tesla;
        try_files /public-key-v2.pem =404;
        default_type text/plain;
    }
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl;
    server_name ft.example.com;
    ssl_certificate     /etc/letsencrypt/live/ft.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ft.example.com/privkey.pem;
    location /.well-known/appspecific/com.tesla.3p.public-key.pem {
        root /etc/tesla;
        try_files /public-key-v2.pem =404;
        default_type text/plain;
    }
    location /health { return 200 "ok"; add_header Content-Type text/plain; }
}
EOF
sudo ln -s /etc/nginx/sites-available/ft.example.com.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d ft.example.com
```

### 5. EC keypairs

```bash
sudo mkdir -p /etc/tesla

# Fresh install only. One keypair; the name does not imply which key is live -
# the hash check below is the only thing that does. (The existing deployment's
# live key is private-key.pem, not a "-v2" file; see the warning below.)
sudo openssl ecparam -name prime256v1 -genkey -noout -out /etc/tesla/private-key.pem
sudo openssl ec -in /etc/tesla/private-key.pem -pubout -out /etc/tesla/public-key.pem
sudo chmod 600 /etc/tesla/private-key.pem

# Verify it's served:
curl https://ft.example.com/.well-known/appspecific/com.tesla.3p.public-key.pem

# Verify WHICH private key that served public key belongs to. If a deployment
# has more than one keypair in /etc/tesla (e.g. a pre-v2 leftover), these can
# diverge - and signing with the wrong one produces JWS the car silently
# rejects. Always confirm before signing anything (section 10):
for k in /etc/tesla/private-key*.pem; do
  echo "$k -> $(sudo openssl ec -in "$k" -pubout 2>/dev/null | sha256sum)"
done
echo "published -> $(curl -s https://ft.example.com/.well-known/appspecific/com.tesla.3p.public-key.pem | sha256sum)"
```

> ⚠️ Regenerating the keypair requires re-registering the partner account and
> re-pairing the virtual key on the car.
>
> ⚠️ On this deployment (checked 2026-09-10) the served public key matches
> `/etc/tesla/private-key.pem`, **not** `private-key-v2.pem`. Trust the hash
> check above over the filename: the `-v2` suffix implies "newer, therefore
> active", which is not what production actually serves. Signing with v2
> produces JWS the car rejects, and the failure looks like a virtual-key
> pairing problem rather than a wrong-key problem - so you can lose hours at
> the car instead of at the keyboard.

### 6. mTLS cert for fleet-telemetry

```bash
sudo cp /etc/letsencrypt/live/tesla.example.com/fullchain.pem \
        /u01/fleet-telemetry/deploy/fleet-telemetry/certs/server.crt
sudo cp /etc/letsencrypt/live/tesla.example.com/privkey.pem \
        /u01/fleet-telemetry/deploy/fleet-telemetry/certs/server.key
```

These are **copies**. certbot renews into `/etc/letsencrypt/live/` and knows
nothing about the container, so without a deploy hook the copy silently ages
out while a perfectly good cert sits unused a directory away. That is exactly
what happened on 2026-08-05: the copy expired at 11:26, telemetry stopped at
11:30, and it stayed dark for 36 days. Install the hook when you install the
certs:

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/fleet-telemetry.sh >/dev/null <<'HOOK'
#!/bin/bash
set -euo pipefail
CERT_DIR=/u01/fleet-telemetry/deploy/fleet-telemetry/certs
[ "${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/tesla.example.com ] || exit 0
install -o root -g root -m 644 "$RENEWED_LINEAGE/fullchain.pem" "$CERT_DIR/server.crt"
install -o root -g root -m 600 "$RENEWED_LINEAGE/privkey.pem"  "$CERT_DIR/server.key"
docker restart tesla-fleet-telemetry >/dev/null
logger -t certbot-fleet-telemetry 'installed renewed cert, restarted tesla-fleet-telemetry'
HOOK
sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/fleet-telemetry.sh
```

> ⚠️ The hook fixes the **serving** side only. If a renewal changes the
> *chain shape* - a new Let's Encrypt intermediate or root - the car will
> still reject the cert, because the CA it validates against is pinned inside
> `fleet_telemetry_config`. See "Car reports `tls: bad certificate`" below.

### 7. Start the stack

```bash
sudo mkdir -p /u01/tesla/pgdata
sudo chown <your-user>:<your-user> /u01/tesla

cd /u01/fleet-telemetry/deploy
# Create .env with POSTGRES_PASSWORD, GF_ADMIN_PASSWORD and GF_TESLA_DB_PASSWORD
# (compose refuses to start without them), edit fleet-telemetry/config.json
docker compose --profile live up -d

# A fresh volume applies every migration on first start. To re-check:
make migrate-status

# Nightly backup and the weekly report (systemd timers):
make install-timers
```

### 8. Partner registration

```bash
PARTNER_TOKEN=$(curl -s -X POST https://auth.tesla.com/oauth2/v3/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=<YOUR_CLIENT_ID>&client_secret=<YOUR_CLIENT_SECRET>&scope=openid vehicle_device_data vehicle_cmds vehicle_location&audience=https://fleet-api.prd.eu.vn.cloud.tesla.com" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -X POST https://fleet-api.prd.eu.vn.cloud.tesla.com/api/1/partner_accounts \
  -H "Authorization: Bearer $PARTNER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain": "ft.example.com"}'
```

### 9. Virtual key pairing

```bash
# Wake car first, then open on a phone with Tesla app:
# https://www.tesla.com/_ak/ft.example.com
# Tap "Add key" in the Tesla app.
```

### 10. Pushing fleet_telemetry_config

Run the proxy **on the server that already holds the signing key**, so the key
never travels. There is no Go toolchain on the production server, so cross-compile locally and
copy the binary across - the same pattern used for the notify daemon.

```bash
# Build proxy for the server (one-time, on your local machine):
git clone --depth 1 https://github.com/teslamotors/vehicle-command /tmp/vehicle-command
cd /tmp/vehicle-command
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build \
  -o /tmp/tesla-http-proxy-linux-amd64 ./cmd/tesla-http-proxy
scp /tmp/tesla-http-proxy-linux-amd64 prod-server:/tmp/

# On the server:
cd /tmp && umask 077
openssl req -x509 -newkey rsa:2048 -keyout proxy-key.pem -out proxy-cert.pem \
  -days 30 -nodes -subj "/CN=localhost"

# Use the key confirmed by the hash check in section 5, NOT whichever
# filename looks newest.
sudo cp /etc/tesla/private-key.pem /tmp/ft-signing-key.pem
sudo chown "$USER:$USER" /tmp/ft-signing-key.pem && chmod 600 /tmp/ft-signing-key.pem

nohup /tmp/tesla-http-proxy-linux-amd64 -cert /tmp/proxy-cert.pem \
  -tls-key /tmp/proxy-key.pem -key-file /tmp/ft-signing-key.pem \
  -host localhost -port 4444 > /tmp/proxy.log 2>&1 &

# Push config (USER_TOKEN from the Authorization Code flow).
# Note the COLLECTION endpoint plus {"vins": [...], "config": {...}} body.
curl -sk -X POST "https://localhost:4444/api/1/vehicles/fleet_telemetry_config" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/ft-config-new.json
# Expected: {"response": {"updated_vehicles": 1}}

# Clean up - these are credentials:
pkill -f "[t]esla-http-proxy-linux-amd64"
rm -f /tmp/ft-signing-key.pem /tmp/proxy-key.pem /tmp/proxy-cert.pem
```

Note the bracket trick in that `pkill`. A plain `pkill -f tesla-http-proxy`
run over SSH also matches the SSH command line carrying it, so it kills your
own session before the `rm` lines run and leaves the key sitting in `/tmp`.

To change only the CA while keeping every configured field, read the live
config back and edit that, rather than rebuilding the field list by hand:

```bash
curl -sS -H "Authorization: Bearer $USER_TOKEN" \
  "$API/api/1/vehicles/<VEHICLE_ID>/fleet_telemetry_config" \
  -o /tmp/ft-config-current.json

python3 -c '
import json
cur = json.load(open("/tmp/ft-config-current.json"))["response"]["config"]
cur["ca"] = open("/etc/letsencrypt/live/tesla.example.com/chain.pem").read()
json.dump({"vins": ["<VIN>"], "config": cur},
          open("/tmp/ft-config-new.json", "w"), indent=1)
'
```

> **Gotchas:**
> - Tesla locks scopes at app creation — "Update" in the portal does nothing. New scopes = new app.
> - `fleet_telemetry_config` must go through the proxy (JWS-signed endpoint), not raw REST.
> - `Experimental_1–15` fields are rejected. Omit them.
> - Odometer fields require `"minimum_delta": 1.0`.
> - The `ca` field must contain the full Let's Encrypt chain.
> - `key_paired: false` is **not** reliable grounds for re-pairing. On
>   2026-09-10 it read `false` with the car awake and online, and the signed
>   push still returned `updated_vehicles: 1`. Try the push first; only go out
>   to the car if it actually fails.
> - A vehicle can carry **more than one** telemetry config - one per
>   registered app. Two configs aimed at the same server make a single car IP
>   emit successful connections and `bad certificate` failures at the same
>   time, which reads as a flapping fault unless you expect it. Removing an
>   entry from the car's Location Sharing screen only revokes location, not
>   the config; deleting a config needs a `DELETE` authenticated as the app
>   that owns it.

### 11. <test-machine> autossh tunnel (after fresh <test-machine> setup)

```bash
sudo apt install -y autossh

sudo tee /etc/systemd/system/autossh-prod-timescale.service << 'EOF'
[Unit]
Description=autossh tunnel — <test-machine>:5433 → Prod TimescaleDB:5432
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=<your-user>
Environment=AUTOSSH_GATETIME=0
ExecStart=/usr/bin/autossh -M 0 -N \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=no \
    -i /home/<your-user>/.ssh/prod_dedicated \
    -L 0.0.0.0:5433:127.0.0.1:5432 \
    <your-user>@<SERVER_IP>
Restart=always
RestartSec=10
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now autossh-prod-timescale

# Verify:
nc -zv 127.0.0.1 5433
```

---

## Backup and restore

Nothing else protects the data: the database is one bind mount on one disk.

### On the production host: `tools/backup.sh` (nightly timer)

`make install-timers` installs `deploy/systemd/tesla-backup.{service,timer}`
(03:30 UTC) together with the weekly report timer. Each run writes into one flat
directory, `BACKUP_DIR` (default `/u01/backups/tesla`):

| File | Content |
|------|---------|
| `tesla-YYYYmmddTHHMMSSZ.dump` | `pg_dump -Fc` of the whole database, via `docker exec` |
| `globals-YYYYmmddTHHMMSSZ.sql` | roles (`pg_dumpall --globals-only`, no passwords) |
| `attachments-YYYYmmddTHHMMSSZ.tar.gz` | service-log photos (`ATTACHMENTS_DIR`) |

Files are written under a `.partial` name and renamed when complete (the dump is
also read back with `pg_restore --list`), so a puller never sees a half-written
file. Mode 640. Local retention `KEEP_DAYS` (default 14), but the newest 3 dumps
are always kept. Settings can go in `/etc/default/tesla-backup`. Run one now with
`make backup`. The weekly report flags a newest dump older than 48 h.

### On the receiving host: `tools/backup_pull.sh` (cron)

A second machine pulls the backups; production never pushes. The script rsyncs
over ssh with a dedicated key, never deletes anything with rsync (not on the
source, not locally), then prunes local copies older than `KEEP_DAYS` (default
30) while always keeping the newest 3 dumps. It exits non-zero with one
`backup_pull: ...` line if rsync fails or if the newest local dump is older than
`MAX_AGE_H` (48 h).

```cron
# m h dom mon dow  command
15 6 * * *  SRC=backup@prod.example.net:/ DEST=/srv/backups/tesla SSH_KEY=/home/backup/.ssh/tesla_backup_pull MIRROR_DIR=/mnt/nas/backups/tesla /opt/fleet-telemetry/tools/backup_pull.sh 2>&1 | logger -t tesla-backup-pull
```

Restrict the pulling key on the **source** to read-only rsync of the backup
directory, in the backup user's `~/.ssh/authorized_keys`:

```
command="rrsync -ro /u01/backups/tesla",restrict ssh-ed25519 AAAA... tesla-backup-pull
```

With `rrsync`, the path in `SRC` is **relative to the restricted directory**:
`SRC=backup@prod.example.net:/` means `/u01/backups/tesla/` on the source. (The
user needs read access to the files, which are mode 640: put it in the owning
group.)

**NAS mirror (optional).** With `MIRROR_DIR` set (e.g. `/mnt/nas/backups/tesla`),
after a successful pull the script copies `DEST` into it with `rsync -a` (no
`--delete`) and applies its own retention, `MIRROR_KEEP_DAYS` (default 90, newest
3 dumps always kept). It first checks that `MIRROR_DIR` exists, is writable, and
lives on a mounted filesystem (`MIRROR_DIR` or a parent is a mount point, or
`MIRROR_MOUNT` names the mount to require), so an unmounted share cannot fill
the local disk. A mirror failure makes the script exit non-zero, but only after
the pull has completed.

### Restore

```bash
# 1. Stack up with an EMPTY database volume (or a scratch container).
# 2. Roles first (grafana_ro), then the database:
docker exec -i tesla-timescaledb psql -U postgres -d postgres < globals-<stamp>.sql   # "already exists" errors are fine
# The extension must exist BEFORE pre_restore. On the production data directory a
# new database does not get it from the template; without this step
# timescaledb_pre_restore() does not exist and pg_restore silently loses most
# hypertable rows (seen in a rehearsal: 5,923 of 63,107 recent rows).
docker exec tesla-timescaledb psql -U postgres -d tesla -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
docker exec tesla-timescaledb psql -U postgres -d tesla -c "SELECT timescaledb_pre_restore();"
docker exec -i tesla-timescaledb pg_restore -U postgres -d tesla --no-owner < tesla-<stamp>.dump
docker exec tesla-timescaledb psql -U postgres -d tesla -c "SELECT timescaledb_post_restore();"
# 3. Bring the schema up to date if the dump predates later migrations, and set
#    the grafana_ro password (042 does both):
make migrate
# 4. Photos:
tar -C /u01/fleet-telemetry -xzf attachments-<stamp>.tar.gz
```

Verified twice: on a scratch container, and on production into a scratch
database (`CREATE DATABASE tesla_rehearsal` + the steps above, 28 MB dump,
restore 5 s): row counts of `telemetry`, `vehicle_alerts`, `trips_mat` and
`schema_migrations` matched the source. Check with `pg_restore` output: any
"errors ignored on restore" means the restore is incomplete.

---

## Logs, health checks and alerts

- Every service in both compose files rotates its json log (`max-size 20m`,
  `max-file 5`). Before that the database log alone reached 1.2 GB.
- Database server settings are passed as `-c` flags in compose (`max_worker_processes`
  32, `timescaledb.max_background_workers` 24, `shared_buffers` 1 GB, `work_mem`
  16 MB, ...); override them in `.env` (`PG_SHARED_BUFFERS`, ...). With the old
  defaults (8 workers) thousands of refresh-policy runs failed with "failed to
  start a background worker". Recreate the container to apply a change.
- `fleet-telemetry` and `tesla-notify-daemon` have process-level healthchecks
  (TLS listener accepts a connection / process alive). They do not prove data is
  arriving; for that:
- the notify daemon's **staleness watchdog** checks hourly whether the newest
  `telemetry` row and the newest `vehicle_connectivity` row are both older than
  `stale_after_hours` (config, default 48, `0` disables; env
  `NOTIFY_STALE_AFTER_HOURS`). It sends one Telegram warning, stays quiet until
  data resumes, then sends one recovery note. State is in `notify_watchdog`
  (`036`), so restarts do not re-alert.
- the weekly report (`tools/weekly_report.sh`, Monday 07:00 UK) checks
  containers, telemetry age, the TLS certificate and chain, matview refreshes,
  failing TimescaleDB jobs, backup age and disk.

**Rate limiting.** When the server's rate limiter refuses a message the socket
`continue`s without an ack (upstream behaviour, FINDINGS 25); the car resends.
Rate limiting is off in this deployment, so this is noted, not changed.

---

## Data retention

| Phase | Storage | Duration |
|-------|---------|----------|
| Hot (uncompressed) | Raw TimescaleDB chunks | 7 days |
| Warm (compressed) | Columnar TimescaleDB | 7 days → 5 years |
| Retention drop | Auto-dropped | After 5 years |

---

## Useful queries

```sql
-- Field coverage (last hour)
SELECT field, count(*), max(ts)
FROM telemetry
WHERE ts > NOW() - INTERVAL '1 hour'
GROUP BY field ORDER BY 1;

-- Drive summary (last 24h)
SELECT
  round(max(num_value)::numeric, 1) AS peak_mph,
  round(avg(num_value)::numeric, 1) AS avg_moving_mph,
  count(*) AS samples
FROM telemetry
WHERE field = 'VehicleSpeed' AND num_value > 0
  AND ts > NOW() - INTERVAL '24 hours';

-- GPS track (last trip)
SELECT ts, ST_Y(geo_value::geometry) AS lat, ST_X(geo_value::geometry) AS lon
FROM telemetry
WHERE field = 'Location' AND ts > NOW() - INTERVAL '6 hours'
ORDER BY ts;

-- Predictive health summary
SELECT vin, overall_risk_score, highest_risk_subsystem, recommended_action
FROM predictive_health_summary ORDER BY overall_risk_score DESC;

-- Total records and distinct fields
SELECT count(*) AS records, count(DISTINCT field) AS fields FROM telemetry;

-- Compression status
SELECT hypertable_name, compression_enabled
FROM timescaledb_information.hypertables;
```

---

## trips view — how trip detection works

The `trips` view (defined in `deploy/sql/002_views.sql`) detects drives using
GPS time gaps rather than the `Gear` field.

1. Compute the time gap between consecutive `Location` points per VIN.
2. Any gap > 10 minutes marks a new trip boundary.
3. Micro-movements < 200 m (parking adjustments) are filtered out.
4. `ROW_NUMBER()` assigns sequential `trip_id` values after filtering.

| Column | Description |
|--------|-------------|
| `trip_id` | Sequential 1-based ID per VIN |
| `started / ended` | UTC timestamps of first/last GPS point |
| `duration` | `ended − started` |
| `distance_km` | Sum of sequential PostGIS haversine distances |
| `max_speed_mph` / `avg_speed_mph` | From `VehicleSpeed` within the trip window |
| `soc_start_pct` / `soc_end_pct` / `soc_used_pct` | From `BatteryLevel` |
| `kwh_used` | From `EnergyRemaining` |
| `wh_per_km` | Efficiency (only when distance > 0.5 km and energy data present) |

> **Why not use `Gear`?** The Gear field updates only on transitions. If the car
> is moving before telemetry connects, the P→D transition is missed. Location
> points arrive every 10 s while moving and stop when parked — gaps are reliable.

---

## Troubleshooting

### Car reports `tls: bad certificate` (no telemetry arriving)

Symptom: `docker logs tesla-fleet-telemetry` fills with

```
http: TLS handshake error from <car-ip>:<port>: remote error: tls: bad certificate
```

every ~20s, `telemetry` stops gaining rows, Grafana empties out and Telegram
goes quiet. `remote error:` means the **car** rejected the certificate we
served - the fault is ours, not the car's.

Work through it in this order:

```bash
# 1. Is the served cert simply expired? (the common case)
sudo openssl x509 -in /u01/fleet-telemetry/deploy/fleet-telemetry/certs/server.crt \
  -noout -subject -dates

# 2. Does a newer cert already exist that nobody copied across?
sudo openssl x509 -in /etc/letsencrypt/live/tesla.example.com/fullchain.pem \
  -noout -dates
```

If 2 is newer than 1, the deploy hook in section 6 is missing. Install it,
copy the cert, restart the container.

If the served cert is current and the car *still* refuses it, compare chain
shapes - this is the trap that cost 36 days in Aug-Sep 2026:

```bash
# What we serve now:
sudo openssl crl2pkcs7 -nocrl \
  -certfile /u01/fleet-telemetry/deploy/fleet-telemetry/certs/server.crt \
  | openssl pkcs7 -print_certs -noout

# What the car was told to trust (needs a USER_TOKEN, see section 10):
curl -sS -H "Authorization: Bearer $USER_TOKEN" \
  "$API/api/1/vehicles/<VEHICLE_ID>/fleet_telemetry_config" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["response"]["config"]["ca"])'
```

The `ca` is pinned at config time and does **not** follow renewals. In
September 2026 Let's Encrypt moved from `leaf <- E8 <- ISRG Root X1` to
`leaf <- YE1 <- Root YE <- ISRG Root X2 <- ISRG Root X1`; the pinned `ca` was
byte-identical to the old expired certificate, so the car rejected a chain
that verified perfectly well against the public trust store. `openssl verify`
succeeding on the server proves nothing about what the car will accept.

Fix: re-push `fleet_telemetry_config` with `ca` swapped for the current chain,
per section 10. Nothing needs doing at the car.

One more red herring: if a single car IP shows successful connections *and*
`bad certificate` failures simultaneously, the vehicle is running two
telemetry configs from two registered apps, and only one has been updated.

## Known Grafana panel quirks

### Odometer unit
Raw `Odometer` is in **miles**. Unit: `mi` (no multiplication). Using `lengthkm`
+ ×1.609 produces megametres in Grafana's SI scaling.

### Power derivation
Tesla does not stream a `Power` field. Derive it:
```sql
-- Time series (telemetry_1m CAGG):
SELECT v.bucket AS time, v.avg_v * i.avg_v / 1000 AS power_kw
FROM telemetry_1m v
JOIN telemetry_1m i ON v.bucket = i.bucket AND v.vin = i.vin
WHERE v.field = 'PackVoltage' AND i.field = 'PackCurrent' AND v.vin = '$vin'
```

### TPMS field names
`TpmsPressureFl`, `TpmsPressureFr`, `TpmsPressureRl`, `TpmsPressureRr` (lowercase `l`/`r`).
Use a pivot query; raw `field, num_value` makes Grafana label columns "num_value".

### Multi-query panels
Every `target` in a panel must have a unique `refId` (A, B, C…). Duplicates
cause `query.duplicateRefId` 400 errors on all queries in the panel.

### Browse URL (Grafana 11)
In Grafana 11 the `/dashboards` route shows **Starred** dashboards (empty by
default). Use `/dashboards/browse` to see all provisioned dashboards, or
navigate via the grid icon → Browse in the left sidebar.
