-- ============================================================
-- Predictive Health Master Dashboard Layer
--
-- Feature gating per docs/FEATURE_MATRIX.md using vehicle_metadata.
-- Aggregates risk scores from ALL diagnostic subsystems into a
-- single unified health score per VIN, plus a 30-day time-series
-- for trend visualisation.
--
-- Subsystems scored (weights sum to 1.0):
--   Battery Health     22 %  — capacity fade, brick imbalance, alerts
--   Drivetrain         14 %  — inverter temps, torque degradation
--   Alerts             15 %  — active critical/urgent/warning count
--   12V Battery        10 %  — sleep wake-up frequency
--   Heat Pump          10 %  — power-per-degree degradation
--   Regen / Brake       7 %  — regen capability, pad wear
--   Suspension          4 %  — steering offset, chassis alerts
--   Air Suspension      5 %  — compressor over-cycling, ride-height leaks
--   Dual Motor          5 %  — front-rear imbalance, regen, thermal throttling
--   Cybertruck          5 %  — tonneau, V2L, tri-motor, 4680 battery, air suspension
--   PCS                 5 %  — onboard charger module health
--
-- Scoring scale (0 = healthy, 100 = critical):
--    0–30  → Healthy   (green)
--   31–60  → Caution   (yellow)
--   61–80  → Warning   (orange)
--   81–100 → Critical  (red)
--
-- Architecture:
--   1. subsystem_risk_score()   — immutable helper that maps
--      any subsystem status text to a 0–100 integer.
--   2. predictive_health_score_1d  — daily time-series view
--      joining all subsystem diagnostic views.
--   3. predictive_health_summary   — current snapshot per VIN
--      with overall score, highest-risk subsystem, and
--      recommended_action text.
--   4. predictive_health_recommendations — actionable next
--      steps derived from the score breakdown.
--
-- Requires: all diagnostic SQL files (005–013) must be deployed
-- first.  This file does NOT create new CAGGs — it re-uses
-- existing ones for fast query performance.
-- ============================================================

-- Drop old overload with NUMERIC parameters (if it exists) to avoid ambiguity
DROP FUNCTION IF EXISTS subsystem_risk_score(TEXT, TEXT, NUMERIC, NUMERIC);

-- ------------------------------------------------------------------
-- 1.  Helper function: subsystem_risk_score
--
-- Maps any status / severity string to a 0–100 risk score.
-- Additional numeric modifier (degradation_pct) can nudge the
-- score upward when supplied; callers should pass an already-
-- normalised positive value (e.g. ABS(raw_trend) or GREATEST(0,…)).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION subsystem_risk_score(
  status TEXT,
  severity TEXT DEFAULT NULL,
  degradation_pct DOUBLE PRECISION DEFAULT NULL,
  brick_delta DOUBLE PRECISION DEFAULT NULL
)
RETURNS INTEGER LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  s INTEGER := 5;
BEGIN
  -- Base score from status keywords
  IF status IS NULL THEN
    s := 5;
  ELSIF status LIKE '%CRITICAL%' OR status LIKE '%FAILURE%'
     OR status LIKE '%OVERHEAT_RISK%' OR status LIKE '%SERVICE_REQUIRED%'
     OR status LIKE '%DEGRADATION_LIKELY%' OR status LIKE '%ALIGNMENT_LIKELY%'
     OR status = 'INVERTER_OVERHEAT_RISK' OR status = 'ALERT_SPIKE'
     OR status = 'PERSISTENT_ISSUES' THEN
    s := 90;
  ELSIF status LIKE '%DEGRADED%' OR status LIKE '%RECOMMENDED%'
     OR status LIKE '%ANOMALY%' OR status LIKE '%IMBALANCE_DETECTED%'
     OR status LIKE '%IMBALANCE_LIKELY%'
     OR status LIKE '%THROTTLING_RISK%'
     OR status LIKE '%LOOSENESS_LIKELY%' THEN
    s := 65;
  ELSIF status LIKE '%WARNING%' OR status LIKE '%SPIKE%'
     OR status LIKE '%PERSISTENT%' THEN
    s := 40;
  ELSIF status = 'NORMAL' OR status = 'HEALTHY' OR status = 'NOT_APPLICABLE' THEN
    s := 5;
  ELSE
    s := 10;
  END IF;

  -- Severity override
  IF severity = 'CRITICAL' THEN
    s := GREATEST(s, 95);
  ELSIF severity = 'URGENT' THEN
    s := GREATEST(s, 75);
  ELSIF severity = 'WARNING' THEN
    s := GREATEST(s, 40);
  END IF;

  -- Numeric modifier (callers pass a normalised positive value)
  IF degradation_pct IS NOT NULL AND degradation_pct > 0 THEN
    s := LEAST(100, s + (degradation_pct / 3)::INTEGER);
  END IF;

  IF brick_delta IS NOT NULL AND brick_delta > 0.3 THEN
    s := s + 15;
  END IF;

  RETURN LEAST(100, GREATEST(0, s));
END;
$$;

-- ------------------------------------------------------------------
-- 2.  predictive_health_score_1d  — daily time-series
--
-- One row per VIN per day with per-subsystem scores and the
-- weighted overall score.  Built by UNION-ing daily scores
-- from each subsystem diagnostic view / CAGG, then GROUP-ing.
--
-- Performance: each subsystem CTE hits an existing CAGG;
-- the final GROUP BY operates on at most ~240 rows per VIN
-- for a 30-day window.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW predictive_health_score_1d AS
WITH
-- Battery Health (009)
bat AS (
  SELECT ts, vin,
    subsystem_risk_score(
      CASE
        WHEN brick_delta_max > 0.5 THEN 'BATTERY_IMBALANCE_DETECTED'
        WHEN capacity_degradation_pct > 10 THEN 'BATTERY_CAPACITY_DEGRADED'
        ELSE 'NORMAL'
      END,
      NULL,
      capacity_degradation_pct,
      brick_delta_max
    ) AS score
  FROM battery_health_diagnostics
),
-- Drivetrain (011)
drv AS (
  SELECT ts, vin,
    subsystem_risk_score(status, NULL, ABS(COALESCE(regen_degradation_pct, 0))) AS score
  FROM drivetrain_diagnostics
),
-- Alerts (012) — aggregated from daily frequency CAGG
alt AS (
  SELECT bucket::timestamptz AS ts, vin,
    CASE
      WHEN SUM(alert_count) FILTER (WHERE severity = 'CRITICAL') > 0 THEN 100
      WHEN SUM(alert_count) FILTER (WHERE severity = 'URGENT') > 0 THEN 75
      WHEN SUM(alert_count) FILTER (WHERE severity = 'WARNING') >= 3 THEN 50
      WHEN SUM(alert_count) FILTER (WHERE severity = 'WARNING') > 0 THEN 25
      ELSE 5
    END AS score
  FROM alert_frequency_1d
  GROUP BY bucket, vin
),
-- 12V Battery (008)
lv AS (
  SELECT ts, vin,
    subsystem_risk_score(status) AS score
  FROM low_voltage_diagnostics
),
-- Heat Pump (007)
hp AS (
  SELECT ts, vin,
    subsystem_risk_score(status, NULL, GREATEST(0, COALESCE(trend_pct, 0))) AS score
  FROM heat_pump_diagnostics
),
-- Regen / Brake (013)
rb AS (
  SELECT ts, vin,
    subsystem_risk_score(status, NULL,
      GREATEST(ABS(COALESCE(regen_torque_trend_pct, 0)),
               GREATEST(0, COALESCE(eff_trend_pct, 0)))) AS score
  FROM regen_brake_diagnostics
),
-- Suspension (010)
sus AS (
  SELECT ts, vin,
    subsystem_risk_score(steering_status, NULL,
      GREATEST(0, COALESCE(offset_trend_pct, 0))) AS score
  FROM suspension_diagnostics
),
-- PCS (006) — scored from daily health CAGG
pcs AS (
  SELECT bucket::timestamptz AS ts, vin,
    CASE
      WHEN failure_hours > 0 THEN 95
      WHEN max_deficit_amps >= 32 THEN 85
      WHEN max_deficit_amps >= 16 THEN 60
      ELSE 5
    END AS score
  FROM pcs_health_1d
),
-- Air Suspension (015)
air AS (
  SELECT ts, vin,
    subsystem_risk_score(status, NULL,
      GREATEST(ABS(COALESCE(cycling_trend_pct, 0)),
               ABS(COALESCE(drift_trend_pct, 0)))) AS score
  FROM air_suspension_diagnostics
),
-- Dual Motor (016)
dm AS (
  SELECT ts, vin,
    subsystem_risk_score(
      status, severity,
      GREATEST(ABS(COALESCE(temp_delta_trend_pct, 0)),
               ABS(COALESCE(regen_trend_pct, 0)))
    ) AS score
  FROM dual_motor_diagnostics
  WHERE motor_config IN ('Dual Motor', 'Performance', 'Tri Motor')
),
-- Cybertruck (017)
ct AS (
  SELECT ts, vin,
    subsystem_risk_score(
      status, severity,
      GREATEST(ABS(COALESCE(value, 0)),
               ABS(COALESCE(baseline, 0)))
    ) AS score
  FROM cybertruck_diagnostics
  WHERE model = 'CT'
),
-- Combine all subsystem scores
all_scores AS (
  SELECT ts, vin, score AS battery_score,
    NULL::INTEGER AS drivetrain_score,
    NULL::INTEGER AS alert_score,
    NULL::INTEGER AS low_voltage_score,
    NULL::INTEGER AS heat_pump_score,
    NULL::INTEGER AS regen_brake_score,
    NULL::INTEGER AS suspension_score,
    NULL::INTEGER AS pcs_score,
    NULL::INTEGER AS air_suspension_score,
    NULL::INTEGER AS dual_motor_score,
    NULL::INTEGER AS cybertruck_score
  FROM bat
  UNION ALL
  SELECT ts, vin, NULL::INTEGER, score, NULL::INTEGER, NULL::INTEGER,
    NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER
  FROM drv
  UNION ALL
  SELECT ts, vin, NULL::INTEGER, NULL::INTEGER, score, NULL::INTEGER,
    NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER
  FROM alt
  UNION ALL
  SELECT ts, vin, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, score,
    NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER
  FROM lv
  UNION ALL
  SELECT ts, vin, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER,
    score, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER
  FROM hp
  UNION ALL
  SELECT ts, vin, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER,
    NULL::INTEGER, score, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER
  FROM rb
  UNION ALL
  SELECT ts, vin, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER,
    NULL::INTEGER, NULL::INTEGER, score, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER
  FROM sus
  UNION ALL
  SELECT ts, vin, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER,
    NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, score, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER
  FROM pcs
  UNION ALL
  SELECT ts, vin, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER,
    NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, score, NULL::INTEGER, NULL::INTEGER
  FROM air
  UNION ALL
  SELECT ts, vin, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER,
    NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, score, NULL::INTEGER
  FROM dm
  UNION ALL
  SELECT ts, vin, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER,
    NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, score
  FROM ct
),
ph_inner AS (SELECT
  ts,
  vin,
  COALESCE(MAX(battery_score),     5) AS battery_score,
  COALESCE(MAX(drivetrain_score),  5) AS drivetrain_score,
  COALESCE(MAX(alert_score),       5) AS alert_score,
  COALESCE(MAX(low_voltage_score), 5) AS low_voltage_score,
  COALESCE(MAX(heat_pump_score),   5) AS heat_pump_score,
  COALESCE(MAX(regen_brake_score), 5) AS regen_brake_score,
  COALESCE(MAX(suspension_score),  5) AS suspension_score,
  COALESCE(MAX(pcs_score),         5) AS pcs_score,
  COALESCE(MAX(air_suspension_score), 5) AS air_suspension_score,
  COALESCE(MAX(dual_motor_score),    5) AS dual_motor_score,
  COALESCE(MAX(cybertruck_score),    5) AS cybertruck_score,
  -- Weighted overall score
  ROUND((
    COALESCE(MAX(battery_score),     5) * 0.22 +
    COALESCE(MAX(drivetrain_score),  5) * 0.14 +
    COALESCE(MAX(alert_score),       5) * 0.15 +
    COALESCE(MAX(low_voltage_score), 5) * 0.10 +
    COALESCE(MAX(heat_pump_score),   5) * 0.10 +
    COALESCE(MAX(regen_brake_score), 5) * 0.07 +
    COALESCE(MAX(suspension_score),  5) * 0.04 +
    COALESCE(MAX(air_suspension_score), 5) * 0.05 +
    COALESCE(MAX(dual_motor_score),    5) * 0.05 +
    COALESCE(MAX(cybertruck_score),    5) * 0.05 +
    COALESCE(MAX(pcs_score),         5) * 0.05
  )::numeric, 1) AS overall_risk_score,
  -- Highest-risk subsystem name
  CASE GREATEST(
    COALESCE(MAX(battery_score), 5), COALESCE(MAX(drivetrain_score), 5),
    COALESCE(MAX(alert_score), 5),   COALESCE(MAX(low_voltage_score), 5),
    COALESCE(MAX(heat_pump_score), 5), COALESCE(MAX(regen_brake_score), 5),
    COALESCE(MAX(suspension_score), 5), COALESCE(MAX(pcs_score), 5),
    COALESCE(MAX(air_suspension_score), 5), COALESCE(MAX(dual_motor_score), 5),
    COALESCE(MAX(cybertruck_score), 5)
  )
    WHEN COALESCE(MAX(battery_score),     5) THEN 'Battery'
    WHEN COALESCE(MAX(drivetrain_score),  5) THEN 'Drivetrain'
    WHEN COALESCE(MAX(alert_score),       5) THEN 'Alerts'
    WHEN COALESCE(MAX(low_voltage_score), 5) THEN '12V Battery'
    WHEN COALESCE(MAX(heat_pump_score),   5) THEN 'Heat Pump'
    WHEN COALESCE(MAX(regen_brake_score), 5) THEN 'Regen/Brake'
    WHEN COALESCE(MAX(suspension_score),  5) THEN 'Suspension'
    WHEN COALESCE(MAX(pcs_score),         5) THEN 'PCS'
    WHEN COALESCE(MAX(air_suspension_score), 5) THEN 'Air Suspension'
    WHEN COALESCE(MAX(dual_motor_score),    5) THEN 'Dual Motor'
    WHEN COALESCE(MAX(cybertruck_score),    5) THEN 'Cybertruck'
  END AS highest_risk_subsystem
FROM all_scores
GROUP BY ts, vin)
SELECT ph.*, vm.model
FROM ph_inner ph
LEFT JOIN vehicle_metadata vm ON vm.vin = ph.vin;

-- ------------------------------------------------------------------
-- 3.  predictive_health_summary  — current snapshot per VIN
--
-- Joins the latest row from every subsystem summary view and
-- computes the weighted overall risk score, highest-risk
-- subsystem, active alert counts, and a human-readable
-- recommended_action.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW predictive_health_summary AS
WITH scores AS (
  SELECT
    v.vin,
    -- Battery (25 %)
    COALESCE(subsystem_risk_score(
      b.overall_status, b.max_alert_severity,
      b.capacity_degradation_pct, b.last_day_brick_delta_max
    ), 5) AS battery_score,
    -- Drivetrain (20 %)
    COALESCE(subsystem_risk_score(
      d.status, NULL, ABS(COALESCE(d.regen_degradation_pct, 0))
    ), 5) AS drivetrain_score,
    -- Alerts (15 %)
    COALESCE(CASE
      WHEN a.critical_active > 0 THEN 100
      WHEN a.urgent_active > 0 THEN 75
      WHEN a.warning_active >= 3 THEN 50
      WHEN a.warning_active > 0 THEN 25
      ELSE 5
    END, 5) AS alert_score,
    -- 12V Battery (10 %)
    COALESCE(subsystem_risk_score(lv.status), 5) AS low_voltage_score,
    -- Heat Pump (10 %)
    COALESCE(subsystem_risk_score(hp.status, NULL, GREATEST(0, COALESCE(hp.trend_pct, 0))), 5) AS heat_pump_score,
    -- Regen / Brake (10 %)
    COALESCE(subsystem_risk_score(
      rb.status, NULL,
      GREATEST(ABS(COALESCE(rb.regen_torque_trend_pct, 0)),
               GREATEST(0, COALESCE(rb.eff_trend_pct, 0)))
    ), 5) AS regen_brake_score,
    -- Suspension (4 %)
    COALESCE(subsystem_risk_score(s.overall_status, s.max_alert_severity), 5) AS suspension_score,
    -- Air Suspension (5 %)
    COALESCE(subsystem_risk_score(
      air.status, NULL,
      GREATEST(ABS(COALESCE(air.cycling_trend_pct, 0)),
               ABS(COALESCE(air.drift_trend_pct, 0)))
    ), 5) AS air_suspension_score,
    -- Dual Motor (5 %)
    COALESCE(subsystem_risk_score(
      dm.status, dm.severity,
      GREATEST(ABS(COALESCE(dm.temp_delta_trend_pct, 0)),
               ABS(COALESCE(dm.regen_trend_pct, 0)))
    ), 5) AS dual_motor_score,
    -- Cybertruck (5 %) — score from overall_severity; no numeric degradation column in cybertruck_summary
    COALESCE(subsystem_risk_score(ct.overall_severity, ct.overall_severity), 5) AS cybertruck_score,
    -- PCS (5 %)
    COALESCE(subsystem_risk_score(pcs.status), 5) AS pcs_score,
    -- Extra context columns
    a.critical_active,
    a.urgent_active,
    a.warning_active,
    a.total_active,
    a.critical_codes,
    a.urgent_codes,
    b.capacity_degradation_pct,
    b.last_day_brick_delta_max,
    d.inverter_temp_max,
    d.regen_degradation_pct,
    rb.brake_remaining_pct,
    rb.eff_trend_pct,
    hp.trend_pct AS heat_pump_trend_pct,
    s.offset_trend_pct AS suspension_offset_trend_pct,
    air.cycling_trend_pct AS air_suspension_cycling_trend_pct,
    air.drift_trend_pct AS air_suspension_drift_trend_pct,
    dm.temp_delta_trend_pct AS dual_motor_temp_delta_trend_pct,
    dm.regen_trend_pct AS dual_motor_regen_trend_pct
  FROM (SELECT DISTINCT vin FROM telemetry) v
  LEFT JOIN battery_health_summary      b   ON b.vin = v.vin
  LEFT JOIN drivetrain_summary          d   ON d.vin = v.vin
  LEFT JOIN alert_critical_active       a   ON a.vin = v.vin
  LEFT JOIN low_voltage_status          lv  ON lv.vin = v.vin
  LEFT JOIN heat_pump_status            hp  ON hp.vin = v.vin
  LEFT JOIN regen_brake_summary         rb  ON rb.vin = v.vin
  LEFT JOIN suspension_summary          s   ON s.vin = v.vin
  LEFT JOIN air_suspension_summary      air ON air.vin = v.vin
  LEFT JOIN dual_motor_summary          dm  ON dm.vin = v.vin
  LEFT JOIN cybertruck_summary          ct  ON ct.vin = v.vin
  LEFT JOIN pcs_status_summary          pcs ON pcs.vin = v.vin
)
SELECT
  scores.vin,
  battery_score,
  drivetrain_score,
  alert_score,
  low_voltage_score,
  heat_pump_score,
  regen_brake_score,
  suspension_score,
  air_suspension_score,
  dual_motor_score,
  cybertruck_score,
  pcs_score,
  -- Composite scores for dashboard grouping
  ROUND(battery_score::numeric, 0) AS battery_risk,
  ROUND((drivetrain_score * 0.60 + regen_brake_score * 0.25 + pcs_score * 0.15)::numeric, 0)
    AS powertrain_risk,
  ROUND((heat_pump_score * 0.60 + CASE WHEN COALESCE(last_day_brick_delta_max, 0) > 0.3 THEN 50 ELSE 5 END * 0.40)::numeric, 0)
    AS thermal_risk,
  -- Overall weighted score
  ROUND((
    battery_score        * 0.22 +
    drivetrain_score     * 0.14 +
    alert_score          * 0.15 +
    low_voltage_score    * 0.10 +
    heat_pump_score      * 0.10 +
    regen_brake_score    * 0.07 +
    suspension_score     * 0.04 +
    air_suspension_score * 0.05 +
    dual_motor_score     * 0.05 +
    cybertruck_score     * 0.05 +
    pcs_score            * 0.05
  )::numeric, 1) AS overall_risk_score,
  -- Highest risk subsystem
  CASE GREATEST(battery_score, drivetrain_score, alert_score, low_voltage_score,
                heat_pump_score, regen_brake_score, suspension_score, air_suspension_score, dual_motor_score, cybertruck_score, pcs_score)
    WHEN battery_score        THEN 'Battery'
    WHEN drivetrain_score     THEN 'Drivetrain'
    WHEN alert_score          THEN 'Alerts'
    WHEN low_voltage_score    THEN '12V Battery'
    WHEN heat_pump_score      THEN 'Heat Pump'
    WHEN regen_brake_score    THEN 'Regen/Brake'
    WHEN suspension_score     THEN 'Suspension'
    WHEN air_suspension_score THEN 'Air Suspension'
    WHEN dual_motor_score     THEN 'Dual Motor'
    WHEN cybertruck_score     THEN 'Cybertruck'
    WHEN pcs_score            THEN 'PCS'
  END AS highest_risk_subsystem,
  COALESCE(critical_active, 0) AS critical_alerts,
  COALESCE(urgent_active, 0)   AS urgent_alerts,
  COALESCE(warning_active, 0)  AS warning_alerts,
  COALESCE(total_active, 0)    AS total_active_alerts,
  COALESCE(critical_codes, '') AS active_critical_codes,
  COALESCE(urgent_codes, '')   AS active_urgent_codes,
  -- Recommended action
  CASE
    WHEN COALESCE(critical_active, 0) > 0
      THEN 'IMMEDIATE SERVICE — Critical: ' || COALESCE(critical_codes, '')
    WHEN battery_score >= 85
      THEN 'Schedule battery service — degradation or imbalance detected'
    WHEN drivetrain_score >= 85
      THEN 'Schedule drivetrain inspection — inverter overheat or motor degradation'
    WHEN air_suspension_score >= 75
      THEN 'Schedule air-suspension inspection — compressor over-cycling or leak suspected'
    WHEN dual_motor_score >= 75
      THEN 'Schedule dual-motor inspection — imbalance, regen degradation, or thermal throttling'
    WHEN cybertruck_score >= 75
      THEN 'Schedule Cybertruck-specific inspection — tonneau, V2L, tri-motor, or 4680 battery issue'
    WHEN alert_score >= 75 AND COALESCE(urgent_active, 0) > 0
      THEN 'Schedule service — Urgent: ' || COALESCE(urgent_codes, '')
    WHEN (battery_score * 0.22 + drivetrain_score * 0.14 + alert_score * 0.15 +
          low_voltage_score * 0.10 + heat_pump_score * 0.10 + regen_brake_score * 0.07 +
          suspension_score * 0.04 + air_suspension_score * 0.05 +
          dual_motor_score * 0.05 + cybertruck_score * 0.05 + pcs_score * 0.05) >= 60
      THEN 'Monitor closely — multiple subsystems showing degradation'
    WHEN (battery_score * 0.22 + drivetrain_score * 0.14 + alert_score * 0.15 +
          low_voltage_score * 0.10 + heat_pump_score * 0.10 + regen_brake_score * 0.07 +
          suspension_score * 0.04 + air_suspension_score * 0.05 +
          dual_motor_score * 0.05 + cybertruck_score * 0.05 + pcs_score * 0.05) >= 40
      THEN 'Plan preventive maintenance — emerging wear patterns detected'
    ELSE 'All systems nominal — continue regular monitoring'
  END AS recommended_action,
  vm.model,
  vm.battery_type,
  vm.has_heat_pump,
  vm.has_air_suspension
FROM scores
LEFT JOIN vehicle_metadata vm ON vm.vin = scores.vin;

-- ------------------------------------------------------------------
-- 4.  predictive_health_recommendations  — per-subsystem actions
--
-- One row per VIN per subsystem with specific next steps.
-- Useful for the "Next Service Recommendations" table panel.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW predictive_health_recommendations AS
SELECT
  vin,
  'Battery' AS subsystem,
  battery_risk AS risk_score,
  CASE
    WHEN battery_risk >= 85 THEN 'CRITICAL'
    WHEN battery_risk >= 60 THEN 'WARNING'
    WHEN battery_risk >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END AS severity,
  CASE
    WHEN battery_risk >= 85 THEN 'Schedule battery pack inspection — capacity fade > 10% or brick imbalance > 0.5 V'
    WHEN battery_risk >= 60 THEN 'Monitor battery health — schedule diagnostic scan at next service'
    WHEN battery_risk >= 40 THEN 'Check tire pressure and alignment — slight efficiency drop detected'
    ELSE 'No action required'
  END AS recommendation
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Powertrain',
  powertrain_risk,
  CASE
    WHEN powertrain_risk >= 85 THEN 'CRITICAL'
    WHEN powertrain_risk >= 60 THEN 'WARNING'
    WHEN powertrain_risk >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN powertrain_risk >= 85 THEN 'Schedule drivetrain inspection — inverter overheat or regen degradation detected'
    WHEN powertrain_risk >= 60 THEN 'Monitor motor temps and regen torque — schedule check if trend continues'
    WHEN powertrain_risk >= 40 THEN 'Verify charging performance — possible PCS derating'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Thermal',
  thermal_risk,
  CASE
    WHEN thermal_risk >= 85 THEN 'CRITICAL'
    WHEN thermal_risk >= 60 THEN 'WARNING'
    WHEN thermal_risk >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN thermal_risk >= 85 THEN 'Inspect HVAC system — heat pump degradation or battery thermal imbalance'
    WHEN thermal_risk >= 60 THEN 'Check cabin filter and refrigerant levels — efficiency declining'
    WHEN thermal_risk >= 40 THEN 'Verify pre-conditioning settings — minor thermal inefficiency'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  '12V / Electrical',
  low_voltage_score,
  CASE
    WHEN low_voltage_score >= 60 THEN 'WARNING'
    WHEN low_voltage_score >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN low_voltage_score >= 60 THEN 'Replace 12V battery — frequent wake-ups indicating capacity loss'
    WHEN low_voltage_score >= 40 THEN 'Monitor 12V system — wake-up frequency increasing'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Suspension',
  suspension_score,
  CASE
    WHEN suspension_score >= 60 THEN 'WARNING'
    ELSE 'OK'
  END,
  CASE
    WHEN suspension_score >= 85 THEN 'Immediate alignment check — chassis alert UI_a006 active'
    WHEN suspension_score >= 60 THEN 'Schedule alignment and bushing inspection — steering offset increasing'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Air Suspension',
  air_suspension_score,
  CASE
    WHEN air_suspension_score >= 85 THEN 'CRITICAL'
    WHEN air_suspension_score >= 60 THEN 'WARNING'
    WHEN air_suspension_score >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN air_suspension_score >= 85 THEN 'Inspect air suspension immediately — compressor failure or severe leak suspected'
    WHEN air_suspension_score >= 60 THEN 'Schedule air-suspension check — compressor over-cycling or ride-height drift detected'
    WHEN air_suspension_score >= 40 THEN 'Monitor air suspension — slight increase in compressor activity'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Dual Motor',
  dual_motor_score,
  CASE
    WHEN dual_motor_score >= 85 THEN 'CRITICAL'
    WHEN dual_motor_score >= 60 THEN 'WARNING'
    WHEN dual_motor_score >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN dual_motor_score >= 85 THEN 'Inspect dual-motor system immediately — severe imbalance or thermal throttling detected'
    WHEN dual_motor_score >= 60 THEN 'Schedule dual-motor inspection — front-rear imbalance, regen degradation, or throttle limiting'
    WHEN dual_motor_score >= 40 THEN 'Monitor dual-motor balance — slight temp delta or regen trend detected'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Cybertruck',
  cybertruck_score,
  CASE
    WHEN cybertruck_score >= 85 THEN 'CRITICAL'
    WHEN cybertruck_score >= 60 THEN 'WARNING'
    WHEN cybertruck_score >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN cybertruck_score >= 85 THEN 'Inspect Cybertruck immediately — tonneau failure, severe tri-motor imbalance, or 4680 battery degradation'
    WHEN cybertruck_score >= 60 THEN 'Schedule Cybertruck inspection — tonneau, V2L, air suspension, or tri-motor issue detected'
    WHEN cybertruck_score >= 40 THEN 'Monitor Cybertruck subsystems — slight anomaly in tonneau, V2L, or tri-motor'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Brakes',
  LEAST(100, GREATEST(0, 100 - COALESCE(brake_remaining_pct, 100)))::INTEGER,
  CASE
    WHEN COALESCE(brake_remaining_pct, 100) <= 25 THEN 'CRITICAL'
    WHEN COALESCE(brake_remaining_pct, 100) <= 50 THEN 'WARNING'
    WHEN COALESCE(brake_remaining_pct, 100) <= 75 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN COALESCE(brake_remaining_pct, 100) <= 25 THEN 'Replace brake pads immediately — estimated < 25% remaining'
    WHEN COALESCE(brake_remaining_pct, 100) <= 50 THEN 'Plan brake pad replacement — ~50% wear reached'
    WHEN COALESCE(brake_remaining_pct, 100) <= 75 THEN 'Inspect brake pads at next service'
    ELSE 'No action required'
  END
FROM regen_brake_summary;

-- ------------------------------------------------------------------
-- 5.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Overall Health"  (Stat + sparkline)
-- --------------------------------------------------------
-- Green  = 0–30
-- Yellow = 31–60
-- Orange = 61–80
-- Red    = 81–100
--
-- SELECT overall_risk_score, highest_risk_subsystem,
--        recommended_action
-- FROM predictive_health_summary
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Battery Risk"  (Stat)
-- --------------------------------------------------------
-- SELECT battery_risk FROM predictive_health_summary WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Powertrain Risk"  (Stat)
-- --------------------------------------------------------
-- SELECT powertrain_risk FROM predictive_health_summary WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Thermal Risk"  (Stat)
-- --------------------------------------------------------
-- SELECT thermal_risk FROM predictive_health_summary WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Risk Score Trend"  (Time series)
-- --------------------------------------------------------
-- Shows overall + subsystem scores over 30 days.
--
-- SELECT
--   ts AS time,
--   overall_risk_score AS "Overall",
--   battery_score AS "Battery",
--   drivetrain_score AS "Drivetrain",
--   alert_score AS "Alerts",
--   heat_pump_score AS "Heat Pump",
--   regen_brake_score AS "Regen/Brake",
--   low_voltage_score AS "12V Battery",
--   suspension_score AS "Suspension",
--   pcs_score AS "PCS"
-- FROM predictive_health_score_1d
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Active Alerts"  (Table)
-- --------------------------------------------------------
-- SELECT
--   alert_code AS "Code",
--   severity AS "Severity",
--   subsystem AS "Subsystem",
--   description AS "Description",
--   is_active AS "Active"
-- FROM parsed_alerts
-- WHERE vin = '$vin'
--   AND is_active = TRUE
-- ORDER BY CASE severity
--   WHEN 'CRITICAL' THEN 1 WHEN 'URGENT' THEN 2
--   WHEN 'WARNING' THEN 3 ELSE 4 END;

-- --------------------------------------------------------
-- Panel: "Next Service Recommendations"  (Table)
-- --------------------------------------------------------
-- SELECT
--   subsystem AS "Subsystem",
--   risk_score AS "Risk",
--   severity AS "Status",
--   recommendation AS "Recommended Action"
-- FROM predictive_health_recommendations
-- WHERE vin = '$vin'
-- ORDER BY CASE severity
--   WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2
--   WHEN 'CAUTION' THEN 3 ELSE 4 END;

-- ------------------------------------------------------------------
-- 6.  Grafana Alert configuration instructions
-- ------------------------------------------------------------------
--
-- 1. Create an Alert Rule on the "Overall Health" panel:
--    Query: SELECT overall_risk_score FROM predictive_health_summary
--           WHERE vin = '$vin'
--    Condition: overall_risk_score > 80
--    Evaluation: every 5m for 5m
--    Action: Send to PagerDuty / Slack / Email
--
-- 2. Create an Alert Rule on the "Battery Risk" panel:
--    Query: SELECT battery_risk FROM predictive_health_summary
--           WHERE vin = '$vin'
--    Condition: battery_risk > 80
--    Evaluation: every 10m for 10m
--    Action: Send to service team
--
-- 3. Create an Alert Rule on the "Powertrain Risk" panel:
--    Query: SELECT powertrain_risk FROM predictive_health_summary
--           WHERE vin = '$vin'
--    Condition: powertrain_risk > 75
--    Evaluation: every 10m for 10m
--    Action: Send to drivetrain team
--
-- 4. Create an Alert Rule for any active critical alert:
--    Query: SELECT critical_active FROM predictive_health_summary
--           WHERE vin = '$vin'
--    Condition: critical_active > 0
--    Evaluation: every 1m for 1m
--    Action: Immediate page to on-call engineer
--
-- 5. Create a Multi-dimensional Alert (all VINs):
--    Query: SELECT vin, overall_risk_score
--           FROM predictive_health_summary
--    Condition: overall_risk_score > 70
--    Group by: vin
--    Action: Slack notification with VIN and recommended_action
--
-- Note: Grafana 12 alert rules support template variables in
-- the alert message.  Use {{ $labels.vin }} to include the
-- affected vehicle identifier.
-- ------------------------------------------------------------------


-- ------------------------------------------------------------------
-- 6.  Feature Matrix Enforcement Verification
--
-- These queries verify that docs/FEATURE_MATRIX.md gating rules
-- are correctly enforced across all predictive subsystems.
-- Run after deploying 005–017 and populating vehicle_metadata.
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Test A — Model 3 SR+ / RWD (VIN[8] = 'A' or 'B')
-- Expected results:
--   • air_suspension_score = 5 (default, no air suspension)
--   • dual_motor_score = 5 (default, RWD)
--   • cybertruck_score = 5 (default, not CT)
--   • heat_pump_score = 5 (default, no heat pump)
-- --------------------------------------------------------
-- SELECT
--   vin,
--   battery_score,
--   drivetrain_score,
--   alert_score,
--   low_voltage_score,
--   heat_pump_score,
--   regen_brake_score,
--   suspension_score,
--   air_suspension_score,
--   dual_motor_score,
--   cybertruck_score,
--   pcs_score,
--   highest_risk_subsystem
-- FROM predictive_health_summary
-- WHERE motor_config = 'RWD'
-- LIMIT 1;

-- --------------------------------------------------------
-- Test B — Model Y LR Performance (VIN[8] = 'G')
-- Expected results:
--   • air_suspension_score may be > 5 if has_air_suspension = true
--   • dual_motor_score active (Performance = Dual Motor)
--   • cybertruck_score = 5 (default, not CT)
--   • heat_pump_score active (post-2021)
-- --------------------------------------------------------
-- SELECT
--   vin,
--   battery_score,
--   drivetrain_score,
--   alert_score,
--   low_voltage_score,
--   heat_pump_score,
--   regen_brake_score,
--   suspension_score,
--   air_suspension_score,
--   dual_motor_score,
--   cybertruck_score,
--   pcs_score,
--   highest_risk_subsystem
-- FROM predictive_health_summary
-- WHERE motor_config = 'Performance'
-- LIMIT 1;

-- --------------------------------------------------------
-- Test C — Cybertruck Cyberbeast Tri-Motor (VIN[3] = 'C', VIN[8] = 'J')
-- Expected results:
--   • air_suspension_score active (has_air_suspension = true)
--   • dual_motor_score active (Tri Motor ∈ Dual Motor set)
--   • cybertruck_score active (model = 'CT')
--   • heat_pump_score active
--   • tri_motor subsystems visible in cybertruck_summary
-- --------------------------------------------------------
-- SELECT
--   vin,
--   battery_score,
--   drivetrain_score,
--   alert_score,
--   low_voltage_score,
--   heat_pump_score,
--   regen_brake_score,
--   suspension_score,
--   air_suspension_score,
--   dual_motor_score,
--   cybertruck_score,
--   pcs_score,
--   highest_risk_subsystem
-- FROM predictive_health_summary
-- WHERE model = 'CT' AND motor_config = 'Tri Motor'
-- LIMIT 1;

-- --------------------------------------------------------
-- Test D — Confirm non-relevant views return zero rows
-- --------------------------------------------------------
-- -- Air suspension for Model 3 RWD
-- SELECT COUNT(*) FROM air_suspension_summary
-- WHERE vin IN (SELECT vin FROM vehicle_metadata WHERE model = '3' AND motor_config = 'RWD');
-- -- Expected: 0

-- -- Dual motor for Model 3 RWD
-- SELECT COUNT(*) FROM dual_motor_summary
-- WHERE vin IN (SELECT vin FROM vehicle_metadata WHERE model = '3' AND motor_config = 'RWD');
-- -- Expected: 0

-- -- Cybertruck for Model Y
-- SELECT COUNT(*) FROM cybertruck_summary
-- WHERE vin IN (SELECT vin FROM vehicle_metadata WHERE model = 'Y');
-- -- Expected: 0

-- -- Heat pump for pre-2021 Model S
-- SELECT COUNT(*) FROM heat_pump_status
-- WHERE vin IN (SELECT vin FROM vehicle_metadata WHERE model = 'S' AND model_year < 2021);
-- -- Expected: 0

-- -- Tri motor for Cybertruck Dual Motor (non-Cyberbeast)
-- SELECT COUNT(*) FROM tri_motor_diagnostics
-- WHERE vin IN (SELECT vin FROM vehicle_metadata WHERE motor_config != 'Tri Motor');
-- -- Expected: 0 (or only NOT_APPLICABLE rows)
