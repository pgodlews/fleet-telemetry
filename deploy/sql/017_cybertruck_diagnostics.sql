-- ============================================================
-- Cybertruck-Specific Predictive Diagnostics Layer
--
-- Feature gating per docs/FEATURE_MATRIX.md: model = 'CT'.
--
-- Context: The Tesla Cybertruck (2024+) is a fundamentally different
--   vehicle architecture from the S3XY lineup:
--     • 48-volt low-voltage architecture (vs 12V)
--     • 800-volt high-voltage architecture (vs 400V)
--     • 4680 structural battery pack (vs 2170/LFP pouch)
--     • Adaptive air suspension with unique modes
--       (Entry / Standard / High / VeryHigh / Extract)
--     • Retractable tonneau cover with dedicated motor & sensors
--     • V2L (Powershare) bidirectional export capability
--     • Tri-motor Cyberbeast variant (front + rear-left + rear-right)
--
-- Why a dedicated layer:
--   While generic battery, drivetrain, and suspension diagnostics
--   already cover the Cybertruck, they miss CT-unique failure modes:
--     • Tonneau motor burnout from debris in tracks
--     • Tonneau position sensor drift causing false "stuck" alerts
--     • 4680 cell-specific degradation curves (different from 2170)
--     • Powershare sustained-load inverter stress
--     • Tri-motor torque-vectoring imbalance (3-way instead of 2-way)
--     • Extract-mode speed-enforced height violations
--
-- Architecture:
--   1. ct_tonneau_samples_1h  → ct_tonneau_daily_1d
--      ct_tonneau_diagnostics     — position consistency, motor runtime
--   2. ct_v2l_samples_1h      → ct_v2l_daily_1d
--      ct_v2l_diagnostics         — sustained export power & duration
--   3. tri_motor_highway_1d   (hierarchical CAGG on dual_motor_samples_1h)
--      tri_motor_diagnostics      — front vs rear-left vs rear-right
--   4. ct_air_suspension_diagnostics
--      — CT-specific extension of 015 (mode checks, speed limits)
--   5. ct_battery_4680_diagnostics
--      — CT-specific extension of 009 (4680 baseline, fade rate)
--   6. cybertruck_diagnostics  — unified UNION ALL view
--   7. cybertruck_summary      — Grafana-friendly snapshot
--
-- Model-aware gating:
--   All views LEFT JOIN vehicle_metadata and gate on model = 'CT'.
--   Non-Cybertruck vehicles return status = 'NOT_APPLICABLE'
--   with NULL metrics.  Zero impact on S3XY deployments.
--
-- Requires superuser (postgres) to run — creates CAGGs.
-- Run after 001_schema.sql, 002_views.sql, 005_vehicle_metadata.sql,
-- 009_battery_health.sql, 015_air_suspension_diagnostics.sql, and
-- 016_dual_motor_diagnostics.sql.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Tonneau Cover — hourly pivot CAGG
--
-- Fields:
--   TonneauOpenPercent  — 0-100 % open
--   TonneauPosition     — enum (Closed, Open, Moving, Stuck, etc.)
--   TonneauTentMode     — enum (Off, TentMode, etc.)
--
-- Failure modes:
--   • Position stuck (position doesn't change for hours while
--     commanded to move)
--   • Motor overwork (high open-percent jitter = motor struggling)
--   • Tent-mode inconsistency (TentMode active but position closed)
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS ct_tonneau_samples_1h CASCADE;

CREATE MATERIALIZED VIEW ct_tonneau_samples_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin,
  -- Position
  LAST(num_value, ts) FILTER (WHERE field = 'TonneauOpenPercent') AS open_pct_last,
  AVG(CASE WHEN field = 'TonneauOpenPercent' THEN num_value END) AS open_pct_avg,
  MAX(CASE WHEN field = 'TonneauOpenPercent' THEN num_value END) AS open_pct_max,
  MIN(CASE WHEN field = 'TonneauOpenPercent' THEN num_value END) AS open_pct_min,
  -- State enums (last value wins)
  LAST(str_value, ts) FILTER (WHERE field = 'TonneauPosition') AS position_last,
  LAST(str_value, ts) FILTER (WHERE field = 'TonneauTentMode') AS tent_mode_last,
  -- Vehicle state for context
  MAX(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS vehicle_speed_max,
  MAX(CASE WHEN field = 'Gear' THEN str_value END) AS gear
FROM telemetry
WHERE field IN (
  'TonneauOpenPercent', 'TonneauPosition', 'TonneauTentMode',
  'VehicleSpeed', 'Gear'
)
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 2.  Tonneau Cover — daily CAGG
-- ------------------------------------------------------------------
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
DROP MATERIALIZED VIEW IF EXISTS ct_tonneau_daily_1d CASCADE;

CREATE MATERIALIZED VIEW ct_tonneau_daily_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  -- Observation hours
  COUNT(*) FILTER (WHERE open_pct_last IS NOT NULL) AS observed_hours,
  -- Position stability (hours with < 1 % change)
  COUNT(*) FILTER (WHERE open_pct_last IS NOT NULL
    AND ABS(COALESCE(open_pct_last, 0) - COALESCE(open_pct_avg, 0)) < 1.0)
    AS stable_hours,
  -- Hours position is stuck at same value
  COUNT(*) FILTER (WHERE open_pct_last IS NOT NULL
    AND open_pct_min = open_pct_max)
    AS stuck_hours,
  -- Hours with "Stuck" enum
  COUNT(*) FILTER (WHERE position_last ILIKE '%stuck%')
    AS stuck_alert_hours,
  -- Hours in TentMode while closed
  COUNT(*) FILTER (WHERE tent_mode_last ILIKE '%tent%'
    AND COALESCE(open_pct_last, 0) < 10)
    AS tent_mode_closed_hours,
  -- Average open percent
  AVG(open_pct_last) FILTER (WHERE open_pct_last IS NOT NULL) AS open_pct_avg,
  -- Movement range
  MAX(open_pct_max) FILTER (WHERE open_pct_last IS NOT NULL) AS open_pct_max,
  MIN(open_pct_min) FILTER (WHERE open_pct_last IS NOT NULL) AS open_pct_min,
  -- Vehicle in motion (tonneau should be closed)
  COUNT(*) FILTER (WHERE vehicle_speed_max > 5
    AND COALESCE(open_pct_last, 0) > 5)
    AS moving_open_hours
FROM ct_tonneau_samples_1h
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 3.  Tonneau Cover — diagnostics view
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW ct_tonneau_diagnostics AS
WITH daily AS (
  SELECT * FROM ct_tonneau_daily_1d WHERE observed_hours >= 4
),
rolling AS (
  SELECT
    d.*,
    -- 7-day / 30-day rolling baselines
    AVG(stuck_hours::numeric) OVER w7 AS stuck_7d,
    AVG(stuck_hours::numeric) OVER w30 AS stuck_30d,
    AVG(moving_open_hours::numeric) OVER w7 AS moving_open_7d,
    AVG(moving_open_hours::numeric) OVER w30 AS moving_open_30d,
    AVG(tent_mode_closed_hours::numeric) OVER w7 AS tent_closed_7d,
    COUNT(*) OVER w7 AS n_7d,
    COUNT(*) OVER w30 AS n_30d
  FROM daily d
  WINDOW
    w7  AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW)
)
SELECT
  bucket AS ts,
  vin,
  observed_hours,
  stuck_hours,
  stuck_alert_hours,
  moving_open_hours,
  tent_mode_closed_hours,
  open_pct_avg,
  open_pct_max,
  open_pct_min,
  -- Baselines
  ROUND(stuck_7d::numeric, 2) AS stuck_7d_avg,
  ROUND(stuck_30d::numeric, 2) AS stuck_30d_avg,
  -- Status
  CASE
    WHEN n_7d < 3 OR n_30d < 10 THEN 'NORMAL'
    WHEN stuck_alert_hours > 0 THEN 'TONNEAU_STUCK_OR_MOTOR_FAILURE'
    WHEN stuck_7d > 2 AND stuck_7d > stuck_30d * 2.0 THEN 'TONNEAU_STUCK_OR_MOTOR_FAILURE'
    WHEN moving_open_hours > 0 THEN 'TONNEAU_OPEN_WHILE_MOVING'
    WHEN tent_mode_closed_hours > 0 THEN 'TONNEAU_TENT_MODE_INCONSISTENCY'
    ELSE 'NORMAL'
  END AS status,
  CASE
    WHEN stuck_alert_hours > 0 THEN 'CRITICAL'
    WHEN (CASE
            WHEN n_7d < 3 OR n_30d < 10 THEN 'NORMAL'
            WHEN stuck_alert_hours > 0 THEN 'TONNEAU_STUCK_OR_MOTOR_FAILURE'
            WHEN stuck_7d > 2 AND stuck_7d > stuck_30d * 2.0 THEN 'TONNEAU_STUCK_OR_MOTOR_FAILURE'
            WHEN moving_open_hours > 0 THEN 'TONNEAU_OPEN_WHILE_MOVING'
            WHEN tent_mode_closed_hours > 0 THEN 'TONNEAU_TENT_MODE_INCONSISTENCY'
            ELSE 'NORMAL'
          END) IN ('TONNEAU_STUCK_OR_MOTOR_FAILURE',
                   'TONNEAU_OPEN_WHILE_MOVING',
                   'TONNEAU_TENT_MODE_INCONSISTENCY')
    THEN 'WARNING'
    ELSE 'NORMAL'
  END AS severity,
  CASE
    WHEN stuck_alert_hours > 0
      THEN 'Tonneau position sensor reports Stuck for ' || stuck_alert_hours || ' hours'
    WHEN stuck_7d > 2 AND stuck_7d > stuck_30d * 2.0
      THEN 'Tonneau stuck-hours trend ' || ROUND(stuck_7d::numeric, 1) || ' vs baseline ' || ROUND(stuck_30d::numeric, 1)
    WHEN moving_open_hours > 0
      THEN 'Tonneau open while vehicle in motion — ' || moving_open_hours || ' hour(s)'
    WHEN tent_mode_closed_hours > 0
      THEN 'Tent mode active but tonneau closed — ' || tent_mode_closed_hours || ' hour(s)'
    ELSE 'Tonneau operating normally'
  END AS anomaly_reason,
  stuck_hours AS value,
  ROUND(stuck_30d::numeric, 2) AS baseline
FROM rolling;

-- ------------------------------------------------------------------
-- 4.  V2L / Powershare — hourly pivot CAGG
--
-- Fields:
--   PowershareInstantaneousPowerKW — real-time export power
--   PowershareStatus               — enum (Active, Standby, Fault, etc.)
--   PowershareHoursLeft            — estimated remaining hours
--   PowershareType                 — HomeBackup, Camp, etc.
--
-- Failure modes:
--   • Sustained high-load export (> 10 kW for > 4 hours)
--   • Frequent fault/restart cycles
--   • Inverter thermal stress from prolonged export
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS ct_v2l_samples_1h CASCADE;

CREATE MATERIALIZED VIEW ct_v2l_samples_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin,
  -- Power export
  MAX(CASE WHEN field = 'PowershareInstantaneousPowerKW' THEN num_value END) AS power_kw_max,
  AVG(CASE WHEN field = 'PowershareInstantaneousPowerKW' THEN num_value END) AS power_kw_avg,
  -- Status
  LAST(str_value, ts) FILTER (WHERE field = 'PowershareStatus') AS status_last,
  LAST(str_value, ts) FILTER (WHERE field = 'PowershareType') AS type_last,
  LAST(num_value, ts) FILTER (WHERE field = 'PowershareHoursLeft') AS hours_left_last,
  -- Inverter temps for thermal correlation
  MAX(CASE WHEN field = 'DiInverterTF' THEN num_value END) AS inv_temp_f_max,
  MAX(CASE WHEN field = 'DiInverterTR' THEN num_value END) AS inv_temp_r_max
FROM telemetry
WHERE field IN (
  'PowershareInstantaneousPowerKW', 'PowershareStatus',
  'PowershareType', 'PowershareHoursLeft',
  'DiInverterTF', 'DiInverterTR'
)
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 5.  V2L / Powershare — daily CAGG
-- ------------------------------------------------------------------
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
DROP MATERIALIZED VIEW IF EXISTS ct_v2l_daily_1d CASCADE;

CREATE MATERIALIZED VIEW ct_v2l_daily_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  -- Active export hours
  COUNT(*) FILTER (WHERE power_kw_avg > 0.1
    AND status_last ILIKE '%active%')
    AS export_hours,
  -- High-load hours (> 5 kW)
  COUNT(*) FILTER (WHERE power_kw_avg > 5.0
    AND status_last ILIKE '%active%')
    AS high_load_hours,
  -- Very high load (> 10 kW)
  COUNT(*) FILTER (WHERE power_kw_avg > 10.0
    AND status_last ILIKE '%active%')
    AS very_high_load_hours,
  -- Fault hours
  COUNT(*) FILTER (WHERE status_last ILIKE '%fault%'
    OR status_last ILIKE '%error%')
    AS fault_hours,
  -- Peak power
  MAX(power_kw_max) FILTER (WHERE status_last ILIKE '%active%')
    AS peak_export_kw,
  -- Average power during active export
  AVG(power_kw_avg) FILTER (WHERE power_kw_avg > 0.1
    AND status_last ILIKE '%active%')
    AS avg_export_kw,
  -- Total energy exported (kWh)
  SUM(power_kw_avg) FILTER (WHERE power_kw_avg > 0.1
    AND status_last ILIKE '%active%')
    AS daily_export_kwh,
  -- Max inverter temps during export
  MAX(inv_temp_f_max) FILTER (WHERE status_last ILIKE '%active%')
    AS inv_temp_f_export_max,
  MAX(inv_temp_r_max) FILTER (WHERE status_last ILIKE '%active%')
    AS inv_temp_r_export_max
FROM ct_v2l_samples_1h
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 6.  V2L / Powershare — diagnostics view
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW ct_v2l_diagnostics AS
WITH daily AS (
  SELECT * FROM ct_v2l_daily_1d WHERE export_hours >= 1
),
rolling AS (
  SELECT
    d.*,
    AVG(high_load_hours::numeric) OVER w7 AS high_load_7d,
    AVG(high_load_hours::numeric) OVER w30 AS high_load_30d,
    AVG(very_high_load_hours::numeric) OVER w7 AS vhigh_load_7d,
    AVG(fault_hours::numeric) OVER w7 AS fault_7d,
    AVG(fault_hours::numeric) OVER w30 AS fault_30d,
    AVG(daily_export_kwh) OVER w7 AS export_kwh_7d,
    AVG(daily_export_kwh) OVER w30 AS export_kwh_30d,
    MAX(inv_temp_f_export_max) OVER w7 AS inv_f_max_7d,
    MAX(inv_temp_r_export_max) OVER w7 AS inv_r_max_7d,
    COUNT(*) OVER w7 AS n_7d,
    COUNT(*) OVER w30 AS n_30d
  FROM daily d
  WINDOW
    w7  AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW)
)
SELECT
  bucket AS ts,
  vin,
  export_hours,
  high_load_hours,
  very_high_load_hours,
  fault_hours,
  peak_export_kw,
  avg_export_kw,
  daily_export_kwh,
  inv_temp_f_export_max,
  inv_temp_r_export_max,
  ROUND(high_load_7d::numeric, 2) AS high_load_7d_avg,
  ROUND(high_load_30d::numeric, 2) AS high_load_30d_avg,
  ROUND(fault_7d::numeric, 2) AS fault_7d_avg,
  -- Status
  CASE
    WHEN n_7d < 3 OR n_30d < 10 THEN 'NORMAL'
    WHEN fault_hours > 0 AND fault_7d > fault_30d * 2.0 THEN 'V2L_FAULT_CYCLE_LIKELY'
    WHEN very_high_load_hours >= 2 THEN 'V2L_HIGH_LOAD_SUSTAINED'
    WHEN high_load_hours >= 4 THEN 'V2L_HIGH_LOAD_SUSTAINED'
    WHEN inv_temp_f_export_max > 85 OR inv_temp_r_export_max > 85 THEN 'V2L_INVERTER_THERMAL_STRESS'
    WHEN export_kwh_7d > export_kwh_30d * 1.5 AND export_kwh_30d > 10 THEN 'V2L_USAGE_SPIKE'
    ELSE 'NORMAL'
  END AS status,
  CASE
    WHEN (CASE
            WHEN n_7d < 3 OR n_30d < 10 THEN 'NORMAL'
            WHEN fault_hours > 0 AND fault_7d > fault_30d * 2.0 THEN 'V2L_FAULT_CYCLE_LIKELY'
            WHEN very_high_load_hours >= 2 THEN 'V2L_HIGH_LOAD_SUSTAINED'
            WHEN high_load_hours >= 4 THEN 'V2L_HIGH_LOAD_SUSTAINED'
            WHEN inv_temp_f_export_max > 85 OR inv_temp_r_export_max > 85 THEN 'V2L_INVERTER_THERMAL_STRESS'
            WHEN export_kwh_7d > export_kwh_30d * 1.5 AND export_kwh_30d > 10 THEN 'V2L_USAGE_SPIKE'
            ELSE 'NORMAL'
          END) = 'V2L_FAULT_CYCLE_LIKELY' THEN 'CRITICAL'
    WHEN (CASE
            WHEN n_7d < 3 OR n_30d < 10 THEN 'NORMAL'
            WHEN fault_hours > 0 AND fault_7d > fault_30d * 2.0 THEN 'V2L_FAULT_CYCLE_LIKELY'
            WHEN very_high_load_hours >= 2 THEN 'V2L_HIGH_LOAD_SUSTAINED'
            WHEN high_load_hours >= 4 THEN 'V2L_HIGH_LOAD_SUSTAINED'
            WHEN inv_temp_f_export_max > 85 OR inv_temp_r_export_max > 85 THEN 'V2L_INVERTER_THERMAL_STRESS'
            WHEN export_kwh_7d > export_kwh_30d * 1.5 AND export_kwh_30d > 10 THEN 'V2L_USAGE_SPIKE'
            ELSE 'NORMAL'
          END) IN ('V2L_HIGH_LOAD_SUSTAINED',
                   'V2L_INVERTER_THERMAL_STRESS',
                   'V2L_USAGE_SPIKE')
    THEN 'WARNING'
    ELSE 'NORMAL'
  END AS severity,
  CASE
    WHEN fault_hours > 0 AND fault_7d > fault_30d * 2.0
      THEN 'Powershare fault cycles spiking — ' || ROUND(fault_7d::numeric, 1) || ' vs baseline ' || ROUND(fault_30d::numeric, 1)
    WHEN very_high_load_hours >= 2
      THEN 'Very high load export sustained — ' || very_high_load_hours || ' hours > 10 kW'
    WHEN high_load_hours >= 4
      THEN 'High load export sustained — ' || high_load_hours || ' hours > 5 kW'
    WHEN inv_temp_f_export_max > 85
      THEN 'Front inverter thermal stress during export — ' || ROUND(inv_temp_f_export_max::numeric, 1) || '°C'
    WHEN inv_temp_r_export_max > 85
      THEN 'Rear inverter thermal stress during export — ' || ROUND(inv_temp_r_export_max::numeric, 1) || '°C'
    WHEN export_kwh_7d > export_kwh_30d * 1.5 AND export_kwh_30d > 10
      THEN 'V2L usage spike — ' || ROUND(export_kwh_7d::numeric, 1) || ' kWh/day vs baseline ' || ROUND(export_kwh_30d::numeric, 1)
    ELSE 'Powershare operating within normal limits'
  END AS anomaly_reason,
  daily_export_kwh AS value,
  ROUND(export_kwh_30d::numeric, 2) AS baseline
FROM rolling;


-- ------------------------------------------------------------------
-- 7.  Tri-Motor (Cyberbeast) — daily CAGG on dual_motor_samples_1h
--
-- The dual_motor_samples_1h CAGG (016) already captures REL/RER
-- fields.  We build a hierarchical daily CAGG on top of it to avoid
-- duplicating the expensive telemetry pivot.
--
-- Cyberbeast has three motors:
--   • Front          (F  fields)
--   • Rear-Left      (REL fields)
--   • Rear-Right     (RER fields)
--
-- Failure modes:
--   • Torque-vectoring imbalance (one rear motor working harder)
--   • Inverter thermal imbalance (front cooler than rears, or one
--     rear inverter hotter than the other)
--   • Axle speed mismatch (differential or half-shaft wear)
-- ------------------------------------------------------------------
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE;
--       tri_motor_highway_1d sources from dual_motor_samples_1h CAGG)
DROP MATERIALIZED VIEW IF EXISTS tri_motor_highway_1d CASCADE;

CREATE MATERIALIZED VIEW tri_motor_highway_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  -- Highway exposure
  COUNT(*) FILTER (WHERE vehicle_speed_max > 50) AS highway_hours,
  -- Front temps during highway
  AVG(inv_temp_f) FILTER (WHERE vehicle_speed_max > 50) AS inv_temp_f_avg,
  AVG(hs_temp_f)  FILTER (WHERE vehicle_speed_max > 50) AS hs_temp_f_avg,
  AVG(st_temp_f)  FILTER (WHERE vehicle_speed_max > 50) AS st_temp_f_avg,
  -- Rear-Left temps during highway
  AVG(inv_temp_rel) FILTER (WHERE vehicle_speed_max > 50) AS inv_temp_rel_avg,
  AVG(hs_temp_rel)  FILTER (WHERE vehicle_speed_max > 50) AS hs_temp_rel_avg,
  AVG(st_temp_rel)  FILTER (WHERE vehicle_speed_max > 50) AS st_temp_rel_avg,
  -- Rear-Right temps during highway
  AVG(inv_temp_rer) FILTER (WHERE vehicle_speed_max > 50) AS inv_temp_rer_avg,
  AVG(hs_temp_rer)  FILTER (WHERE vehicle_speed_max > 50) AS hs_temp_rer_avg,
  AVG(st_temp_rer)  FILTER (WHERE vehicle_speed_max > 50) AS st_temp_rer_avg,
  -- Axle speeds during highway straight-line
  AVG(axle_speed_f)   FILTER (WHERE vehicle_speed_max > 50
    AND (gear IS NULL OR gear IN ('D','ShiftStateD','invalid','')))
    AS axle_speed_f_avg,
  AVG(axle_speed_rel) FILTER (WHERE vehicle_speed_max > 50
    AND (gear IS NULL OR gear IN ('D','ShiftStateD','invalid','')))
    AS axle_speed_rel_avg,
  AVG(axle_speed_rer) FILTER (WHERE vehicle_speed_max > 50
    AND (gear IS NULL OR gear IN ('D','ShiftStateD','invalid','')))
    AS axle_speed_rer_avg,
  -- Torque peaks during highway
  MIN(regen_torque_f)   FILTER (WHERE vehicle_speed_max > 50) AS regen_torque_f_peak,
  MIN(regen_torque_rel) FILTER (WHERE vehicle_speed_max > 50) AS regen_torque_rel_peak,
  MIN(regen_torque_rer) FILTER (WHERE vehicle_speed_max > 50) AS regen_torque_rer_peak,
  MAX(accel_torque_f)   FILTER (WHERE vehicle_speed_max > 50) AS accel_torque_f_peak,
  MAX(accel_torque_rel) FILTER (WHERE vehicle_speed_max > 50) AS accel_torque_rel_peak,
  MAX(accel_torque_rer) FILTER (WHERE vehicle_speed_max > 50) AS accel_torque_rer_peak,
  -- Motor currents
  MAX(motor_current_f)   FILTER (WHERE vehicle_speed_max > 50) AS motor_current_f_max,
  MAX(motor_current_rel) FILTER (WHERE vehicle_speed_max > 50) AS motor_current_rel_max,
  MAX(motor_current_rer) FILTER (WHERE vehicle_speed_max > 50) AS motor_current_rer_max
FROM dual_motor_samples_1h
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 8.  Tri-Motor (Cyberbeast) — diagnostics view
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW tri_motor_diagnostics AS
WITH daily AS (
  SELECT * FROM tri_motor_highway_1d WHERE highway_hours >= 1
),
rolling AS (
  SELECT
    d.*,
    -- Rolling averages
    AVG(inv_temp_f_avg) OVER w7 AS inv_f_7d,
    AVG(inv_temp_rel_avg) OVER w7 AS inv_rel_7d,
    AVG(inv_temp_rer_avg) OVER w7 AS inv_rer_7d,
    AVG(axle_speed_rel_avg) OVER w7 AS speed_rel_7d,
    AVG(axle_speed_rer_avg) OVER w7 AS speed_rer_7d,
    AVG(ABS(regen_torque_f_peak)) OVER w7 AS regen_f_7d,
    AVG(ABS(regen_torque_rel_peak)) OVER w7 AS regen_rel_7d,
    AVG(ABS(regen_torque_rer_peak)) OVER w7 AS regen_rer_7d,
    AVG(ABS(accel_torque_f_peak)) OVER w7 AS accel_f_7d,
    AVG(ABS(accel_torque_rel_peak)) OVER w7 AS accel_rel_7d,
    AVG(ABS(accel_torque_rer_peak)) OVER w7 AS accel_rer_7d,
    -- 30-day baselines
    AVG(inv_temp_f_avg) OVER w30 AS inv_f_30d,
    AVG(inv_temp_rel_avg) OVER w30 AS inv_rel_30d,
    AVG(inv_temp_rer_avg) OVER w30 AS inv_rer_30d,
    AVG(ABS(regen_torque_f_peak)) OVER w30 AS regen_f_30d,
    AVG(ABS(accel_torque_f_peak)) OVER w30 AS accel_f_30d,
    -- Dynamic thresholds
    AVG(inv_temp_rel_avg) OVER w90 + 2 * STDDEV(inv_temp_rel_avg) OVER w90 AS inv_rel_p95,
    AVG(inv_temp_rer_avg) OVER w90 + 2 * STDDEV(inv_temp_rer_avg) OVER w90 AS inv_rer_p95,
    -- Rear temp delta (REL vs RER)
    ABS(COALESCE(inv_temp_rel_avg, 0) - COALESCE(inv_temp_rer_avg, 0)) AS rear_temp_delta,
    -- Front vs avg rear temp delta
    ABS(COALESCE(inv_temp_f_avg, 0)
      - ((COALESCE(inv_temp_rel_avg, 0) + COALESCE(inv_temp_rer_avg, 0)) / 2.0))
      AS front_rear_temp_delta,
    -- Rear axle speed imbalance
    CASE
      WHEN axle_speed_rel_avg IS NOT NULL AND axle_speed_rer_avg IS NOT NULL
       AND (axle_speed_rel_avg + axle_speed_rer_avg) > 0
      THEN ABS(axle_speed_rel_avg - axle_speed_rer_avg)
           / ((axle_speed_rel_avg + axle_speed_rer_avg) / 2.0) * 100
      ELSE NULL
    END AS rear_axle_imbalance_pct,
    -- Counts
    COUNT(*) OVER w7 AS n_7d,
    COUNT(*) OVER w30 AS n_30d,
    COUNT(*) OVER w90 AS n_90d
  FROM daily d
  WINDOW
    w7  AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW),
    w90 AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '90 days' PRECEDING AND CURRENT ROW)
),
with_derived AS (
  SELECT
    *,
    -- Sustained power proxy (composite accel torque / front baseline)
    -- Computed here (not in rolling) because accel_f_30d is a same-level alias
    CASE
      WHEN accel_f_30d > 0 AND accel_torque_f_peak IS NOT NULL
      THEN (accel_torque_f_peak + accel_torque_rel_peak + accel_torque_rer_peak)
           / (3.0 * accel_f_30d) * 100
      ELSE NULL
    END AS sustained_power_pct
  FROM rolling
),
vin_config AS (
  SELECT vin, motor_config FROM vehicle_metadata
  WHERE motor_config = 'Tri Motor'
),
with_status AS (
  SELECT
    d.*,
    c.motor_config,
    CASE
      WHEN c.motor_config IS NULL THEN 'NOT_APPLICABLE'
      WHEN d.n_7d < 3 OR d.n_30d < 10 THEN 'NORMAL'
      WHEN d.rear_temp_delta > 10 THEN 'TRI_MOTOR_REAR_IMBALANCE_LIKELY'
      WHEN d.front_rear_temp_delta > 12 THEN 'TRI_MOTOR_FRONT_REAR_IMBALANCE_LIKELY'
      WHEN d.rear_axle_imbalance_pct > 3 THEN 'TRI_MOTOR_REAR_AXLE_IMBALANCE'
      WHEN d.sustained_power_pct IS NOT NULL AND d.sustained_power_pct < 90
        THEN 'TRI_MOTOR_THERMAL_THROTTLING_RISK'
      ELSE 'NORMAL'
    END AS status
  FROM with_derived d
  LEFT JOIN vin_config c ON c.vin = d.vin
)
SELECT
  r.bucket AS ts,
  r.vin,
  r.highway_hours,
  r.inv_temp_f_avg,
  r.inv_temp_rel_avg,
  r.inv_temp_rer_avg,
  ROUND(r.rear_temp_delta::numeric, 2) AS rear_temp_delta,
  ROUND(r.front_rear_temp_delta::numeric, 2) AS front_rear_temp_delta,
  ROUND(r.rear_axle_imbalance_pct::numeric, 2) AS rear_axle_imbalance_pct,
  ROUND(r.sustained_power_pct::numeric, 2) AS sustained_power_pct,
  r.n_7d,
  r.n_30d,
  r.n_90d,
  r.motor_config,
  -- Status (computed in with_status CTE)
  r.status,
  CASE
    WHEN r.motor_config IS NULL THEN 'NORMAL'
    WHEN r.rear_temp_delta > 15 OR r.front_rear_temp_delta > 18 THEN 'CRITICAL'
    WHEN r.status IN ('TRI_MOTOR_REAR_IMBALANCE_LIKELY',
                      'TRI_MOTOR_FRONT_REAR_IMBALANCE_LIKELY',
                      'TRI_MOTOR_REAR_AXLE_IMBALANCE',
                      'TRI_MOTOR_THERMAL_THROTTLING_RISK')
    THEN 'WARNING'
    ELSE 'NORMAL'
  END AS severity,
  CASE
    WHEN r.motor_config IS NULL THEN 'Non-Tri-Motor vehicle — tri-motor diagnostics not applicable'
    WHEN r.rear_temp_delta > 10
      THEN 'Rear inverter temp delta ' || ROUND(r.rear_temp_delta::numeric, 1) || '°C (REL vs RER) exceeds 10°C'
    WHEN r.front_rear_temp_delta > 12
      THEN 'Front-rear temp delta ' || ROUND(r.front_rear_temp_delta::numeric, 1) || '°C exceeds 12°C'
    WHEN r.rear_axle_imbalance_pct > 3
      THEN 'Rear axle speed imbalance ' || ROUND(r.rear_axle_imbalance_pct::numeric, 1) || '% exceeds 3%'
    WHEN r.sustained_power_pct IS NOT NULL AND r.sustained_power_pct < 90
      THEN 'Sustained power ' || ROUND(r.sustained_power_pct::numeric, 1) || '% below 90% of 30-day baseline'
    ELSE 'Tri-motor system balanced and within thermal limits'
  END AS anomaly_reason,
  ROUND(GREATEST(r.rear_temp_delta, r.front_rear_temp_delta)::numeric, 2) AS value,
  10.0 AS baseline
FROM with_status r;


-- ------------------------------------------------------------------
-- 9.  Cybertruck Air Suspension Extension
--
-- Extends the generic air_suspension_diagnostics (015) with
-- Cybertruck-specific checks:
--   • Mode validation — Extract mode at speed > 5 mph is unsafe
--   • VeryHigh mode tracking — failure to reach target height
--   • CT-specific compressor duty thresholds (heavier vehicle =
--     higher baseline compressor load)
--
-- We JOIN the existing air_suspension_summary rather than
-- duplicating CAGGs.  This keeps the CT layer lightweight and
-- guarantees consistency with the generic air-suspension health
-- score used in predictive_health_summary.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW ct_air_suspension_diagnostics AS
WITH ct_air AS (
  SELECT
    a.*,
    vm.model,
    vm.has_air_suspension
  FROM air_suspension_diagnostics a
  LEFT JOIN vehicle_metadata vm ON vm.vin = a.vin
),
-- Pull latest mode from telemetry for speed-enforced checks
latest_mode AS (
  SELECT DISTINCT ON (vin, time_bucket('1 day', ts))
    vin,
    time_bucket('1 day', ts) AS day,
    str_value AS mode,
    MAX(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS speed_max
  FROM telemetry
  WHERE field IN ('AirSuspensionMode', 'VehicleSpeed')
  GROUP BY vin, time_bucket('1 day', ts), str_value
  ORDER BY vin, time_bucket('1 day', ts), MAX(ts) DESC
)
SELECT
  a.ts,
  a.vin,
  a.model,
  a.has_air_suspension,
  a.status AS air_status,
  NULL::text AS air_severity,
  NULL::text AS air_anomaly_reason,
  a.compressor_cycling_hours,
  a.duty_cycle AS duty_cycle_pct,
  a.height_drift_max_mm,
  m.mode AS last_mode,
  m.speed_max,
  -- CT-specific status
  CASE
    WHEN a.model != 'CT' OR a.has_air_suspension IS NOT TRUE THEN 'NOT_APPLICABLE'
    WHEN m.mode = 'Extract' AND m.speed_max > 5 THEN 'CT_AIR_SUSPENSION_EXTRACT_AT_SPEED'
    WHEN m.mode = 'VeryHigh' AND a.height_drift_max_mm > 8 THEN 'CT_AIR_SUSPENSION_VERYHIGH_DRIFT'
    WHEN a.duty_cycle > 0.20 THEN 'CT_AIR_SUSPENSION_COMPRESSOR_OVERWORK'
    WHEN a.status IN ('AIR_SUSPENSION_COMPRESSOR_OVERWORK_LIKELY',
                      'AIR_LEAK_SUSPECTED')
    THEN a.status
    ELSE 'NORMAL'
  END AS status,
  CASE
    WHEN a.model != 'CT' OR a.has_air_suspension IS NOT TRUE THEN 'NORMAL'
    WHEN m.mode = 'Extract' AND m.speed_max > 5 THEN 'CRITICAL'
    WHEN a.duty_cycle > 0.20 THEN 'WARNING'
    WHEN a.status IN ('AIR_SUSPENSION_COMPRESSOR_OVERWORK_LIKELY',
                      'AIR_LEAK_SUSPECTED')
    THEN 'WARNING'
    ELSE 'NORMAL'
  END AS severity,
  CASE
    WHEN a.model != 'CT' OR a.has_air_suspension IS NOT TRUE
      THEN 'Non-Cybertruck or no air suspension'
    WHEN m.mode = 'Extract' AND m.speed_max > 5
      THEN 'Extract mode active at ' || ROUND(m.speed_max::numeric, 0) || ' mph — speed limit violation'
    WHEN m.mode = 'VeryHigh' AND a.height_drift_max_mm > 8
      THEN 'VeryHigh mode ride-height drift ' || ROUND(a.height_drift_max_mm::numeric, 1) || ' mm exceeds 8 mm'
    WHEN a.duty_cycle > 0.20
      THEN 'Compressor duty cycle ' || ROUND((a.duty_cycle * 100)::numeric, 1) || '% exceeds 20% (CT heavy-vehicle baseline)'
    WHEN a.status IN ('AIR_SUSPENSION_COMPRESSOR_OVERWORK_LIKELY',
                      'AIR_LEAK_SUSPECTED')
    THEN 'Air suspension anomaly detected'
    ELSE 'Cybertruck air suspension operating normally'
  END AS anomaly_reason,
  ROUND((a.duty_cycle * 100)::numeric, 2) AS value,
  15.0 AS baseline
FROM ct_air a
LEFT JOIN latest_mode m
  ON m.vin = a.vin AND m.day = time_bucket('1 day', a.ts);

-- ------------------------------------------------------------------
-- 10.  Cybertruck 4680 Structural Battery Extension
--
-- The 4680 structural pack in the Cybertruck has different
-- characteristics from the 2170 cells in Model S/X/3/Y:
--   • Higher initial capacity (≈ 123 kWh usable vs ≈ 82 kWh for
--     Model Y LR 2170)
--   • Different thermal behaviour (tabless electrodes, better
--     heat rejection, but larger single-cell failure modes)
--   • Slower fade rate early in life (structural pack constraint)
--   • Different brick-voltage delta tolerance (larger cells =
--     wider acceptable delta, but harder to balance)
--
-- We reuse the battery_health_diagnostics view (009) and apply
-- CT-specific thresholds.  The baseline capacity is derived from
-- the first recorded rest-capacity reading for each CT VIN.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW ct_battery_4680_diagnostics AS
WITH ct_battery AS (
  SELECT
    b.*,
    vm.model,
    vm.battery_type
  FROM battery_health_diagnostics b
  LEFT JOIN vehicle_metadata vm ON vm.vin = b.vin
),
-- CT-specific baseline per VIN (first recorded rest capacity)
ct_baselines AS (
  SELECT
    vin,
    (ARRAY_AGG(derived_capacity_kwh ORDER BY ts)
      FILTER (WHERE derived_capacity_kwh IS NOT NULL))[1]
      AS baseline_capacity_kwh,
    (ARRAY_AGG(ideal_range ORDER BY ts)
      FILTER (WHERE ideal_range IS NOT NULL))[1]
      AS baseline_ideal_range,
    (ARRAY_AGG(rated_range ORDER BY ts)
      FILTER (WHERE rated_range IS NOT NULL))[1]
      AS baseline_rated_range
  FROM battery_rest_capacity
  GROUP BY vin
)
SELECT
  b.ts,
  b.vin,
  b.model,
  b.battery_type,
  b.derived_capacity_kwh,
  b.capacity_degradation_pct,
  b.brick_delta_max,
  b.brick_delta_avg,
  bl.baseline_capacity_kwh,
  bl.baseline_ideal_range,
  bl.baseline_rated_range,
  -- CT-specific degradation relative to CT baseline
  CASE WHEN bl.baseline_capacity_kwh > 0 AND b.derived_capacity_kwh IS NOT NULL
    THEN ROUND(((bl.baseline_capacity_kwh - b.derived_capacity_kwh)
                / bl.baseline_capacity_kwh * 100)::numeric, 2)
    ELSE b.capacity_degradation_pct
  END AS ct_degradation_pct,
  -- Status (CT-specific thresholds)
  CASE
    WHEN b.model != 'CT' OR b.battery_type != '4680' THEN 'NOT_APPLICABLE'
    WHEN b.capacity_degradation_pct > 15 THEN 'CT_4680_SEVERE_DEGRADATION'
    WHEN b.capacity_degradation_pct > 10 THEN 'CT_4680_MODERATE_DEGRADATION'
    WHEN b.capacity_degradation_pct > 7 THEN 'CT_4680_EARLY_DEGRADATION'
    WHEN b.brick_delta_max > 0.15 THEN 'CT_4680_BRICK_IMBALANCE'
    ELSE 'NORMAL'
  END AS status,
  CASE
    WHEN b.model != 'CT' OR b.battery_type != '4680' THEN 'NORMAL'
    WHEN b.capacity_degradation_pct > 15 THEN 'CRITICAL'
    WHEN b.capacity_degradation_pct > 10 THEN 'URGENT'
    WHEN b.capacity_degradation_pct > 7 OR b.brick_delta_max > 0.15 THEN 'WARNING'
    ELSE 'NORMAL'
  END AS severity,
  CASE
    WHEN b.model != 'CT' OR b.battery_type != '4680'
      THEN 'Non-Cybertruck or non-4680 battery'
    WHEN b.capacity_degradation_pct > 15
      THEN '4680 structural pack severe degradation — ' || b.capacity_degradation_pct || '% capacity loss'
    WHEN b.capacity_degradation_pct > 10
      THEN '4680 structural pack moderate degradation — ' || b.capacity_degradation_pct || '% capacity loss'
    WHEN b.capacity_degradation_pct > 7
      THEN '4680 structural pack early degradation — ' || b.capacity_degradation_pct || '% (monitor)'
    WHEN b.brick_delta_max > 0.15
      THEN '4680 cell brick imbalance — ' || ROUND(b.brick_delta_max::numeric, 3) || ' V exceeds 0.15 V'
    ELSE '4680 structural pack within CT-specific thresholds'
  END AS anomaly_reason,
  b.capacity_degradation_pct AS value,
  5.0 AS baseline
FROM ct_battery b
LEFT JOIN ct_baselines bl ON bl.vin = b.vin;


-- ------------------------------------------------------------------
-- 11.  cybertruck_diagnostics  — unified master view
--
-- Unions all CT-specific subsystems into a single time-series
-- view with common columns for Grafana and programmatic access.
--
-- Columns: vin, ts, model, subsystem, status, severity,
--          anomaly_reason, value, baseline
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW cybertruck_diagnostics AS
-- Tonneau
SELECT
  vin,
  ts,
  'CT' AS model,
  'tonneau' AS subsystem,
  status,
  severity,
  anomaly_reason,
  value,
  baseline
FROM ct_tonneau_diagnostics

UNION ALL

-- V2L / Powershare
SELECT
  vin,
  ts,
  'CT' AS model,
  'v2l' AS subsystem,
  status,
  severity,
  anomaly_reason,
  value,
  baseline
FROM ct_v2l_diagnostics

UNION ALL

-- Tri-Motor (Cyberbeast only)
SELECT
  vin,
  ts,
  'CT' AS model,
  'tri_motor' AS subsystem,
  status,
  severity,
  anomaly_reason,
  value,
  baseline
FROM tri_motor_diagnostics
WHERE motor_config = 'Tri Motor'

UNION ALL

-- Air Suspension
SELECT
  vin,
  ts,
  model,
  'air_suspension' AS subsystem,
  status,
  severity,
  anomaly_reason,
  value,
  baseline
FROM ct_air_suspension_diagnostics

UNION ALL

-- 4680 Battery
SELECT
  vin,
  ts,
  model,
  'battery_4680' AS subsystem,
  status,
  severity,
  anomaly_reason,
  value,
  baseline
FROM ct_battery_4680_diagnostics;

-- ------------------------------------------------------------------
-- 12.  cybertruck_summary  — Grafana-friendly latest snapshot
--
-- One row per VIN with the worst status across all CT subsystems,
-- plus pivoted columns for individual subsystem health.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW cybertruck_summary AS
WITH latest_per_subsystem AS (
  SELECT DISTINCT ON (vin, subsystem)
    vin,
    subsystem,
    ts,
    status,
    severity,
    anomaly_reason,
    value,
    baseline
  FROM cybertruck_diagnostics
  WHERE status != 'NOT_APPLICABLE'
  ORDER BY vin, subsystem, ts DESC
),
pivoted AS (
  SELECT
    vin,
    MAX(ts) AS last_ts,
    -- Worst status across subsystems
    MAX(CASE severity
      WHEN 'CRITICAL' THEN 4
      WHEN 'URGENT'   THEN 3
      WHEN 'WARNING'  THEN 2
      WHEN 'CAUTION'  THEN 1
      ELSE 0
    END) AS worst_severity_rank,
    -- Tonneau
    MAX(CASE WHEN subsystem = 'tonneau' THEN status END) AS tonneau_status,
    MAX(CASE WHEN subsystem = 'tonneau' THEN severity END) AS tonneau_severity,
    MAX(CASE WHEN subsystem = 'tonneau' THEN anomaly_reason END) AS tonneau_reason,
    MAX(CASE WHEN subsystem = 'tonneau' THEN value END) AS tonneau_value,
    -- V2L
    MAX(CASE WHEN subsystem = 'v2l' THEN status END) AS v2l_status,
    MAX(CASE WHEN subsystem = 'v2l' THEN severity END) AS v2l_severity,
    MAX(CASE WHEN subsystem = 'v2l' THEN anomaly_reason END) AS v2l_reason,
    MAX(CASE WHEN subsystem = 'v2l' THEN value END) AS v2l_value,
    -- Tri-Motor
    MAX(CASE WHEN subsystem = 'tri_motor' THEN status END) AS tri_motor_status,
    MAX(CASE WHEN subsystem = 'tri_motor' THEN severity END) AS tri_motor_severity,
    MAX(CASE WHEN subsystem = 'tri_motor' THEN anomaly_reason END) AS tri_motor_reason,
    MAX(CASE WHEN subsystem = 'tri_motor' THEN value END) AS tri_motor_value,
    -- Air Suspension
    MAX(CASE WHEN subsystem = 'air_suspension' THEN status END) AS air_suspension_status,
    MAX(CASE WHEN subsystem = 'air_suspension' THEN severity END) AS air_suspension_severity,
    MAX(CASE WHEN subsystem = 'air_suspension' THEN anomaly_reason END) AS air_suspension_reason,
    MAX(CASE WHEN subsystem = 'air_suspension' THEN value END) AS air_suspension_value,
    -- 4680 Battery
    MAX(CASE WHEN subsystem = 'battery_4680' THEN status END) AS battery_4680_status,
    MAX(CASE WHEN subsystem = 'battery_4680' THEN severity END) AS battery_4680_severity,
    MAX(CASE WHEN subsystem = 'battery_4680' THEN anomaly_reason END) AS battery_4680_reason,
    MAX(CASE WHEN subsystem = 'battery_4680' THEN value END) AS battery_4680_value
  FROM latest_per_subsystem
  GROUP BY vin
)
SELECT
  p.vin,
  p.last_ts,
  p.tonneau_status,
  p.tonneau_severity,
  p.tonneau_reason,
  p.v2l_status,
  p.v2l_severity,
  p.v2l_reason,
  p.tri_motor_status,
  p.tri_motor_severity,
  p.tri_motor_reason,
  p.air_suspension_status,
  p.air_suspension_severity,
  p.air_suspension_reason,
  p.battery_4680_status,
  p.battery_4680_severity,
  p.battery_4680_reason,
  -- Overall worst status
  CASE p.worst_severity_rank
    WHEN 4 THEN 'CRITICAL'
    WHEN 3 THEN 'URGENT'
    WHEN 2 THEN 'WARNING'
    WHEN 1 THEN 'CAUTION'
    ELSE 'NORMAL'
  END AS overall_severity,
  -- Overall anomaly reason (priority order)
  COALESCE(
    NULLIF(p.battery_4680_reason, '4680 structural pack within CT-specific thresholds'),
    NULLIF(p.tri_motor_reason, 'Tri-motor system balanced and within thermal limits'),
    NULLIF(p.air_suspension_reason, 'Cybertruck air suspension operating normally'),
    NULLIF(p.v2l_reason, 'Powershare operating within normal limits'),
    NULLIF(p.tonneau_reason, 'Tonneau operating normally'),
    'All Cybertruck subsystems nominal'
  ) AS overall_reason,
  vm.model,
  vm.motor_config,
  vm.battery_type
FROM pivoted p
LEFT JOIN vehicle_metadata vm ON vm.vin = p.vin
WHERE vm.model = 'CT';

-- ------------------------------------------------------------------
-- 13.  Refresh policies
-- ------------------------------------------------------------------
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('ct_tonneau_samples_1h');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('ct_tonneau_samples_1h',
  start_offset  => INTERVAL '7 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- ct_tonneau_daily_1d is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('ct_tonneau_daily_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('ct_v2l_samples_1h');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('ct_v2l_samples_1h',
  start_offset  => INTERVAL '7 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- ct_v2l_daily_1d is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('ct_v2l_daily_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- tri_motor_highway_1d is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('tri_motor_highway_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ------------------------------------------------------------------
-- 14.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Cybertruck Health Overview"  (Stat panel)
-- --------------------------------------------------------
-- Green  = NORMAL
-- Yellow = WARNING / CAUTION
-- Red    = CRITICAL / URGENT
--
-- SELECT
--   overall_severity,
--   tonneau_status,
--   v2l_status,
--   tri_motor_status,
--   air_suspension_status,
--   battery_4680_status,
--   overall_reason
-- FROM cybertruck_summary
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Tonneau Position History"  (Time series)
-- --------------------------------------------------------
-- SELECT
--   bucket AS time,
--   open_pct_last AS "Open %",
--   position_last AS "Position"
-- FROM ct_tonneau_samples_1h
-- WHERE vin = '$vin'
--   AND $__timeFilter(bucket)
-- ORDER BY bucket;

-- --------------------------------------------------------
-- Panel: "V2L Export Power"  (Time series)
-- --------------------------------------------------------
-- SELECT
--   bucket AS time,
--   power_kw_avg AS "Export power (kW)",
--   status_last AS "Status"
-- FROM ct_v2l_samples_1h
-- WHERE vin = '$vin'
--   AND $__timeFilter(bucket)
-- ORDER BY bucket;

-- --------------------------------------------------------
-- Panel: "Tri-Motor Temp Deltas"  (Time series)
-- --------------------------------------------------------
-- SELECT
--   ts AS time,
--   inv_temp_f_avg AS "Front (°C)",
--   inv_temp_rel_avg AS "Rear-Left (°C)",
--   inv_temp_rer_avg AS "Rear-Right (°C)",
--   rear_temp_delta AS "Rear delta (°C)"
-- FROM tri_motor_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "4680 Battery Degradation"  (Time series)
-- --------------------------------------------------------
-- SELECT
--   ts AS time,
--   ct_degradation_pct AS "Degradation %",
--   capacity_degradation_pct AS "Generic degradation %"
-- FROM ct_battery_4680_diagnostics
-- WHERE vin = '$vin'
--   AND model = 'CT'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Cybertruck Fleet Overview"  (Table)
-- --------------------------------------------------------
-- SELECT
--   vin,
--   overall_severity,
--   tonneau_status,
--   v2l_status,
--   tri_motor_status,
--   air_suspension_status,
--   battery_4680_status
-- FROM cybertruck_summary
-- WHERE model = 'CT'
-- ORDER BY
--   CASE overall_severity
--     WHEN 'CRITICAL' THEN 1
--     WHEN 'URGENT'   THEN 2
--     WHEN 'WARNING'  THEN 3
--     ELSE 4
--   END;

-- ------------------------------------------------------------------
-- 15.  Testing & verification instructions
-- ------------------------------------------------------------------

-- Step 1 — Start simulator with Cybertruck standard VIN
--   VIN[3] = 'C'  (e.g. 7SACGDEE9PF000001)
--   VIN[8] = 'E'  (Dual Motor standard)
--
-- Step 2 — Start simulator with Cyberbeast Tri-Motor VIN
--   VIN[3] = 'C'
--   VIN[8] = 'J'  (Tri Motor)
--
-- Step 3 — Verify ct_tonneau_diagnostics populates
--   SELECT * FROM ct_tonneau_diagnostics WHERE vin = '...';
--   Expected: status = 'NORMAL', open_pct_avg within 0-100
--
-- Step 4 — Simulate tonneau stuck event
--   UPDATE telemetry SET str_value = 'Stuck'
--   WHERE vin = '...' AND field = 'TonneauPosition'
--   AND ts > NOW() - INTERVAL '1 hour';
--   REFRESH MATERIALIZED VIEW ct_tonneau_daily_1d;
--   SELECT status, severity FROM ct_tonneau_diagnostics
--   WHERE vin = '...' ORDER BY ts DESC LIMIT 1;
--   Expected: status = 'TONNEAU_STUCK_OR_MOTOR_FAILURE',
--             severity = 'CRITICAL'
--
-- Step 5 — Verify ct_v2l_diagnostics with high export
--   UPDATE telemetry SET num_value = 12.5
--   WHERE vin = '...' AND field = 'PowershareInstantaneousPowerKW'
--   AND ts > NOW() - INTERVAL '4 hours';
--   REFRESH MATERIALIZED VIEW ct_v2l_daily_1d;
--   SELECT status, severity FROM ct_v2l_diagnostics
--   WHERE vin = '...' ORDER BY ts DESC LIMIT 1;
--   Expected: status = 'V2L_HIGH_LOAD_SUSTAINED'
--
-- Step 6 — Verify tri_motor_diagnostics (Cyberbeast only)
--   SELECT * FROM tri_motor_diagnostics WHERE vin = '...';
--   Expected: status = 'NORMAL', rear_temp_delta < 5°C
--
-- Step 7 — Simulate tri-motor rear imbalance
--   UPDATE telemetry SET num_value = 95
--   WHERE vin = '...' AND field = 'DiInverterTREL'
--   AND ts > NOW() - INTERVAL '1 day';
--   REFRESH MATERIALIZED VIEW tri_motor_highway_1d;
--   SELECT status, severity FROM tri_motor_diagnostics
--   WHERE vin = '...' ORDER BY ts DESC LIMIT 1;
--   Expected: status = 'TRI_MOTOR_REAR_IMBALANCE_LIKELY'
--
-- Step 8 — Verify ct_battery_4680_diagnostics
--   SELECT * FROM ct_battery_4680_diagnostics
--   WHERE vin = '...' AND model = 'CT';
--   Expected: status = 'NORMAL' or early degradation
--
-- Step 9 — Verify non-Cybertruck returns NOT_APPLICABLE
--   SELECT status, severity FROM cybertruck_diagnostics
--   WHERE vin = (SELECT vin FROM vehicle_metadata WHERE model != 'CT' LIMIT 1)
--   LIMIT 1;
--   Expected: status = 'NOT_APPLICABLE', severity = 'NORMAL'
--
-- Step 10 — Verify cybertruck_summary
--   SELECT * FROM cybertruck_summary WHERE vin = '...';
--   Expected: one row, overall_severity, all subsystem statuses
--
-- Step 11 — Clean up synthetic data
--   DELETE FROM telemetry WHERE vin = '...' AND ts > NOW() - INTERVAL '2 days';
