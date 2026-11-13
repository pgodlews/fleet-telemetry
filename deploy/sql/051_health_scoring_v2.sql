-- ============================================================
-- 051_health_scoring_v2.sql — no evidence is not "healthy"; one bad
-- subsystem can turn the headline red (S1, S7 scoring, FINDINGS 2)
--
-- Before: every subsystem without rows, without recent evidence or not
-- fitted to the car scored 5 (= NORMAL) and kept its weight, so a rear-
-- drive Model 3 was "healthy" on dual motor, Cybertruck and air
-- suspension; a PCS score of 95 moved the total by 4.75 points; the
-- headline only said more than "All systems nominal" past a weighted 40;
-- and highest_risk_subsystem said "Battery" whenever everything was 5.
--
-- Now, in predictive_health_summary (and the daily series):
--   * A subsystem score is NULL when the subsystem does not apply to the
--     vehicle (subsystem_applies: heat pump needs has_heat_pump, dual
--     motor a dual/tri-motor config, Cybertruck model CT), when its
--     input reports NO_DATA / NOT_APPLICABLE, or when its newest
--     evidence is older than subsystem_evidence_limit():
--       battery 45 days (weekly full charges), suspension 30 days
--       (needs straight highway driving), everything else 14 days.
--     Each subsystem's evidence timestamp is a column (<name>_last_ts).
--   * overall_risk_score is the weighted mean over the non-NULL scores
--     only (weights in subsystem_weight(), unchanged from 031 apart from
--     air suspension, which is gone — 045); NULL when nothing is scored.
--     scored_subsystems / scored_weight say how much evidence it rests on.
--   * headline_severity = the worst of: the band of the weighted score,
--     any single subsystem's band, CRITICAL for any active critical
--     alert (even with nothing else scored); NO_DATA when nothing is
--     scored and no critical alert is active. Bands (risk_band): >= 85
--     CRITICAL, >= 60 WARNING, >= 40 CAUTION, else NORMAL.
--   * highest_risk_subsystem is NULL unless some score is >= 40.
--   * recommended_action has an explicit branch for every subsystem at
--     its critical and warning bands (including PCS, 12 V, suspension,
--     regen/brake), and a "no recent data" text instead of "nominal"
--     when nothing could be scored.
--   * Battery is scored on the full-charge estimator the headline shows
--     (battery_health_summary / battery_full_charge_trend, 049), with the
--     same-timestamp brick spread (046).
--   * PCS is scored from pcs_status_summary (047); the hourly
--     pcs_health_1d failure_hours (the old 16/32 A rule) is no longer
--     an input.
--   * telemetry_last_ts / telemetry_age_h now describe the newest
--     diagnostic evidence across subsystems, not the newest row of any
--     field (a GPS point made months-old diagnostics look current);
--     vehicle_last_seen is the newest telemetry row, computed on read.
--
-- Stored like 041: <name>_live holds the body, <name>_mat the rows
-- (refreshed hourly by refresh_predictive_matviews_job), and <name> is
-- a thin view; ages are computed on read. The objects were dropped in
-- 045 and are created fresh here (column lists changed). Idempotent.
-- ============================================================

-- ------------------------------------------------------------------
-- Rules in one place.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION subsystem_weight(subsystem text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE subsystem
    WHEN 'battery'     THEN 0.22
    WHEN 'drivetrain'  THEN 0.14
    WHEN 'alerts'      THEN 0.15
    WHEN 'low_voltage' THEN 0.10
    WHEN 'heat_pump'   THEN 0.10
    WHEN 'regen_brake' THEN 0.07
    WHEN 'suspension'  THEN 0.04
    WHEN 'dual_motor'  THEN 0.05
    WHEN 'cybertruck'  THEN 0.04
    WHEN 'pcs'         THEN 0.05
  END::numeric
$$;

CREATE OR REPLACE FUNCTION subsystem_evidence_limit(subsystem text)
RETURNS interval LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE subsystem
    WHEN 'battery'    THEN INTERVAL '45 days'
    WHEN 'suspension' THEN INTERVAL '30 days'
    ELSE INTERVAL '14 days'
  END
$$;

CREATE OR REPLACE FUNCTION subsystem_applies(subsystem text, model text, motor_config text, has_heat_pump boolean)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE subsystem
    WHEN 'heat_pump'  THEN COALESCE(has_heat_pump, false)
    WHEN 'dual_motor' THEN COALESCE(motor_config IN ('Dual Motor', 'Performance', 'Tri Motor'), false)
    WHEN 'cybertruck' THEN COALESCE(model = 'CT', false)
    ELSE true
  END
$$;

CREATE OR REPLACE FUNCTION risk_band(score numeric)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN score IS NULL THEN NULL
    WHEN score >= 85 THEN 'CRITICAL'
    WHEN score >= 60 THEN 'WARNING'
    WHEN score >= 40 THEN 'CAUTION'
    ELSE 'NORMAL'
  END
$$;

CREATE OR REPLACE FUNCTION band_rank(band text)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE band WHEN 'CRITICAL' THEN 4 WHEN 'WARNING' THEN 3 WHEN 'CAUTION' THEN 2 WHEN 'NORMAL' THEN 1 ELSE 0 END
$$;

-- Weighted mean over non-NULL scores (scores and weights in the same order).
CREATE OR REPLACE FUNCTION weighted_mean(scores numeric[], weights numeric[])
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN SUM(w) FILTER (WHERE s IS NOT NULL) > 0
              THEN ROUND(SUM(s * w) FILTER (WHERE s IS NOT NULL) / SUM(w) FILTER (WHERE s IS NOT NULL), 1) END
  FROM UNNEST(scores, weights) AS u(s, w)
$$;

-- ------------------------------------------------------------------
-- Daily series.
-- ------------------------------------------------------------------
DROP VIEW IF EXISTS predictive_health_score_1d;
DROP MATERIALIZED VIEW IF EXISTS predictive_health_score_1d_mat;
DROP VIEW IF EXISTS predictive_health_score_1d_live;

CREATE VIEW predictive_health_score_1d_live AS
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

CREATE MATERIALIZED VIEW predictive_health_score_1d_mat AS
  SELECT * FROM predictive_health_score_1d_live
WITH NO DATA;
CREATE UNIQUE INDEX predictive_health_score_1d_mat_uq ON predictive_health_score_1d_mat (vin, ts);

CREATE VIEW predictive_health_score_1d AS
  SELECT * FROM predictive_health_score_1d_mat;

COMMENT ON VIEW predictive_health_score_1d IS
  'Daily per-subsystem risk scores; NULL = no evidence that day or not
   applicable to the vehicle. Overall is renormalised over the scored
   subsystems (051). Stored in predictive_health_score_1d_mat.';

-- ------------------------------------------------------------------
-- Current summary.
-- ------------------------------------------------------------------
DROP VIEW IF EXISTS predictive_health_recommendations;
DROP VIEW IF EXISTS predictive_health_summary;
DROP MATERIALIZED VIEW IF EXISTS predictive_health_summary_mat;
DROP VIEW IF EXISTS predictive_health_summary_live;

CREATE VIEW predictive_health_summary_live AS
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
    subsystem_risk_score(b.overall_status, b.max_alert_severity,
                         GREATEST(0, b.capacity_degradation_pct)::double precision,
                         b.last_day_brick_delta_max) AS battery_raw,
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
    CASE WHEN battery_score IS NOT NULL
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

CREATE MATERIALIZED VIEW predictive_health_summary_mat AS
  SELECT * FROM predictive_health_summary_live
WITH NO DATA;
CREATE UNIQUE INDEX predictive_health_summary_mat_uq ON predictive_health_summary_mat (vin);

-- Public view: stored rows; ages and "last seen" computed on read.
CREATE VIEW predictive_health_summary AS
SELECT
  m.vin,
  m.battery_score, m.drivetrain_score, m.alert_score, m.low_voltage_score, m.heat_pump_score,
  m.regen_brake_score, m.suspension_score, m.dual_motor_score, m.cybertruck_score, m.pcs_score,
  m.battery_risk, m.powertrain_risk, m.thermal_risk, m.overall_risk_score,
  m.telemetry_last_ts,
  ROUND((EXTRACT(EPOCH FROM (now() - m.telemetry_last_ts)) / 3600.0)::numeric, 1) AS telemetry_age_h,
  m.highest_risk_subsystem,
  m.critical_alerts, m.urgent_alerts, m.warning_alerts, m.total_active_alerts,
  m.active_critical_codes, m.active_urgent_codes,
  m.recommended_action,
  m.model, m.battery_type, m.has_heat_pump,
  m.headline_severity, m.scored_subsystems, m.scored_weight,
  m.battery_last_ts, m.drivetrain_last_ts, m.alerts_last_ts, m.low_voltage_last_ts, m.heat_pump_last_ts,
  m.regen_brake_last_ts, m.suspension_last_ts, m.dual_motor_last_ts, m.cybertruck_last_ts, m.pcs_last_ts,
  m.capacity_degradation_pct, m.last_day_brick_delta_max, m.inverter_temp_max, m.regen_degradation_pct,
  m.brake_remaining_pct, m.eff_trend_pct, m.heat_pump_trend_pct, m.suspension_lat_std_trend_pct,
  m.dual_motor_temp_delta_trend_pct, m.dual_motor_regen_trend_pct,
  lt.ts AS vehicle_last_seen
FROM predictive_health_summary_mat m
LEFT JOIN LATERAL (SELECT t.ts FROM telemetry t WHERE t.vin = m.vin ORDER BY t.ts DESC LIMIT 1) lt ON TRUE;

COMMENT ON VIEW predictive_health_summary IS
  'Current per-VIN risk summary (051). Scores are NULL when the subsystem does
   not apply or its evidence (<name>_last_ts) is older than
   subsystem_evidence_limit(); the overall score is renormalised over the
   scored subsystems. telemetry_last_ts/_age_h = newest diagnostic evidence;
   vehicle_last_seen = newest telemetry row. Stored in
   predictive_health_summary_mat (hourly); ages computed on read.';

-- ------------------------------------------------------------------
-- Recommendations: 038 texts, no air suspension, NULL = no data.
-- ------------------------------------------------------------------
CREATE VIEW predictive_health_recommendations AS
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
    CASE WHEN brake_remaining_pct <= 25 THEN 'Have brake pads measured now — mileage-based estimate below 25% (unvalidated: assumes 50,000 mi pad life, ignores past replacements)'
         WHEN brake_remaining_pct <= 50 THEN 'Have brake pads measured at the next service — mileage-based estimate near 50%'
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
SELECT vin, subsystem, risk_score,
  CASE
    WHEN risk_score IS NULL THEN 'NO DATA'
    WHEN subsystem IN ('12V / Electrical', 'Charging (PCS)') AND risk_score >= 60 THEN 'WARNING'
    WHEN subsystem = 'Brakes' THEN
      CASE WHEN risk_score >= 75 THEN 'CRITICAL' WHEN risk_score >= 50 THEN 'WARNING'
           WHEN risk_score >= 25 THEN 'CAUTION' ELSE 'OK' END
    ELSE COALESCE(NULLIF(risk_band(risk_score), 'NORMAL'), 'OK')
  END AS severity,
  CASE WHEN risk_score IS NULL
       THEN 'No recent data for this subsystem (or it does not apply to this vehicle)'
       ELSE recommendation END AS recommendation,
  evidence_ts
FROM arms;

COMMENT ON VIEW predictive_health_recommendations IS
  'One row per subsystem with its risk, severity and advice (051). risk_score
   NULL / severity NO DATA = no recent evidence; evidence_ts is the newest
   input the row rests on.';

-- ------------------------------------------------------------------
-- Refresh rotation: the carried state first (046), the daily
-- diagnostics, then the two stored health views. Air suspension is gone.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION predictive_matview_list()
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY[
    'vehicle_state_1h',
    'battery_capacity_1d',
    'pcs_health_1d',
    'pcs_health_1w',
    'heat_pump_cop_1d',
    'low_voltage_wakeups_1d',
    'suspension_steering_1d',
    'drivetrain_highway_1d',
    'regen_brake_daily_1d',
    'alert_frequency_1w',
    'dual_motor_highway_1d',
    'tri_motor_highway_1d',
    'ct_tonneau_daily_1d',
    'ct_v2l_daily_1d',
    'predictive_health_score_1d_mat',
    'predictive_health_summary_mat'
  ]::text[]
$$;

SELECT refresh_one_matview('predictive_health_score_1d_mat') AS score_1d_refreshed;
SELECT refresh_one_matview('predictive_health_summary_mat')  AS summary_refreshed;
