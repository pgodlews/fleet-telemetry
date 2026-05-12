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
| Keypair | `/etc/tesla/private-key-v2.pem` + `public-key-v2.pem` (on Prod Server) |
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

SQL migrations live in `deploy/sql/`. They are idempotent and must be run in
order on a fresh instance.

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
| `015_air_suspension_diagnostics.sql` | Air suspension duty cycle, height deviation (where fitted) |
| `016_dual_motor_diagnostics.sql` | Front/rear motor balance, temperature delta, efficiency split |
| `017_cybertruck_diagnostics.sql` | Cybertruck-specific: tonneau, V2L, tri-motor, 4680 cells |

### Applying migrations

```bash
# On Prod Server (production):
ssh prod-server
for f in /u01/fleet-telemetry/deploy/sql/0*.sql; do
  echo "=== $f ==="
  docker exec -i tesla-timescaledb psql -U postgres -d tesla < "$f"
done

# On <test-machine> (test):
for f in /home/<your-user>/docker/tesla-test/fleet-telemetry/deploy/sql/0*.sql; do
  echo "=== $f ==="
  docker exec -i tesla-test-timescaledb psql -U postgres -d tesla < "$f"
done
```

### After migrations — grant grafana_ro access

```bash
docker exec tesla-timescaledb psql -U postgres -d tesla -c \
  "GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;
   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro;"
```

### Refreshing regular materialized views

Second-tier diagnostic matviews are regular `MATERIALIZED VIEW`s (not CAGGs)
due to a TimescaleDB hierarchical CAGG bug after DROP+RECREATE. Refresh manually
or add a cron:

```bash
docker exec tesla-timescaledb psql -U postgres -d tesla -c "
  REFRESH MATERIALIZED VIEW battery_capacity_1d;
  REFRESH MATERIALIZED VIEW pcs_health_1d;
  REFRESH MATERIALIZED VIEW pcs_health_1w;
  REFRESH MATERIALIZED VIEW heat_pump_cop_1d;
  REFRESH MATERIALIZED VIEW low_voltage_wakeups_1d;
  REFRESH MATERIALIZED VIEW regen_brake_daily_1d;
  REFRESH MATERIALIZED VIEW drivetrain_highway_1d;
  REFRESH MATERIALIZED VIEW air_suspension_health_1d;
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
for f in deploy/sql/0*.sql; do
  echo "=== $f ==="
  docker exec -i tesla-test-timescaledb psql -U postgres -d tesla < "$f"
done

# Grant grafana_ro
docker exec tesla-test-timescaledb psql -U postgres -d tesla -c \
  "GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;"
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

# v2 keypair (active)
sudo openssl ecparam -name prime256v1 -genkey -noout -out /etc/tesla/private-key-v2.pem
sudo openssl ec -in /etc/tesla/private-key-v2.pem -pubout -out /etc/tesla/public-key-v2.pem
sudo chmod 600 /etc/tesla/private-key-v2.pem

# Verify it's served:
curl https://ft.example.com/.well-known/appspecific/com.tesla.3p.public-key.pem
```

> ⚠️ Regenerating the keypair requires re-registering the partner account and
> re-pairing the virtual key on the car.

### 6. mTLS cert for fleet-telemetry

```bash
sudo cp /etc/letsencrypt/live/tesla.example.com/fullchain.pem \
        /u01/fleet-telemetry/deploy/fleet-telemetry/certs/server.crt
sudo cp /etc/letsencrypt/live/tesla.example.com/privkey.pem \
        /u01/fleet-telemetry/deploy/fleet-telemetry/certs/server.key
```

### 7. Start the stack

```bash
sudo mkdir -p /u01/tesla/pgdata
sudo chown <your-user>:<your-user> /u01/tesla

cd /u01/fleet-telemetry/deploy
cp deploy/.env.sample deploy/.env
# Edit deploy/.env with actual passwords, edit deploy/fleet-telemetry/config.json
docker compose --profile live up -d

# Apply all migrations
for f in sql/0*.sql; do
  echo "=== $f ===" && docker exec -i tesla-timescaledb psql -U postgres -d tesla < "$f"
done
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

```bash
# Build proxy (one-time, on local machine):
git clone https://github.com/teslamotors/vehicle-command /tmp/vehicle-command
cd /tmp/vehicle-command && go build -o tesla-http-proxy ./cmd/tesla-http-proxy

openssl req -x509 -newkey rsa:2048 -keyout proxy-key.pem -out proxy-cert.pem \
  -days 365 -nodes -subj "/CN=localhost"

scp prod-server:/etc/tesla/private-key-v2.pem /tmp/ft-private-key.pem

./tesla-http-proxy -cert proxy-cert.pem -tls-key proxy-key.pem \
  -key-file /tmp/ft-private-key.pem -host localhost -port 4444

# Push config (USER_TOKEN from Authorization Code flow):
curl -sk -X POST "https://localhost:4444/api/1/vehicles/<YOUR_VEHICLE_ID>/fleet_telemetry_config" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/ft-config-all.json
# Expected: {"response": {"updated_vehicles": 1}}
```

> **Gotchas:**
> - Tesla locks scopes at app creation — "Update" in the portal does nothing. New scopes = new app.
> - `fleet_telemetry_config` must go through the proxy (JWS-signed endpoint), not raw REST.
> - `Experimental_1–15` fields are rejected. Omit them.
> - Odometer fields require `"minimum_delta": 1.0`.
> - The `ca` field must contain the full Let's Encrypt chain.
> - If `key_paired` stays `false`, the car was sleeping. Wake first, then re-pair.

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
