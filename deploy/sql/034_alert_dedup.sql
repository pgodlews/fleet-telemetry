-- ============================================================
-- 034_alert_dedup.sql — one row per alert instance; alerts close (P3)
--
-- Before this file, writeAlerts plain-inserted every alert of every
-- message with ts = message time. The vehicle repeats active alerts in
-- later messages and resends unacknowledged records, so one alert
-- instance became tens of thousands of rows, and the message that
-- carried ended_at inserted yet another row instead of closing the open
-- one. parsed_alerts counted every open copy as active, forever.
--
-- This file, together with the matching datastore/postgres change
-- (writeAlerts/writeErrors upsert ON CONFLICT (vin, name, ts) with
-- ts = started_at / created_at), makes one instance one row:
--
--   1. Collapse existing vehicle_alerts rows to one per
--      (vin, name, started_at), keeping the latest non-null ended_at
--      and the latest non-empty audience; set ts = started_at.
--      Rows with no usable started_at (NULL or epoch) keep their own ts
--      and are deduplicated on that.
--   2. The same for vehicle_errors on (vin, name, created_at).
--   3. Unique indexes on (vin, name, ts) — the hypertable partition
--      column has to be part of any unique index, which is why ts must
--      be the deterministic event time.
--   4. parsed_alerts: an alert is active only if ended_at IS NULL and it
--      started within alert_active_window() (7 days, defined once
--      below). alert_critical_active inherits this. The same rewrite
--      reads charge_state_at_alert from DetailedChargeState (P2).
--   5. Refresh alert_frequency_1d over the full range and the weekly
--      rollup, outside the transaction (continuous aggregates cannot be
--      refreshed inside one).
--
-- Deploy with the new fleet-telemetry image: the old binary inserts with
-- ts = message time, which the unique index does not stop, so it would
-- keep creating duplicates. Re-running this file collapses them again.
--
-- Idempotent: steps 1-2 only rewrite when there is something to collapse.
-- ============================================================

-- One place for the "still active" window used by parsed_alerts.
CREATE OR REPLACE FUNCTION alert_active_window()
RETURNS interval
LANGUAGE sql IMMUTABLE AS $$ SELECT INTERVAL '7 days' $$;

COMMENT ON FUNCTION alert_active_window() IS
  'An alert with ended_at IS NULL counts as active only if it started within
   this window. Bounds the damage of an end event that never arrived.';

BEGIN;

DO $$
DECLARE
  n_before  bigint;
  n_after   bigint;
  n_groups  bigint;
BEGIN
  -- ---------------- vehicle_alerts ----------------
  SELECT COUNT(*) INTO n_before FROM vehicle_alerts;
  SELECT COUNT(*) INTO n_groups FROM (
    SELECT 1 FROM vehicle_alerts
    GROUP BY vin, name,
      CASE WHEN started_at >= TIMESTAMPTZ '2000-01-01' THEN started_at ELSE ts END
  ) g;
  RAISE NOTICE '034 vehicle_alerts: % rows, % instances', n_before, n_groups;

  IF n_before > n_groups OR EXISTS (
       SELECT 1 FROM vehicle_alerts
       WHERE started_at >= TIMESTAMPTZ '2000-01-01' AND ts <> started_at)
  THEN
    CREATE TEMP TABLE _alerts_dedup ON COMMIT DROP AS
    SELECT
      CASE WHEN started_at >= TIMESTAMPTZ '2000-01-01' THEN started_at ELSE ts END AS key_ts,
      vin,
      name,
      -- latest non-empty audience
      (ARRAY_AGG(audience ORDER BY ts DESC)
         FILTER (WHERE audience IS NOT NULL AND audience <> ''))[1] AS audience,
      MAX(started_at) FILTER (WHERE started_at >= TIMESTAMPTZ '2000-01-01') AS started_at,
      MAX(ended_at) AS ended_at
    FROM vehicle_alerts
    GROUP BY 1, vin, name;

    -- The old non-unique ts index stays; the unique index is created
    -- after the rewrite.
    DELETE FROM vehicle_alerts;
    INSERT INTO vehicle_alerts (ts, vin, name, audience, started_at, ended_at)
    SELECT key_ts, vin, name, audience, started_at, ended_at FROM _alerts_dedup;

    SELECT COUNT(*) INTO n_after FROM vehicle_alerts;
    RAISE NOTICE '034 vehicle_alerts: collapsed % rows to %', n_before, n_after;
  ELSE
    RAISE NOTICE '034 vehicle_alerts: nothing to collapse';
  END IF;

  -- ---------------- vehicle_errors ----------------
  SELECT COUNT(*) INTO n_before FROM vehicle_errors;
  SELECT COUNT(*) INTO n_groups FROM (
    SELECT 1 FROM vehicle_errors
    GROUP BY vin, name,
      CASE WHEN created_at >= TIMESTAMPTZ '2000-01-01' THEN created_at ELSE ts END
  ) g;
  RAISE NOTICE '034 vehicle_errors: % rows, % instances', n_before, n_groups;

  IF n_before > n_groups OR EXISTS (
       SELECT 1 FROM vehicle_errors
       WHERE created_at >= TIMESTAMPTZ '2000-01-01' AND ts <> created_at)
  THEN
    CREATE TEMP TABLE _errors_dedup ON COMMIT DROP AS
    SELECT DISTINCT ON (key_ts, vin, name)
      key_ts, vin, name, body, tags, created_at
    FROM (
      SELECT
        CASE WHEN created_at >= TIMESTAMPTZ '2000-01-01' THEN created_at ELSE ts END AS key_ts,
        vin, name, body, tags,
        CASE WHEN created_at >= TIMESTAMPTZ '2000-01-01' THEN created_at END AS created_at,
        ts
      FROM vehicle_errors
    ) e
    ORDER BY key_ts, vin, name, ts DESC;

    DELETE FROM vehicle_errors;
    INSERT INTO vehicle_errors (ts, vin, name, body, tags, created_at)
    SELECT key_ts, vin, name, body, tags, created_at FROM _errors_dedup;

    SELECT COUNT(*) INTO n_after FROM vehicle_errors;
    RAISE NOTICE '034 vehicle_errors: collapsed % rows to %', n_before, n_after;
  ELSE
    RAISE NOTICE '034 vehicle_errors: nothing to collapse';
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS vehicle_alerts_vin_name_ts_uq
  ON vehicle_alerts (vin, name, ts);
CREATE UNIQUE INDEX IF NOT EXISTS vehicle_errors_vin_name_ts_uq
  ON vehicle_errors (vin, name, ts);

COMMIT;

-- ------------------------------------------------------------------
-- parsed_alerts — same columns and order as 012; is_active bounded by
-- alert_active_window(); charge_state_at_alert from DetailedChargeState.
-- alert_critical_active, alert_history_summary and the dashboards read
-- through this view and need no change.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW parsed_alerts AS
SELECT
  a.ts,
  a.vin,
  a.name AS alert_code,
  a.audience,
  a.started_at,
  a.ended_at,
  -- Active = not ended AND started within alert_active_window(). An alert
  -- whose end event never arrived stops counting as active after the
  -- window instead of holding the headline red forever.
  (a.ended_at IS NULL
   AND COALESCE(a.started_at, a.ts) > now() - alert_active_window()) AS is_active,
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
  -- DetailedChargeState, not ChargeState: ChargeState carries the charger
  -- state machine (Idle/Enable/Startup/...) and never says "Charging".
  -- The proto prefix is stripped so the column reads 'Charging', 'Complete'.
  (SELECT regexp_replace(str_value, '^DetailedChargeState', '') FROM telemetry t
   WHERE t.vin = a.vin AND t.field = 'DetailedChargeState'
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
-- Rebuild the alert rollups from the collapsed table. Outside any
-- transaction block: TimescaleDB refuses to refresh a continuous
-- aggregate inside one.
-- ------------------------------------------------------------------
CALL refresh_continuous_aggregate('alert_frequency_1d', NULL, NULL);
REFRESH MATERIALIZED VIEW alert_frequency_1w;
