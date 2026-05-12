-- ============================================================
-- Predictive Anomaly Detection Layer
--
-- Requires superuser (postgres) to run — creates CAGGs,
-- Features are gated per docs/FEATURE_MATRIX.md using vehicle_metadata.
-- functions and refresh policies.
--
-- Architecture:
--   1. CAGGs (telemetry_anomaly_1h / _1d) downsample raw EAV
--      telemetry into hourly/daily materialized aggregates for
--      15 safety-critical fields.
--   2. telemetry_rolling_stats computes 7-day and 30-day rolling
--      mean, stddev, median and MAD using window functions over
--      the hourly CAGG.
--   3. telemetry_anomalies joins current hourly values with their
--      rolling baselines and flags deviations > 3σ or > 3×MAD.
--
-- Run this after 001_schema.sql and 002_views.sql are in place.
-- Refresh policies are idempotent (safe to re-run).
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Hourly Continuous Aggregate — 15 key fields
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS telemetry_anomaly_1h CASCADE;

CREATE MATERIALIZED VIEW telemetry_anomaly_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin,
  field,
  AVG(num_value)   AS avg_v,
  STDDEV(num_value) AS stddev_v,
  MIN(num_value)   AS min_v,
  MAX(num_value)   AS max_v,
  COUNT(*)         AS n
FROM telemetry
WHERE field IN (
  -- Battery health & safety
  'PackVoltage', 'PackCurrent', 'ModuleTempMax', 'ModuleTempMin',
  'IsolationResistance',
  -- Tyre safety
  'TpmsPressureFl', 'TpmsPressureFr', 'TpmsPressureRl', 'TpmsPressureRr',
  -- Drive state
  'Soc', 'VehicleSpeed',
  -- Powertrain thermal
  'DiStatorTempR', 'DiInverterTR',
  -- Dynamics
  'LateralAcceleration', 'LongitudinalAcceleration'
)
  AND num_value IS NOT NULL
GROUP BY bucket, vin, field;

-- ------------------------------------------------------------------
-- 2.  Daily Continuous Aggregate — same fields, coarser grain
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS telemetry_anomaly_1d CASCADE;

CREATE MATERIALIZED VIEW telemetry_anomaly_1d
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 day', ts) AS bucket,
  vin,
  field,
  AVG(num_value)   AS avg_v,
  STDDEV(num_value) AS stddev_v,
  MIN(num_value)   AS min_v,
  MAX(num_value)   AS max_v,
  COUNT(*)         AS n
FROM telemetry
WHERE field IN (
  'PackVoltage', 'PackCurrent', 'ModuleTempMax', 'ModuleTempMin',
  'IsolationResistance',
  'TpmsPressureFl', 'TpmsPressureFr', 'TpmsPressureRl', 'TpmsPressureRr',
  'Soc', 'VehicleSpeed',
  'DiStatorTempR', 'DiInverterTR',
  'LateralAcceleration', 'LongitudinalAcceleration'
)
  AND num_value IS NOT NULL
GROUP BY bucket, vin, field;

-- ------------------------------------------------------------------
-- 3.  Refresh policies
--
-- 1h CAGG: refresh every hour, covering the last 7 days of raw data.
-- 1d CAGG: refresh once a day, covering the last 30 days.
-- ------------------------------------------------------------------
DO $$
BEGIN
  -- 1h policy
  PERFORM remove_continuous_aggregate_policy('telemetry_anomaly_1h');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

SELECT add_continuous_aggregate_policy('telemetry_anomaly_1h',
  start_offset  => INTERVAL '7 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

DO $$
BEGIN
  -- 1d policy
  PERFORM remove_continuous_aggregate_policy('telemetry_anomaly_1d');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

SELECT add_continuous_aggregate_policy('telemetry_anomaly_1d',
  start_offset  => INTERVAL '30 days',
  end_offset    => INTERVAL '1 day',
  schedule_interval => INTERVAL '1 day'
);

-- ------------------------------------------------------------------
-- 4.  Helper function: calculate_anomaly_score
--
-- Returns z_score (σ-based) and mad_score (Median-Absolute-Deviation
-- based) for a single observation against its rolling baseline.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION calculate_anomaly_score(
  val        DOUBLE PRECISION,
  avg_v      DOUBLE PRECISION,
  stddev_v   DOUBLE PRECISION,
  median_v   DOUBLE PRECISION,
  mad_v      DOUBLE PRECISION
)
RETURNS TABLE(z_score DOUBLE PRECISION, mad_score DOUBLE PRECISION)
LANGUAGE SQL IMMUTABLE AS $$
  SELECT
    CASE
      WHEN stddev_v > 0 AND stddev_v IS NOT NULL
        THEN (val - avg_v) / stddev_v
      ELSE 0
    END,
    CASE
      WHEN mad_v > 0 AND mad_v IS NOT NULL
        THEN ABS(val - median_v) / mad_v
      ELSE 0
    END;
$$;

-- ------------------------------------------------------------------
-- 5.  Rolling statistical baselines
--
-- Built on top of telemetry_anomaly_1h.  For every hourly bucket we
-- look back 7 days (168 buckets) and 30 days (720 buckets) to
-- compute:
--   • rolling mean   (window AVG)
--   • rolling stddev (window STDDEV)
--   • rolling median (PERCENTILE_CONT over the window)
--   • rolling MAD    (median of |value - median| over the window)
--
-- Median & MAD are calculated with correlated sub-queries.  Because
-- the source is already down-sampled to ~15 fields × 1 VIN × 24 h
-- = 360 rows/day, the cost is negligible for Grafana dashboards.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW telemetry_rolling_stats AS
WITH hourly AS (
  SELECT bucket, vin, field, avg_v
  FROM telemetry_anomaly_1h
),
-- 7-day rolling median via ordered-set aggregate
med7 AS (
  SELECT
    h.bucket, h.vin, h.field, h.avg_v,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY h2.avg_v)
     FROM hourly h2
     WHERE h2.vin   = h.vin
       AND h2.field = h.field
       AND h2.bucket BETWEEN h.bucket - INTERVAL '7 days' AND h.bucket
    ) AS median_7d
  FROM hourly h
),
-- 30-day rolling median
med30 AS (
  SELECT
    m.*,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY h2.avg_v)
     FROM hourly h2
     WHERE h2.vin   = m.vin
       AND h2.field = m.field
       AND h2.bucket BETWEEN m.bucket - INTERVAL '30 days' AND m.bucket
    ) AS median_30d
  FROM med7 m
)
SELECT
  m.bucket,
  m.vin,
  m.field,
  m.avg_v,

  -- 7-day window stats
  AVG(m.avg_v) OVER w7                                    AS avg_7d,
  STDDEV(m.avg_v) OVER w7                                 AS stddev_7d,
  m.median_7d,
  (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ABS(h2.avg_v - m.median_7d))
   FROM hourly h2
   WHERE h2.vin   = m.vin
     AND h2.field = m.field
     AND h2.bucket BETWEEN m.bucket - INTERVAL '7 days' AND m.bucket
  )                                                       AS mad_7d,

  -- 30-day window stats
  AVG(m.avg_v) OVER w30                                   AS avg_30d,
  STDDEV(m.avg_v) OVER w30                                AS stddev_30d,
  m.median_30d,
  (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ABS(h2.avg_v - m.median_30d))
   FROM hourly h2
   WHERE h2.vin   = m.vin
     AND h2.field = m.field
     AND h2.bucket BETWEEN m.bucket - INTERVAL '30 days' AND m.bucket
  )                                                       AS mad_30d,

  -- observation count in each window (handy for confidence)
  COUNT(*) OVER w7                                        AS n_7d,
  COUNT(*) OVER w30                                       AS n_30d

FROM med30 m
WINDOW
  w7  AS (PARTITION BY m.vin, m.field ORDER BY m.bucket RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW),
  w30 AS (PARTITION BY m.vin, m.field ORDER BY m.bucket RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW);

-- ------------------------------------------------------------------
-- 6.  Main anomaly detection view
--
-- Flags any hourly observation whose z-score or MAD-score exceeds 3.
-- Severity escalates to "critical" when either score exceeds 4.
--
-- Columns:
--   ts, vin, field, value      — the observation
--   baseline_avg, baseline_stddev, baseline_median, baseline_mad
--                              — 7-day rolling baseline
--   z_score, mad_score         — deviation metrics
--   anomaly_type               — 'z_score' | 'mad' | 'both' | 'normal'
--   severity                   — 'critical' | 'warning' | 'normal'
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW telemetry_anomalies AS
WITH scored AS (
  SELECT
    bucket AS ts,
    vin,
    field,
    avg_v AS value,
    avg_7d   AS baseline_avg,
    stddev_7d AS baseline_stddev,
    median_7d AS baseline_median,
    mad_7d   AS baseline_mad,
    (calculate_anomaly_score(avg_v, avg_7d, stddev_7d, median_7d, mad_7d)).z_score   AS z_score,
    (calculate_anomaly_score(avg_v, avg_7d, stddev_7d, median_7d, mad_7d)).mad_score AS mad_score
  FROM telemetry_rolling_stats
  WHERE stddev_7d IS NOT NULL
    AND mad_7d    IS NOT NULL
    AND n_7d      >= 24          -- require at least 24 hourly samples (~1 day)
)
SELECT
  ts,
  vin,
  field,
  value,
  baseline_avg,
  baseline_stddev,
  baseline_median,
  baseline_mad,
  ROUND(z_score::numeric,   3) AS z_score,
  ROUND(mad_score::numeric, 3) AS mad_score,
  CASE
    WHEN ABS(z_score) > 3 AND ABS(mad_score) > 3 THEN 'both'
    WHEN ABS(z_score) > 3 THEN 'z_score'
    WHEN ABS(mad_score) > 3 THEN 'mad'
    ELSE 'normal'
  END AS anomaly_type,
  CASE
    WHEN GREATEST(ABS(z_score), ABS(mad_score)) > 4 THEN 'critical'
    WHEN GREATEST(ABS(z_score), ABS(mad_score)) > 3 THEN 'warning'
    ELSE 'normal'
  END AS severity
FROM scored;

-- ------------------------------------------------------------------
-- 7.  Convenience view: latest risk snapshot per VIN
--
-- Shows the most recent anomaly scores for every monitored field,
-- useful for a Grafana "Current Risk Score" Stat panel.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW telemetry_anomaly_latest AS
SELECT DISTINCT ON (ta.vin, ta.field)
  ta.ts,
  ta.vin,
  ta.field,
  ta.value,
  ta.z_score,
  ta.mad_score,
  ta.anomaly_type,
  ta.severity,
  vm.model
FROM telemetry_anomalies ta
LEFT JOIN vehicle_metadata vm ON vm.vin = ta.vin
ORDER BY ta.vin, ta.field, ta.ts DESC;

-- ------------------------------------------------------------------
-- 8.  Example Grafana queries
--
-- Copy these into raw-SQL panels in a new "Tesla — Anomalies"
-- dashboard (or add panels to Overview / Energy).
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Current Risk Score"  (Stat panel)
-- --------------------------------------------------------
-- Shows the highest anomaly score across all fields for the
-- selected VIN right now.  Use a Threshold colour rule:
--   green  < 1
--   yellow 1 – 3
--   red    > 3
--
-- SELECT
--   GREATEST(ABS(z_score), ABS(mad_score)) AS risk_score,
--   field AS "Worst Field"
-- FROM telemetry_anomaly_latest
-- WHERE vin = '$vin'
-- ORDER BY risk_score DESC
-- LIMIT 1;

-- --------------------------------------------------------
-- Panel: "Anomaly Timeline"  (Time series panel)
-- --------------------------------------------------------
-- Count of anomalies per hour.  Stack or colour by severity.
--
-- SELECT
--   ts AS time,
--   COUNT(*) FILTER (WHERE severity = 'critical') AS critical,
--   COUNT(*) FILTER (WHERE severity = 'warning')  AS warning
-- FROM telemetry_anomalies
-- WHERE vin = '$vin'
--   AND anomaly_type != 'normal'
--   AND $__timeFilter(ts)
-- GROUP BY ts
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Field Deviation"  (Time series panel)
-- --------------------------------------------------------
-- Overlay raw value + 7-day rolling band for a single field.
-- Replace 'PackVoltage' with the field you want to inspect.
--
-- SELECT
--   ts AS time,
--   value AS "Value",
--   baseline_avg AS "Baseline",
--   baseline_avg + 3 * baseline_stddev AS "+3σ",
--   baseline_avg - 3 * baseline_stddev AS "-3σ"
-- FROM telemetry_anomalies
-- WHERE vin = '$vin'
--   AND field = 'PackVoltage'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- ------------------------------------------------------------------
-- 9.  How to test with the simulator
-- ------------------------------------------------------------------
-- The simulator (tools/simulator/) writes realistic synthetic
-- telemetry to the same `telemetry` hypertable.  Use it to build
-- a baseline and then inject anomalies.
--
-- Step 1 — Baseline (run for at least 24 h)
--   go run ./tools/simulator \
--     -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
--     -vins "SIMULATEDVIN001" \
--     -interval 30
--
--   Let this run overnight.  The CAGG refresh policy will
--   materialise hourly buckets.  telemetry_rolling_stats needs
--   ≥24 hourly samples (n_7d >= 24) before it starts scoring.
--
-- Step 2 — Verify baselines exist
--   SELECT field, avg_7d, stddev_7d, median_7d, mad_7d
--   FROM telemetry_rolling_stats
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY bucket DESC LIMIT 20;
--
-- Step 3 — Inject an anomaly manually
--   The simulator generates values inside the bands defined in
--   bandsFor().  To force an anomaly, insert an outlier directly:
--
--   INSERT INTO telemetry (ts, vin, field, num_value)
--   VALUES (NOW(), 'SIMULATEDVIN001', 'PackVoltage', 520.0);
--   -- Baseline for PackVoltage is ~380 ± 10.  520 is >10σ.
--
--   Within the next CAGG refresh cycle (≤1 h) the outlier will
--   appear in telemetry_anomalies with severity = 'critical'.
--
-- Step 4 — Verify the alert
--   SELECT * FROM telemetry_anomalies
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 5 — Clean up
--   DELETE FROM telemetry
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field = 'PackVoltage'
--     AND num_value = 520.0;
--
--   Or simply stop the simulator and remove the test VIN:
--   DELETE FROM telemetry WHERE vin = 'SIMULATEDVIN001';
--   SELECT remove_continuous_aggregate_policy('telemetry_anomaly_1h');
--   DROP MATERIALIZED VIEW telemetry_anomaly_1h CASCADE;
--   -- then re-create from this file.
-- ------------------------------------------------------------------
