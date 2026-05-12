-- ============================================================
-- Suspension & Alignment Early-Warning Layer
--
-- IMPORTANT — Schema limitation:
-- Features are gated per docs/FEATURE_MATRIX.md using vehicle_metadata.
--   Tesla Fleet Telemetry, as implemented in this repository,
--   does NOT expose a SteeringAngle field in the vehicle_data
--   protobuf (confirmed by catalog search of all 259 fields).
--   The only steering-related field is GpsHeading (vehicle
--   orientation, not wheel angle).
--
--   For production use this layer will auto-activate when
--   SteeringAngle data appears (the SQL references it safely
--   via NULL-tolerant pivots).  For end-to-end testing the
--   field has been added to tools/simulator/fields.json.
--
-- Detection strategy (dual):
--   1. PRIMARY  — UI_a006 alert from vehicle_alerts.
--      This is the high-confidence signal.  When Tesla's own
--      BMS/CDC flags a chassis/alignment issue, trust it.
--   2. SECONDARY — Progressive steering-offset increase during
--      highway straight-line driving.  If the driver must hold
--      a larger and larger steering angle to keep lateral
--      acceleration near zero, mechanical drag is building
--      (worn bushings, ball joints, toe drift, etc.).
--
-- Architecture:
--   1. suspension_samples_1m   — 1-minute pivot aligning
--      VehicleSpeed, LateralAcceleration, SteeringAngle.
--   2. suspension_steering_1d  — daily CAGG computing median
--      steering offset during highway straight-line segments.
--   3. suspension_trip_offsets — per-trip analysis using the
--      existing trips view to isolate highway segments.
--   4. suspension_diagnostics  — rolling 7d/30d/90d trends
--      with alignment-degradation flag.
--   5. suspension_alerts       — UI_a006 and related alerts.
--   6. suspension_summary      — combined snapshot for Grafana.
--
-- Highway / straight-line criteria:
--   • speed_avg  > 50 mph  (~80 km/h)
--   • |lat_accel_avg| < 0.05 g  (approximately straight)
--   • SteeringAngle sample present (if not, only drift-proxy)
--
-- Requires superuser (postgres) to run — creates CAGGs.
-- Run after 001_schema.sql and 002_views.sql.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  1-minute pivot CAGG — align speed, lateral accel, steering
--
-- We bucket at 1 minute so that the three fields (sampled every
-- 30 s) are aligned in time.  AVG() smooths jitter; LAST()
-- captures the final sample of each minute.
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS suspension_samples_1m CASCADE;

CREATE MATERIALIZED VIEW suspension_samples_1m
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 minute', ts) AS bucket,
  vin,
  -- Speed
  AVG(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS speed_avg,
  MAX(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS speed_max,
  -- Lateral acceleration
  AVG(CASE WHEN field = 'LateralAcceleration' THEN num_value END) AS lat_accel_avg,
  MAX(ABS(CASE WHEN field = 'LateralAcceleration' THEN num_value END)) AS lat_accel_max_abs,
  -- Steering angle (NULL when field is absent from telemetry)
  AVG(CASE WHEN field = 'SteeringAngle' THEN num_value END) AS steering_avg,
  LAST(num_value, ts) FILTER (WHERE field = 'SteeringAngle') AS steering_last,
  -- GPS heading (supplementary — rate of change hints at turning)
  LAST(num_value, ts) FILTER (WHERE field = 'GpsHeading') AS heading_last,
  -- Sample counts for confidence
  COUNT(*) FILTER (WHERE field = 'VehicleSpeed')           AS n_speed,
  COUNT(*) FILTER (WHERE field = 'LateralAcceleration')    AS n_lat,
  COUNT(*) FILTER (WHERE field = 'SteeringAngle')          AS n_steering
FROM telemetry
WHERE field IN ('VehicleSpeed', 'LateralAcceleration', 'SteeringAngle', 'GpsHeading')
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 2.  Daily steering-offset trend CAGG (built on 1-minute pivot)
--
-- Steering offset = median steering angle during highway
-- straight-line driving.  A healthy car stays within ±1–2°.
-- Progressive drift beyond ±3–5° suggests mechanical wear.
--
-- When SteeringAngle is absent from the stream (production
-- schema today) the median will be NULL and the drift-proxy
-- (LateralAcceleration variance) is still collected.
-- ------------------------------------------------------------------
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
DROP MATERIALIZED VIEW IF EXISTS suspension_steering_1d CASCADE;

CREATE MATERIALIZED VIEW suspension_steering_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  -- Highway minutes (speed > 50 mph)
  COUNT(*) FILTER (WHERE speed_avg > 50) AS highway_minutes,
  -- Straight-line highway minutes
  COUNT(*) FILTER (WHERE speed_avg > 50 AND ABS(lat_accel_avg) < 0.05)
    AS straight_highway_minutes,
  -- Steering offset — median angle during straight highway
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY steering_avg)
    FILTER (WHERE
      speed_avg > 50
      AND ABS(lat_accel_avg) < 0.05
      AND steering_avg IS NOT NULL
    ) AS steering_offset_median,
  -- Steering offset — mean (less robust, easier for simple alerts)
  AVG(steering_avg) FILTER (WHERE
    speed_avg > 50
    AND ABS(lat_accel_avg) < 0.05
    AND steering_avg IS NOT NULL
  ) AS steering_offset_mean,
  -- Absolute offset magnitude (for magnitude-only trending)
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ABS(steering_avg))
    FILTER (WHERE
      speed_avg > 50
      AND ABS(lat_accel_avg) < 0.05
      AND steering_avg IS NOT NULL
    ) AS steering_offset_abs_median,
  -- Lateral-accel drift proxy (works even without steering angle)
  AVG(lat_accel_avg) FILTER (WHERE
    speed_avg > 50
    AND ABS(lat_accel_avg) < 0.05
  ) AS lat_accel_drift,
  -- Lateral-accel variance (increases with looseness / vibration)
  STDDEV(lat_accel_avg) FILTER (WHERE speed_avg > 50) AS lat_accel_stddev,
  -- Max lateral accel on highway (lane changes, curves)
  MAX(lat_accel_max_abs) FILTER (WHERE speed_avg > 50) AS lat_accel_max_abs
FROM suspension_samples_1m
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 3.  Refresh policies
-- ------------------------------------------------------------------
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('suspension_samples_1m');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('suspension_samples_1m',
  start_offset  => INTERVAL '3 days',
  end_offset    => INTERVAL '1 minute',
  schedule_interval => INTERVAL '5 minutes'
);

-- suspension_steering_1d is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('suspension_steering_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ------------------------------------------------------------------
-- 4.  suspension_trip_offsets  — per-trip highway segment analysis
--
-- Uses the existing trips view to isolate individual drives.
-- For each trip that reached highway speeds, computes the
-- steering offset during straight-line segments.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW suspension_trip_offsets AS
WITH trip_buckets AS (
  SELECT
    t.vin,
    t.trip_id,
    t.started,
    t.ended,
    t.distance_km,
    t.max_speed_mph,
    m.bucket,
    m.speed_avg,
    m.lat_accel_avg,
    m.steering_avg
  FROM trips t
  JOIN suspension_samples_1m m
    ON m.vin = t.vin
   AND m.bucket BETWEEN t.started AND t.ended
  WHERE t.max_speed_mph > 50
)
SELECT
  vin,
  trip_id,
  started,
  ended,
  distance_km,
  max_speed_mph,
  -- Steering offset (NULL if SteeringAngle absent)
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY steering_avg)
    FILTER (WHERE
      speed_avg > 50
      AND ABS(lat_accel_avg) < 0.05
      AND steering_avg IS NOT NULL
    ) AS steering_offset_median,
  -- Minutes of straight highway driving in this trip
  COUNT(*) FILTER (WHERE
    speed_avg > 50
    AND ABS(lat_accel_avg) < 0.05
    AND steering_avg IS NOT NULL
  ) AS straight_highway_minutes,
  -- Drift proxy (works without steering angle)
  AVG(lat_accel_avg) FILTER (WHERE
    speed_avg > 50
    AND ABS(lat_accel_avg) < 0.05
  ) AS lat_accel_drift,
  STDDEV(lat_accel_avg) FILTER (WHERE speed_avg > 50) AS lat_accel_stddev
FROM trip_buckets
GROUP BY vin, trip_id, started, ended, distance_km, max_speed_mph;

-- ------------------------------------------------------------------
-- 5.  suspension_diagnostics  — rolling trends & degradation flag
--
-- Uses the daily CAGG to compute 7-day / 30-day / 90-day rolling
-- averages of steering-offset magnitude.  Flags alignment
-- degradation when the short-term average rises significantly
-- above the long-term baseline while highway exposure stays
-- consistent.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW suspension_diagnostics AS
WITH daily AS (
  SELECT
    bucket,
    vin,
    highway_minutes,
    straight_highway_minutes,
    steering_offset_median,
    steering_offset_mean,
    steering_offset_abs_median,
    lat_accel_drift,
    lat_accel_stddev,
    lat_accel_max_abs
  FROM suspension_steering_1d
),
first_baseline AS (
  SELECT
    vin,
    (ARRAY_AGG(steering_offset_abs_median ORDER BY bucket)
      FILTER (WHERE steering_offset_abs_median IS NOT NULL))[1]
      AS baseline_offset_abs
  FROM daily
  WHERE straight_highway_minutes >= 5
  GROUP BY vin
),
rolling AS (
  SELECT
    d.*,
    b.baseline_offset_abs,
    -- Rolling averages of absolute offset magnitude
    AVG(steering_offset_abs_median) OVER w7  AS offset_abs_7d,
    AVG(steering_offset_abs_median) OVER w30 AS offset_abs_30d,
    AVG(steering_offset_abs_median) OVER w90 AS offset_abs_90d,
    -- Rolling averages of drift proxy
    AVG(lat_accel_stddev) OVER w30 AS lat_std_30d,
    AVG(lat_accel_stddev) OVER w90 AS lat_std_90d,
    -- Observation counts
    COUNT(*) OVER w7  AS n_7d,
    COUNT(*) OVER w30 AS n_30d,
    COUNT(*) OVER w90 AS n_90d
  FROM daily d
  LEFT JOIN first_baseline b ON b.vin = d.vin
  WINDOW
    w7  AS (PARTITION BY d.vin ORDER BY d.bucket
            RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY d.vin ORDER BY d.bucket
            RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW),
    w90 AS (PARTITION BY d.vin ORDER BY d.bucket
            RANGE BETWEEN INTERVAL '90 days' PRECEDING AND CURRENT ROW)
)
SELECT
  bucket AS ts,
  vin,
  highway_minutes,
  straight_highway_minutes,
  ROUND(steering_offset_median::numeric, 2) AS steering_offset_median,
  ROUND(steering_offset_mean::numeric, 2) AS steering_offset_mean,
  ROUND(steering_offset_abs_median::numeric, 2) AS steering_offset_abs_median,
  ROUND(lat_accel_drift::numeric, 4) AS lat_accel_drift,
  ROUND(lat_accel_stddev::numeric, 4) AS lat_accel_stddev,
  ROUND(lat_accel_max_abs::numeric, 3) AS lat_accel_max_abs,
  baseline_offset_abs,
  ROUND(offset_abs_7d::numeric, 2)  AS offset_abs_7d_avg,
  ROUND(offset_abs_30d::numeric, 2) AS offset_abs_30d_avg,
  ROUND(offset_abs_90d::numeric, 2) AS offset_abs_90d_avg,
  n_7d,
  n_30d,
  n_90d,
  -- Trend: % increase of 30d over 90d
  CASE WHEN offset_abs_90d > 0
    THEN ROUND(((offset_abs_30d - offset_abs_90d) / offset_abs_90d * 100)::numeric, 1)
    ELSE NULL
  END AS offset_trend_pct,
  -- Degradation flag
  CASE
    -- High-confidence: UI_a006 already fired (checked in summary view)
    -- Here we flag purely from telemetry trends:
    WHEN n_30d >= 10 AND n_90d >= 20
     AND offset_abs_90d > 0
     AND offset_abs_30d > offset_abs_90d * 1.5
     AND offset_abs_30d > 3.0
    THEN 'SUSPENSION_ALIGNMENT_LIKELY'
    WHEN n_30d >= 10 AND n_90d >= 20
     AND baseline_offset_abs > 0
     AND offset_abs_30d > baseline_offset_abs * 2.0
    THEN 'SUSPENSION_ALIGNMENT_LIKELY'
    WHEN n_30d >= 10
     AND lat_accel_stddev > 0.03
     AND lat_std_30d > lat_std_90d * 1.5
    THEN 'SUSPENSION_LOOSENESS_LIKELY'
    ELSE 'NORMAL'
  END AS steering_status
FROM rolling;

-- ------------------------------------------------------------------
-- 6.  suspension_alerts  — UI_a006 and related alert codes
--
-- UI_a006 is the high-confidence signal.  All other UI_a* codes
-- are included for context.  When UI_a006 is active, immediate
-- inspection is recommended.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW suspension_alerts AS
SELECT
  ts,
  vin,
  name AS alert_code,
  audience,
  started_at,
  ended_at,
  CASE
    WHEN name = 'UI_a006' THEN 'CRITICAL'
    WHEN name LIKE 'UI_a%' THEN 'WARNING'
    WHEN name LIKE 'CH_%'  THEN 'WARNING'
    ELSE 'INFO'
  END AS severity,
  CASE name
    WHEN 'UI_a006' THEN 'Chassis/alignment issue detected — inspect suspension immediately'
    ELSE 'Suspension-related alert'
  END AS description
FROM vehicle_alerts
WHERE name = 'UI_a006'
   OR name LIKE 'CH_%';

-- ------------------------------------------------------------------
-- 7.  suspension_summary  — combined snapshot for Grafana
--
-- Brings together the latest steering-offset trend, the most
-- recent UI_a006 status, and the overall service recommendation.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW suspension_summary AS
WITH latest_diag AS (
  SELECT vin, MAX(ts) AS last_ts
  FROM suspension_diagnostics
  WHERE straight_highway_minutes >= 5
  GROUP BY vin
),
diag_snapshot AS (
  SELECT d.*
  FROM suspension_diagnostics d
  JOIN latest_diag l ON l.vin = d.vin AND l.last_ts = d.ts
),
active_alerts AS (
  SELECT
    vin,
    COUNT(*) FILTER (WHERE ended_at IS NULL) AS active_alert_count,
    STRING_AGG(DISTINCT alert_code, ', ' ORDER BY alert_code)
      FILTER (WHERE ended_at IS NULL) AS active_alert_codes,
    MAX(severity) FILTER (WHERE ended_at IS NULL) AS max_severity
  FROM suspension_alerts
  WHERE ts > NOW() - INTERVAL '30 days'
  GROUP BY vin
),
latest_trip AS (
  SELECT vin, MAX(started) AS last_started
  FROM suspension_trip_offsets
  WHERE straight_highway_minutes >= 5
  GROUP BY vin
),
trip_snapshot AS (
  SELECT t.*
  FROM suspension_trip_offsets t
  JOIN latest_trip l ON l.vin = t.vin AND l.last_started = t.started
)
SELECT
  d.vin,
  d.ts AS last_diag_ts,
  d.steering_offset_median AS last_offset_median,
  d.steering_offset_abs_median AS last_offset_abs_median,
  d.offset_abs_30d_avg,
  d.offset_abs_90d_avg,
  d.offset_trend_pct,
  d.lat_accel_stddev AS last_lat_accel_stddev,
  d.steering_status,
  t.started AS last_trip_started,
  t.steering_offset_median AS last_trip_offset,
  t.straight_highway_minutes AS last_trip_straight_minutes,
  COALESCE(a.active_alert_count, 0) AS active_alert_count,
  a.active_alert_codes,
  COALESCE(a.max_severity, 'NONE') AS max_alert_severity,
  CASE
    WHEN COALESCE(a.max_severity, 'NONE') = 'CRITICAL'
      THEN 'SUSPENSION_SERVICE_REQUIRED'
    WHEN COALESCE(a.max_severity, 'NONE') = 'URGENT'
      THEN 'SUSPENSION_SERVICE_RECOMMENDED'
    WHEN d.steering_status = 'SUSPENSION_ALIGNMENT_LIKELY'
      THEN 'SUSPENSION_ALIGNMENT_LIKELY'
    WHEN d.steering_status = 'SUSPENSION_LOOSENESS_LIKELY'
      THEN 'SUSPENSION_LOOSENESS_LIKELY'
    ELSE 'NORMAL'
  END AS overall_status,
  vm.model,
  vm.has_air_suspension
FROM diag_snapshot d
LEFT JOIN trip_snapshot t ON t.vin = d.vin
LEFT JOIN active_alerts a ON a.vin = d.vin
LEFT JOIN vehicle_metadata vm ON vm.vin = d.vin;

-- ------------------------------------------------------------------
-- 8.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Suspension Status"  (Stat + colour threshold)
-- --------------------------------------------------------
-- Red    = SUSPENSION_SERVICE_REQUIRED  (UI_a006 active)
-- Orange = SUSPENSION_SERVICE_RECOMMENDED
-- Yellow = SUSPENSION_ALIGNMENT_LIKELY / SUSPENSION_LOOSENESS_LIKELY
-- Green  = NORMAL
--
-- SELECT
--   overall_status,
--   offset_trend_pct,
--   last_offset_abs_median,
--   active_alert_count,
--   max_alert_severity
-- FROM suspension_summary
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Steering Offset Trend"  (Time series)
-- --------------------------------------------------------
-- Absolute steering-offset magnitude with 30-day and 90-day
-- baselines.  Add Alert rule on steering_status.
--
-- SELECT
--   ts AS time,
--   steering_offset_abs_median AS "Daily offset (°)",
--   offset_abs_30d_avg AS "30-day avg",
--   offset_abs_90d_avg AS "90-day avg"
-- FROM suspension_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Lateral Acceleration vs Steering Angle"  (Scatter)
-- --------------------------------------------------------
-- Each point = one 1-minute highway sample.  Healthy points
-- cluster near (0, 0).  A drifted suspension shifts the cloud
-- horizontally (non-zero steering at zero lateral accel).
--
-- SELECT
--   steering_avg AS "Steering angle (°)",
--   lat_accel_avg AS "Lateral accel (g)"
-- FROM suspension_samples_1m
-- WHERE vin = '$vin'
--   AND speed_avg > 50
--   AND ABS(lat_accel_avg) < 0.10
--   AND steering_avg IS NOT NULL
--   AND $__timeFilter(bucket)
-- ORDER BY bucket;

-- --------------------------------------------------------
-- Panel: "Highway Drift Proxy"  (Time series)
-- --------------------------------------------------------
-- Works even when SteeringAngle is absent.  Rising std-dev
-- of lateral accel during highway driving indicates
-- increased vibration / looseness.
--
-- SELECT
--   ts AS time,
--   lat_accel_stddev AS "Lateral accel std-dev",
--   lat_accel_drift AS "Mean drift"
-- FROM suspension_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Per-Trip Steering Offset"  (Table)
-- --------------------------------------------------------
-- Lists recent trips with highway straight-line offset.
--
-- SELECT
--   started AS "Trip start",
--   distance_km AS "Distance (km)",
--   max_speed_mph AS "Max speed (mph)",
--   steering_offset_median AS "Offset (°)",
--   straight_highway_minutes AS "Straight min"
-- FROM suspension_trip_offsets
-- WHERE vin = '$vin'
-- ORDER BY started DESC
-- LIMIT 50;

-- --------------------------------------------------------
-- Panel: "Active Alerts"  (Table)
-- --------------------------------------------------------
-- UI_a006 and related suspension alerts.
--
-- SELECT
--   alert_code AS "Alert",
--   severity AS "Severity",
--   description AS "Description",
--   started_at AS "Started"
-- FROM suspension_alerts
-- WHERE vin = '$vin'
--   AND ended_at IS NULL
-- ORDER BY severity, started_at DESC;

-- ------------------------------------------------------------------
-- 9.  How to test with the simulator
-- ------------------------------------------------------------------
-- The simulator now includes SteeringAngle (added to
-- fields.json).  It generates a sine-wave by default.
--
-- Step 1 — Re-build and start the simulator
--   cd tools/simulator
--   go build -o simulator .
--   ./simulator \
--     -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
--     -vins "SIMULATEDVIN001" \
--     -interval 30
--
--   Let it run until there are several trips with highway speed.
--
-- Step 2 — Verify highway data exists
--   SELECT bucket, speed_avg, lat_accel_avg, steering_avg
--   FROM suspension_samples_1m
--   WHERE vin = 'SIMULATEDVIN001'
--     AND speed_avg > 50
--   ORDER BY bucket DESC LIMIT 10;
--
-- Step 3 — Inject a constant steering offset (simulate alignment drift)
--   -- Insert a +5° offset into all recent SteeringAngle samples
--   UPDATE telemetry
--   SET num_value = num_value + 5.0
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field = 'SteeringAngle'
--     AND ts > NOW() - INTERVAL '2 hours';
--
--   -- Refresh CAGGs
--   CALL refresh_continuous_aggregate('suspension_samples_1m',
--     NOW() - INTERVAL '1 day', NOW());
--   CALL refresh_continuous_aggregate('suspension_steering_1d',
--     NOW() - INTERVAL '7 days', NOW());
--
--   SELECT ts, steering_offset_abs_median, offset_trend_pct, steering_status
--   FROM suspension_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 4 — Simulate UI_a006 alert (high-confidence primary signal)
--   INSERT INTO vehicle_alerts (ts, vin, name, started_at)
--   VALUES (NOW(), 'SIMULATEDVIN001', 'UI_a006', NOW());
--
--   SELECT * FROM suspension_summary
--   WHERE vin = 'SIMULATEDVIN001';
--
-- Step 5 — Simulate increased lateral-accel looseness
--   -- Increase LateralAcceleration variance by adding jitter
--   UPDATE telemetry
--   SET num_value = num_value + (random() - 0.5) * 0.05
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field = 'LateralAcceleration'
--     AND ts > NOW() - INTERVAL '2 hours';
--
--   CALL refresh_continuous_aggregate('suspension_samples_1m',
--     NOW() - INTERVAL '1 day', NOW());
--
--   SELECT ts, lat_accel_stddev, steering_status
--   FROM suspension_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 6 — Clean up
--   DELETE FROM telemetry WHERE vin = 'SIMULATEDVIN001';
--   DELETE FROM vehicle_alerts WHERE vin = 'SIMULATEDVIN001';
--   SELECT remove_continuous_aggregate_policy('suspension_samples_1m');
--   DROP MATERIALIZED VIEW suspension_samples_1m CASCADE;
--   -- then re-create from this file.
-- ------------------------------------------------------------------
