-- ============================================================
-- Dual-Motor Balancing, Regen, and Performance Thermal Diagnostics
--
-- Feature gating per docs/FEATURE_MATRIX.md:
--   motor_config IN ('Dual Motor', 'Performance', 'Tri Motor').
--
-- Context: Dual-motor (LR AWD), Performance, and Tri-Motor vehicles
--   have two independent drive units (front + rear).  Under healthy
--   conditions they share load symmetrically and stay within a few
--   degrees of each other thermally.  When imbalance appears it is
--   usually one of:
--     • Torque-vectoring calibration drift (one axle working harder)
--     • Failing inverter or motor bearing (elevated temp on one side)
--     • Differential or axle-shaft issue (speed mismatch at same torque)
--     • Regen asymmetric limit (one inverter derating earlier than the
--       other — common as power modules age)
--
-- Performance variants run higher sustained power and tighter thermal
--   margins, so thresholds are more aggressive:
--     • Dual Motor (LR AWD) — standard thresholds
--     • Performance / Tri Motor — tighter temp-delta and regen-drop
--       thresholds, plus earlier thermal-throttle detection
--
-- Schema note:
--   Fleet Telemetry exposes per-axle fields (Di*F / Di*R) but does
--   NOT stream explicit "power limit" or "thermal throttle" enums.
--   We therefore infer limits from:
--     • Torque command vs actual   (DiSlaveTorqueCmd vs DiTorqueActual*)
--     • Temperature-driven torque roll-off (rising temps with falling
--       torque at constant command)
--     • Regen torque magnitude trends (ABS of most-negative torque)
--   These proxies are directionally correct and stable for trend
--   detection over 7–30 day windows.
--
-- Model-aware gating:
--   The CAGGs compute for all vehicles (RWD simply has NULL rear-axle
--   columns).  The diagnostic view LEFT JOINs vehicle_metadata and
--   only flags degradation when motor_config IN ('Dual Motor',
--   'Performance', 'Tri Motor').  RWD vehicles return status = 'NORMAL'
--   with NULL metrics.  Zero impact on single-motor deployments.
--
-- Architecture:
--   1. dual_motor_samples_1h   — hourly pivot of per-axle temps,
--      torque, axle speed, motor current, and torque command.
--   2. dual_motor_highway_1d   — daily CAGG filtering to highway
--      hours (> 50 mph) where imbalance is most visible.
--   3. dual_motor_diagnostics  — main view with 7-day / 30-day / 90-day
--      rolling baselines and model-aware degradation flags.
--   4. dual_motor_summary      — Grafana-friendly latest snapshot.
--
-- Requires superuser (postgres) to run — creates CAGGs.
-- Run after 001_schema.sql, 002_views.sql, 005_vehicle_metadata.sql,
-- and 011_drivetrain_diagnostics.sql (shares trip-analysis concepts).
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Hourly pivot CAGG — per-axle temps, torque, speed, current
--
-- We keep front and rear values separate (no GREATEST/LEAST collapse)
-- so we can compute deltas and ratios.  All four inverter positions
-- (F, R, REL, RER) are present in the protobuf but for dual-motor
-- vehicles the meaningful split is front axle (F) vs rear axle (R).
-- The REL/RER fields are included for Tri-Motor completeness.
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS dual_motor_samples_1h CASCADE;

CREATE MATERIALIZED VIEW dual_motor_samples_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin,
  -- Front inverter temps
  MAX(CASE WHEN field = 'DiInverterTF'  THEN num_value END) AS inv_temp_f,
  MAX(CASE WHEN field = 'DiHeatsinkTF'  THEN num_value END) AS hs_temp_f,
  MAX(CASE WHEN field = 'DiStatorTempF' THEN num_value END) AS st_temp_f,
  -- Rear inverter temps
  MAX(CASE WHEN field = 'DiInverterTR'  THEN num_value END) AS inv_temp_r,
  MAX(CASE WHEN field = 'DiHeatsinkTR'  THEN num_value END) AS hs_temp_r,
  MAX(CASE WHEN field = 'DiStatorTempR' THEN num_value END) AS st_temp_r,
  -- Rear-extended (Tri-Motor completeness)
  MAX(CASE WHEN field = 'DiInverterTREL'  THEN num_value END) AS inv_temp_rel,
  MAX(CASE WHEN field = 'DiHeatsinkTREL'  THEN num_value END) AS hs_temp_rel,
  MAX(CASE WHEN field = 'DiStatorTempREL' THEN num_value END) AS st_temp_rel,
  MAX(CASE WHEN field = 'DiInverterTRER'  THEN num_value END) AS inv_temp_rer,
  MAX(CASE WHEN field = 'DiHeatsinkTRER'  THEN num_value END) AS hs_temp_rer,
  MAX(CASE WHEN field = 'DiStatorTempRER' THEN num_value END) AS st_temp_rer,
  -- Axle speeds
  AVG(CASE WHEN field = 'DiAxleSpeedF'  THEN num_value END) AS axle_speed_f,
  AVG(CASE WHEN field = 'DiAxleSpeedR'  THEN num_value END) AS axle_speed_r,
  AVG(CASE WHEN field = 'DiAxleSpeedREL' THEN num_value END) AS axle_speed_rel,
  AVG(CASE WHEN field = 'DiAxleSpeedRER' THEN num_value END) AS axle_speed_rer,
  -- Torque (min = regen, max = accel)
  MIN(CASE WHEN field = 'DiTorqueActualF'  THEN num_value END) AS regen_torque_f,
  MAX(CASE WHEN field = 'DiTorqueActualF'  THEN num_value END) AS accel_torque_f,
  MIN(CASE WHEN field = 'DiTorqueActualR'  THEN num_value END) AS regen_torque_r,
  MAX(CASE WHEN field = 'DiTorqueActualR'  THEN num_value END) AS accel_torque_r,
  MIN(CASE WHEN field = 'DiTorqueActualREL' THEN num_value END) AS regen_torque_rel,
  MAX(CASE WHEN field = 'DiTorqueActualREL' THEN num_value END) AS accel_torque_rel,
  MIN(CASE WHEN field = 'DiTorqueActualRER' THEN num_value END) AS regen_torque_rer,
  MAX(CASE WHEN field = 'DiTorqueActualRER' THEN num_value END) AS accel_torque_rer,
  -- Torque command (shared across all axles)
  MAX(CASE WHEN field = 'DiSlaveTorqueCmd' THEN num_value END) AS torque_cmd_max,
  AVG(CASE WHEN field = 'DiSlaveTorqueCmd' THEN num_value END) AS torque_cmd_avg,
  -- Motor current
  MAX(CASE WHEN field = 'DiMotorCurrentF'  THEN num_value END) AS motor_current_f,
  MAX(CASE WHEN field = 'DiMotorCurrentR'  THEN num_value END) AS motor_current_r,
  MAX(CASE WHEN field = 'DiMotorCurrentREL' THEN num_value END) AS motor_current_rel,
  MAX(CASE WHEN field = 'DiMotorCurrentRER' THEN num_value END) AS motor_current_rer,
  -- Vehicle speed (for highway filtering)
  MAX(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS vehicle_speed_max,
  -- Gear (for straight-line filtering)
  MAX(CASE WHEN field = 'Gear' THEN str_value END) AS gear
FROM telemetry
WHERE field IN (
  'DiInverterTF', 'DiInverterTR', 'DiInverterTREL', 'DiInverterTRER',
  'DiHeatsinkTF', 'DiHeatsinkTR', 'DiHeatsinkTREL', 'DiHeatsinkTRER',
  'DiStatorTempF', 'DiStatorTempR', 'DiStatorTempREL', 'DiStatorTempRER',
  'DiAxleSpeedF', 'DiAxleSpeedR', 'DiAxleSpeedREL', 'DiAxleSpeedRER',
  'DiTorqueActualF', 'DiTorqueActualR', 'DiTorqueActualREL', 'DiTorqueActualRER',
  'DiSlaveTorqueCmd',
  'DiMotorCurrentF', 'DiMotorCurrentR', 'DiMotorCurrentREL', 'DiMotorCurrentRER',
  'VehicleSpeed', 'Gear'
)
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 2.  Daily highway CAGG — filter to demanding driving conditions
--
-- Imbalance is most visible during sustained highway driving where
-- both axles should be sharing load evenly.  We filter to hours with
-- vehicle_speed_max > 50 mph and straight-line gear (D or invalid).
--
-- For each day we capture the worst-case (hottest) temps and the
-- peak regen/accel torque per axle.
-- ------------------------------------------------------------------
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
DROP MATERIALIZED VIEW IF EXISTS dual_motor_highway_1d CASCADE;

CREATE MATERIALIZED VIEW dual_motor_highway_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  -- Highway exposure
  COUNT(*) FILTER (WHERE vehicle_speed_max > 50) AS highway_hours,
  -- Front temps during highway
  MAX(inv_temp_f)  FILTER (WHERE vehicle_speed_max > 50) AS inv_temp_f_max,
  MAX(hs_temp_f)   FILTER (WHERE vehicle_speed_max > 50) AS hs_temp_f_max,
  MAX(st_temp_f)   FILTER (WHERE vehicle_speed_max > 50) AS st_temp_f_max,
  AVG(inv_temp_f)  FILTER (WHERE vehicle_speed_max > 50) AS inv_temp_f_avg,
  AVG(hs_temp_f)   FILTER (WHERE vehicle_speed_max > 50) AS hs_temp_f_avg,
  AVG(st_temp_f)   FILTER (WHERE vehicle_speed_max > 50) AS st_temp_f_avg,
  -- Rear temps during highway
  MAX(inv_temp_r)  FILTER (WHERE vehicle_speed_max > 50) AS inv_temp_r_max,
  MAX(hs_temp_r)   FILTER (WHERE vehicle_speed_max > 50) AS hs_temp_r_max,
  MAX(st_temp_r)   FILTER (WHERE vehicle_speed_max > 50) AS st_temp_r_max,
  AVG(inv_temp_r)  FILTER (WHERE vehicle_speed_max > 50) AS inv_temp_r_avg,
  AVG(hs_temp_r)   FILTER (WHERE vehicle_speed_max > 50) AS hs_temp_r_avg,
  AVG(st_temp_r)   FILTER (WHERE vehicle_speed_max > 50) AS st_temp_r_avg,
  -- Axle speeds during highway straight-line
  AVG(axle_speed_f) FILTER (WHERE vehicle_speed_max > 50
    AND (gear IS NULL OR gear IN ('D','ShiftStateD','invalid',''))) AS axle_speed_f_avg,
  AVG(axle_speed_r) FILTER (WHERE vehicle_speed_max > 50
    AND (gear IS NULL OR gear IN ('D','ShiftStateD','invalid',''))) AS axle_speed_r_avg,
  -- Peak regen torque (most negative) during highway
  MIN(regen_torque_f) FILTER (WHERE vehicle_speed_max > 50) AS regen_torque_f_peak,
  MIN(regen_torque_r) FILTER (WHERE vehicle_speed_max > 50) AS regen_torque_r_peak,
  -- Peak accel torque during highway
  MAX(accel_torque_f) FILTER (WHERE vehicle_speed_max > 50) AS accel_torque_f_peak,
  MAX(accel_torque_r) FILTER (WHERE vehicle_speed_max > 50) AS accel_torque_r_peak,
  -- Torque command during highway
  MAX(torque_cmd_max) FILTER (WHERE vehicle_speed_max > 50) AS torque_cmd_peak,
  AVG(torque_cmd_avg) FILTER (WHERE vehicle_speed_max > 50) AS torque_cmd_avg,
  -- Motor current during highway
  MAX(motor_current_f) FILTER (WHERE vehicle_speed_max > 50) AS motor_current_f_max,
  MAX(motor_current_r) FILTER (WHERE vehicle_speed_max > 50) AS motor_current_r_max
FROM dual_motor_samples_1h
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 3.  Refresh policies
-- ------------------------------------------------------------------
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('dual_motor_samples_1h');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('dual_motor_samples_1h',
  start_offset  => INTERVAL '7 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- dual_motor_highway_1d is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('dual_motor_highway_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ------------------------------------------------------------------
-- 4.  dual_motor_diagnostics  — rolling trends & model-aware flags
--
-- Computes per-axle rolling baselines and derives four metrics:
--   1. front_rear_temp_delta     — avg inverter temp difference (°C)
--   2. axle_speed_imbalance_pct  — relative axle speed mismatch (%)
--   3. regen_limit_pct_of_baseline — 7-day regen vs 30-day baseline (%)
--   4. sustained_power_pct       — 7-day accel vs 30-day baseline (%)
--   5. thermal_throttle_ratio    — actual / commanded torque during
--                                   sustained acceleration
--
-- Thresholds are model-aware via vehicle_metadata.motor_config:
--   • Dual Motor     — standard thresholds
--   • Performance    — tighter temp (8°C warning), regen (95%),
--                      power (95%), throttle (95%)
--   • Tri Motor      — same as Performance (high-stress config)
--   • RWD / other    — all metrics NULL, status = 'NOT_APPLICABLE'
--
-- Degradation flags (applied in priority order):
--   DUAL_MOTOR_IMBALANCE_LIKELY  — temp delta or axle speed mismatch
--   REGEN_DEGRADATION_LIKELY     — regen torque drop > model threshold
--   THERMAL_THROTTLING_RISK      — sustained power drop OR throttle
--                                    ratio below model threshold
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW dual_motor_diagnostics AS
WITH daily AS (
  SELECT
    bucket,
    vin,
    highway_hours,
    inv_temp_f_avg,
    inv_temp_r_avg,
    st_temp_f_avg,
    st_temp_r_avg,
    hs_temp_f_avg,
    hs_temp_r_avg,
    axle_speed_f_avg,
    axle_speed_r_avg,
    regen_torque_f_peak,
    regen_torque_r_peak,
    accel_torque_f_peak,
    accel_torque_r_peak,
    torque_cmd_peak,
    torque_cmd_avg,
    motor_current_f_max,
    motor_current_r_max,
    -- Front-rear inverter temp delta (absolute)
    ABS(COALESCE(inv_temp_f_avg, 0) - COALESCE(inv_temp_r_avg, 0)) AS inv_temp_delta,
    -- Front-rear stator temp delta
    ABS(COALESCE(st_temp_f_avg, 0) - COALESCE(st_temp_r_avg, 0)) AS st_temp_delta,
    -- Axle speed imbalance (% of average)
    CASE
      WHEN axle_speed_f_avg IS NOT NULL AND axle_speed_r_avg IS NOT NULL
       AND (axle_speed_f_avg + axle_speed_r_avg) > 0
      THEN ABS(axle_speed_f_avg - axle_speed_r_avg)
           / ((axle_speed_f_avg + axle_speed_r_avg) / 2.0) * 100
      ELSE NULL
    END AS axle_speed_imbalance_pct,
    -- Thermal throttle proxy: avg actual torque / commanded torque
    -- during highway accel (when torque_cmd > 50 Nm)
    CASE
      WHEN torque_cmd_avg > 50
       AND accel_torque_f_peak IS NOT NULL
       AND accel_torque_r_peak IS NOT NULL
      THEN (accel_torque_f_peak + accel_torque_r_peak) / (2.0 * torque_cmd_avg) * 100
      ELSE NULL
    END AS throttle_ratio_pct,
    -- Composite regen torque (magnitude, most negative)
    LEAST(COALESCE(regen_torque_f_peak, 0), COALESCE(regen_torque_r_peak, 0)) AS regen_torque_peak,
    -- Composite accel torque
    GREATEST(COALESCE(accel_torque_f_peak, 0), COALESCE(accel_torque_r_peak, 0)) AS accel_torque_peak
  FROM dual_motor_highway_1d
  WHERE highway_hours >= 1
),
-- Pull motor_config once per vin so we don't repeat the JOIN
vin_config AS (
  SELECT vin, motor_config FROM vehicle_metadata
  WHERE motor_config IN ('Dual Motor', 'Performance', 'Tri Motor')
),
rolling AS (
  SELECT
    d.*,
    c.motor_config,
    -- 7-day rolling averages
    AVG(inv_temp_delta) OVER w7 AS inv_delta_7d,
    AVG(st_temp_delta) OVER w7 AS st_delta_7d,
    AVG(axle_speed_imbalance_pct) OVER w7 AS speed_imbalance_7d,
    AVG(throttle_ratio_pct) OVER w7 AS throttle_ratio_7d,
    AVG(ABS(regen_torque_peak)) OVER w7 AS regen_mag_7d,
    AVG(ABS(accel_torque_peak)) OVER w7 AS accel_mag_7d,
    -- 30-day rolling averages
    AVG(inv_temp_delta) OVER w30 AS inv_delta_30d,
    AVG(st_temp_delta) OVER w30 AS st_delta_30d,
    AVG(axle_speed_imbalance_pct) OVER w30 AS speed_imbalance_30d,
    AVG(throttle_ratio_pct) OVER w30 AS throttle_ratio_30d,
    AVG(ABS(regen_torque_peak)) OVER w30 AS regen_mag_30d,
    AVG(ABS(accel_torque_peak)) OVER w30 AS accel_mag_30d,
    -- 90-day rolling averages (longer baseline for Performance)
    AVG(inv_temp_delta) OVER w90 AS inv_delta_90d,
    AVG(ABS(regen_torque_peak)) OVER w90 AS regen_mag_90d,
    AVG(ABS(accel_torque_peak)) OVER w90 AS accel_mag_90d,
    -- Dynamic 95th-percentile temp-delta proxy (90d avg + 2σ)
    AVG(inv_temp_delta) OVER w90 + 2 * STDDEV(inv_temp_delta) OVER w90 AS inv_delta_p95,
    -- Observation counts
    COUNT(*) OVER w7  AS n_7d,
    COUNT(*) OVER w30 AS n_30d,
    COUNT(*) OVER w90 AS n_90d
  FROM daily d
  LEFT JOIN vin_config c ON c.vin = d.vin
  WINDOW
    w7  AS (PARTITION BY d.vin ORDER BY d.bucket
            RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY d.vin ORDER BY d.bucket
            RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW),
    w90 AS (PARTITION BY d.vin ORDER BY d.bucket
            RANGE BETWEEN INTERVAL '90 days' PRECEDING AND CURRENT ROW)
), with_thresholds AS (
  SELECT
    *,
    CASE motor_config
      WHEN 'Performance' THEN 8.0
      WHEN 'Tri Motor'   THEN 8.0
      ELSE 10.0
    END AS temp_delta_warn_threshold,
    CASE motor_config
      WHEN 'Performance' THEN 12.0
      WHEN 'Tri Motor'   THEN 12.0
      ELSE 15.0
    END AS temp_delta_crit_threshold,
    CASE motor_config
      WHEN 'Performance' THEN 2.0
      WHEN 'Tri Motor'   THEN 2.0
      ELSE 3.0
    END AS axle_imbalance_warn_threshold,
    CASE motor_config
      WHEN 'Performance' THEN 4.0
      WHEN 'Tri Motor'   THEN 4.0
      ELSE 5.0
    END AS axle_imbalance_crit_threshold,
    CASE motor_config
      WHEN 'Performance' THEN 95.0
      WHEN 'Tri Motor'   THEN 95.0
      ELSE 92.0
    END AS regen_threshold_pct,
    CASE motor_config
      WHEN 'Performance' THEN 95.0
      WHEN 'Tri Motor'   THEN 95.0
      ELSE 92.0
    END AS power_threshold_pct,
    CASE motor_config
      WHEN 'Performance' THEN 95.0
      WHEN 'Tri Motor'   THEN 95.0
      ELSE 93.0
    END AS throttle_threshold_pct
  FROM rolling
), with_status AS (
  SELECT
    *,
    -- Status flag (priority order)
    CASE
      -- Not applicable (RWD or missing motor_config)
      WHEN motor_config IS NULL THEN 'NOT_APPLICABLE'
      -- Imbalance: temp delta exceeds dynamic threshold
      WHEN n_7d >= 3 AND n_30d >= 10
       AND inv_delta_p95 > 0
       AND inv_delta_7d > inv_delta_p95
      THEN 'DUAL_MOTOR_IMBALANCE_LIKELY'
      WHEN n_7d >= 3 AND n_30d >= 10
       AND inv_delta_7d > temp_delta_crit_threshold
      THEN 'DUAL_MOTOR_IMBALANCE_LIKELY'
      WHEN n_7d >= 3 AND n_30d >= 10
       AND axle_speed_imbalance_pct > axle_imbalance_crit_threshold
      THEN 'DUAL_MOTOR_IMBALANCE_LIKELY'
      WHEN n_7d >= 3 AND n_30d >= 10
       AND inv_delta_7d > temp_delta_warn_threshold
      THEN 'DUAL_MOTOR_IMBALANCE_LIKELY'
      WHEN n_7d >= 3 AND n_30d >= 10
       AND axle_speed_imbalance_pct > axle_imbalance_warn_threshold
      THEN 'DUAL_MOTOR_IMBALANCE_LIKELY'
      -- Regen degradation: 7d regen magnitude below model-specific threshold
      WHEN n_7d >= 3 AND n_30d >= 10
       AND regen_mag_30d > 0
       AND ABS(regen_torque_peak) < regen_mag_30d * (regen_threshold_pct / 100.0)
      THEN 'REGEN_DEGRADATION_LIKELY'
      -- Thermal throttling: sustained power below threshold OR throttle ratio low
      -- Gated to Performance and Tri Motor only per FEATURE_MATRIX.md
      WHEN motor_config IN ('Performance', 'Tri Motor')
       AND n_7d >= 3 AND n_30d >= 10
       AND accel_mag_30d > 0
       AND ABS(accel_torque_peak) < accel_mag_30d * (power_threshold_pct / 100.0)
      THEN 'THERMAL_THROTTLING_RISK'
      WHEN motor_config IN ('Performance', 'Tri Motor')
       AND n_7d >= 3 AND n_30d >= 10
       AND throttle_ratio_7d IS NOT NULL
       AND throttle_ratio_7d < throttle_threshold_pct
      THEN 'THERMAL_THROTTLING_RISK'
      ELSE 'NORMAL'
    END AS status
  FROM with_thresholds
)
SELECT
  bucket AS ts,
  vin,
  motor_config,
  highway_hours,
  ROUND(inv_temp_delta::numeric, 2) AS front_rear_temp_delta,
  ROUND(st_temp_delta::numeric, 2) AS front_rear_stator_delta,
  ROUND(axle_speed_imbalance_pct::numeric, 2) AS axle_speed_imbalance_pct,
  ROUND(throttle_ratio_pct::numeric, 2) AS thermal_throttle_ratio,
  -- Regen limit % of baseline (7d vs 30d)
  CASE WHEN regen_mag_30d > 0
    THEN ROUND((ABS(regen_torque_peak) / regen_mag_30d * 100)::numeric, 1)
    ELSE NULL
  END AS regen_limit_pct_of_baseline,
  -- Sustained power % of baseline (7d vs 30d)
  CASE WHEN accel_mag_30d > 0
    THEN ROUND((ABS(accel_torque_peak) / accel_mag_30d * 100)::numeric, 1)
    ELSE NULL
  END AS sustained_power_pct,
  n_7d,
  n_30d,
  n_90d,
  -- Model-aware threshold parameters (computed in with_thresholds CTE)
  temp_delta_warn_threshold,
  temp_delta_crit_threshold,
  axle_imbalance_warn_threshold,
  axle_imbalance_crit_threshold,
  regen_threshold_pct,
  power_threshold_pct,
  throttle_threshold_pct,
  -- Status (computed in with_status CTE)
  status,
  -- Severity
  CASE
    WHEN motor_config IS NULL THEN 'NORMAL'
    WHEN n_7d >= 3 AND n_30d >= 10
     AND (inv_delta_7d > temp_delta_crit_threshold
          OR axle_speed_imbalance_pct > axle_imbalance_crit_threshold)
    THEN 'CRITICAL'
    WHEN status IN ('DUAL_MOTOR_IMBALANCE_LIKELY', 'REGEN_DEGRADATION_LIKELY', 'THERMAL_THROTTLING_RISK')
    THEN 'WARNING'
    ELSE 'NORMAL'
  END AS severity,
  -- Human-readable reason
  CASE
    WHEN motor_config IS NULL THEN 'Single-motor vehicle — dual-motor diagnostics not applicable'
    WHEN inv_delta_7d > temp_delta_crit_threshold
      THEN 'Front-rear inverter temp delta ' || ROUND(inv_delta_7d::numeric, 1) || '°C exceeds critical threshold (' || temp_delta_crit_threshold || '°C)'
    WHEN inv_delta_7d > temp_delta_warn_threshold
      THEN 'Front-rear inverter temp delta ' || ROUND(inv_delta_7d::numeric, 1) || '°C exceeds warning threshold (' || temp_delta_warn_threshold || '°C)'
    WHEN axle_speed_imbalance_pct > axle_imbalance_crit_threshold
      THEN 'Axle speed imbalance ' || ROUND(axle_speed_imbalance_pct::numeric, 1) || '% exceeds critical threshold (' || axle_imbalance_crit_threshold || '%)'
    WHEN axle_speed_imbalance_pct > axle_imbalance_warn_threshold
      THEN 'Axle speed imbalance ' || ROUND(axle_speed_imbalance_pct::numeric, 1) || '% exceeds warning threshold (' || axle_imbalance_warn_threshold || '%)'
    WHEN ABS(regen_torque_peak) < regen_mag_30d * (regen_threshold_pct / 100.0)
      THEN 'Regen torque ' || ROUND(ABS(regen_torque_peak)::numeric, 1) || ' Nm below ' || regen_threshold_pct || '% of 30-day baseline'
    WHEN ABS(accel_torque_peak) < accel_mag_30d * (power_threshold_pct / 100.0)
      THEN 'Sustained power ' || ROUND(ABS(accel_torque_peak)::numeric, 1) || ' Nm below ' || power_threshold_pct || '% of 30-day baseline'
    WHEN throttle_ratio_7d < throttle_threshold_pct
      THEN 'Thermal throttle ratio ' || ROUND(throttle_ratio_7d::numeric, 1) || '% below threshold (' || throttle_threshold_pct || '%)'
    ELSE 'All dual-motor metrics within model-specific thresholds'
  END AS anomaly_reason,
  -- Trend magnitudes
  CASE WHEN inv_delta_30d > 0
    THEN ROUND(((inv_delta_7d - inv_delta_30d) / inv_delta_30d * 100)::numeric, 1)
    ELSE NULL
  END AS temp_delta_trend_pct,
  CASE WHEN regen_mag_30d > 0
    THEN ROUND(((ABS(regen_torque_peak) - regen_mag_30d) / regen_mag_30d * 100)::numeric, 1)
    ELSE NULL
  END AS regen_trend_pct,
  -- Raw values for Grafana time-series panels
  inv_temp_f_avg,
  inv_temp_r_avg,
  regen_torque_peak,
  regen_mag_7d,
  regen_mag_30d,
  throttle_ratio_7d,
  throttle_ratio_30d
FROM with_status;

-- ------------------------------------------------------------------
-- 5.  dual_motor_summary  — Grafana-friendly latest snapshot
--
-- Only returns rows for dual-motor configs (Dual Motor, Performance,
-- Tri Motor).  RWD vehicles are filtered out at the view level.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW dual_motor_summary AS
WITH latest AS (
  SELECT vin, MAX(ts) AS last_ts
  FROM dual_motor_diagnostics
  WHERE motor_config IN ('Dual Motor', 'Performance', 'Tri Motor')
  GROUP BY vin
)
SELECT
  l.vin,
  l.last_ts,
  d.motor_config,
  d.status,
  d.severity,
  d.anomaly_reason,
  d.front_rear_temp_delta,
  d.front_rear_stator_delta,
  d.axle_speed_imbalance_pct,
  d.thermal_throttle_ratio,
  d.regen_limit_pct_of_baseline,
  d.sustained_power_pct,
  d.temp_delta_trend_pct,
  d.regen_trend_pct,
  vm.model,
  vm.battery_type
FROM latest l
JOIN dual_motor_diagnostics d
  ON d.vin = l.vin AND d.ts = l.last_ts
LEFT JOIN vehicle_metadata vm ON vm.vin = l.vin;

-- ------------------------------------------------------------------
-- 6.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Dual Motor Health"  (Stat + colour threshold)
-- --------------------------------------------------------
-- Green  = NORMAL
-- Yellow = WARNING (DUAL_MOTOR_IMBALANCE_LIKELY / REGEN_DEGRADATION_LIKELY / THERMAL_THROTTLING_RISK)
-- Red    = CRITICAL (severity = 'CRITICAL')
--
-- SELECT
--   status,
--   severity,
--   motor_config,
--   front_rear_temp_delta,
--   axle_speed_imbalance_pct,
--   regen_limit_pct_of_baseline,
--   sustained_power_pct,
--   anomaly_reason
-- FROM dual_motor_summary
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Front vs Rear Inverter Temp"  (Time series)
-- --------------------------------------------------------
-- Overlay front and rear temps with delta band.
--
-- SELECT
--   ts AS time,
--   inv_temp_f_avg AS "Front inverter (°C)",
--   inv_temp_r_avg AS "Rear inverter (°C)",
--   front_rear_temp_delta AS "Delta (°C)"
-- FROM dual_motor_diagnostics
-- WHERE vin = '$vin'
--   AND motor_config IS NOT NULL
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Axle Speed Correlation"  (Scatter)
-- --------------------------------------------------------
-- Each point = one daily highway observation.  Healthy points
-- cluster along the diagonal.  Off-diagonal points indicate
-- speed mismatch (differential, tire circumference, or sensor
-- drift issues).
--
-- SELECT
--   axle_speed_f_avg AS "Front axle speed (RPM)",
--   axle_speed_r_avg AS "Rear axle speed (RPM)"
-- FROM dual_motor_diagnostics
-- WHERE vin = '$vin'
--   AND motor_config IS NOT NULL
--   AND $__timeFilter(ts);

-- --------------------------------------------------------
-- Panel: "Regen & Power Trend"  (Time series)
-- --------------------------------------------------------
-- Shows composite regen and accel torque magnitudes with
-- 30-day and 90-day baselines.  Alert on regen_trend_pct.
--
-- SELECT
--   ts AS time,
--   ABS(regen_torque_peak) AS "Regen torque (Nm)",
--   regen_mag_7d AS "7-day avg",
--   regen_mag_30d AS "30-day avg",
--   regen_mag_90d AS "90-day avg"
-- FROM dual_motor_diagnostics
-- WHERE vin = '$vin'
--   AND motor_config IS NOT NULL
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Thermal Throttle Ratio"  (Time series)
-- --------------------------------------------------------
-- Actual torque as % of commanded torque during highway accel.
-- Below 95 % for Performance = thermal throttling.
--
-- SELECT
--   ts AS time,
--   thermal_throttle_ratio AS "Throttle ratio (%)",
--   throttle_ratio_7d AS "7-day avg",
--   throttle_ratio_30d AS "30-day avg"
-- FROM dual_motor_diagnostics
-- WHERE vin = '$vin'
--   AND motor_config IS NOT NULL
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Dual Motor Fleet Overview"  (Table)
-- --------------------------------------------------------
-- Fleet-wide snapshot with model and motor_config filters.
--
-- SELECT
--   vin,
--   model,
--   motor_config,
--   status,
--   severity,
--   front_rear_temp_delta,
--   axle_speed_imbalance_pct,
--   anomaly_reason
-- FROM dual_motor_summary
-- WHERE model = '$model'
-- ORDER BY
--   CASE severity
--     WHEN 'CRITICAL' THEN 1
--     WHEN 'WARNING'  THEN 2
--     ELSE 3
--   END;

-- ------------------------------------------------------------------
-- 7.  How to test with the simulator
-- ------------------------------------------------------------------
-- The simulator generates Di* fields for all vehicles.  For dual-motor
-- configs (C, D, E, F, G, H, J in VIN position 8) the simulator
-- produces correlated front/rear values with realistic differences.
--
-- Step 1 — Start the simulator with a Performance VIN
--   go run ./tools/simulator \
--     -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
--     -vins "5YJ3E1EF8PF000001" \
--     -interval 30
--
--   Position 8 = 'F' → Performance motor config.
--
-- Step 2 — Verify motor_config in vehicle_metadata
--   SELECT vin, model, motor_config FROM vehicle_metadata
--   WHERE vin = '5YJ3E1EF8PF000001';
--
-- Step 3 — Wait for CAGGs (≤ 1 hour), then verify diagnostics
--   SELECT ts, motor_config, status, severity, front_rear_temp_delta,
--          axle_speed_imbalance_pct, anomaly_reason
--   FROM dual_motor_diagnostics
--   WHERE vin = '5YJ3E1EF8PF000001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 4 — Simulate front-rear temp imbalance
--   Raise front inverter temp by 15 °C for 3 hours:
--
--   INSERT INTO telemetry (ts, vin, field, num_value)
--   SELECT generate_series(
--     NOW(),
--     NOW() + INTERVAL '3 hours',
--     INTERVAL '30 seconds'
--   ), '5YJ3E1EF8PF000001', 'DiInverterTF', 95.0;
--
--   CALL refresh_continuous_aggregate('dual_motor_samples_1h',
--     NOW() - INTERVAL '1 day', NOW());
--   CALL refresh_continuous_aggregate('dual_motor_highway_1d',
--     NOW() - INTERVAL '7 days', NOW());
--
--   SELECT ts, status, severity, front_rear_temp_delta, anomaly_reason
--   FROM dual_motor_diagnostics
--   WHERE vin = '5YJ3E1EF8PF000001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 5 — Simulate regen degradation
--   Reduce rear regen torque magnitude by 20 %:
--
--   INSERT INTO telemetry (ts, vin, field, num_value)
--   SELECT generate_series(
--     NOW(),
--     NOW() + INTERVAL '2 hours',
--     INTERVAL '30 seconds'
--   ), '5YJ3E1EF8PF000001', 'DiTorqueActualR', -80.0;
--
--   CALL refresh_continuous_aggregate('dual_motor_samples_1h',
--     NOW() - INTERVAL '1 day', NOW());
--   CALL refresh_continuous_aggregate('dual_motor_highway_1d',
--     NOW() - INTERVAL '7 days', NOW());
--
--   SELECT ts, status, severity, regen_limit_pct_of_baseline, anomaly_reason
--   FROM dual_motor_diagnostics
--   WHERE vin = '5YJ3E1EF8PF000001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 6 — Simulate thermal throttling
--   Reduce actual torque to 85 % of commanded:
--
--   INSERT INTO telemetry (ts, vin, field, num_value)
--   SELECT generate_series(
--     NOW(),
--     NOW() + INTERVAL '2 hours',
--     INTERVAL '30 seconds'
--   ), '5YJ3E1EF8PF000001', 'DiTorqueActualF', 170.0;
--
--   INSERT INTO telemetry (ts, vin, field, num_value)
--   SELECT generate_series(
--     NOW(),
--     NOW() + INTERVAL '2 hours',
--     INTERVAL '30 seconds'
--   ), '5YJ3E1EF8PF000001', 'DiTorqueActualR', 170.0;
--
--   -- Commanded torque stays at 200 Nm (existing baseline)
--   CALL refresh_continuous_aggregate('dual_motor_samples_1h',
--     NOW() - INTERVAL '1 day', NOW());
--   CALL refresh_continuous_aggregate('dual_motor_highway_1d',
--     NOW() - INTERVAL '7 days', NOW());
--
--   SELECT ts, status, severity, sustained_power_pct, thermal_throttle_ratio, anomaly_reason
--   FROM dual_motor_diagnostics
--   WHERE vin = '5YJ3E1EF8PF000001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 7 — Confirm RWD vehicle shows NOT_APPLICABLE
--   SELECT * FROM dual_motor_summary
--   WHERE vin = '5YJ3E1EA8PF000001';  -- RWD Model 3
--   -- Expected: status = 'NOT_APPLICABLE', severity = 'NORMAL'
--
-- Step 8 — Clean up
--   DELETE FROM telemetry
--   WHERE vin = '5YJ3E1EF8PF000001'
--     AND field LIKE 'Di%'
--     AND ts > NOW() - INTERVAL '4 hours';
--
--   Or remove the whole test VIN and rebuild:
--   DELETE FROM telemetry WHERE vin = '5YJ3E1EF8PF000001';
--   SELECT remove_continuous_aggregate_policy('dual_motor_samples_1h');
--   DROP MATERIALIZED VIEW dual_motor_samples_1h CASCADE;
--   -- then re-create from this file.
-- ------------------------------------------------------------------
