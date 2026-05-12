-- Tesla Fleet Telemetry → TimescaleDB schema
-- Idempotent. Safe to run on every deploy.

CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS postgis;

-- ============================================================
-- Main telemetry hypertable
-- ============================================================
CREATE TABLE IF NOT EXISTS telemetry (
  ts          TIMESTAMPTZ      NOT NULL,
  vin         TEXT             NOT NULL,
  field       TEXT             NOT NULL,
  num_value   DOUBLE PRECISION,
  str_value   TEXT,
  geo_value   GEOGRAPHY(POINT, 4326),
  PRIMARY KEY (ts, vin, field)
);

SELECT create_hypertable(
  'telemetry', 'ts',
  chunk_time_interval => INTERVAL '7 days',
  if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS telemetry_vin_field_ts
  ON telemetry (vin, field, ts DESC);
CREATE INDEX IF NOT EXISTS telemetry_field_ts
  ON telemetry (field, ts DESC);
CREATE INDEX IF NOT EXISTS telemetry_geo
  ON telemetry USING GIST (geo_value)
  WHERE geo_value IS NOT NULL;

-- Compression
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM timescaledb_information.compression_settings
    WHERE hypertable_name = 'telemetry'
  ) THEN
    EXECUTE $sql$
      ALTER TABLE telemetry SET (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'vin, field',
        timescaledb.compress_orderby   = 'ts DESC'
      )
    $sql$;
    PERFORM add_compression_policy('telemetry', INTERVAL '7 days');
    PERFORM add_retention_policy('telemetry', INTERVAL '5 years');
  END IF;
END$$;

-- ============================================================
-- Side-channel records: alerts, errors, connectivity
-- These are low-volume but useful for ops dashboards.
-- ============================================================
CREATE TABLE IF NOT EXISTS vehicle_alerts (
  ts        TIMESTAMPTZ NOT NULL,
  vin       TEXT        NOT NULL,
  name      TEXT        NOT NULL,
  audience  TEXT,
  started_at TIMESTAMPTZ,
  ended_at   TIMESTAMPTZ
);
SELECT create_hypertable('vehicle_alerts', 'ts',
  chunk_time_interval => INTERVAL '30 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS vehicle_alerts_vin_ts ON vehicle_alerts (vin, ts DESC);

CREATE TABLE IF NOT EXISTS vehicle_errors (
  ts         TIMESTAMPTZ NOT NULL,
  vin        TEXT        NOT NULL,
  name       TEXT        NOT NULL,
  body       TEXT,
  tags       JSONB,
  created_at TIMESTAMPTZ
);
SELECT create_hypertable('vehicle_errors', 'ts',
  chunk_time_interval => INTERVAL '30 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS vehicle_errors_vin_ts ON vehicle_errors (vin, ts DESC);

CREATE TABLE IF NOT EXISTS vehicle_connectivity (
  ts            TIMESTAMPTZ NOT NULL,
  vin           TEXT        NOT NULL,
  status        TEXT        NOT NULL,
  network_interface TEXT,
  reason        TEXT
);
SELECT create_hypertable('vehicle_connectivity', 'ts',
  chunk_time_interval => INTERVAL '30 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS vehicle_connectivity_vin_ts ON vehicle_connectivity (vin, ts DESC);

-- ============================================================
-- Continuous aggregates: 1-minute and 1-hour rollups
-- ============================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS telemetry_1m
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 minute', ts) AS bucket,
  vin, field,
  AVG(num_value)              AS avg_v,
  MIN(num_value)              AS min_v,
  MAX(num_value)              AS max_v,
  LAST(num_value, ts)         AS last_v,
  COUNT(*)                    AS n
FROM telemetry
WHERE num_value IS NOT NULL
GROUP BY bucket, vin, field
WITH NO DATA;

CREATE MATERIALIZED VIEW IF NOT EXISTS telemetry_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin, field,
  AVG(num_value)            AS avg_v,
  MIN(num_value)            AS min_v,
  MAX(num_value)            AS max_v,
  LAST(num_value, ts)       AS last_v,
  COUNT(*)                  AS n
FROM telemetry
WHERE num_value IS NOT NULL
GROUP BY bucket, vin, field
WITH NO DATA;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM timescaledb_information.jobs
    WHERE proc_name = 'policy_refresh_continuous_aggregate'
      AND hypertable_name = 'telemetry_1m'
  ) THEN
    PERFORM add_continuous_aggregate_policy('telemetry_1m',
      start_offset      => INTERVAL '1 day',
      end_offset        => INTERVAL '1 minute',
      schedule_interval => INTERVAL '1 minute');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM timescaledb_information.jobs
    WHERE proc_name = 'policy_refresh_continuous_aggregate'
      AND hypertable_name = 'telemetry_1h'
  ) THEN
    PERFORM add_continuous_aggregate_policy('telemetry_1h',
      start_offset      => INTERVAL '7 days',
      end_offset        => INTERVAL '1 hour',
      schedule_interval => INTERVAL '5 minutes');
  END IF;
END$$;
