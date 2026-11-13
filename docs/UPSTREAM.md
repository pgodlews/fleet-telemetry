# Original Tesla Fleet Telemetry Documentation



Fleet Telemetry is a server reference implementation for Tesla's telemetry protocol. It is the best way to get data from Tesla vehicles. Owners can allow registered applications to receive telemetry securely and directly from their vehicles. This reference implementation can be used by individual owners as is or by fleet operators who can extend it to aggregate data accross their fleet.

The service handles device connectivity as well as receiving and storing transmitted data. Once configured, devices establish a WebSocket connection to push configurable telemetry records. Fleet Telemetry provides clients with ack, error, or rate limit responses. The application also provides an event stream to determine the vehicle connection state, which can be used as a proxy for vehicle online state.

By configuring `fleet_telemetry_config`, individual owners and fleet operators can control the selected fields and minimum intervals for data transmission. All signals are transmitted on change, but not more frequently than the configured interval.

## Configuring and running the service

### Setup steps

1. Create a developer application via [developer.tesla.com](https://developer.tesla.com).
   - In the "Client Details" step, it is recommended to select "Authorization Code and Machine-to-Machine" for most use cases. "Machine-to-Machine" (M2M) should only be selected for business accounts that own vehicles.
2. Generate an EC private key using the secp256r1 curve (prime256v1).
   - `openssl ecparam -name prime256v1 -genkey -noout -out private-key.pem`
3. Derive its public key.
   - `openssl ec -in private-key.pem -pubout -out public-key.pem`
4. Host this public key at: `https://*application-domain.com*/.well-known/appspecific/com.tesla.3p.public-key.pem`.
5. Generate a Partner Authentication Token. ([docs](https://developer.tesla.com/docs/fleet-api/authentication/partner-tokens))
6. Register the application with Fleet API via the [register](https://developer.tesla.com/docs/fleet-api/endpoints/partner-endpoints#register) endpoint.
7. Configure a fleet-telemetry server. Full details are described in [install steps](#install-steps).
8. Validate the server configuration using [check_server_cert.sh](https://github.com/teslamotors/fleet-telemetry/blob/main/tools/check_server_cert.sh).
    - From a local computer, create `validate_server.json` with the following fields:
      - `hostname`: The hostname the fleet-telemetry server.
      - `port`: The port the fleet-telemetry server -- Default 443.
      - `ca`: The full certificate chain used to generate the server's TLS certificate.
    - Run `./check_server_cert.sh validate_server.json`
9. Pair the application's virtual key to the vehicle(s). See documentation here: https://developer.tesla.com/docs/fleet-api/virtual-keys/developer-guide.
10. Configure and run the [vehicle-command proxy](https://github.com/teslamotors/vehicle-command#installation-and-configuration) with the application private key.
11. Configure vehicle(s) with the [fleet_telemetry_config](https://developer.tesla.com/docs/fleet-api/endpoints/vehicle-endpoints#fleet-telemetry-config-create) endpoint.
12. Wait for `synced` to be true when getting [fleet_telemetry_config](https://developer.tesla.com/docs/fleet-api/endpoints/vehicle-endpoints#fleet-telemetry-config-get).
13. Vehicles will connect and stream data directly to the hosted fleet-telemetry server. To diagnose connection or streaming problems use the [fleet_telemetry_errors](https://developer.tesla.com/docs/fleet-api/endpoints/partner-endpoints#fleet-telemetry-errors) endpoint.

### Install on Kubernetes with Helm Chart (recommended)
For ease of installation and operation, run Fleet Telemetry on Kubernetes or a similar environment. Helm Charts help define, install, and upgrade applications on Kubernetes. A reference helm chart is available [here](https://github.com/teslamotors/helm-charts/blob/main/charts/fleet-telemetry/README.md).

### Install steps
1. Allocate and assign a [FQDN](https://en.wikipedia.org/wiki/Fully_qualified_domain_name). This will be used in the server and client (vehicle) configuration.

2. Design a simple hosting architecture. We recommend: Firewall/Loadbalancer -> Fleet Telemetry -> Kafka.

3. Ensure mTLS connections are terminated on the Fleet Telemetry service.

4. Configure the server (Helm charts cover some of this configuration)
```
{
  "host": string - hostname,
  "port": int - port,
  "log_level": string - trace, debug, info, warn, error,
  "json_log_enable": bool,
  "namespace": string - kafka topic prefix,
  "reliable_ack": bool - for use with reliable datastores, recommend setting to true with kafka,
  "transmit_decoded_records": bool - if true, transmit JSON to dispatchers instead of proto.
  "monitoring": {
    "prometheus_metrics_port": int,
    "profiler_port": int,
    "profiling_path": string - out path,
    "statsd": { if not using prometheus
      "host": string - host:port of the statsd server,
      "prefix": string - prefix for statsd metrics,
      "sample_rate": int - 0 to 100 percentage to sample stats,
      "flush_period": int - ms flush period
    }
  },
  "logger": {
    "verbose": bool - include data types in the logs. Only applicable for records of type 'V'
  },
  "kafka": { // librdkafka kafka config, seen here: https://raw.githubusercontent.com/confluentinc/librdkafka/master/CONFIGURATION.md
    "bootstrap.servers": "kafka:9092",
    "queue.buffering.max.messages": 1000000
  },
  "kinesis": {
    "max_retries": 3,
    "streams": {
      "V": "custom_stream_name"
    }
  },
  "rate_limit": {
    "enabled": bool,
    "message_limit": int - ex.: 1000
  },
  "records": { // list of records and their dispatchers, currently: alerts, errors, and V(vehicle data)
    "alerts": [
        "logger"
    ],
    "errors": [
        "logger"
    ],
    "V": [
        "kinesis",
        "kafka"
    ]
  },
  "tls": {
    "server_cert": string - server cert location,
    "server_key": string - server key location
  }
}
```
Example: [server_config.json](./examples/server_config.json)

5. (Manual install only) Deploy and run the server. Get the latest docker image information from our [docker hub](https://hub.docker.com/r/tesla/fleet-telemetry/tags). This can be run as a binary via `./fleet-telemetry -config=/etc/fleet-telemetry/config.json` directly on a server, or as a Kubernetes deployment. Example snippet:
```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fleet-telemetry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fleet-telemetry
  template:
    metadata:
      labels:
        app: fleet-telemetry
    spec:
      containers:
      - name: fleet-telemetry
        image: tesla/fleet-telemetry:<tag>
        command: ["/fleet-telemetry", "-config=/etc/fleet-telemetry/config.json"]
        ports:
        - containerPort: 443
---
apiVersion: v1
kind: Service
metadata:
  name: fleet-telemetry
spec:
  selector:
    app: fleet-telemetry
  ports:
    - protocol: TCP
      port: 443
      targetPort: 443
  type: LoadBalancer
```


## Vehicle Compatibility

Vehicles must be running firmware version 2023.20.6 or later.  Some older model S/X are not supported.

## Personalized Backends/Dispatchers
Dispatchers handle vehicle data processing upon its arrival at Fleet Telemetry servers. They can be of any type, from distributed message queues to  STDOUT logger.  Here is a list of the currently supported [dispatchers](./telemetry/producer.go#L10-L19)::
* Kafka (preferred): Configure with the config.json file.  See implementation here: [config/config.go](./config/config.go)
  * Topics will need to be created for \*prefix\*`_V`,\*prefix\*`_connectivity` and \*prefix\*`_alerts`. The default prefix is `tesla`
* Kinesis: Configure with standard [AWS env variables and config files](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html). The default AWS credentials and config files are: `~/.aws/credentials` and `~/.aws/config`.
  * By default, stream names will be \*configured namespace\*_\*topic_name\*  ex.: `tesla_V`, `tesla_alerts`, etc
  * Configure stream names directly by setting the streams config `"kinesis": { "streams": { *topic_name*: stream_name } }`
  * Override stream names with env variables: KINESIS_STREAM_\*uppercase topic\* ex.: `KINESIS_STREAM_V`
* Google pubsub: Along with the required pubsub config (See ./test/integration/config.json for example), be sure to set the environment variable `GOOGLE_APPLICATION_CREDENTIALS`
  * On startup, the server will attempt to create missing topics and panic on failure.
* ZMQ: Configure with the config.json file.  See implementation here: [config/config.go](./config/config.go)
* MQTT: Configure using the config.json file. See implementation in [config/config.go](./config/config.go)
  * See detailed MQTT information in the [MQTT README](./datastore/mqtt/README.md)
* Logger: This is a simple STDOUT logger that serializes the protos to json.

>NOTE: To add a new dispatcher, please provide integration tests and updated documentation. To serialize dispatcher data as json instead of protobufs, add a config `transmit_decoded_records` and set value to `true` as shown [here](config/test_configs_test.go#L186)

## Reliable Acks
Fleet Telemetry can send ack messages back to the vehicle. This is useful for applications that need to ensure the data was received and processed. To enable this feature, set `reliable_ack_sources` to one of configured dispatchers (`kafka`,`kinesis`,`pubsub`,`zmq`, `mqtt`) in the config file. Reliable acks can only be set to one dispatcher per recordType. See [here](./test/integration/config.json#L8) for sample config.

## Detecting Vehicle Connectivity Changes
On the vehicle, Fleet Telemetry client behave similarly to how the connectivity engine for vehicle commands. Therefore we can use Fleet Telemetry connectivity event to assume when a vehicle is online. Note that it is a proxy, but if configured properly Fleet Telemetry connectivity time should match vehicle connectivity state in 99%+. To enable connectivity events simply add the `connectivity` records in the list of events in [server_config.json](./examples/server_config.json) file:

  ```
    "records": {
        "connectivity": [
            "kafka"
        ]
      }
  ```

## Tracking incoming signals
If you have metrics enabled, you can use it to track count of incoming signals. This can help you identify approximate billing for your service. There are two ways to track signals. By default, it tracks signals per record_type (\*prefix\*`V` and \*prefix\*`alerts`). If you wish to track signals for a subset of VINs, you can add `vins_signal_tracking_enabled` in the config file which will track metrics for usage from those particular vins as well. 

## Metrics
Configure and use Prometheus or a StatsD-interface supporting data store for metrics. The integration test runs Fleet Telemetry with [grafana](https://grafana.com/docs/grafana/latest/datasources/google-cloud-monitoring/), which is compatible with prometheus. It also has an example dashboard which tracks important metrics related to the hosted server. Sample screenshot for the [sample dashboard](./test/integration/grafana/provisioning/dashboards/dashboard.json):-

![Basic Dashboard](./doc/grafana-dashboard.png)

## Logging

To suppress [tls handshake error logging](https://cs.opensource.google/go/go/+/master:src/net/http/server.go;l=1933?q=%22TLS%20handshake%20error%20from%20%22&ss=go%2Fgo), set environment variable `SUPPRESS_TLS_HANDSHAKE_ERROR_LOGGING` to `true`. See [docker compose](./docker-compose.yml) for example.

## Protos
Data is encapsulated into protobuf messages of different types. Protos can be recompiled via:

  1. Install protoc, currently on version 4.25.1: https://grpc.io/docs/protoc-installation/
  2. Install protoc-gen-go: `go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.28`
  3. Run make command
  ```sh
  make generate-protos
  ```
## Airbrake
Fleet Telemetry can publish errors to [airbrake](https://www.airbrake.io/error-monitoring). The integration test runs Fleet Telemetry with [errbit](https://github.com/errbit/errbit), which is an airbrake compliant self-hosted error catcher. A project key can be set for airbrake using either the config file or via an environment variable `AIRBRAKE_PROJECT_KEY`.

# Testing

## Unit Tests
To run the unit tests: `make test`

Common Errors:

```
~/fleet-telemetry➜ git:(main) ✗  make test
go build github.com/confluentinc/confluent-kafka-go/v2/kafka:
# pkg-config --cflags  -- rdkafka
Package rdkafka was not found in the pkg-config search path.
Perhaps you should add the directory containing `rdkafka.pc'
to the PKG_CONFIG_PATH environment variable
No package 'rdkafka' found
pkg-config: exit status 1
make: *** [install] Error 1
```
librdkafka is missing, on macOS install it via `brew install librdkafka pkg-config` or follow instructions here https://github.com/confluentinc/confluent-kafka-go#getting-started

```
~/fleet-telemetry➜ git:(main) ✗  make test
go build github.com/confluentinc/confluent-kafka-go/v2/kafka:
# pkg-config --cflags  -- rdkafka
Package libcrypto was not found in the pkg-config search path.
Perhaps you should add the directory containing `libcrypto.pc'
to the PKG_CONFIG_PATH environment variable
Package 'libcrypto', required by 'rdkafka', not found
pkg-config: exit status 1
make: *** [install] Error 1

~/fleet-telemetry➜ git:(main) ✗  locate libcrypto.pc
/opt/homebrew/Cellar/openssl@3/3.0.8/lib/pkgconfig/libcrypto.pc

~/fleet-telemetry➜ git:(main) ✗  export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/opt/homebrew/Cellar/openssl@3/3.0.8/lib/pkgconfig/
```
A reference to libcrypto is not set properly. To resolve find the reference to libcrypto by pkgconfig and set et the PKG_CONFIG_PATH accordingly.

libzmq is missing. Install with:
```sh
sudo apt install -y libsodium-dev libzmq3-dev
```
Or for macOS:
```sh
brew install libsodium zmq
```

## Integration Tests

To run the integration tests: `make integration`
To log into errbit instances, default username is `noreply@example.org` and default password is `test123`

## Building the binary for Linux from Mac ARM64

```sh
DOCKER_BUILD_KIT=1 DOCKER_CLI_EXPERIMENTAL=enabled docker buildx version
docker buildx create --name go-builder --driver docker-container --driver-opt network=host --buildkitd-flags '--allow-insecure-entitlement network.host' --use
docker buildx inspect --bootstrap
docker buildx build --no-cache --progress=plain --platform linux/amd64 -t <name:tag>(e.x.: fleet-telemetry:local.1.1) -f Dockerfile . --load
container_id=$(docker create fleet-telemetry:local.1.1) docker cp $container_id:/fleet-telemetry /tmp/fleet-telemetry
```

## Cross-Model Compatibility

The predictive maintenance stack now supports **all Tesla models** that stream Fleet Telemetry data. Vehicle metadata is detected automatically on first telemetry receipt — no manual VIN registration required.

### How it works

1. **CarType enum (preferred)** — The vehicle's firmware streams `CarType` (e.g. `CarTypeModelY`, `CarTypeCybertruck`). The Postgres dispatcher captures this and populates the `vehicles` table with model, year, battery type, and feature flags.
2. **VIN parsing (fallback)** — If `CarType` is not yet available, the dispatcher falls back to decoding the VIN:
   - Position 4 (index 3): `S` / `X` / `3` / `Y` / `C` (Cybertruck) / `T` (Semi)
   - Position 10 (index 9): model year (`M`=2021, `N`=2022, `P`=2023, `R`=2024, etc.)
   - Position 8: motor config hint (RWD / Dual Motor / Performance / Tri Motor)

### Supported models

| Model | CarType | Auto-detected features |
|-------|---------|------------------------|
| Model 3 | `CarTypeModel3` | 2170 / LFP battery, heat pump (2021+) |
| Model Y | `CarTypeModelY` | 2170 / 4680 battery, heat pump |
| Model S | `CarTypeModelS` | 18650 / 2170 battery, air suspension |
| Model X | `CarTypeModelX` | 18650 / 2170 battery, air suspension |
| Cybertruck | `CarTypeCybertruck` | 4680 battery, air suspension, tri-motor |
| Semi | `CarTypeSemiTruck` | 4680 battery, powershare |

### What Model Y / Cybertruck owners get immediately

- **Battery Health** — 4680 vs 2170 baselines are inferred from model + year, so capacity fade curves use the correct chemistry expectations.
- **Heat Pump** — Model Y and 2021+ Model 3 automatically get heat-pump degradation detection; older Model S/X skip the HVAC warning.
- **Air Suspension** — not monitored. No Tesla vehicle sends ride height, compressor state, suspension mode or steering angle through Fleet Telemetry (none of these fields is in `protos/vehicle_data.proto`, upstream's current proto, or Tesla's published field list), so `045` removed the air-suspension views, the Cybertruck air-suspension subsystem, the steering-offset check, their dashboard panels and the simulator fields.
- **PCS Diagnostics** — All models get the 16/32 A charger module failure detection.
- **Tonneau / Powershare** — Cybertruck and Semi get their unique fields in the simulator and catalog.

### Simulator multi-model support

Run the simulator with VINs from different models:

```bash
cd tools/simulator
go build -o simulator .

# Model 3 + Model Y + Cybertruck
./simulator \
  -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
  -vins "5YJ3E1EA8PF000001,7SAYGDEE9PF000002,7G2CE1EB7TF000003" \
  -interval 30
```

The simulator auto-detects the model from each VIN and generates model-specific fields (e.g. `TonneauPosition` for Cybertruck, `PowershareStatus` for Semi).

### Grafana model filtering

The Predictive Health dashboard includes a `$model` template variable. Use it to:
- Filter fleet-wide views to a specific model
- Show Cybertruck-specific tonneau metrics only when `model = 'CT'`

Example query:
```sql
SELECT vin, overall_risk_score, recommended_action
FROM predictive_health_summary
WHERE model = '$model'
  AND overall_risk_score > 40
ORDER BY overall_risk_score DESC;
```

## Air suspension and steering angle — not available

Earlier versions shipped air-suspension compressor and ride-height diagnostics (`015`) and a steering-offset alignment check (`010`). They were built on `AirSuspensionHeightFL/FR/RL/RR`, `AirSuspensionCompressorState`, `AirSuspensionMode` and `SteeringAngle`, which no Tesla vehicle sends through Fleet Telemetry: they are not in this fork's proto, not in upstream's current `protos/vehicle_data.proto`, and not in Tesla's published available-data list for any model (checked November 2026). Only the simulator ever wrote them. Migration `045` removes everything built on them; the suspension view now uses what the car does send — `UI_a006` / `CH_*` alerts and highway lateral-acceleration variance (`LateralAcceleration`). If Tesla adds such fields, regenerate the protos and the views can be rebuilt.

## Dual Motor Diagnostics

### What it does

`deploy/sql/016_dual_motor_diagnostics.sql` adds a subsystem layer for dual-motor vehicles (Model 3/Y Long Range AWD, Performance, and Cybertruck Tri-Motor):

- **Front vs Rear inverter temperatures** — Tracks `DiInverterTF` vs `DiInverterTR` using rolling 7-day / 30-day / 90-day baselines. A sustained delta > 12 °C flags `DUAL_MOTOR_IMBALANCE_DETECTED`.
- **Axle speed imbalance** — Compares `DiAxleSpeedF` vs `DiAxleSpeedR` at highway speeds; > 3 % sustained mismatch suggests differential or half-shaft wear.
- **Regen degradation** — Monitors peak regen torque (`DiTorqueActualF/R`) vs 90-day baseline. A > 10 % drop (8 % for Performance variants) flags `REGEN_DEGRADATION_LIKELY`.
- **Thermal throttling** — Detects sustained power/torque drop when inverter temperatures exceed 75 °C, or sustained power falls below 90 % of model-specific baseline.

### Performance variant thresholds

| Threshold | Standard Dual Motor | Performance |
|-----------|--------------------|-------------|
| Regen degradation | 10 % drop | 8 % drop |
| Thermal throttle (power) | < 90 % baseline | < 88 % baseline |
| Temp delta warning | 12 °C | 10 °C |
| Imbalance warning | 3 % axle speed | 2.5 % axle speed |

### Model gating

The `vehicle_metadata.motor_config` column gates all dual-motor features:

- **Dual Motor** — all diagnostics active
- **Performance** — tighter thresholds, lower thermal/power baselines
- **Tri Motor** — front + rear monitored; front motors averaged
- **RWD** — `dual_motor_summary` returns NULL; the dual-motor score is NULL (not applicable) and is left out of the weighted total; Grafana panels show "N/A"

### Predictive Health integration

The dual-motor subsystem is weighted at **5 %** of the overall health score (shaved from Drivetrain 18 % → 15 %). Final weights:

| Subsystem | Weight |
|-----------|--------|
| Battery | 22 % |
| Drivetrain | 14 % |
| Alerts | 15 % |
| 12V | 10 % |
| Heat Pump | 10 % |
| Regen/Brake | 7 % |
| Suspension | 4 % |
| Dual Motor | 5 % |
| Cybertruck | 4 % |
| PCS | 5 % |

Since `051` the overall score is the weighted mean over the subsystems that apply to the vehicle and have recent evidence (`subsystem_weight()`, `subsystem_applies()`, `subsystem_evidence_limit()`), so these weights are renormalised per vehicle; a subsystem without evidence scores NULL, not a healthy 5. The headline severity is the worst of the weighted band, any single subsystem's band and any active critical alert.

### Grafana panels

The Predictive Health dashboard includes dual-motor panels gated by the `$motor_config` template variable (hidden, auto-set from metadata):
- **Dual Motor Health** — Stat panel showing `status`, `severity`, `temp_delta`, `imbalance_pct`, `regen_limit`, `sustained_power`, `anomaly_reason`
- **Front vs Rear Inverter Temp** — Time series with delta overlay
- **Regen & Power Trend** — Regen torque vs 7-day / 30-day trend
- **Thermal Throttle Ratio** — Percentage of sustained power vs baseline with 93 % yellow / 95 % red thresholds

### Simulator testing

```bash
cd tools/simulator
go build -o simulator .

# Model 3 Performance dual-motor (VIN[8] = 'F')
./simulator \
  -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
  -vins "5YJ3E1EA8PF000001" \
  -interval 30

# Model Y Long Range AWD (VIN[8] = 'E')
./simulator \
  -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
  -vins "7SAYGEE9PF000001" \
  -interval 30
```

The simulator generates `DiInverterTF/TR`, `DiHeatsinkTF/TR`, `DiStatorTempF/R`, `DiTorqueActualF/R`, `DiAxleSpeedF/R`, `DiMotorCurrentF/R`, and `DiVBatF/R` for dual-motor VINs. RWD VINs (VIN[8] = 'A' or 'B') skip per-axle fields entirely.

## Cybertruck Diagnostics

### What it does

`deploy/sql/017_cybertruck_diagnostics.sql` adds a comprehensive predictive layer for Tesla Cybertruck (standard and Cyberbeast Tri-Motor), covering four CT-unique subsystems:

- **Tonneau Cover Health** — Monitors `TonneauOpenPercent`, `TonneauPosition`, and `TonneauTentMode`. Flags `TONNEAU_STUCK_OR_MOTOR_FAILURE` when the position sensor reports stuck for multiple hours, or `TONNEAU_OPEN_WHILE_MOVING` when the cover is open during driving.
- **V2L / Powershare Monitoring** — Tracks `PowershareInstantaneousPowerKW`, `PowershareStatus`, and `PowershareHoursLeft`. Flags `V2L_HIGH_LOAD_SUSTAINED` when export exceeds 5 kW for 4+ hours, `V2L_INVERTER_THERMAL_STRESS` when inverter temps exceed 85 °C during export, and `V2L_FAULT_CYCLE_LIKELY` when fault/restart cycles spike.
- **Tri-Motor Balancing (Cyberbeast)** — Monitors front (`DiInverterTF`), rear-left (`DiInverterTREL`), and rear-right (`DiInverterTRER`) inverter temps, plus axle speeds and torque. Flags `TRI_MOTOR_REAR_IMBALANCE_LIKELY` when REL vs RER delta exceeds 10 °C, `TRI_MOTOR_FRONT_REAR_IMBALANCE_LIKELY` when front vs rear delta exceeds 12 °C, and `TRI_MOTOR_THERMAL_THROTTLING_RISK` when sustained power falls below 90% of baseline.
- **4680 Structural Battery Degradation** — Extends the generic battery health view (009) with Cybertruck-specific baselines. Uses the first-recorded rest-capacity reading per VIN as the CT baseline. Flags `CT_4680_EARLY_DEGRADATION` at > 7%, `CT_4680_MODERATE_DEGRADATION` at > 10%, and `CT_4680_SEVERE_DEGRADATION` at > 15% capacity loss. Also monitors brick-voltage delta with a 0.15 V threshold (larger cells tolerate wider deltas but are harder to balance).

### How this helps Cybertruck owners

The Cybertruck is the most discussed and eagerly anticipated vehicle in the Tesla lineup, with enormous community interest in self-hosted telemetry. This layer makes this project the definitive self-hosted tool for Cybertruck owners by:

- **Catching tonneau motor failure early** — The tonneau cover motor and track assembly is a known wear item. Detecting stuck-position trends before total failure saves a $800–$1,200 service visit.
- **Protecting V2L inverter health** — Powershare is a flagship Cybertruck feature. Sustained 11.5 kW home backup can thermally stress the PCS2 inverter. Early warning prevents derating or shutdown during critical backup events.
- **Monitoring tri-motor torque vectoring** — The Cyberbeast's three-motor layout is unique. Detecting rear-left vs rear-right imbalance early can prevent differential or half-shaft damage under high-load towing or off-road conditions.
- **Tracking 4680 structural pack health** — The 4680 cells have different degradation characteristics from 2170/LFP. CT-specific baselines and thresholds give owners accurate, model-aware capacity fade tracking.
- **Validating adaptive suspension safety** — Extract mode at highway speeds is dangerous and can damage the suspension. Automatic detection provides peace of mind.

### Model gating

All cybertruck diagnostics are gated on `vehicle_metadata.model = 'CT'`. Non-Cybertruck vehicles return `NOT_APPLICABLE` with NULL metrics, and the Cybertruck score is NULL (not applicable) for them, so it does not enter the weighted total.

### Predictive Health integration

The Cybertruck subsystem is weighted at **5 %** of the overall health score (shaved from Battery 23 % → 22 %, Drivetrain 15 % → 14 %, Regen/Brake 8 % → 7 %). Final weights:

| Subsystem | Weight |
|-----------|--------|
| Battery | 22 % |
| Drivetrain | 14 % |
| Alerts | 15 % |
| 12V | 10 % |
| Heat Pump | 10 % |
| Regen/Brake | 7 % |
| Suspension | 4 % |
| Dual Motor | 5 % |
| Cybertruck | 4 % |
| PCS | 5 % |

Since `051` the overall score is the weighted mean over the subsystems that apply to the vehicle and have recent evidence (`subsystem_weight()`, `subsystem_applies()`, `subsystem_evidence_limit()`), so these weights are renormalised per vehicle; a subsystem without evidence scores NULL, not a healthy 5. The headline severity is the worst of the weighted band, any single subsystem's band and any active critical alert.

### Grafana panels

The Predictive Health dashboard includes Cybertruck panels gated by the `$model` template variable:
- **Cybertruck Health** — Stat panel showing `overall_severity`, plus all five subsystem statuses
- **Tonneau Position** — Time series showing open percent and position state
- **V2L Export Power** — Time series with 5 kW yellow / 10 kW red thresholds
- **Tri-Motor Inverter Temps** — Time series with front, rear-left, rear-right, and delta overlay (Cyberbeast only)
- **4680 Battery Degradation** — Time series comparing CT-specific vs generic degradation with 7% yellow / 10% red thresholds

### Simulator testing

```bash
cd tools/simulator
go build -o simulator .

# Cybertruck Dual Motor standard (VIN[3] = 'C', VIN[8] = 'E')
./simulator \
  -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
  -vins "7SACGEE9PF000001" \
  -interval 30

# Cyberbeast Tri-Motor (VIN[3] = 'C', VIN[8] = 'J')
./simulator \
  -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
  -vins "7SACGJE9PF000001" \
  -interval 30
```

The simulator generates `TonneauOpenPercent/Position/TentMode`, `PowershareInstantaneousPowerKW/Status/Type/HoursLeft`, `DiInverterTREL/TRER`, `DiHeatsinkTREL/TRER`, `DiStatorTempREL/RER`, `DiAxleSpeedREL/RER`, `DiTorqueActualREL/RER`, `DiMotorCurrentREL/RER`, and `DiVBatREL/RER` for Cybertruck VINs. It also simulates synthetic tonneau stuck events.

## Security and Privacy considerations

System administrators should apply standard best practices, which are beyond
the scope of this README.

Moreover, the following application-specific considerations apply:

* Vehicles authenticate to the telemetry server with TLS client certificates
  and use a variety of security measures designed to prevent unauthorized
  access to the corresponding private key. However, as a defense-in-depth
  precaution, backend services should anticipate the possibility that a
  vehicle's TLS private key may be compromised. Therefore:
  * Backend systems should sanitize data before using it.
  * Users should consider threats from actors that may be incentivized to
    submit falsified data.
  * Users should filter by vehicle identification number (VIN) using an
    allowlist if possible.
* Configuration-signing private keys should be kept offline.
* Configuration-signing private keys should be kept in an HSM.
* If telemetry data is compromised, threat actors may be able to make
  inferences about driver behavior even if explicit location data is not
  collected. Security policies should be set accordingly.
* Tesla strongly encourages providers to only collect data they need, limited to
  the frequency they need.
* Providers agree to take full responsibility for privacy risks, as soon as data
  leave the devices (for more info read our privacy policies).
