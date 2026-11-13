-- ============================================================
-- 053_owner_decisions.sql — brake estimate, dashcam alert, LFP brick
-- spread (owner decisions after 051)
--
-- a) Brakes. brake_wear_estimate is odometer / an assumed 50,000-mile
--    pad life, scaled by regen. Without a recorded pad replacement it
--    counted the whole odometer and showed CRITICAL. Now:
--      * service_intervals gains 'brake_pads' (so the bot offers it when
--        a service is logged; the 50,000 mi interval is the model's own
--        assumption, shown as the description says);
--      * brake_wear_estimate measures wear from the newest brake_pads
--        service_completions odometer when there is one (wear_basis
--        SINCE_PAD_REPLACEMENT) and otherwise from the whole odometer
--        (NO_PAD_RECORD); appended columns pad_replaced_at,
--        pad_replaced_odometer_mi, wear_basis;
--      * predictive_health_recommendations: with NO_PAD_RECORD the Brakes
--        row is INFO, worded "estimate only — no pad replacement on
--        record; log one to calibrate"; with a record the normal bands
--        apply. The Brakes row has never been part of the headline
--        severity (051 computes that from the summary scores only).
-- b) UI_a111 (dashcam USB drive not SuperSpeed) is INFO, as an explicit
--    code rule at the top of parsed_alerts' severity CASE. The daily
--    series now takes alert severities from parsed_alerts too; the
--    alert_frequency_1d continuous aggregate (dashboard 12's frequency
--    charts) keeps the old classification.
-- c) Brick spread on LFP. 046 made the spread simultaneous; LFP cells
--    still spread near full charge by nature. For LFP packs
--    battery_capacity_1d now uses only samples whose carried-forward
--    state of charge (last Soc at or before the sample) is below 90 %.
--    On the production copy that leaves 42 of 150 days above 0.3 V
--    (64 before the gate; 42 of the 113 days with such samples), still a
--    large share, so no new threshold is guessed: the gate stays, and for
--    LFP the brick spread no longer adds to the battery score (+15 above
--    0.3 V) or to thermal_risk. Other chemistries unchanged.
-- d) vehicle_state_1h (046) is rebuilt in full each hour (about 3 s on
--    six months of one vehicle); make it incremental once that refresh
--    exceeds about 30 s.
--
-- Views are restated in full (CREATE OR REPLACE, same columns, plus the
-- three appended brake_wear_estimate columns); matviews are rebuilt or
-- refreshed at the end. Idempotent.
-- ============================================================

-- ft_rebuild_capture (046) walked pg_depend with UNION ALL; pg_depend has
-- one row per referenced column, so with the predictive-health chain in
-- place the number of paths exploded and the capture ran for minutes.
-- UNION keeps one row per (object, depth).
CREATE OR REPLACE FUNCTION ft_rebuild_capture(roots text[])
RETURNS int LANGUAGE plpgsql SET search_path = public, pg_catalog AS $$
DECLARE n int;
BEGIN
  WITH RECURSIVE deps AS (
    SELECT c.oid, 0 AS lvl
    FROM pg_class c
    WHERE c.relnamespace = 'public'::regnamespace AND c.relname = ANY (roots)
    UNION
    SELECT dep.oid, d.lvl + 1
    FROM deps d
    JOIN pg_depend pd ON pd.refobjid = d.oid AND pd.classid = 'pg_rewrite'::regclass
    JOIN pg_rewrite r ON r.oid = pd.objid
    JOIN pg_class dep ON dep.oid = r.ev_class
    WHERE dep.oid <> d.oid AND d.lvl < 20
  ), dd AS (
    SELECT oid, MAX(lvl) AS depth FROM deps WHERE lvl > 0 GROUP BY oid
  )
  INSERT INTO ft_view_rebuild (name, kind, depth, def, indexdefs, comment)
  SELECT c.relname, c.relkind, dd.depth, pg_get_viewdef(c.oid, true),
         COALESCE((SELECT array_agg(pg_get_indexdef(i.indexrelid)) FROM pg_index i WHERE i.indrelid = c.oid), '{}'),
         obj_description(c.oid, 'pg_class')
  FROM dd JOIN pg_class c ON c.oid = dd.oid
  WHERE c.relkind IN ('v', 'm')
    AND NOT (c.relname = ANY (roots))
  ON CONFLICT (name) DO UPDATE
    SET depth = GREATEST(ft_view_rebuild.depth, EXCLUDED.depth);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- a) service item for pad replacements
INSERT INTO service_intervals (item, description, interval_months, interval_miles, severity, applies_to)
VALUES ('brake_pads',
        'Brake pads replaced (record it to calibrate the wear estimate; the 50,000 mi interval is the estimate''s assumption, not a Tesla schedule)',
        NULL, 50000, 'CAUTION', 'all')
ON CONFLICT (item) DO NOTHING;

-- b) parsed_alerts — 034 body plus the UI_a111 rule (columns unchanged)
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
    -- Explicit code rules first. UI_a111 (dashcam USB drive not
    -- SuperSpeed) is informational: it says nothing about the vehicle's
    -- health and was holding the alert score at 25 (053).
    WHEN a.name = 'UI_a111' OR a.name LIKE 'UI\_a111\_%' THEN 'INFO'
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

-- a) brake wear from the recorded pad replacement
CREATE OR REPLACE VIEW brake_wear_estimate AS
WITH latest AS (
  SELECT vin, MAX(bucket) AS last_bucket
  FROM regen_brake_daily_1d
  WHERE odometer IS NOT NULL
  GROUP BY vin
),
pads AS (   -- newest recorded brake-pad replacement (bot: service item brake_pads)
  SELECT DISTINCT ON (vin) vin, completed_at, odometer_mi
  FROM service_completions
  WHERE item = 'brake_pads'
  ORDER BY vin, completed_at DESC, id DESC
),
snapshot AS (
  SELECT
    d.vin,
    d.odometer,
    d.lifetime_energy_used_drive,
    d.lifetime_energy_gained_regen,
    CASE WHEN (d.lifetime_energy_gained_regen + d.lifetime_energy_used_drive) > 0
      THEN d.lifetime_energy_gained_regen
           / (d.lifetime_energy_gained_regen + d.lifetime_energy_used_drive)
      ELSE 0
    END AS regen_ratio,
    (SELECT regen_ratio_30d_avg / 100
     FROM regen_brake_diagnostics diag
     WHERE diag.vin = d.vin AND diag.ts = d.bucket
     LIMIT 1) AS recent_regen_ratio,
    p.completed_at AS pad_replaced_at,
    p.odometer_mi  AS pad_replaced_odometer_mi,
    -- miles on the current pads: since the recorded replacement when there
    -- is one with a usable odometer, otherwise the whole odometer
    CASE WHEN p.odometer_mi IS NOT NULL AND p.odometer_mi <= d.odometer
         THEN d.odometer - p.odometer_mi ELSE d.odometer END AS pad_miles
  FROM regen_brake_daily_1d d
  JOIN latest l ON l.vin = d.vin AND l.last_bucket = d.bucket
  LEFT JOIN pads p ON p.vin = d.vin
)
SELECT
  vin,
  ROUND(odometer::numeric, 1) AS odometer_mi,
  ROUND((odometer * 1.60934)::numeric, 1) AS odometer_km,
  ROUND(lifetime_energy_used_drive::numeric, 2) AS lifetime_drive_kwh,
  ROUND(lifetime_energy_gained_regen::numeric, 2) AS lifetime_regen_kwh,
  ROUND((regen_ratio * 100)::numeric, 1) AS lifetime_regen_ratio_pct,
  ROUND((COALESCE(recent_regen_ratio, regen_ratio) * 100)::numeric, 1) AS recent_regen_ratio_pct,
  ROUND(LEAST(100, GREATEST(0,
      pad_miles / 50000.0 * (1 - COALESCE(recent_regen_ratio, regen_ratio)) * 100
    ))::numeric, 1) AS wear_pct,
  ROUND(LEAST(100, GREATEST(0,
      100 - (pad_miles / 50000.0 * (1 - COALESCE(recent_regen_ratio, regen_ratio)) * 100)
    ))::numeric, 1) AS remaining_pct,
  ROUND(GREATEST(0, 50000.0 / NULLIF(1 - COALESCE(recent_regen_ratio, regen_ratio), 0) - pad_miles)::numeric, 0)
    AS estimated_remaining_mi,
  CASE
    WHEN COALESCE(recent_regen_ratio, regen_ratio) > 0.30 THEN 'Heavy Regen — extended pad life'
    WHEN COALESCE(recent_regen_ratio, regen_ratio) > 0.20 THEN 'Normal Regen — typical pad life'
    WHEN COALESCE(recent_regen_ratio, regen_ratio) > 0.10 THEN 'Light Regen — reduced pad life'
    ELSE 'Very Light Regen — inspect pads frequently'
  END AS brake_style_assessment,
  -- appended (053)
  pad_replaced_at,
  ROUND(pad_replaced_odometer_mi::numeric, 1) AS pad_replaced_odometer_mi,
  CASE WHEN pad_replaced_odometer_mi IS NOT NULL AND pad_replaced_odometer_mi <= odometer
       THEN 'SINCE_PAD_REPLACEMENT' ELSE 'NO_PAD_RECORD' END AS wear_basis
FROM snapshot;

-- ------------------------------------------------------------------
-- c) battery_capacity_1d with the LFP state-of-charge gate. Same
--    columns as 046; dependents captured and recreated.
-- ------------------------------------------------------------------
SELECT ft_rebuild_capture(ARRAY['battery_capacity_1d']) AS captured_dependents;
SELECT ft_rebuild_drop(ARRAY['battery_capacity_1d']);

CREATE MATERIALIZED VIEW battery_capacity_1d AS
WITH tagged AS (
  SELECT s.bucket, s.vin,
    s.energy_remaining_last, s.battery_level_last, s.ideal_range_last, s.rated_range_last,
    (st.at_rest IS TRUE
     AND ABS(COALESCE(s.pack_current_avg, 0) * COALESCE(s.pack_voltage_avg, 0)) < 500) AS is_rest
  FROM battery_samples_1h s
  LEFT JOIN vehicle_state_1h st ON st.vin = s.vin AND st.bucket = s.bucket
), pairs AS (
  -- BrickVoltageMax and BrickVoltageMin from the same payload only (046)
  SELECT a.vin, a.ts, a.num_value - b.num_value AS delta
  FROM telemetry a
  JOIN telemetry b ON b.vin = a.vin AND b.ts = a.ts AND b.field = 'BrickVoltageMin'
  WHERE a.field = 'BrickVoltageMax' AND a.num_value IS NOT NULL AND b.num_value IS NOT NULL
), gated AS (
  -- LFP: only samples taken below 90 % state of charge (053)
  SELECT p.vin, p.ts, p.delta
  FROM pairs p
  LEFT JOIN vehicle_metadata vm ON vm.vin = p.vin
  WHERE vm.battery_type IS DISTINCT FROM 'LFP'
     OR (SELECT s.num_value FROM telemetry s
         WHERE s.vin = p.vin AND s.field = 'Soc' AND s.ts <= p.ts
         ORDER BY s.ts DESC LIMIT 1) < 90
), brick AS (
  SELECT vin, time_bucket('1 day', ts) AS bucket,
         MAX(delta) AS brick_delta_max, AVG(delta) AS brick_delta_avg
  FROM gated
  GROUP BY 1, 2
), daily AS (
  SELECT time_bucket('1 day', bucket) AS bucket, vin,
    COUNT(*) FILTER (WHERE is_rest) AS rest_hours,
    LAST(energy_remaining_last, bucket) FILTER (WHERE is_rest AND battery_level_last > 0) AS energy_remaining_rest,
    LAST(battery_level_last, bucket)    FILTER (WHERE is_rest AND battery_level_last > 0) AS battery_level_rest,
    LAST(ideal_range_last, bucket)      FILTER (WHERE is_rest) AS ideal_range_rest,
    LAST(rated_range_last, bucket)      FILTER (WHERE is_rest) AS rated_range_rest
  FROM tagged
  GROUP BY 1, 2
)
SELECT d.bucket, d.vin, d.rest_hours, d.energy_remaining_rest, d.battery_level_rest,
       d.ideal_range_rest, d.rated_range_rest, b.brick_delta_max, b.brick_delta_avg
FROM daily d
LEFT JOIN brick b ON b.vin = d.vin AND b.bucket = d.bucket;
CREATE UNIQUE INDEX IF NOT EXISTS battery_capacity_1d_uq ON battery_capacity_1d (vin, bucket);

SELECT ft_rebuild_restore() AS recreated_dependents;

-- b) daily series: alert severities from parsed_alerts
CREATE OR REPLACE VIEW predictive_health_score_1d_live AS
WITH vm AS (
  SELECT vin, model, motor_config, has_heat_pump FROM vehicle_metadata
),
bat AS (   -- full-charge estimator (049), weekly points
  SELECT t.ts, t.vin,
    subsystem_risk_score(
      CASE WHEN t.capacity_degradation_pct > 10 THEN 'BATTERY_CAPACITY_DEGRADED' ELSE 'NORMAL' END,
      NULL, GREATEST(0, t.capacity_degradation_pct)::double precision, NULL) AS score
  FROM battery_full_charge_trend t
  WHERE t.capacity_degradation_pct IS NOT NULL
),
drv AS (
  SELECT ts, vin, subsystem_risk_score(status, NULL, GREATEST(0, -COALESCE(regen_degradation_pct, 0))) AS score
  FROM drivetrain_diagnostics
),
alt AS (   -- per day of alert start, severities from parsed_alerts (053: the CAGG keeps the old classification)
  SELECT date_trunc('day', COALESCE(started_at, ts)) AS ts, vin,
    CASE
      WHEN COUNT(*) FILTER (WHERE severity = 'CRITICAL') > 0 THEN 100
      WHEN COUNT(*) FILTER (WHERE severity = 'URGENT') > 0 THEN 75
      WHEN COUNT(*) FILTER (WHERE severity = 'WARNING') >= 3 THEN 50
      WHEN COUNT(*) FILTER (WHERE severity = 'WARNING') > 0 THEN 25
      ELSE 5
    END AS score
  FROM parsed_alerts
  GROUP BY 1, 2
),
lv AS (
  SELECT ts, vin, subsystem_risk_score(status) AS score FROM low_voltage_diagnostics
),
hp AS (
  SELECT d.ts, d.vin, subsystem_risk_score(d.status, NULL, GREATEST(0, COALESCE(d.trend_pct, 0))) AS score
  FROM heat_pump_diagnostics d
  WHERE d.status NOT IN ('NO_DATA', 'NOT_APPLICABLE')
),
rb AS (
  SELECT ts, vin,
    subsystem_risk_score(status, NULL,
      GREATEST(GREATEST(0, -COALESCE(regen_torque_trend_pct, 0)), GREATEST(0, COALESCE(eff_trend_pct, 0)))) AS score
  FROM regen_brake_diagnostics
),
sus AS (
  SELECT ts, vin, subsystem_risk_score(suspension_status) AS score FROM suspension_diagnostics
),
pcs AS (   -- 047: per AC session day
  SELECT date_trunc('day', started) AS ts, vin,
    MAX(CASE WHEN flagged THEN 60 ELSE 5 END) AS score
  FROM pcs_charge_sessions
  GROUP BY 1, 2
),
dm AS (
  SELECT ts, vin,
    subsystem_risk_score(status, severity,
      GREATEST(GREATEST(0, COALESCE(temp_delta_trend_pct, 0)), GREATEST(0, -COALESCE(regen_trend_pct, 0)))) AS score
  FROM dual_motor_diagnostics
  WHERE status <> 'NOT_APPLICABLE'
),
ct AS (
  SELECT ts, vin, subsystem_risk_score(status, severity, NULL::double precision) AS score
  FROM cybertruck_diagnostics
  WHERE model = 'CT' AND status <> 'NOT_APPLICABLE'
),
all_scores AS (
  SELECT ts, vin, 'battery'::text AS sub, score FROM bat
  UNION ALL SELECT ts, vin, 'drivetrain',  score FROM drv
  UNION ALL SELECT ts, vin, 'alerts',      score FROM alt
  UNION ALL SELECT ts, vin, 'low_voltage', score FROM lv
  UNION ALL SELECT ts, vin, 'heat_pump',   score FROM hp
  UNION ALL SELECT ts, vin, 'regen_brake', score FROM rb
  UNION ALL SELECT ts, vin, 'suspension',  score FROM sus
  UNION ALL SELECT ts, vin, 'pcs',         score FROM pcs
  UNION ALL SELECT ts, vin, 'dual_motor',  score FROM dm
  UNION ALL SELECT ts, vin, 'cybertruck',  score FROM ct
),
gated AS (
  SELECT s.ts, s.vin, s.sub, s.score
  FROM all_scores s
  LEFT JOIN vm ON vm.vin = s.vin
  WHERE subsystem_applies(s.sub, vm.model, vm.motor_config, vm.has_heat_pump)
),
per_day AS (
  SELECT ts, vin,
    MAX(score) FILTER (WHERE sub = 'battery')     AS battery_score,
    MAX(score) FILTER (WHERE sub = 'drivetrain')  AS drivetrain_score,
    MAX(score) FILTER (WHERE sub = 'alerts')      AS alert_score,
    MAX(score) FILTER (WHERE sub = 'low_voltage') AS low_voltage_score,
    MAX(score) FILTER (WHERE sub = 'heat_pump')   AS heat_pump_score,
    MAX(score) FILTER (WHERE sub = 'regen_brake') AS regen_brake_score,
    MAX(score) FILTER (WHERE sub = 'suspension')  AS suspension_score,
    MAX(score) FILTER (WHERE sub = 'pcs')         AS pcs_score,
    MAX(score) FILTER (WHERE sub = 'dual_motor')  AS dual_motor_score,
    MAX(score) FILTER (WHERE sub = 'cybertruck')  AS cybertruck_score
  FROM gated
  GROUP BY ts, vin
),
ranked AS (
  SELECT p.*,
    weighted_mean(
      ARRAY[battery_score, drivetrain_score, alert_score, low_voltage_score, heat_pump_score,
            regen_brake_score, suspension_score, pcs_score, dual_motor_score, cybertruck_score]::numeric[],
      ARRAY[subsystem_weight('battery'), subsystem_weight('drivetrain'), subsystem_weight('alerts'),
            subsystem_weight('low_voltage'), subsystem_weight('heat_pump'), subsystem_weight('regen_brake'),
            subsystem_weight('suspension'), subsystem_weight('pcs'), subsystem_weight('dual_motor'),
            subsystem_weight('cybertruck')]) AS overall_risk_score,
    GREATEST(battery_score, drivetrain_score, alert_score, low_voltage_score, heat_pump_score,
             regen_brake_score, suspension_score, pcs_score, dual_motor_score, cybertruck_score) AS max_score
  FROM per_day p
)
SELECT r.ts, r.vin,
  r.battery_score, r.drivetrain_score, r.alert_score, r.low_voltage_score, r.heat_pump_score,
  r.regen_brake_score, r.suspension_score, r.pcs_score, r.dual_motor_score, r.cybertruck_score,
  r.overall_risk_score,
  CASE WHEN r.max_score >= 40 THEN
    CASE r.max_score
      WHEN r.battery_score     THEN 'Battery'
      WHEN r.alert_score       THEN 'Alerts'
      WHEN r.drivetrain_score  THEN 'Drivetrain'
      WHEN r.low_voltage_score THEN '12V Battery'
      WHEN r.heat_pump_score   THEN 'Heat Pump'
      WHEN r.regen_brake_score THEN 'Regen/Brake'
      WHEN r.pcs_score         THEN 'PCS'
      WHEN r.dual_motor_score  THEN 'Dual Motor'
      WHEN r.suspension_score  THEN 'Suspension'
      WHEN r.cybertruck_score  THEN 'Cybertruck'
    END
  END AS highest_risk_subsystem,
  risk_band(r.overall_risk_score) AS overall_band,
  vm.model
FROM ranked r
LEFT JOIN vm ON vm.vin = r.vin;

-- c) summary: no brick-spread contribution for LFP
CREATE OR REPLACE VIEW predictive_health_summary_live AS
WITH v AS (
  SELECT vin, model, battery_type, motor_config, has_heat_pump FROM vehicle_metadata
),
fresh AS (   -- vehicle reporting at all: the evidence for "no active alerts"
  SELECT v.vin, lt.ts AS reported_ts
  FROM v
  LEFT JOIN LATERAL (SELECT t.ts FROM telemetry t WHERE t.vin = v.vin ORDER BY t.ts DESC LIMIT 1) lt ON TRUE
),
bfc AS (
  SELECT vin, MAX(peak_ts) AS last_ts FROM battery_full_charge_weekly GROUP BY vin
),
raw AS (
  SELECT
    v.vin, v.model, v.battery_type, v.motor_config, v.has_heat_pump,
    -- battery: full-charge estimator + simultaneous brick spread + BMS alerts
    bfc.last_ts AS battery_last_ts,
    -- 053: no brick-spread modifier for LFP packs (see header)
    subsystem_risk_score(b.overall_status, b.max_alert_severity,
                         GREATEST(0, b.capacity_degradation_pct)::double precision,
                         CASE WHEN v.battery_type = 'LFP' THEN NULL ELSE b.last_day_brick_delta_max END) AS battery_raw,
    d.last_ts AS drivetrain_last_ts,
    subsystem_risk_score(d.status, NULL, GREATEST(0, -COALESCE(d.regen_degradation_pct, 0))) AS drivetrain_raw,
    -- evidence for the alert score: the vehicle reporting at all, or an active alert itself
    GREATEST(f.reported_ts, a.latest_active_ts) AS alerts_last_ts,
    CASE
      WHEN COALESCE(a.critical_active, 0) > 0 THEN 100
      WHEN COALESCE(a.urgent_active, 0) > 0 THEN 75
      WHEN COALESCE(a.warning_active, 0) >= 3 THEN 50
      WHEN COALESCE(a.warning_active, 0) > 0 THEN 25
      ELSE 5
    END AS alerts_raw,
    lv.last_ts AS low_voltage_last_ts,
    subsystem_risk_score(lv.status) AS low_voltage_raw,
    hp.last_ts AS heat_pump_last_ts,
    CASE WHEN hp.status NOT IN ('NO_DATA', 'NOT_APPLICABLE')
         THEN subsystem_risk_score(hp.status, NULL, GREATEST(0, COALESCE(hp.trend_pct, 0))) END AS heat_pump_raw,
    rb.last_ts AS regen_brake_last_ts,
    subsystem_risk_score(rb.status, NULL,
      GREATEST(GREATEST(0, -COALESCE(rb.regen_torque_trend_pct, 0)), GREATEST(0, COALESCE(rb.eff_trend_pct, 0)))) AS regen_brake_raw,
    GREATEST(s.last_diag_ts, CASE WHEN s.active_alert_count > 0 THEN f.reported_ts END) AS suspension_last_ts,
    CASE WHEN s.overall_status <> 'NO_DATA'
         THEN subsystem_risk_score(s.overall_status, NULLIF(s.max_alert_severity, 'NONE')) END AS suspension_raw,
    dm.last_ts AS dual_motor_last_ts,
    CASE WHEN dm.status <> 'NOT_APPLICABLE'
         THEN subsystem_risk_score(dm.status, dm.severity,
                GREATEST(GREATEST(0, COALESCE(dm.temp_delta_trend_pct, 0)), GREATEST(0, -COALESCE(dm.regen_trend_pct, 0)))) END AS dual_motor_raw,
    ct.last_ts AS cybertruck_last_ts,
    subsystem_risk_score(ct.overall_severity, ct.overall_severity) AS cybertruck_raw,
    pcs.last_session_ts AS pcs_last_ts,
    subsystem_risk_score(pcs.status) AS pcs_raw,
    -- context
    a.critical_active, a.urgent_active, a.warning_active, a.total_active, a.critical_codes, a.urgent_codes,
    b.capacity_degradation_pct, b.last_day_brick_delta_max,
    d.inverter_temp_max, d.regen_degradation_pct,
    rb.brake_remaining_pct, rb.eff_trend_pct,
    hp.trend_pct AS heat_pump_trend_pct,
    s.lat_std_trend_pct AS suspension_lat_std_trend_pct,
    dm.temp_delta_trend_pct AS dual_motor_temp_delta_trend_pct,
    dm.regen_trend_pct AS dual_motor_regen_trend_pct
  FROM v
  LEFT JOIN fresh f                     ON f.vin = v.vin
  LEFT JOIN bfc                         ON bfc.vin = v.vin
  LEFT JOIN battery_health_summary b    ON b.vin = v.vin
  LEFT JOIN drivetrain_summary d        ON d.vin = v.vin
  LEFT JOIN alert_critical_active a     ON a.vin = v.vin
  LEFT JOIN low_voltage_status lv       ON lv.vin = v.vin
  LEFT JOIN heat_pump_status hp         ON hp.vin = v.vin
  LEFT JOIN regen_brake_summary rb      ON rb.vin = v.vin
  LEFT JOIN suspension_summary s        ON s.vin = v.vin
  LEFT JOIN dual_motor_summary dm       ON dm.vin = v.vin
  LEFT JOIN cybertruck_summary ct       ON ct.vin = v.vin
  LEFT JOIN pcs_status_summary pcs      ON pcs.vin = v.vin
),
-- A score counts only when the subsystem applies and its evidence is
-- within the subsystem's limit.
scores AS (
  SELECT r.*,
    CASE WHEN subsystem_applies('battery', model, motor_config, has_heat_pump)
          AND battery_last_ts > now() - subsystem_evidence_limit('battery') THEN battery_raw END AS battery_score,
    CASE WHEN drivetrain_last_ts > now() - subsystem_evidence_limit('drivetrain') THEN drivetrain_raw END AS drivetrain_score,
    CASE WHEN alerts_last_ts > now() - subsystem_evidence_limit('alerts') THEN alerts_raw END AS alert_score,
    CASE WHEN low_voltage_last_ts > now() - subsystem_evidence_limit('low_voltage') THEN low_voltage_raw END AS low_voltage_score,
    CASE WHEN subsystem_applies('heat_pump', model, motor_config, has_heat_pump)
          AND heat_pump_last_ts > now() - subsystem_evidence_limit('heat_pump') THEN heat_pump_raw END AS heat_pump_score,
    CASE WHEN regen_brake_last_ts > now() - subsystem_evidence_limit('regen_brake') THEN regen_brake_raw END AS regen_brake_score,
    CASE WHEN suspension_last_ts > now() - subsystem_evidence_limit('suspension') THEN suspension_raw END AS suspension_score,
    CASE WHEN subsystem_applies('dual_motor', model, motor_config, has_heat_pump)
          AND dual_motor_last_ts > now() - subsystem_evidence_limit('dual_motor') THEN dual_motor_raw END AS dual_motor_score,
    CASE WHEN subsystem_applies('cybertruck', model, motor_config, has_heat_pump)
          AND cybertruck_last_ts > now() - subsystem_evidence_limit('cybertruck') THEN cybertruck_raw END AS cybertruck_score,
    CASE WHEN pcs_last_ts > now() - subsystem_evidence_limit('pcs') THEN pcs_raw END AS pcs_score
  FROM raw r
),
ranked AS (
  SELECT s.*,
    ARRAY[battery_score, drivetrain_score, alert_score, low_voltage_score, heat_pump_score,
          regen_brake_score, suspension_score, dual_motor_score, cybertruck_score, pcs_score]::numeric[] AS sc,
    ARRAY[subsystem_weight('battery'), subsystem_weight('drivetrain'), subsystem_weight('alerts'),
          subsystem_weight('low_voltage'), subsystem_weight('heat_pump'), subsystem_weight('regen_brake'),
          subsystem_weight('suspension'), subsystem_weight('dual_motor'), subsystem_weight('cybertruck'),
          subsystem_weight('pcs')] AS wt,
    GREATEST(battery_score, drivetrain_score, alert_score, low_voltage_score, heat_pump_score,
             regen_brake_score, suspension_score, dual_motor_score, cybertruck_score, pcs_score) AS max_score,
    -- brick spread 0 V -> 0, 0.5 V -> 100, only with fresh battery evidence
    CASE WHEN battery_score IS NOT NULL AND battery_type IS DISTINCT FROM 'LFP'
         THEN LEAST(100, GREATEST(0, COALESCE(last_day_brick_delta_max, 0) * 200)) END AS brick_delta_score
  FROM scores s
),
final AS (
  SELECT r.*,
    weighted_mean(sc, wt) AS overall_risk_score,
    (SELECT COUNT(*) FROM UNNEST(sc) x WHERE x IS NOT NULL)::int AS scored_subsystems,
    (SELECT SUM(w) FROM UNNEST(sc, wt) u(x, w) WHERE x IS NOT NULL) AS scored_weight,
    GREATEST(battery_last_ts, drivetrain_last_ts, low_voltage_last_ts, heat_pump_last_ts, regen_brake_last_ts,
             suspension_last_ts, dual_motor_last_ts, cybertruck_last_ts, pcs_last_ts) AS evidence_last_ts
  FROM ranked r
)
SELECT
  vin,
  battery_score, drivetrain_score, alert_score, low_voltage_score, heat_pump_score,
  regen_brake_score, suspension_score, dual_motor_score, cybertruck_score, pcs_score,
  battery_score AS battery_risk,
  weighted_mean(ARRAY[drivetrain_score, regen_brake_score, pcs_score]::numeric[], ARRAY[0.60, 0.25, 0.15]::numeric[]) AS powertrain_risk,
  weighted_mean(ARRAY[heat_pump_score, brick_delta_score]::numeric[], ARRAY[0.60, 0.40]::numeric[]) AS thermal_risk,
  overall_risk_score,
  evidence_last_ts AS telemetry_last_ts,
  ROUND((EXTRACT(EPOCH FROM (now() - evidence_last_ts)) / 3600.0)::numeric, 1) AS telemetry_age_h,
  CASE WHEN max_score >= 40 THEN
    CASE max_score
      WHEN battery_score     THEN 'Battery'
      WHEN alert_score       THEN 'Alerts'
      WHEN drivetrain_score  THEN 'Drivetrain'
      WHEN low_voltage_score THEN '12V Battery'
      WHEN heat_pump_score   THEN 'Heat Pump'
      WHEN regen_brake_score THEN 'Regen/Brake'
      WHEN pcs_score         THEN 'PCS'
      WHEN dual_motor_score  THEN 'Dual Motor'
      WHEN suspension_score  THEN 'Suspension'
      WHEN cybertruck_score  THEN 'Cybertruck'
    END
  END AS highest_risk_subsystem,
  COALESCE(critical_active, 0) AS critical_alerts,
  COALESCE(urgent_active, 0)   AS urgent_alerts,
  COALESCE(warning_active, 0)  AS warning_alerts,
  COALESCE(total_active, 0)    AS total_active_alerts,
  COALESCE(critical_codes, '') AS active_critical_codes,
  COALESCE(urgent_codes, '')   AS active_urgent_codes,
  CASE
    WHEN COALESCE(critical_active, 0) > 0
      THEN 'IMMEDIATE SERVICE — Critical alert: ' || COALESCE(critical_codes, '')
    -- any single subsystem at its critical band
    WHEN battery_score     >= 85 THEN 'Schedule battery service — capacity loss or cell imbalance at critical level'
    WHEN drivetrain_score  >= 85 THEN 'Schedule drivetrain inspection — inverter overheating or motor degradation'
    WHEN pcs_score         >= 85 THEN 'Have the charging system checked — AC charging repeatedly far below the requested current'
    WHEN low_voltage_score >= 85 THEN 'Have the 12V / low-voltage system diagnosed — DC-DC converter very active while parked'
    WHEN suspension_score  >= 85 THEN 'Inspect suspension and alignment — chassis alert or strong looseness signal'
    WHEN regen_brake_score >= 85 THEN 'Inspect regenerative braking — regen torque or efficiency well below baseline'
    WHEN heat_pump_score   >= 85 THEN 'Schedule HVAC inspection — heat-pump power per degree well above baseline'
    WHEN dual_motor_score  >= 85 THEN 'Inspect dual-motor system — severe front/rear imbalance or thermal throttling'
    WHEN cybertruck_score  >= 85 THEN 'Inspect Cybertruck systems — tonneau, V2L, tri-motor or 4680 pack issue'
    WHEN COALESCE(urgent_active, 0) > 0
      THEN 'Schedule service — Urgent alert: ' || COALESCE(urgent_codes, '')
    -- warning band
    WHEN battery_score     >= 60 THEN 'Book a battery health check at next service — capacity or imbalance trending worse'
    WHEN drivetrain_score  >= 60 THEN 'Monitor drivetrain temperatures and regen torque; check if the trend continues'
    WHEN pcs_score         >= 60 THEN 'Check the charging setup — AC charging drew well below the requested current in more than one session (supply, cable, connector, onboard charger)'
    WHEN low_voltage_score >= 60 THEN 'Have the 12V / low-voltage system diagnosed — DC-DC converter active unusually often while parked (activity proxy, not a battery test)'
    WHEN suspension_score  >= 60 THEN 'Schedule suspension inspection — rising lateral-acceleration variance or chassis alert'
    WHEN regen_brake_score >= 60 THEN 'Check regenerative braking — regen torque or efficiency trending down'
    WHEN heat_pump_score   >= 60 THEN 'Schedule HVAC check — heat-pump power per degree drifting up'
    WHEN dual_motor_score  >= 60 THEN 'Schedule dual-motor inspection — front/rear imbalance or regen degradation'
    WHEN cybertruck_score  >= 60 THEN 'Schedule Cybertruck inspection — tonneau, V2L or tri-motor anomaly'
    WHEN overall_risk_score IS NULL
      THEN 'No recent diagnostic data — check that telemetry is arriving'
    WHEN overall_risk_score >= 40
      THEN 'Plan preventive maintenance — several subsystems showing wear'
    ELSE 'No issues found in the subsystems with recent data'
  END AS recommended_action,
  model, battery_type, has_heat_pump,
  -- appended: evidence and headline
  CASE
    WHEN COALESCE(critical_active, 0) > 0 THEN 'CRITICAL'
    WHEN overall_risk_score IS NULL THEN 'NO_DATA'
    ELSE (ARRAY['NORMAL', 'NORMAL', 'CAUTION', 'WARNING', 'CRITICAL'])[1 + GREATEST(
            band_rank(risk_band(overall_risk_score)),
            band_rank(risk_band(max_score)),
            CASE WHEN COALESCE(critical_active, 0) > 0 THEN 4 ELSE 0 END)]
  END AS headline_severity,
  scored_subsystems,
  scored_weight,
  battery_last_ts, drivetrain_last_ts, alerts_last_ts, low_voltage_last_ts, heat_pump_last_ts,
  regen_brake_last_ts, suspension_last_ts, dual_motor_last_ts, cybertruck_last_ts, pcs_last_ts,
  capacity_degradation_pct, last_day_brick_delta_max, inverter_temp_max, regen_degradation_pct,
  brake_remaining_pct, eff_trend_pct, heat_pump_trend_pct, suspension_lat_std_trend_pct,
  dual_motor_temp_delta_trend_pct, dual_motor_regen_trend_pct
FROM final;

-- a) recommendations: Brakes INFO without a pad record
CREATE OR REPLACE VIEW predictive_health_recommendations AS
WITH s AS (SELECT * FROM predictive_health_summary),
arms AS (
  SELECT vin, 'Battery'::text AS subsystem, battery_risk AS risk_score, battery_last_ts AS evidence_ts,
    CASE WHEN battery_risk >= 85 THEN 'Schedule battery pack inspection — capacity fade > 10% or brick imbalance > 0.5 V'
         WHEN battery_risk >= 60 THEN 'Monitor battery health — schedule diagnostic scan at next service'
         WHEN battery_risk >= 40 THEN 'Watch the full-charge capacity trend; no action yet'
         ELSE 'No action required' END AS recommendation
  FROM s
  UNION ALL
  SELECT vin, 'Powertrain', powertrain_risk, GREATEST(drivetrain_last_ts, regen_brake_last_ts, pcs_last_ts),
    CASE WHEN powertrain_risk >= 85 THEN 'Schedule drivetrain inspection — inverter overheat or regen degradation detected'
         WHEN powertrain_risk >= 60 THEN 'Monitor motor temps and regen torque — schedule check if trend continues'
         WHEN powertrain_risk >= 40 THEN 'Keep an eye on drivetrain and charging trends'
         ELSE 'No action required' END
  FROM s
  UNION ALL
  SELECT vin, 'Thermal', thermal_risk, GREATEST(heat_pump_last_ts, battery_last_ts),
    CASE WHEN thermal_risk >= 85 THEN 'Inspect HVAC system — heat pump degradation or battery thermal imbalance'
         WHEN thermal_risk >= 60 THEN 'Check cabin filter and refrigerant levels — efficiency declining'
         WHEN thermal_risk >= 40 THEN 'Verify pre-conditioning settings — minor thermal inefficiency'
         ELSE 'No action required' END
  FROM s
  UNION ALL
  SELECT vin, '12V / Electrical', low_voltage_score, low_voltage_last_ts,
    CASE WHEN low_voltage_score >= 60 THEN 'Have the 12V / low-voltage system diagnosed — DC-DC converter active unusually often while parked (activity proxy, not a battery capacity test)'
         WHEN low_voltage_score >= 40 THEN 'Monitor 12V system — DC-DC activity while parked increasing'
         ELSE 'No action required' END
  FROM s
  UNION ALL
  SELECT vin, 'Suspension', suspension_score, suspension_last_ts,
    CASE WHEN suspension_score >= 85 THEN 'Immediate suspension check — chassis alert active'
         WHEN suspension_score >= 60 THEN 'Schedule suspension inspection — lateral-acceleration variance rising'
         ELSE 'No action required' END
  FROM s
  UNION ALL
  SELECT vin, 'Charging (PCS)', pcs_score, pcs_last_ts,
    CASE WHEN pcs_score >= 60 THEN 'Check the charging setup — AC charging drew well below the requested current in more than one session'
         WHEN pcs_score >= 40 THEN 'One AC session drew well below the requested current — watch the next sessions'
         ELSE 'No action required' END
  FROM s
  UNION ALL
  SELECT vin, 'Dual Motor', dual_motor_score, dual_motor_last_ts,
    CASE WHEN dual_motor_score >= 85 THEN 'Inspect dual-motor system immediately — severe imbalance or thermal throttling detected'
         WHEN dual_motor_score >= 60 THEN 'Schedule dual-motor inspection — front-rear imbalance, regen degradation, or throttle limiting'
         WHEN dual_motor_score >= 40 THEN 'Monitor dual-motor balance — slight temp delta or regen trend detected'
         ELSE 'No action required' END
  FROM s WHERE dual_motor_last_ts IS NOT NULL OR dual_motor_score IS NOT NULL
  UNION ALL
  SELECT vin, 'Cybertruck', cybertruck_score, cybertruck_last_ts,
    CASE WHEN cybertruck_score >= 85 THEN 'Inspect Cybertruck immediately — tonneau failure, severe tri-motor imbalance, or 4680 battery degradation'
         WHEN cybertruck_score >= 60 THEN 'Schedule Cybertruck inspection — tonneau, V2L or tri-motor issue detected'
         WHEN cybertruck_score >= 40 THEN 'Monitor Cybertruck subsystems — slight anomaly in tonneau, V2L, or tri-motor'
         ELSE 'No action required' END
  FROM s WHERE model = 'CT'
  UNION ALL
  SELECT vin, 'Brakes',
    LEAST(100, GREATEST(0, 100 - brake_remaining_pct))::numeric, regen_brake_last_ts,
    CASE WHEN brake_remaining_pct <= 25 THEN 'Have brake pads measured now — wear estimate since the recorded pad replacement below 25% remaining (assumes 50,000 mi pad life)'
         WHEN brake_remaining_pct <= 50 THEN 'Have brake pads measured at the next service — estimate since the recorded pad replacement near 50% remaining'
         WHEN brake_remaining_pct <= 75 THEN 'Inspect brake pads at next service'
         ELSE 'No action required' END
  FROM s
  UNION ALL
  SELECT i.vin, 'HV Isolation', subsystem_risk_score(i.status)::numeric, i.ts,
    CASE WHEN i.status = 'ISOLATION_RESISTANCE_LOW' THEN 'Have the HV isolation checked by Tesla service — isolation resistance below 100 kOhm (unvalidated threshold)'
         WHEN i.status = 'WARNING' THEN 'Monitor HV isolation resistance — below 250 kOhm (unvalidated threshold)'
         ELSE 'No action required' END
  FROM (SELECT DISTINCT ON (vin) vin, status, ts FROM isolation_resistance_diagnostics
        WHERE status <> 'NO_DATA' ORDER BY vin, ts DESC) i
)
SELECT arms.vin, subsystem, risk_score,
  CASE
    WHEN risk_score IS NULL THEN 'NO DATA'
    WHEN subsystem = 'Brakes' AND bw.wear_basis IS DISTINCT FROM 'SINCE_PAD_REPLACEMENT' THEN 'INFO'
    WHEN subsystem IN ('12V / Electrical', 'Charging (PCS)') AND risk_score >= 60 THEN 'WARNING'
    WHEN subsystem = 'Brakes' THEN
      CASE WHEN risk_score >= 75 THEN 'CRITICAL' WHEN risk_score >= 50 THEN 'WARNING'
           WHEN risk_score >= 25 THEN 'CAUTION' ELSE 'OK' END
    ELSE COALESCE(NULLIF(risk_band(risk_score), 'NORMAL'), 'OK')
  END AS severity,
  CASE WHEN risk_score IS NULL
       THEN 'No recent data for this subsystem (or it does not apply to this vehicle)'
       WHEN subsystem = 'Brakes' AND bw.wear_basis IS DISTINCT FROM 'SINCE_PAD_REPLACEMENT'
       THEN 'Estimate only — no pad replacement on record; log one to calibrate (mileage model: '
            || COALESCE(bw.wear_pct::text, '?') || '% worn assuming a 50,000 mi pad life)'
       ELSE recommendation END AS recommendation,
  evidence_ts
FROM arms
LEFT JOIN brake_wear_estimate bw ON bw.vin = arms.vin AND arms.subsystem = 'Brakes';

-- ------------------------------------------------------------------
-- Refresh the stored health views with the new bodies.
-- ------------------------------------------------------------------
SELECT refresh_one_matview('predictive_health_score_1d_mat') AS score_1d_refreshed;
SELECT refresh_one_matview('predictive_health_summary_mat')  AS summary_refreshed;
