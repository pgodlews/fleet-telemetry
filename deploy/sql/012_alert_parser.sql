-- ============================================================
-- Comprehensive Tesla Alert Parser & Management Layer
--
-- The vehicle_alerts side-channel table receives low-volume but
-- Features are gated per docs/FEATURE_MATRIX.md using vehicle_metadata.
-- high-value alert payloads from the Tesla fleet telemetry
-- stream.  Each alert is a string code (e.g. BMS_u018,
-- UI_a006, PCS_a016) with start/end timestamps and an
-- audience (Customer, Service, ServiceFix).
--
-- This layer:
--   1. Parses every alert code into structured columns
--      (subsystem, severity, description, service bulletin).
--   2. Enriches alerts with nearest telemetry context
--      (speed, charge state, battery level) so engineers can
--      correlate alerts with driving / charging / parked state.
--   3. Builds daily and weekly frequency CAGGs for trend
--      analysis and subsystem health monitoring.
--   4. Maintains an alert_history_summary with first_seen,
--      last_seen, recurrence_count, and active status.
--   5. Surfaces active critical alerts for immediate action.
--
-- Severity mapping rules (applied in order):
--   CRITICAL  — known life-safety or severe-damage codes
--               (UI_a006, BMS_f064, any *_f* fault prefix)
--   URGENT    — any *_u* urgent prefix
--   WARNING   — any *_a* alert prefix
--   INFO      — everything else
--
-- Subsystem mapping:
--   BMS_*     → Battery Management System
--   DI_*      → Drive Inverter / motor
--   UI_a*     → User Interface / vehicle state
--   PCS_*     → Power Conversion System (onboard charger)
--   CH_*      → Chassis / suspension / brakes
--   CC_*      → Climate Control
--   CP_*      → Charge Port
--   TP_*      → Tire Pressure
--   AT_*      → Autopilot
--
-- Requires superuser (postgres) to run — creates CAGGs.
-- Run after 001_schema.sql and 002_views.sql.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  parsed_alerts  — structured alert view with telemetry context
--
-- Each row is one alert enriched with:
--   • parsed subsystem, severity, description
--   • is_active flag (ended_at IS NULL)
--   • nearest telemetry sample BEFORE the alert timestamp
--     for VehicleSpeed, ChargeState, BatteryLevel, AC/DC power
--
-- NOTE: The lateral subqueries are indexed by (vin, field, ts)
-- and run once per alert row.  For high-volume alert tables
-- (>10 k rows) consider materialising this view periodically.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW parsed_alerts AS
SELECT
  a.ts,
  a.vin,
  a.name AS alert_code,
  a.audience,
  a.started_at,
  a.ended_at,
  CASE WHEN a.ended_at IS NULL THEN TRUE ELSE FALSE END AS is_active,
  -- Subsystem (pattern-based)
  CASE
    WHEN a.name LIKE 'BMS_%'  THEN 'BMS'
    WHEN a.name LIKE 'DI_%'   THEN 'Drive Inverter'
    WHEN a.name LIKE 'UI_a%'  THEN 'User Interface'
    WHEN a.name LIKE 'PCS_%'  THEN 'Power Conversion'
    WHEN a.name LIKE 'CH_%'   THEN 'Chassis'
    WHEN a.name LIKE 'CC_%'   THEN 'Climate Control'
    WHEN a.name LIKE 'CP_%'   THEN 'Charge Port'
    WHEN a.name LIKE 'TP_%'   THEN 'Tire Pressure'
    WHEN a.name LIKE 'AT_%'   THEN 'Autopilot'
    ELSE 'Other'
  END AS subsystem,
  -- Severity (explicit codes first, then pattern fallback)
  CASE
    WHEN a.name IN ('UI_a006', 'BMS_f064', 'PCS_f001', 'DI_f001')
      THEN 'CRITICAL'
    WHEN a.name LIKE 'BMS_f%' THEN 'CRITICAL'
    WHEN a.name LIKE 'DI_f%'  THEN 'CRITICAL'
    WHEN a.name LIKE 'PCS_f%' THEN 'CRITICAL'
    WHEN a.name LIKE 'CH_f%'  THEN 'CRITICAL'
    WHEN a.name LIKE 'CC_f%'  THEN 'CRITICAL'
    WHEN a.name = 'BMS_u018'  THEN 'URGENT'
    WHEN a.name LIKE 'BMS_u%' THEN 'URGENT'
    WHEN a.name LIKE 'DI_u%'  THEN 'URGENT'
    WHEN a.name LIKE 'PCS_u%' THEN 'URGENT'
    WHEN a.name LIKE 'CH_u%'  THEN 'URGENT'
    WHEN a.name LIKE 'CC_u%'  THEN 'URGENT'
    WHEN a.name LIKE 'BMS_a%' THEN 'WARNING'
    WHEN a.name LIKE 'DI_a%'  THEN 'WARNING'
    WHEN a.name LIKE 'PCS_a%' THEN 'WARNING'
    WHEN a.name LIKE 'UI_a%'  THEN 'WARNING'
    WHEN a.name LIKE 'CH_a%'  THEN 'WARNING'
    WHEN a.name LIKE 'CC_a%'  THEN 'WARNING'
    WHEN a.name LIKE 'CP_a%'  THEN 'WARNING'
    WHEN a.name LIKE 'TP_a%'  THEN 'WARNING'
    WHEN a.name LIKE 'AT_a%'  THEN 'WARNING'
    ELSE 'INFO'
  END AS severity,
  -- Human-readable descriptions (known codes) with service bulletin refs
  CASE a.name
    WHEN 'UI_a006' THEN
      'Chassis/alignment abnormal — suspension or steering component fault (SB-21-31-001: Steering Rack Replacement)'
    WHEN 'BMS_f064' THEN
      'BMS critical fault 064 — contactor weld or isolation fault, immediate service required (SB-23-00-009)'
    WHEN 'BMS_f065' THEN
      'BMS critical fault 065 — pyro fuse blown, vehicle immobilised, tow required'
    WHEN 'BMS_u018' THEN
      'BMS urgent 018 — cell voltage imbalance > 100 mV detected, schedule battery service (SB-22-00-012)'
    WHEN 'BMS_u019' THEN
      'BMS urgent 019 — pack thermal runaway warning, inspect cooling system immediately'
    WHEN 'BMS_u020' THEN
      'BMS urgent 020 — heater fault causing reduced cold-weather range'
    WHEN 'BMS_a001' THEN
      'BMS alert 001 — charging power reduced due to high pack temperature'
    WHEN 'BMS_a002' THEN
      'BMS alert 002 — charging power reduced due to low pack temperature'
    WHEN 'BMS_a003' THEN
      'BMS alert 003 — regenerative braking limited due to cold battery'
    WHEN 'PCS_a016' THEN
      'PCS alert 016 — onboard charger derating, inspect Gen-3 charger (SB-22-10-005)'
    WHEN 'PCS_f001' THEN
      'PCS fault 001 — charging system failure, discontinue charging immediately'
    WHEN 'PCS_u002' THEN
      'PCS urgent 002 — charge port over-temperature, inspect connector pins'
    WHEN 'DI_f001' THEN
      'Drive inverter fault — motor phase short or IGBT desaturation, reduce power (SB-21-17-003)'
    WHEN 'DI_u003' THEN
      'Drive inverter urgent 003 — inverter over-temperature, power reduced, inspect coolant loop'
    WHEN 'DI_u004' THEN
      'Drive inverter urgent 004 — stator over-temperature, sustained high load likely cause'
    WHEN 'DI_a005' THEN
      'Drive inverter alert 005 — torque command vs actual mismatch > 5 %, monitor for degradation'
    WHEN 'CP_a007' THEN
      'Charge port alert 007 — latch or proximity sensor intermittent fault, clean port'
    WHEN 'CP_a008' THEN
      'Charge port alert 008 — charge port door actuator fault'
    WHEN 'CH_u001' THEN
      'Chassis urgent 001 — brake booster pressure low, inspect brake system (SB-20-31-002)'
    WHEN 'CH_u002' THEN
      'Chassis urgent 002 — suspension height sensor out of range, inspect air suspension'
    WHEN 'CC_a001' THEN
      'Climate alert 001 — HVAC compressor duty cycle abnormal, refrigerant level may be low'
    WHEN 'CC_a002' THEN
      'Climate alert 002 — cabin heater efficiency reduced, inspect PTC heater'
    WHEN 'TP_a001' THEN
      'Tire pressure alert — one or more tires significantly under-inflated'
    WHEN 'AT_a001' THEN
      'Autopilot alert 001 — camera calibration required, drive above 25 mph for 20 min'
    ELSE a.name || ' — refer to Tesla service manual or TSB database'
  END AS description,
  -- Telemetry context (nearest sample BEFORE alert)
  (SELECT num_value FROM telemetry t
   WHERE t.vin = a.vin AND t.field = 'VehicleSpeed'
     AND t.ts <= a.ts ORDER BY t.ts DESC LIMIT 1) AS vehicle_speed_at_alert,
  (SELECT str_value FROM telemetry t
   WHERE t.vin = a.vin AND t.field = 'ChargeState'
     AND t.ts <= a.ts ORDER BY t.ts DESC LIMIT 1) AS charge_state_at_alert,
  (SELECT str_value FROM telemetry t
   WHERE t.vin = a.vin AND t.field = 'Gear'
     AND t.ts <= a.ts ORDER BY t.ts DESC LIMIT 1) AS gear_at_alert,
  (SELECT num_value FROM telemetry t
   WHERE t.vin = a.vin AND t.field = 'BatteryLevel'
     AND t.ts <= a.ts ORDER BY t.ts DESC LIMIT 1) AS battery_level_at_alert,
  (SELECT num_value FROM telemetry t
   WHERE t.vin = a.vin AND t.field = 'ACChargingPower'
     AND t.ts <= a.ts ORDER BY t.ts DESC LIMIT 1) AS ac_power_at_alert,
  (SELECT num_value FROM telemetry t
   WHERE t.vin = a.vin AND t.field = 'DCChargingPower'
     AND t.ts <= a.ts ORDER BY t.ts DESC LIMIT 1) AS dc_power_at_alert
FROM vehicle_alerts a;

-- ------------------------------------------------------------------
-- 2.  alert_frequency_1d  — daily alert counts per subsystem/severity
--
-- Built directly on the vehicle_alerts hypertable.  Uses the
-- same parsing CASEs so downstream CAGGs don't re-parse.
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS alert_frequency_1d CASCADE;

CREATE MATERIALIZED VIEW alert_frequency_1d
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 day', ts) AS bucket,
  vin,
  -- Subsystem
  CASE
    WHEN name LIKE 'BMS_%'  THEN 'BMS'
    WHEN name LIKE 'DI_%'   THEN 'Drive Inverter'
    WHEN name LIKE 'UI_a%'  THEN 'User Interface'
    WHEN name LIKE 'PCS_%'  THEN 'Power Conversion'
    WHEN name LIKE 'CH_%'   THEN 'Chassis'
    WHEN name LIKE 'CC_%'   THEN 'Climate Control'
    WHEN name LIKE 'CP_%'   THEN 'Charge Port'
    WHEN name LIKE 'TP_%'   THEN 'Tire Pressure'
    WHEN name LIKE 'AT_%'   THEN 'Autopilot'
    ELSE 'Other'
  END AS subsystem,
  -- Severity
  CASE
    WHEN name IN ('UI_a006', 'BMS_f064', 'PCS_f001', 'DI_f001')
      THEN 'CRITICAL'
    WHEN name LIKE 'BMS_f%' THEN 'CRITICAL'
    WHEN name LIKE 'DI_f%'  THEN 'CRITICAL'
    WHEN name LIKE 'PCS_f%' THEN 'CRITICAL'
    WHEN name LIKE 'CH_f%'  THEN 'CRITICAL'
    WHEN name LIKE 'CC_f%'  THEN 'CRITICAL'
    WHEN name = 'BMS_u018'  THEN 'URGENT'
    WHEN name LIKE 'BMS_u%' THEN 'URGENT'
    WHEN name LIKE 'DI_u%'  THEN 'URGENT'
    WHEN name LIKE 'PCS_u%' THEN 'URGENT'
    WHEN name LIKE 'CH_u%'  THEN 'URGENT'
    WHEN name LIKE 'CC_u%'  THEN 'URGENT'
    WHEN name LIKE 'BMS_a%' THEN 'WARNING'
    WHEN name LIKE 'DI_a%'  THEN 'WARNING'
    WHEN name LIKE 'PCS_a%' THEN 'WARNING'
    WHEN name LIKE 'UI_a%'  THEN 'WARNING'
    WHEN name LIKE 'CH_a%'  THEN 'WARNING'
    WHEN name LIKE 'CC_a%'  THEN 'WARNING'
    WHEN name LIKE 'CP_a%'  THEN 'WARNING'
    WHEN name LIKE 'TP_a%'  THEN 'WARNING'
    WHEN name LIKE 'AT_a%'  THEN 'WARNING'
    ELSE 'INFO'
  END AS severity,
  COUNT(*) AS alert_count,
  COUNT(*) FILTER (WHERE ended_at IS NULL) AS active_count
FROM vehicle_alerts
GROUP BY bucket, vin, subsystem, severity;

-- ------------------------------------------------------------------
-- 3.  alert_frequency_1w  — weekly rollup (regular matview)
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS alert_frequency_1w CASCADE;

CREATE MATERIALIZED VIEW alert_frequency_1w AS
SELECT
  time_bucket('7 days', bucket) AS bucket,
  vin,
  subsystem,
  severity,
  SUM(alert_count) AS alert_count,
  SUM(active_count) AS active_count
FROM alert_frequency_1d
GROUP BY bucket, vin, subsystem, severity;

-- ------------------------------------------------------------------
-- 4.  Refresh policies
-- ------------------------------------------------------------------
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('alert_frequency_1d');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('alert_frequency_1d',
  start_offset  => INTERVAL '30 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- alert_frequency_1w is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('alert_frequency_1w'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ------------------------------------------------------------------
-- 5.  alert_history_summary  — per-code lifecycle view
--
-- One row per VIN + alert_code.  Shows first_seen, last_seen,
-- recurrence count, active count, and current status.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW alert_history_summary AS
SELECT
  pa.vin,
  pa.alert_code,
  MIN(pa.ts) AS first_seen,
  MAX(pa.ts) AS last_seen,
  COUNT(*) AS recurrence_count,
  COUNT(*) FILTER (WHERE pa.is_active) AS active_count,
  MAX(pa.ts) FILTER (WHERE pa.is_active) AS last_active_ts,
  pa.subsystem,
  pa.severity,
  MAX(pa.description) AS description,
  vm.model
FROM parsed_alerts pa
LEFT JOIN vehicle_metadata vm ON vm.vin = pa.vin
GROUP BY pa.vin, pa.alert_code, pa.subsystem, pa.severity, vm.model
ORDER BY pa.vin, pa.severity, recurrence_count DESC;

-- ------------------------------------------------------------------
-- 6.  alert_critical_active  — active critical/urgent snapshot
--
-- Fast query for Grafana "Active Critical Alerts" stat panel.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW alert_critical_active AS
SELECT
  vin,
  COUNT(*) FILTER (WHERE severity = 'CRITICAL' AND is_active) AS critical_active,
  COUNT(*) FILTER (WHERE severity = 'URGENT' AND is_active) AS urgent_active,
  COUNT(*) FILTER (WHERE severity = 'WARNING' AND is_active) AS warning_active,
  COUNT(*) FILTER (WHERE is_active) AS total_active,
  STRING_AGG(DISTINCT alert_code, ', ' ORDER BY alert_code)
    FILTER (WHERE severity = 'CRITICAL' AND is_active) AS critical_codes,
  STRING_AGG(DISTINCT alert_code, ', ' ORDER BY alert_code)
    FILTER (WHERE severity = 'URGENT' AND is_active) AS urgent_codes,
  MAX(ts) FILTER (WHERE severity = 'CRITICAL' AND is_active) AS latest_critical_ts,
  MAX(ts) FILTER (WHERE is_active) AS latest_active_ts
FROM parsed_alerts
GROUP BY vin;

-- ------------------------------------------------------------------
-- 7.  alert_subsystem_trends  — rolling 7d/30d subsystem health
--
-- Uses the daily CAGG to compute short-term vs long-term alert
-- rates per subsystem.  A spike in any subsystem triggers
-- investigation.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW alert_subsystem_trends AS
WITH daily AS (
  SELECT bucket, vin, subsystem,
    SUM(alert_count) AS daily_alerts,
    SUM(active_count) AS daily_active
  FROM alert_frequency_1d
  GROUP BY bucket, vin, subsystem
),
rolling AS (
  SELECT
    *,
    AVG(daily_alerts) OVER w7  AS alert_rate_7d,
    AVG(daily_alerts) OVER w30 AS alert_rate_30d,
    SUM(daily_active) OVER w7  AS active_sum_7d,
    COUNT(*) OVER w7  AS n_7d,
    COUNT(*) OVER w30 AS n_30d
  FROM daily
  WINDOW
    w7  AS (PARTITION BY vin, subsystem ORDER BY bucket
            RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY vin, subsystem ORDER BY bucket
            RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW)
)
SELECT
  bucket AS ts,
  vin,
  subsystem,
  daily_alerts,
  daily_active,
  ROUND(alert_rate_7d::numeric, 2)  AS alert_rate_7d,
  ROUND(alert_rate_30d::numeric, 2) AS alert_rate_30d,
  active_sum_7d,
  n_7d,
  n_30d,
  CASE WHEN alert_rate_30d > 0
    THEN ROUND(((alert_rate_7d - alert_rate_30d) / alert_rate_30d * 100)::numeric, 1)
    ELSE NULL
  END AS trend_pct,
  CASE
    WHEN n_7d >= 3 AND n_30d >= 10
     AND alert_rate_30d > 0
     AND alert_rate_7d > alert_rate_30d * 3.0
    THEN 'ALERT_SPIKE'
    WHEN active_sum_7d >= 3
    THEN 'PERSISTENT_ISSUES'
    ELSE 'NORMAL'
  END AS subsystem_status
FROM rolling;

-- ------------------------------------------------------------------
-- 8.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Active Critical Alerts"  (Stat)
-- --------------------------------------------------------
-- Red when > 0 critical alerts are active.
--
-- SELECT critical_active, critical_codes
-- FROM alert_critical_active
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Alert Severity Breakdown"  (Stat row)
-- --------------------------------------------------------
--
-- SELECT critical_active, urgent_active, warning_active, total_active
-- FROM alert_critical_active
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Alert Frequency Timeline"  (Time series)
-- --------------------------------------------------------
-- Daily alert count stacked by subsystem.
--
-- SELECT
--   bucket AS time,
--   SUM(alert_count) FILTER (WHERE subsystem='BMS') AS "BMS",
--   SUM(alert_count) FILTER (WHERE subsystem='Drive Inverter') AS "Drive Inverter",
--   SUM(alert_count) FILTER (WHERE subsystem='User Interface') AS "UI",
--   SUM(alert_count) FILTER (WHERE subsystem='Power Conversion') AS "PCS",
--   SUM(alert_count) FILTER (WHERE subsystem='Chassis') AS "Chassis",
--   SUM(alert_count) FILTER (WHERE subsystem='Climate Control') AS "Climate",
--   SUM(alert_count) FILTER (WHERE subsystem='Charge Port') AS "Charge Port"
-- FROM alert_frequency_1d
-- WHERE vin = '$vin'
--   AND $__timeFilter(bucket)
-- GROUP BY bucket
-- ORDER BY bucket;

-- --------------------------------------------------------
-- Panel: "Subsystem Alert Rate"  (Time series)
-- --------------------------------------------------------
-- 7-day vs 30-day rolling alert rate per subsystem.
--
-- SELECT
--   ts AS time,
--   alert_rate_7d AS "7-day rate",
--   alert_rate_30d AS "30-day rate"
-- FROM alert_subsystem_trends
-- WHERE vin = '$vin'
--   AND subsystem = 'BMS'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Parsed Alert History"  (Table)
-- --------------------------------------------------------
-- Full parsed alerts with telemetry context.
--
-- SELECT
--   ts AS "Alert time",
--   alert_code AS "Code",
--   severity AS "Severity",
--   subsystem AS "Subsystem",
--   description AS "Description",
--   is_active AS "Active",
--   vehicle_speed_at_alert AS "Speed (mph)",
--   charge_state_at_alert AS "Charge state",
--   battery_level_at_alert AS "SOC %"
-- FROM parsed_alerts
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts DESC
-- LIMIT 200;

-- --------------------------------------------------------
-- Panel: "Alert History Summary"  (Table)
-- --------------------------------------------------------
-- One row per alert code showing lifetime stats.
--
-- SELECT
--   alert_code AS "Code",
--   severity AS "Severity",
--   subsystem AS "Subsystem",
--   first_seen AS "First seen",
--   last_seen AS "Last seen",
--   recurrence_count AS "Count",
--   active_count AS "Active now",
--   description AS "Description"
-- FROM alert_history_summary
-- WHERE vin = '$vin'
-- ORDER BY
--   CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'URGENT' THEN 2
--                 WHEN 'WARNING' THEN 3 ELSE 4 END,
--   recurrence_count DESC;

-- --------------------------------------------------------
-- Panel: "Weekly Alert Summary"  (Bar chart)
-- --------------------------------------------------------
--
-- SELECT
--   bucket AS time,
--   SUM(alert_count) AS "Total alerts",
--   SUM(active_count) AS "Still active"
-- FROM alert_frequency_1w
-- WHERE vin = '$vin'
--   AND $__timeFilter(bucket)
-- GROUP BY bucket
-- ORDER BY bucket;

-- ------------------------------------------------------------------
-- 9.  How to test with the simulator
-- ------------------------------------------------------------------
-- The simulator does NOT natively emit vehicle_alerts.  We
-- inject synthetic alert rows directly into vehicle_alerts.
--
-- Step 1 — Verify the table exists
--   SELECT COUNT(*) FROM vehicle_alerts;
--
-- Step 2 — Inject a mix of synthetic alerts
--   INSERT INTO vehicle_alerts (ts, vin, name, audience, started_at, ended_at)
--   VALUES
--     (NOW() - INTERVAL '2 hours', 'SIMULATEDVIN001', 'UI_a006', 'Service', NOW() - INTERVAL '2 hours', NULL),
--     (NOW() - INTERVAL '1 day',    'SIMULATEDVIN001', 'BMS_u018', 'Service', NOW() - INTERVAL '1 day', NULL),
--     (NOW() - INTERVAL '3 days',   'SIMULATEDVIN001', 'BMS_a001', 'Customer', NOW() - INTERVAL '3 days', NOW() - INTERVAL '2 days'),
--     (NOW() - INTERVAL '5 days',   'SIMULATEDVIN001', 'PCS_a016', 'Service', NOW() - INTERVAL '5 days', NOW() - INTERVAL '4 days'),
--     (NOW() - INTERVAL '7 days',   'SIMULATEDVIN001', 'DI_u003', 'Service', NOW() - INTERVAL '7 days', NULL),
--     (NOW() - INTERVAL '10 days',  'SIMULATEDVIN001', 'BMS_f064', 'Service', NOW() - INTERVAL '10 days', NOW() - INTERVAL '9 days'),
--     (NOW() - INTERVAL '14 days',  'SIMULATEDVIN001', 'CC_a001', 'Customer', NOW() - INTERVAL '14 days', NULL),
--     (NOW() - INTERVAL '1 hour',   'SIMULATEDVIN001', 'CH_u001', 'Service', NOW() - INTERVAL '1 hour', NULL);
--
-- Step 3 — Refresh CAGGs
--   CALL refresh_continuous_aggregate('alert_frequency_1d',
--     NOW() - INTERVAL '30 days', NOW());
--   CALL refresh_continuous_aggregate('alert_frequency_1w',
--     NOW() - INTERVAL '90 days', NOW());
--
-- Step 4 — Verify parsed output
--   SELECT alert_code, severity, subsystem, is_active, description
--   FROM parsed_alerts
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC;
--
-- Step 5 — Verify history summary
--   SELECT alert_code, severity, recurrence_count, active_count, first_seen, last_seen
--   FROM alert_history_summary
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY severity, recurrence_count DESC;
--
-- Step 6 — Verify critical snapshot
--   SELECT * FROM alert_critical_active
--   WHERE vin = 'SIMULATEDVIN001';
--
-- Step 7 — Simulate a BMS alert spike
--   INSERT INTO vehicle_alerts (ts, vin, name, audience, started_at, ended_at)
--   SELECT generate_series(
--     NOW() - INTERVAL '3 days',
--     NOW(),
--     INTERVAL '4 hours'
--   ), 'SIMULATEDVIN001', 'BMS_a00' || (random()*3)::int, 'Customer', generate_series(
--     NOW() - INTERVAL '3 days',
--     NOW(),
--     INTERVAL '4 hours'
--   ), NULL;
--
--   CALL refresh_continuous_aggregate('alert_frequency_1d',
--     NOW() - INTERVAL '7 days', NOW());
--
--   SELECT ts, subsystem, daily_alerts, alert_rate_7d, alert_rate_30d, subsystem_status
--   FROM alert_subsystem_trends
--   WHERE vin = 'SIMULATEDVIN001'
--     AND subsystem = 'BMS'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 8 — Clean up
--   DELETE FROM vehicle_alerts WHERE vin = 'SIMULATEDVIN001';
--   SELECT remove_continuous_aggregate_policy('alert_frequency_1d');
--   DROP MATERIALIZED VIEW alert_frequency_1d CASCADE;
--   -- then re-create from this file.
-- ------------------------------------------------------------------
