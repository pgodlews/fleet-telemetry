-- ============================================================
-- Drivetrain / Motor & Inverter Diagnostics Layer
--
-- Context: Tesla Fleet Telemetry exposes raw drive-inverter
-- Features are gated per docs/FEATURE_MATRIX.md using vehicle_metadata.
-- temperatures, torques, and motor currents, but does NOT
-- stream explicit "regen power limit" or "max torque limit"
-- fields.  We therefore derive health indicators from:
--
--   1. Temperature trends — highest inverter / heatsink / stator
--      temps observed during highway driving.
--   2. Peak torque trends — most negative (regen) and most
--      positive (acceleration) torque delivered per highway
--      segment.  A progressive drop indicates derating.
--
-- Architecture:
--   1. drivetrain_samples_1h    — hourly pivot capturing the
--      worst-case temps and peak torques across all axles.
--   2. drivetrain_highway_1d    — daily CAGG filtering to
--      highway hours (VehicleSpeed > 50 mph).
--   3. drivetrain_trip_analysis — per-trip stats using the
--      existing trips view.
--   4. drivetrain_diagnostics   — rolling 7d/30d/90d trends
--      with dynamic 95th-percentile temp baselines and
--      torque-degradation flags.
--   5. drivetrain_summary       — Grafana-friendly snapshot.
--
-- Flags:
--   INVERTER_OVERHEAT_RISK      — 7-day avg temp exceeds
--      90-day avg + 2σ (≈ 95th-percentile proxy) OR absolute
--      threshold (inverter > 85 °C, stator > 120 °C).
--   DRIVE_UNIT_DEGRADATION_LIKELY — peak regen or accel
--      torque drops > 10 % below the 90-day baseline while
--      highway exposure stays consistent.
--
-- Requires superuser (postgres) to run — creates CAGGs.
-- Run after 001_schema.sql and 002_views.sql.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Hourly pivot CAGG — drivetrain fields aligned per hour
--
-- We collapse F/R/REL/RER (front, rear, rear-ext-left,
-- rear-ext-right) into a single "worst case" per hour:
--   • max inverter temp   = hottest inverter anywhere
--   • max heatsink temp   = hottest heatsink anywhere
--   • max stator temp     = hottest stator anywhere
--   • peak regen torque   = most negative torque anywhere
--   • peak accel torque   = most positive torque anywhere
--
-- This keeps the daily CAGG small while still capturing
-- the component most likely to fail first.
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS drivetrain_samples_1h CASCADE;

CREATE MATERIALIZED VIEW drivetrain_samples_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin,
  -- Worst-case temps across all inverter positions
  GREATEST(
    MAX(CASE WHEN field = 'DiInverterTF'  THEN num_value END),
    MAX(CASE WHEN field = 'DiInverterTR'  THEN num_value END),
    MAX(CASE WHEN field = 'DiInverterTREL' THEN num_value END),
    MAX(CASE WHEN field = 'DiInverterTRER' THEN num_value END)
  ) AS inverter_temp_max,
  GREATEST(
    MAX(CASE WHEN field = 'DiHeatsinkTF'  THEN num_value END),
    MAX(CASE WHEN field = 'DiHeatsinkTR'  THEN num_value END),
    MAX(CASE WHEN field = 'DiHeatsinkTREL' THEN num_value END),
    MAX(CASE WHEN field = 'DiHeatsinkTRER' THEN num_value END)
  ) AS heatsink_temp_max,
  GREATEST(
    MAX(CASE WHEN field = 'DiStatorTempF'  THEN num_value END),
    MAX(CASE WHEN field = 'DiStatorTempR'  THEN num_value END),
    MAX(CASE WHEN field = 'DiStatorTempREL' THEN num_value END),
    MAX(CASE WHEN field = 'DiStatorTempRER' THEN num_value END)
  ) AS stator_temp_max,
  -- Peak regen torque (most negative) across all positions
  LEAST(
    MIN(CASE WHEN field = 'DiTorqueActualF'  THEN num_value END),
    MIN(CASE WHEN field = 'DiTorqueActualR'  THEN num_value END),
    MIN(CASE WHEN field = 'DiTorqueActualREL' THEN num_value END),
    MIN(CASE WHEN field = 'DiTorqueActualRER' THEN num_value END)
  ) AS peak_regen_torque,
  -- Peak accel torque (most positive) across all positions
  GREATEST(
    MAX(CASE WHEN field = 'DiTorqueActualF'  THEN num_value END),
    MAX(CASE WHEN field = 'DiTorqueActualR'  THEN num_value END),
    MAX(CASE WHEN field = 'DiTorqueActualREL' THEN num_value END),
    MAX(CASE WHEN field = 'DiTorqueActualRER' THEN num_value END)
  ) AS peak_accel_torque,
  -- Torque command (for ratio tracking)
  MIN(CASE WHEN field = 'DiSlaveTorqueCmd' THEN num_value END) AS torque_cmd_min,
  MAX(CASE WHEN field = 'DiSlaveTorqueCmd' THEN num_value END) AS torque_cmd_max,
  -- Motor current (max across front/rear)
  GREATEST(
    MAX(CASE WHEN field = 'DiMotorCurrentF' THEN num_value END),
    MAX(CASE WHEN field = 'DiMotorCurrentR' THEN num_value END)
  ) AS motor_current_max,
  -- Vehicle speed
  MAX(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS vehicle_speed_max
FROM telemetry
WHERE field IN (
  'DiHeatsinkTF', 'DiHeatsinkTR', 'DiHeatsinkTREL', 'DiHeatsinkTRER',
  'DiInverterTF', 'DiInverterTR', 'DiInverterTREL', 'DiInverterTRER',
  'DiStatorTempF', 'DiStatorTempR', 'DiStatorTempREL', 'DiStatorTempRER',
  'DiTorqueActualF', 'DiTorqueActualR', 'DiTorqueActualREL', 'DiTorqueActualRER',
  'DiSlaveTorqueCmd', 'DiTorquemotor',
  'DiMotorCurrentF', 'DiMotorCurrentR',
  'VehicleSpeed'
)
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 2.  Daily highway drivetrain CAGG (built on hourly pivot)
--
-- Filters to hours where the vehicle reached highway speeds
-- (> 50 mph).  Captures the max temps and peak torques seen
-- during demanding driving — the conditions that stress the
-- drivetrain most.
-- ------------------------------------------------------------------
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
DROP MATERIALIZED VIEW IF EXISTS drivetrain_highway_1d CASCADE;

CREATE MATERIALIZED VIEW drivetrain_highway_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  -- Highway exposure
  COUNT(*) FILTER (WHERE vehicle_speed_max > 50) AS highway_hours,
  -- Max temps during highway hours
  MAX(inverter_temp_max) FILTER (WHERE vehicle_speed_max > 50)
    AS inverter_temp_max,
  MAX(heatsink_temp_max) FILTER (WHERE vehicle_speed_max > 50)
    AS heatsink_temp_max,
  MAX(stator_temp_max) FILTER (WHERE vehicle_speed_max > 50)
    AS stator_temp_max,
  -- Peak regen during highway (most negative)
  MIN(peak_regen_torque) FILTER (WHERE vehicle_speed_max > 50)
    AS peak_regen_torque,
  -- Peak accel during highway (most positive)
  MAX(peak_accel_torque) FILTER (WHERE vehicle_speed_max > 50)
    AS peak_accel_torque,
  -- Peak motor current during highway
  MAX(motor_current_max) FILTER (WHERE vehicle_speed_max > 50)
    AS motor_current_max
FROM drivetrain_samples_1h
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 3.  Refresh policies
-- ------------------------------------------------------------------
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('drivetrain_samples_1h');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('drivetrain_samples_1h',
  start_offset  => INTERVAL '7 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- drivetrain_highway_1d is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('drivetrain_highway_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ------------------------------------------------------------------
-- 4.  drivetrain_trip_analysis  — per-trip highway stats
--
-- Uses the existing trips view to isolate individual drives.
-- For each trip that reached highway speeds, captures the
-- worst-case temps and peak torques.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW drivetrain_trip_analysis AS
WITH trip_buckets AS (
  SELECT
    t.vin,
    t.trip_id,
    t.started,
    t.ended,
    t.distance_km,
    t.max_speed_mph,
    m.bucket,
    m.inverter_temp_max,
    m.heatsink_temp_max,
    m.stator_temp_max,
    m.peak_regen_torque,
    m.peak_accel_torque,
    m.motor_current_max,
    m.vehicle_speed_max
  FROM trips t
  JOIN drivetrain_samples_1h m
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
  MAX(inverter_temp_max) AS inverter_temp_max,
  MAX(heatsink_temp_max) AS heatsink_temp_max,
  MAX(stator_temp_max) AS stator_temp_max,
  MIN(peak_regen_torque) AS peak_regen_torque,
  MAX(peak_accel_torque) AS peak_accel_torque,
  MAX(motor_current_max) AS motor_current_max,
  COUNT(*) FILTER (WHERE vehicle_speed_max > 50) AS highway_hours
FROM trip_buckets
GROUP BY vin, trip_id, started, ended, distance_km, max_speed_mph;

-- ------------------------------------------------------------------
-- 5.  drivetrain_diagnostics  — rolling trends & degradation flags
--
-- Computes 7-day / 30-day / 90-day rolling statistics for
-- temperatures and torques.  Uses AVG + 2·STDDEV as a dynamic
-- 95th-percentile proxy for temperature baselines.
--
-- Degradation logic:
--   • INVERTER_OVERHEAT_RISK  — 7d avg temp > 90d avg + 2σ
--     OR absolute threshold exceeded
--   • DRIVE_UNIT_DEGRADATION_LIKELY — peak regen or accel
--     torque magnitude drops > 10 % below 90-day baseline
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW drivetrain_diagnostics AS
WITH daily AS (
  SELECT
    bucket,
    vin,
    highway_hours,
    inverter_temp_max,
    heatsink_temp_max,
    stator_temp_max,
    peak_regen_torque,
    peak_accel_torque,
    motor_current_max
  FROM drivetrain_highway_1d
  WHERE highway_hours >= 1
),
rolling AS (
  SELECT
    *,
    -- Temperature rolling averages
    AVG(inverter_temp_max) OVER w7  AS inv_temp_7d,
    AVG(inverter_temp_max) OVER w30 AS inv_temp_30d,
    AVG(inverter_temp_max) OVER w90 AS inv_temp_90d,
    STDDEV(inverter_temp_max) OVER w90 AS inv_temp_90d_std,
    AVG(heatsink_temp_max) OVER w7  AS hs_temp_7d,
    AVG(heatsink_temp_max) OVER w30 AS hs_temp_30d,
    AVG(heatsink_temp_max) OVER w90 AS hs_temp_90d,
    STDDEV(heatsink_temp_max) OVER w90 AS hs_temp_90d_std,
    AVG(stator_temp_max) OVER w7  AS st_temp_7d,
    AVG(stator_temp_max) OVER w30 AS st_temp_30d,
    AVG(stator_temp_max) OVER w90 AS st_temp_90d,
    STDDEV(stator_temp_max) OVER w90 AS st_temp_90d_std,
    -- Torque rolling averages (magnitude)
    AVG(ABS(peak_regen_torque)) OVER w30 AS regen_mag_30d,
    AVG(ABS(peak_regen_torque)) OVER w90 AS regen_mag_90d,
    AVG(ABS(peak_accel_torque)) OVER w30 AS accel_mag_30d,
    AVG(ABS(peak_accel_torque)) OVER w90 AS accel_mag_90d,
    -- Observation counts
    COUNT(*) OVER w7  AS n_7d,
    COUNT(*) OVER w30 AS n_30d,
    COUNT(*) OVER w90 AS n_90d
  FROM daily
  WINDOW
    w7  AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW),
    w90 AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '90 days' PRECEDING AND CURRENT ROW)
)
SELECT
  bucket AS ts,
  vin,
  highway_hours,
  ROUND(inverter_temp_max::numeric, 1) AS inverter_temp_max,
  ROUND(heatsink_temp_max::numeric, 1) AS heatsink_temp_max,
  ROUND(stator_temp_max::numeric, 1) AS stator_temp_max,
  ROUND(peak_regen_torque::numeric, 1) AS peak_regen_torque,
  ROUND(peak_accel_torque::numeric, 1) AS peak_accel_torque,
  ROUND(motor_current_max::numeric, 1) AS motor_current_max,
  -- Rolling temp stats
  ROUND(inv_temp_7d::numeric, 1)  AS inv_temp_7d_avg,
  ROUND(inv_temp_30d::numeric, 1) AS inv_temp_30d_avg,
  ROUND(inv_temp_90d::numeric, 1) AS inv_temp_90d_avg,
  ROUND(inv_temp_90d_std::numeric, 1) AS inv_temp_90d_stddev,
  ROUND(hs_temp_7d::numeric, 1)  AS hs_temp_7d_avg,
  ROUND(hs_temp_30d::numeric, 1) AS hs_temp_30d_avg,
  ROUND(hs_temp_90d::numeric, 1) AS hs_temp_90d_avg,
  ROUND(hs_temp_90d_std::numeric, 1) AS hs_temp_90d_stddev,
  ROUND(st_temp_7d::numeric, 1)  AS st_temp_7d_avg,
  ROUND(st_temp_30d::numeric, 1) AS st_temp_30d_avg,
  ROUND(st_temp_90d::numeric, 1) AS st_temp_90d_avg,
  ROUND(st_temp_90d_std::numeric, 1) AS st_temp_90d_stddev,
  -- Dynamic 95th-percentile proxy (avg + 2σ)
  ROUND((inv_temp_90d + 2 * NULLIF(inv_temp_90d_std, 0))::numeric, 1)
    AS inv_temp_p95_proxy,
  ROUND((hs_temp_90d + 2 * NULLIF(hs_temp_90d_std, 0))::numeric, 1)
    AS hs_temp_p95_proxy,
  ROUND((st_temp_90d + 2 * NULLIF(st_temp_90d_std, 0))::numeric, 1)
    AS st_temp_p95_proxy,
  -- Torque rolling stats
  ROUND(regen_mag_30d::numeric, 1) AS regen_mag_30d_avg,
  ROUND(regen_mag_90d::numeric, 1) AS regen_mag_90d_avg,
  ROUND(accel_mag_30d::numeric, 1) AS accel_mag_30d_avg,
  ROUND(accel_mag_90d::numeric, 1) AS accel_mag_90d_avg,
  n_7d,
  n_30d,
  n_90d,
  -- Degradation flags
  CASE
    WHEN n_90d >= 20
     AND inv_temp_7d > inv_temp_90d + 2 * NULLIF(inv_temp_90d_std, 0)
    THEN 'INVERTER_OVERHEAT_RISK'
    WHEN n_90d >= 20
     AND hs_temp_7d > hs_temp_90d + 2 * NULLIF(hs_temp_90d_std, 0)
    THEN 'INVERTER_OVERHEAT_RISK'
    WHEN n_90d >= 20
     AND st_temp_7d > st_temp_90d + 2 * NULLIF(st_temp_90d_std, 0)
    THEN 'INVERTER_OVERHEAT_RISK'
    WHEN inverter_temp_max > 85
      OR heatsink_temp_max > 90
      OR stator_temp_max > 120
    THEN 'INVERTER_OVERHEAT_RISK'
    WHEN n_30d >= 10 AND n_90d >= 20
     AND regen_mag_90d > 0
     AND regen_mag_30d < regen_mag_90d * 0.90
    THEN 'DRIVE_UNIT_DEGRADATION_LIKELY'
    WHEN n_30d >= 10 AND n_90d >= 20
     AND accel_mag_90d > 0
     AND accel_mag_30d < accel_mag_90d * 0.90
    THEN 'DRIVE_UNIT_DEGRADATION_LIKELY'
    ELSE 'NORMAL'
  END AS status,
  -- Trend percentages
  CASE WHEN regen_mag_90d > 0
    THEN ROUND(((regen_mag_30d - regen_mag_90d) / regen_mag_90d * 100)::numeric, 1)
    ELSE NULL
  END AS regen_degradation_pct,
  CASE WHEN accel_mag_90d > 0
    THEN ROUND(((accel_mag_30d - accel_mag_90d) / accel_mag_90d * 100)::numeric, 1)
    ELSE NULL
  END AS accel_degradation_pct
FROM rolling;

-- ------------------------------------------------------------------
-- 6.  drivetrain_summary  — Grafana-friendly snapshot
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW drivetrain_summary AS
WITH latest AS (
  SELECT vin, MAX(ts) AS last_ts
  FROM drivetrain_diagnostics
  GROUP BY vin
)
SELECT
  l.vin,
  l.last_ts,
  d.status,
  d.inverter_temp_max,
  d.heatsink_temp_max,
  d.stator_temp_max,
  d.inv_temp_7d_avg,
  d.inv_temp_30d_avg,
  d.inv_temp_90d_avg,
  d.inv_temp_p95_proxy,
  d.peak_regen_torque,
  d.peak_accel_torque,
  d.regen_mag_30d_avg,
  d.regen_mag_90d_avg,
  d.regen_degradation_pct,
  d.accel_degradation_pct,
  d.highway_hours,
  CASE
    WHEN d.status LIKE '%OVERHEAT%' THEN 'INVERTER_OVERHEAT_RISK'
    WHEN d.status LIKE '%DEGRADATION%' THEN 'DRIVE_UNIT_DEGRADATION_LIKELY'
    ELSE 'NORMAL'
  END AS overall_status,
  vm.model,
  d.accel_mag_30d_avg,
  d.accel_mag_90d_avg
FROM latest l
JOIN drivetrain_diagnostics d
  ON d.vin = l.vin AND d.ts = l.last_ts
LEFT JOIN vehicle_metadata vm ON vm.vin = l.vin;

-- ------------------------------------------------------------------
-- 7.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Drivetrain Status"  (Stat + colour threshold)
-- --------------------------------------------------------
-- Red    = INVERTER_OVERHEAT_RISK
-- Orange = DRIVE_UNIT_DEGRADATION_LIKELY
-- Green  = NORMAL
--
-- SELECT overall_status, inverter_temp_max, regen_degradation_pct
-- FROM drivetrain_summary
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Inverter Temperature Trend"  (Time series)
-- --------------------------------------------------------
-- Shows daily max inverter temp with 7-day avg, 30-day avg,
-- and dynamic 95th-percentile band.
--
-- SELECT
--   ts AS time,
--   inverter_temp_max AS "Daily max (°C)",
--   inv_temp_7d_avg AS "7-day avg",
--   inv_temp_30d_avg AS "30-day avg",
--   inv_temp_p95_proxy AS "95th percentile proxy"
-- FROM drivetrain_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Regen Torque Trend"  (Time series)
-- --------------------------------------------------------
-- Peak regen torque with 30-day and 90-day baselines.
-- Add Alert rule when regen_degradation_pct < -10.
--
-- SELECT
--   ts AS time,
--   ABS(peak_regen_torque) AS "Peak regen (Nm)",
--   regen_mag_30d_avg AS "30-day avg",
--   regen_mag_90d_avg AS "90-day avg"
-- FROM drivetrain_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Current Regen % of Baseline"  (Stat)
-- --------------------------------------------------------
-- Big number showing how much regen capacity remains vs
-- the 90-day baseline.
--
-- SELECT
--   CASE WHEN regen_mag_90d_avg > 0
--     THEN ROUND((regen_mag_30d_avg / regen_mag_90d_avg * 100)::numeric, 1)
--     ELSE NULL
--   END AS "Regen % of baseline"
-- FROM drivetrain_summary
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Per-Trip Drivetrain Stats"  (Table)
-- --------------------------------------------------------
-- Lists recent trips with worst-case temps and peak torques.
--
-- SELECT
--   started AS "Trip start",
--   distance_km AS "Distance (km)",
--   max_speed_mph AS "Max speed (mph)",
--   inverter_temp_max AS "Inv temp (°C)",
--   stator_temp_max AS "Stator temp (°C)",
--   ABS(peak_regen_torque) AS "Peak regen (Nm)",
--   peak_accel_torque AS "Peak accel (Nm)"
-- FROM drivetrain_trip_analysis
-- WHERE vin = '$vin'
-- ORDER BY started DESC
-- LIMIT 50;

-- ------------------------------------------------------------------
-- 8.  How to test with the simulator
-- ------------------------------------------------------------------
-- The simulator generates Di* fields with sine-wave defaults:
--   Temps  → base 25 °C, amplitude 8 °C
--   Torque → base 100 Nm, amplitude 80 Nm
--
-- Step 1 — Start the simulator
--   go run ./tools/simulator \
--     -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
--     -vins "SIMULATEDVIN001" \
--     -interval 30
--
--   Let it run until there are several days of highway trips.
--
-- Step 2 — Verify highway data exists
--   SELECT bucket, highway_hours, inverter_temp_max, peak_regen_torque
--   FROM drivetrain_highway_1d
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY bucket DESC LIMIT 5;
--
-- Step 3 — Simulate gradual inverter temp rise (overheating)
--   UPDATE telemetry
--   SET num_value = num_value + 25.0
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field LIKE 'DiInverterT%'
--     AND ts > NOW() - INTERVAL '2 hours';
--
--   CALL refresh_continuous_aggregate('drivetrain_samples_1h',
--     NOW() - INTERVAL '1 day', NOW());
--   CALL refresh_continuous_aggregate('drivetrain_highway_1d',
--     NOW() - INTERVAL '7 days', NOW());
--
--   SELECT ts, inverter_temp_max, inv_temp_7d_avg, status
--   FROM drivetrain_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 4 — Simulate regen torque drop (degradation)
--   -- Reduce torque actual values by 20 %
--   UPDATE telemetry
--   SET num_value = num_value * 0.8
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field LIKE 'DiTorqueActual%'
--     AND ts > NOW() - INTERVAL '7 days';
--
--   CALL refresh_continuous_aggregate('drivetrain_samples_1h',
--     NOW() - INTERVAL '7 days', NOW());
--   CALL refresh_continuous_aggregate('drivetrain_highway_1d',
--     NOW() - INTERVAL '30 days', NOW());
--
--   SELECT ts, regen_mag_30d_avg, regen_mag_90d_avg,
--          regen_degradation_pct, status
--   FROM drivetrain_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 5 — Simulate stator overheat (absolute threshold)
--   UPDATE telemetry
--   SET num_value = 125.0
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field LIKE 'DiStatorTemp%'
--     AND ts > NOW() - INTERVAL '1 hour';
--
--   CALL refresh_continuous_aggregate('drivetrain_samples_1h',
--     NOW() - INTERVAL '1 day', NOW());
--
--   SELECT ts, stator_temp_max, status
--   FROM drivetrain_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 6 — Clean up
--   DELETE FROM telemetry WHERE vin = 'SIMULATEDVIN001';
--   SELECT remove_continuous_aggregate_policy('drivetrain_samples_1h');
--   DROP MATERIALIZED VIEW drivetrain_samples_1h CASCADE;
--   -- then re-create from this file.
-- ------------------------------------------------------------------
