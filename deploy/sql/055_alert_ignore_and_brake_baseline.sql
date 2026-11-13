-- ============================================================
-- 055_alert_ignore_and_brake_baseline.sql — per-vehicle ignored alert
-- codes; original-pads baseline and brake inspections
--
-- 1. Ignored alert codes (data, not a rule). Some alerts are artefacts
--    of one installation (e.g. a Raspberry Pi emulating the dashcam USB
--    drive raises UI_a111 while it enumerates). 053's rule that classes
--    UI_a111 as INFO for everyone stays.
--      * pm_alert_ignore (vin, alert_code, reason, created_at; PK vin +
--        alert_code); ignore_alert_code(vin, code, reason) adds or
--        updates an entry, unignore_alert_code(vin, code) removes it.
--      * alert_is_ignored(vin, name) matches like 053: the exact code or
--        the code followed by an underscore suffix (UI_a111 matches
--        UI_a111_DashcamUsbDriveNotSuperSpeed).
--      * parsed_alerts.is_active is false for an ignored code, so it does
--        not count in alert_critical_active (total and per severity, the
--        summary's alert score and headline) or alert_history_summary's
--        active_count, and is not listed by the active-alert tables
--        (dashboards 12 and 14 filter on is_active). The daily score
--        series leaves ignored codes out. History keeps the rows;
--        dashboard 12 shows an "Ignored" column. parsed_alerts keeps its
--        columns (012/034 restate it on FORCE=1).
--
-- 2. Brake pads: "no information" vs "owner confirmed original pads".
--      * brake_pads_baseline (vin PK, confirmed_at, note) records the
--        owner's confirmation that the factory pads were never replaced;
--        confirmed_at is when it was confirmed, not a service date, and
--        no service_completions row is invented. Helper:
--        confirm_original_brake_pads(vin, note).
--      * brake_wear_estimate.wear_basis gains ORIGINAL_PADS_CONFIRMED
--        (wear over the whole odometer, as before, but now known); it
--        appends last_inspection_at, original_pads_confirmed_at,
--        pad_miles.
--      * New service item brake_inspection ("pads measured, OK", every
--        12 months): the bot offers it like the other items (its list
--        comes from service_intervals). An inspection in the last 12
--        months that is not older than the last replacement makes the
--        Brakes row OK with the date; after 12 months the estimate is back.
--      * The Brakes row is never CRITICAL (estimate only): capped at
--        WARNING for any basis; NO_PAD_RECORD stays INFO. It is not part
--        of the headline severity (it never was).
--
-- Idempotent.
-- ============================================================

-- ------------------------------------------------------------------
-- 1. Ignored alert codes
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pm_alert_ignore (
  vin        TEXT        NOT NULL,
  alert_code TEXT        NOT NULL,
  reason     TEXT        NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (vin, alert_code)
);
COMMENT ON TABLE pm_alert_ignore IS
  'Alert codes ignored for one vehicle (installation artefacts). An ignored
   code is never active; history keeps it (055).';

CREATE OR REPLACE FUNCTION alert_is_ignored(p_vin TEXT, p_name TEXT)
RETURNS boolean LANGUAGE sql STABLE SET search_path = public, pg_catalog AS $$
  SELECT EXISTS (
    SELECT 1 FROM pm_alert_ignore i
    WHERE i.vin = p_vin
      AND (p_name = i.alert_code
           OR p_name LIKE replace(replace(replace(i.alert_code, '\', '\\'), '_', '\_'), '%', '\%') || '\_%'))
$$;

CREATE OR REPLACE FUNCTION ignore_alert_code(p_vin TEXT, p_alert_code TEXT, p_reason TEXT)
RETURNS pm_alert_ignore LANGUAGE plpgsql SET search_path = public, pg_catalog AS $$
DECLARE r pm_alert_ignore;
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'a reason is required';
  END IF;
  INSERT INTO pm_alert_ignore (vin, alert_code, reason)
  VALUES (p_vin, p_alert_code, p_reason)
  ON CONFLICT (vin, alert_code) DO UPDATE SET reason = EXCLUDED.reason
  RETURNING * INTO r;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION unignore_alert_code(p_vin TEXT, p_alert_code TEXT)
RETURNS boolean LANGUAGE sql SET search_path = public, pg_catalog AS $$
  WITH d AS (DELETE FROM pm_alert_ignore WHERE vin = p_vin AND alert_code = p_alert_code RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM d)
$$;

-- ------------------------------------------------------------------
-- 2. Brake baseline and inspections
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS brake_pads_baseline (
  vin          TEXT        PRIMARY KEY,
  confirmed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  note         TEXT        NOT NULL
);
COMMENT ON TABLE brake_pads_baseline IS
  'Owner confirmation that the brake pads are the original factory set (never
   replaced). confirmed_at is when this was confirmed, not a service date (055).';

CREATE OR REPLACE FUNCTION confirm_original_brake_pads(p_vin TEXT, p_note TEXT)
RETURNS brake_pads_baseline LANGUAGE plpgsql SET search_path = public, pg_catalog AS $$
DECLARE r brake_pads_baseline;
BEGIN
  INSERT INTO brake_pads_baseline (vin, note) VALUES (p_vin, p_note)
  ON CONFLICT (vin) DO UPDATE SET note = EXCLUDED.note, confirmed_at = now()
  RETURNING * INTO r;
  RETURN r;
END $$;

INSERT INTO service_intervals (item, description, interval_months, interval_miles, severity, applies_to)
VALUES ('brake_inspection',
        'Brake inspection — pad thickness measured, OK (a measurement within 12 months clears the mileage estimate)',
        12, NULL, 'CAUTION', 'all')
ON CONFLICT (item) DO NOTHING;

-- An inspection counts while it is under 12 months old and not older
-- than the last recorded pad replacement.
CREATE OR REPLACE FUNCTION brake_inspection_current(p_inspected_at TIMESTAMPTZ, p_replaced_at TIMESTAMPTZ)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p_inspected_at IS NOT NULL
     AND p_inspected_at > now() - INTERVAL '12 months'
     AND (p_replaced_at IS NULL OR p_inspected_at >= p_replaced_at)
$$;

-- parsed_alerts — 053 body; ignored codes are never active (columns unchanged)
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
  -- 055: a code ignored for this vehicle (pm_alert_ignore) is never active.
  (a.ended_at IS NULL
   AND COALESCE(a.started_at, a.ts) > now() - alert_active_window()
   AND NOT alert_is_ignored(a.vin, a.name)) AS is_active,
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

-- brake_wear_estimate — 053 body plus baseline and inspections (appended columns)
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
inspections AS (   -- newest "pads measured, OK" (bot: service item brake_inspection)
  SELECT DISTINCT ON (vin) vin, completed_at
  FROM service_completions
  WHERE item = 'brake_inspection'
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
    i.completed_at AS last_inspection_at,
    o.confirmed_at AS original_pads_confirmed_at,
    p.completed_at AS pad_replaced_at,
    p.odometer_mi  AS pad_replaced_odometer_mi,
    -- miles on the current pads: since the recorded replacement when there
    -- is one with a usable odometer, otherwise the whole odometer
    CASE WHEN p.odometer_mi IS NOT NULL AND p.odometer_mi <= d.odometer
         THEN d.odometer - p.odometer_mi ELSE d.odometer END AS pad_miles
  FROM regen_brake_daily_1d d
  JOIN latest l ON l.vin = d.vin AND l.last_bucket = d.bucket
  LEFT JOIN pads p ON p.vin = d.vin
  LEFT JOIN inspections i ON i.vin = d.vin
  LEFT JOIN brake_pads_baseline o ON o.vin = d.vin
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
         THEN 'SINCE_PAD_REPLACEMENT'
       WHEN original_pads_confirmed_at IS NOT NULL
         THEN 'ORIGINAL_PADS_CONFIRMED'
       ELSE 'NO_PAD_RECORD' END AS wear_basis,
  -- appended (055)
  last_inspection_at,
  original_pads_confirmed_at,
  ROUND(pad_miles::numeric, 0) AS pad_miles
FROM snapshot;

-- daily series: ignored codes left out
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
  WHERE NOT alert_is_ignored(vin, alert_code)   -- 055
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

-- recommendations: Brakes per (2)
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
    -- Brakes (055): a recent "pads measured, OK" wins; no information is
    -- INFO; otherwise a mileage-only estimate is capped at WARNING.
    WHEN subsystem = 'Brakes' AND brake_inspection_current(bw.last_inspection_at, bw.pad_replaced_at) THEN 'OK'
    WHEN subsystem = 'Brakes' AND bw.wear_basis IS DISTINCT FROM 'SINCE_PAD_REPLACEMENT'
                              AND bw.wear_basis IS DISTINCT FROM 'ORIGINAL_PADS_CONFIRMED' THEN 'INFO'
    WHEN subsystem IN ('12V / Electrical', 'Charging (PCS)') AND risk_score >= 60 THEN 'WARNING'
    WHEN subsystem = 'Brakes' THEN
      CASE WHEN risk_score >= 50 THEN 'WARNING'      -- never CRITICAL: estimate only
           WHEN risk_score >= 25 THEN 'CAUTION' ELSE 'OK' END
    ELSE COALESCE(NULLIF(risk_band(risk_score), 'NORMAL'), 'OK')
  END AS severity,
  CASE WHEN risk_score IS NULL
       THEN 'No recent data for this subsystem (or it does not apply to this vehicle)'
       WHEN subsystem = 'Brakes' AND brake_inspection_current(bw.last_inspection_at, bw.pad_replaced_at)
       THEN 'Pads measured OK on ' || to_char(bw.last_inspection_at, 'YYYY-MM-DD')
            || '; next check due by ' || to_char(bw.last_inspection_at + INTERVAL '12 months', 'YYYY-MM-DD')
       WHEN subsystem = 'Brakes' AND bw.wear_basis = 'ORIGINAL_PADS_CONFIRMED' AND risk_score >= 50
       THEN 'Original pads at ' || to_char(bw.odometer_mi, 'FM999,999') || ' mi — estimate only; '
            || 'have pad thickness measured at the next service and log the result (brake inspection)'
       WHEN subsystem = 'Brakes' AND bw.wear_basis = 'ORIGINAL_PADS_CONFIRMED'
       THEN 'Original pads at ' || to_char(bw.odometer_mi, 'FM999,999') || ' mi — estimate '
            || COALESCE(bw.wear_pct::text, '?') || '% worn (assumes a 50,000 mi pad life)'
       WHEN subsystem = 'Brakes' AND bw.wear_basis = 'SINCE_PAD_REPLACEMENT' AND risk_score >= 50
       THEN 'Pads replaced at ' || to_char(bw.pad_replaced_odometer_mi, 'FM999,999') || ' mi; estimate '
            || COALESCE(bw.wear_pct::text, '?') || '% worn since — estimate only; have pad thickness measured and log the result'
       WHEN subsystem = 'Brakes' AND bw.wear_basis = 'NO_PAD_RECORD'
       THEN 'Estimate only — no pad replacement on record; log one to calibrate (mileage model: '
            || COALESCE(bw.wear_pct::text, '?') || '% worn assuming a 50,000 mi pad life)'
       ELSE recommendation END AS recommendation,
  evidence_ts
FROM arms
LEFT JOIN brake_wear_estimate bw ON bw.vin = arms.vin AND arms.subsystem = 'Brakes';

SELECT refresh_one_matview('predictive_health_score_1d_mat') AS score_1d_refreshed;
SELECT refresh_one_matview('predictive_health_summary_mat')  AS summary_refreshed;
