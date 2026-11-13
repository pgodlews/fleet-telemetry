-- ============================================================
-- 031_diagnostic_sign_fixes.sql
--
-- Scoring corrections from the 2026-09-09 review.
--
--   1. Trend modifiers were wrapped in ABS(), so a component that is
--      *improving* raised its own risk score by exactly as much as one
--      degrading at the same rate. Each metric now contributes only in
--      the direction that actually means deterioration:
--
--        regen_degradation_pct   (011)  falls as regen weakens  -> -x
--        regen_torque_trend_pct  (013)  falls as regen weakens  -> -x
--        regen_trend_pct         (016)  falls as regen weakens  -> -x
--        temp_delta_trend_pct    (016)  rises with inverter dT  -> +x
--        cycling_trend_pct       (015)  rises with compressor duty -> +x
--        drift_trend_pct         (015)  rises with height drift -> +x
--
--      eff_trend_pct and the heat-pump trend were already correctly
--      clamped with GREATEST(0, ...) and are unchanged.
--
--   2. The Cybertruck branch passed GREATEST(ABS(value), ABS(baseline))
--      as degradation_pct. cybertruck_diagnostics UNIONs five
--      subsystems with different units, and subsystem_risk_score adds
--      degradation_pct/3 points, so a raw baseline could add tens of
--      points of risk with no relationship to any deterioration. The
--      numeric modifier is dropped; status and severity still score.
--
--   3. low_voltage_diagnostics' sudden-onset branch was unreachable.
--      Its 30-day window contains the 7-day window, and the values are
--      non-negative, so cycling_30d = 0 forces cycling_7d = 0 and
--      "cycling_30d = 0 AND cycling_7d >= 2" can never hold. The
--      baseline is now a prior-only window that ends where the recent
--      window begins.
--
-- The two 014 views are restated in full because CREATE OR REPLACE
-- VIEW requires the whole definition; apart from the expressions named
-- above they are byte-identical to 014.
--
-- Requires 014_predictive_health.sql (and 008 for part 3).
-- Safe to re-run.
-- ============================================================

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
    subsystem_risk_score(status, NULL, GREATEST(0, -COALESCE(regen_degradation_pct, 0))) AS score
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
      GREATEST(GREATEST(0, -COALESCE(regen_torque_trend_pct, 0)),
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
      GREATEST(GREATEST(0, COALESCE(cycling_trend_pct, 0)),
               GREATEST(0, COALESCE(drift_trend_pct, 0)))) AS score
  FROM air_suspension_diagnostics
),
-- Dual Motor (016)
dm AS (
  SELECT ts, vin,
    subsystem_risk_score(
      status, severity,
      GREATEST(GREATEST(0, COALESCE(temp_delta_trend_pct, 0)),
               GREATEST(0, -COALESCE(regen_trend_pct, 0)))
    ) AS score
  FROM dual_motor_diagnostics
  WHERE motor_config IN ('Dual Motor', 'Performance', 'Tri Motor')
),
-- Cybertruck (017)
ct AS (
  SELECT ts, vin,
    subsystem_risk_score(
      status, severity,
      -- No numeric modifier. cybertruck_diagnostics UNIONs five
      -- subsystems whose value/baseline carry different units
      -- (seconds, kW, °C, mm, V), and these raw magnitudes were being
      -- passed as a percentage: a 150 mm suspension height added 50
      -- points on its own. Re-enable only with a per-subsystem,
      -- signed, dimensionless deterioration measure.
      NULL::DOUBLE PRECISION
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
  -- Weighted overall score (weights sum to 1.00; see header comment)
  ROUND((
    COALESCE(MAX(battery_score),        5) * 0.22 +
    COALESCE(MAX(drivetrain_score),     5) * 0.14 +
    COALESCE(MAX(alert_score),          5) * 0.15 +
    COALESCE(MAX(low_voltage_score),    5) * 0.10 +
    COALESCE(MAX(heat_pump_score),      5) * 0.10 +
    COALESCE(MAX(regen_brake_score),    5) * 0.07 +
    COALESCE(MAX(suspension_score),     5) * 0.04 +
    COALESCE(MAX(air_suspension_score), 5) * 0.04 +
    COALESCE(MAX(dual_motor_score),     5) * 0.05 +
    COALESCE(MAX(cybertruck_score),     5) * 0.04 +
    COALESCE(MAX(pcs_score),            5) * 0.05
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
      d.status, NULL, GREATEST(0, -COALESCE(d.regen_degradation_pct, 0))
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
      GREATEST(GREATEST(0, -COALESCE(rb.regen_torque_trend_pct, 0)),
               GREATEST(0, COALESCE(rb.eff_trend_pct, 0)))
    ), 5) AS regen_brake_score,
    -- Suspension (4 %)
    COALESCE(subsystem_risk_score(s.overall_status, s.max_alert_severity), 5) AS suspension_score,
    -- Air Suspension (5 %)
    COALESCE(subsystem_risk_score(
      air.status, NULL,
      GREATEST(GREATEST(0, COALESCE(air.cycling_trend_pct, 0)),
               GREATEST(0, COALESCE(air.drift_trend_pct, 0)))
    ), 5) AS air_suspension_score,
    -- Dual Motor (5 %)
    COALESCE(subsystem_risk_score(
      dm.status, dm.severity,
      GREATEST(GREATEST(0, COALESCE(dm.temp_delta_trend_pct, 0)),
               GREATEST(0, -COALESCE(dm.regen_trend_pct, 0)))
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
),
-- ranked CTE folds in derived columns so the overall_risk_score is computed
-- exactly once (B1 fix) and downstream CASE statements reference it instead
-- of re-summing the weighted expression.  thermal_risk is now a continuous
-- mapping rather than a 2-state step (R1 fix), and telemetry freshness is
-- exposed so dashboards can distinguish "healthy" from "no data" (B4 fix).
ranked AS (
  SELECT
    s.*,
    -- Continuous brick-imbalance risk: 0 V → 0, 0.5 V → 100 (was {5,50} step)
    LEAST(100, GREATEST(0, COALESCE(s.last_day_brick_delta_max, 0) * 200))
      ::INTEGER AS brick_delta_score,
    -- Newest telemetry timestamp & age in hours.  A subsystem score of 5
    -- (= NORMAL) only means "healthy" when telemetry_age_h is recent; if
    -- it is large, the score should be interpreted as "unknown" instead.
    (SELECT MAX(ts) FROM telemetry t WHERE t.vin = s.vin) AS telemetry_last_ts,
    ROUND((EXTRACT(EPOCH FROM (
      NOW() - (SELECT MAX(ts) FROM telemetry t WHERE t.vin = s.vin)
    )) / 3600.0)::numeric, 1) AS telemetry_age_h,
    -- Overall weighted score: single source of truth.  Weights sum to 1.00.
    ROUND((
      s.battery_score        * 0.22 +
      s.drivetrain_score     * 0.14 +
      s.alert_score          * 0.15 +
      s.low_voltage_score    * 0.10 +
      s.heat_pump_score      * 0.10 +
      s.regen_brake_score    * 0.07 +
      s.suspension_score     * 0.04 +
      s.air_suspension_score * 0.04 +
      s.dual_motor_score     * 0.05 +
      s.cybertruck_score     * 0.04 +
      s.pcs_score            * 0.05
    )::numeric, 1) AS overall_risk_score
  FROM scores s
)
SELECT
  ranked.vin,
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
  -- Thermal risk is a true continuous blend (R1 fix): heat-pump degradation
  -- weighted 0.60, brick imbalance scaled 0–100 weighted 0.40.
  ROUND((heat_pump_score * 0.60 + brick_delta_score * 0.40)::numeric, 0)
    AS thermal_risk,
  overall_risk_score,
  telemetry_last_ts,
  telemetry_age_h,
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
  -- Recommended action.  Heat-pump degradation now routes to a service
  -- recommendation (N4 fix); the overall thresholds reference the named
  -- overall_risk_score column rather than re-summing weights (B1 fix).
  CASE
    WHEN COALESCE(critical_active, 0) > 0
      THEN 'IMMEDIATE SERVICE — Critical: ' || COALESCE(critical_codes, '')
    WHEN battery_score >= 85
      THEN 'Schedule battery service — degradation or imbalance detected'
    WHEN drivetrain_score >= 85
      THEN 'Schedule drivetrain inspection — inverter overheat or motor degradation'
    WHEN heat_pump_score >= 75
      THEN 'Schedule HVAC inspection — heat-pump power-per-degree drift detected'
    WHEN air_suspension_score >= 75
      THEN 'Schedule air-suspension inspection — compressor over-cycling or leak suspected'
    WHEN dual_motor_score >= 75
      THEN 'Schedule dual-motor inspection — imbalance, regen degradation, or thermal throttling'
    WHEN cybertruck_score >= 75
      THEN 'Schedule Cybertruck-specific inspection — tonneau, V2L, tri-motor, or 4680 battery issue'
    WHEN alert_score >= 75 AND COALESCE(urgent_active, 0) > 0
      THEN 'Schedule service — Urgent: ' || COALESCE(urgent_codes, '')
    WHEN overall_risk_score >= 60
      THEN 'Monitor closely — multiple subsystems showing degradation'
    WHEN overall_risk_score >= 40
      THEN 'Plan preventive maintenance — emerging wear patterns detected'
    ELSE 'All systems nominal — continue regular monitoring'
  END AS recommended_action,
  vm.model,
  vm.battery_type,
  vm.has_heat_pump,
  vm.has_air_suspension
FROM ranked
LEFT JOIN vehicle_metadata vm ON vm.vin = ranked.vin;

-- ------------------------------------------------------------------
-- 3.  low_voltage_diagnostics — reachable sudden-onset detection.
--
-- cycling_baseline is a 30-day window ending 7 days back, so it shares
-- no rows with cycling_7d and can legitimately be zero while the
-- recent window is not. The two new columns are appended at the end,
-- which CREATE OR REPLACE VIEW permits, so 014 and the dashboards keep
-- their existing column positions.
--
-- Note that this detects a change in a DCDC-activity proxy during
-- sleep, not a measurement of the 12 V battery. Treat the status as a
-- prompt to diagnose, not as evidence to replace the battery: parked
-- exposure, Sentry, climate and charging activity are not yet
-- controlled for.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW low_voltage_diagnostics AS
WITH daily AS (
  SELECT
    bucket,
    vin,
    sleep_hours,
    dcdc_cycling_sleep_hours,
    dcdc_always_on_sleep_hours,
    dcdc_true_samples_during_sleep,
    -- Wake-up rate: cycling hours per sleep hour (0.0 = perfect sleep)
    CASE WHEN sleep_hours > 0
      THEN dcdc_cycling_sleep_hours::numeric / sleep_hours
      ELSE 0
    END AS wakeup_rate
  FROM low_voltage_wakeups_1d
  WHERE sleep_hours >= 1
),
rolling AS (
  SELECT
    bucket,
    vin,
    sleep_hours,
    dcdc_cycling_sleep_hours,
    dcdc_always_on_sleep_hours,
    dcdc_true_samples_during_sleep,
    wakeup_rate,
    -- 7-day rolling averages
    AVG(dcdc_cycling_sleep_hours) OVER w7 AS cycling_7d,
    AVG(dcdc_true_samples_during_sleep) OVER w7 AS samples_7d,
    AVG(wakeup_rate) OVER w7 AS rate_7d,
    -- 30-day rolling averages
    AVG(dcdc_cycling_sleep_hours) OVER w30 AS cycling_30d,
    AVG(dcdc_true_samples_during_sleep) OVER w30 AS samples_30d,
    AVG(wakeup_rate) OVER w30 AS rate_30d,
    -- Prior-only baseline: 30 days ending where the 7-day window
    -- starts, so it shares no rows with cycling_7d.
    AVG(dcdc_cycling_sleep_hours) OVER wbase AS cycling_baseline,
    -- Observation counts for confidence
    COUNT(*) OVER w7 AS n_7d,
    COUNT(*) OVER w30 AS n_30d,
    COUNT(*) OVER wbase AS n_base
  FROM daily
  WINDOW
    w7  AS (PARTITION BY vin ORDER BY bucket RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY vin ORDER BY bucket RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW),
    wbase AS (PARTITION BY vin ORDER BY bucket RANGE BETWEEN INTERVAL '37 days' PRECEDING AND INTERVAL '7 days' PRECEDING)
)
SELECT
  bucket AS ts,
  vin,
  sleep_hours,
  dcdc_cycling_sleep_hours,
  dcdc_always_on_sleep_hours,
  dcdc_true_samples_during_sleep,
  ROUND(wakeup_rate::numeric, 3) AS wakeup_rate,
  ROUND(cycling_7d::numeric, 2) AS cycling_7d_avg,
  ROUND(cycling_30d::numeric, 2) AS cycling_30d_avg,
  ROUND(rate_7d::numeric, 3) AS rate_7d_avg,
  ROUND(rate_30d::numeric, 3) AS rate_30d_avg,
  n_7d,
  n_30d,
  -- Degradation flag: >2x the prior baseline, OR onset from a prior
  -- baseline of zero.
  --
  -- Both branches now compare against cycling_baseline rather than
  -- cycling_30d. cycling_30d contains the same rows as cycling_7d, so
  -- the onset branch ("baseline zero, recent >= 2") described a state
  -- that cannot exist: with non-negative inputs a zero 30-day average
  -- forces a zero 7-day average.
  CASE
    WHEN n_7d >= 3 AND n_base >= 10
     AND cycling_baseline > 0
     AND cycling_7d > cycling_baseline * 2.0
    THEN 'LOW_VOLTAGE_BATTERY_DEGRADATION_LIKELY'
    WHEN n_7d >= 3 AND n_base >= 10
     AND cycling_baseline = 0
     AND cycling_7d >= 2
    THEN 'LOW_VOLTAGE_BATTERY_DEGRADATION_LIKELY'
    ELSE 'NORMAL'
  END AS status,
  -- Trend magnitude (% increase of the recent window over the prior baseline)
  CASE
    WHEN cycling_baseline > 0
    THEN ROUND(((cycling_7d - cycling_baseline) / cycling_baseline * 100)::numeric, 1)
    ELSE NULL
  END AS trend_pct,
  -- New columns, appended so existing positions are unchanged.
  ROUND(cycling_baseline::numeric, 2) AS cycling_baseline_avg,
  n_base
FROM rolling;
