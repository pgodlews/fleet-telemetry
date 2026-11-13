-- ============================================================
-- 047_pcs_requested_current.sql — PCS check against the current
-- that was actually requested (plan section 10.2, FINDINGS 9)
--
-- 006 flagged "PCS module failure" when ChargeAmps fell 16 or 32 A
-- below ChargeCurrentRequestMax taken near session start. The maximum
-- is what the supply offers, not what the car was asked to draw, so a
-- 48 A supply with a 32 A set point looked like a failed module; later
-- set-point changes and end-of-charge taper were ignored.
--
-- Now, per AC charging session (charge_sessions with AC power and no DC
-- power), each ChargeAmps sample is compared with the target in force
-- at that moment, LEAST(ChargeCurrentRequest, ChargeCurrentRequestMax),
-- each the last value reported at or before the sample. A sample is
-- eligible only in stable conditions:
--   * at least 5 minutes after the session started (ramp-up),
--   * the target unchanged for the previous 5 minutes,
--   * state of charge more than 3 points below ChargeLimitSoc
--     (the car tapers current near the limit on purpose).
-- An eligible sample qualifies when the shortfall is at least 6 A and
-- at least 25 % of the target. A session is flagged when qualifying
-- samples are sustained: 3 or more, at least a quarter of the
-- session's eligible samples, and spanning at least 10 minutes.
-- Status per vehicle (last 30 days):
--   PCS_CURRENT_BELOW_REQUEST_REPEATED  2 or more flagged sessions
--   PCS_CURRENT_BELOW_REQUEST           1 flagged session
--   NORMAL                              AC sessions, none flagged
-- The wording is a prompt to investigate (supply, cable, connector
-- temperature or the onboard charger), not a diagnosis.
--
-- On a production copy: 54 AC sessions, 2,409 ChargeAmps samples; of
-- 309 samples with a >= 6 A / 25 % shortfall, 274 were taper near the
-- charge limit and 280 in the last 30 minutes of a session; with the
-- rules above no session is flagged (3 would be on span alone: isolated
-- dips averaging 30-31.6 A against a 32 A target).
--
-- New views pcs_charge_current (per sample) and pcs_charge_sessions
-- (per session) replace pcs_diagnostics / pcs_session_summary, which are
-- dropped (no dashboard read them); pcs_status_summary keeps its columns.
-- pcs_health_1d / pcs_health_1w are left in place but are no longer a
-- scoring input (050). Idempotent.
-- ============================================================

INSERT INTO pm_status_dictionary (status, base_score, notes) VALUES
  ('PCS_CURRENT_BELOW_REQUEST',          40, 'one AC session drew well below the requested current (047)'),
  ('PCS_CURRENT_BELOW_REQUEST_REPEATED', 60, 'two or more AC sessions in 30 days drew well below the requested current (047)')
ON CONFLICT (status) DO UPDATE SET base_score = EXCLUDED.base_score, notes = EXCLUDED.notes;

DROP VIEW IF EXISTS pcs_status_summary;
DROP VIEW IF EXISTS pcs_charge_sessions;
DROP VIEW IF EXISTS pcs_charge_current;
-- The 006 sample/session views encode the old comparison; they are
-- removed rather than reshaped, so that 006 can recreate them on a
-- FORCE=1 re-run (a CREATE OR REPLACE over different columns would fail)
-- and this file drops them again.
DROP VIEW IF EXISTS pcs_session_summary;
DROP VIEW IF EXISTS pcs_diagnostics;

CREATE VIEW pcs_charge_current AS
WITH ac_sessions AS (
  SELECT cs.vin, cs.session_id, cs.started, COALESCE(cs.ended, now()) AS ended
  FROM charge_sessions cs
  WHERE EXISTS (SELECT 1 FROM telemetry p
                WHERE p.vin = cs.vin AND p.field = 'ACChargingPower' AND p.num_value > 0
                  AND p.ts BETWEEN cs.started AND COALESCE(cs.ended, now()))
    AND NOT EXISTS (SELECT 1 FROM telemetry p
                WHERE p.vin = cs.vin AND p.field = 'DCChargingPower' AND p.num_value > 0
                  AND p.ts BETWEEN cs.started AND COALESCE(cs.ended, now()))
), samples AS (
  SELECT s.vin, s.session_id, s.started, s.ended, a.ts, a.num_value AS charge_amps,
         rq.num_value AS current_request, rq.ts AS current_request_ts,
         rm.num_value AS current_request_max, rm.ts AS current_request_max_ts,
         soc.num_value AS soc, lim.num_value AS charge_limit_soc
  FROM ac_sessions s
  JOIN telemetry a ON a.vin = s.vin AND a.field = 'ChargeAmps'
                  AND a.ts >= s.started AND a.ts < s.ended AND a.num_value IS NOT NULL
  LEFT JOIN LATERAL (SELECT num_value, ts FROM telemetry t WHERE t.vin = s.vin AND t.field = 'ChargeCurrentRequest'
                     AND t.ts <= a.ts ORDER BY t.ts DESC LIMIT 1) rq ON TRUE
  LEFT JOIN LATERAL (SELECT num_value, ts FROM telemetry t WHERE t.vin = s.vin AND t.field = 'ChargeCurrentRequestMax'
                     AND t.ts <= a.ts ORDER BY t.ts DESC LIMIT 1) rm ON TRUE
  LEFT JOIN LATERAL (SELECT num_value FROM telemetry t WHERE t.vin = s.vin AND t.field = 'Soc'
                     AND t.ts <= a.ts ORDER BY t.ts DESC LIMIT 1) soc ON TRUE
  LEFT JOIN LATERAL (SELECT num_value FROM telemetry t WHERE t.vin = s.vin AND t.field = 'ChargeLimitSoc'
                     AND t.ts <= a.ts ORDER BY t.ts DESC LIMIT 1) lim ON TRUE
), judged AS (
  SELECT *,
    LEAST(current_request, current_request_max) AS target_amps,
    (ts >= started + INTERVAL '5 minutes'
     AND GREATEST(current_request_ts, current_request_max_ts) <= ts - INTERVAL '5 minutes'
     AND LEAST(current_request, current_request_max) > 0
     AND (soc IS NULL OR charge_limit_soc IS NULL OR soc < charge_limit_soc - 3)) AS eligible
  FROM samples
)
SELECT vin, session_id, started AS session_started, ended AS session_ended, ts,
       charge_amps, current_request, current_request_max, target_amps,
       target_amps - charge_amps AS shortfall_amps, soc, charge_limit_soc, eligible,
       (eligible AND target_amps - charge_amps >= 6
                 AND target_amps - charge_amps >= 0.25 * target_amps) AS below_request
FROM judged;

COMMENT ON VIEW pcs_charge_current IS
  'AC charging current against the requested current in force at each sample
   (047). below_request marks a stable-conditions shortfall of >= 6 A and
   >= 25 % of the target.';

CREATE VIEW pcs_charge_sessions AS
SELECT vin, session_id,
  MIN(session_started) AS started,
  MAX(session_ended)   AS ended,
  COUNT(*)                          AS samples,
  COUNT(*) FILTER (WHERE eligible)  AS eligible_samples,
  COUNT(*) FILTER (WHERE below_request) AS below_request_samples,
  MAX(target_amps)  FILTER (WHERE eligible) AS target_amps,
  AVG(charge_amps)  FILTER (WHERE eligible) AS avg_amps,
  MAX(shortfall_amps) FILTER (WHERE below_request) AS max_shortfall_amps,
  MAX(ts) FILTER (WHERE below_request) - MIN(ts) FILTER (WHERE below_request) AS below_request_span,
  -- Sustained: at least 3 short samples, at least a quarter of the
  -- session's eligible samples, spanning at least 10 minutes. Isolated
  -- dips (3-6 of 65-109 samples in the production copy) do not count.
  (COUNT(*) FILTER (WHERE below_request) >= 3
   AND COUNT(*) FILTER (WHERE below_request) >= 0.25 * COUNT(*) FILTER (WHERE eligible)
   AND MAX(ts) FILTER (WHERE below_request) - MIN(ts) FILTER (WHERE below_request) >= INTERVAL '10 minutes') AS flagged
FROM pcs_charge_current
GROUP BY vin, session_id;

CREATE VIEW pcs_status_summary AS
WITH recent AS (
  SELECT * FROM pcs_charge_sessions WHERE started > now() - INTERVAL '30 days'
), latest AS (
  SELECT vin, MAX(started) AS last_session_started FROM pcs_charge_sessions GROUP BY vin
), agg AS (
  SELECT vin,
    COUNT(*) FILTER (WHERE flagged) AS flagged_30d,
    MAX(max_shortfall_amps) FILTER (WHERE flagged) AS max_shortfall
  FROM recent GROUP BY vin
)
SELECT l.vin,
  l.last_session_started AS last_session_ts,
  CASE
    WHEN COALESCE(a.flagged_30d, 0) >= 2 THEN 'PCS_CURRENT_BELOW_REQUEST_REPEATED'
    WHEN COALESCE(a.flagged_30d, 0) = 1  THEN 'PCS_CURRENT_BELOW_REQUEST'
    ELSE 'NORMAL'
  END AS status,
  ROUND(a.max_shortfall::numeric, 1) AS deficit_amps,
  COALESCE(a.flagged_30d, 0)::bigint AS sessions_affected,
  (SELECT COUNT(*) FROM recent r WHERE r.vin = l.vin)::bigint AS total_sessions,
  vm.model
FROM latest l
LEFT JOIN agg a ON a.vin = l.vin
LEFT JOIN vehicle_metadata vm ON vm.vin = l.vin;

COMMENT ON VIEW pcs_status_summary IS
  'AC charging current vs requested current over the last 30 days (047).
   sessions_affected / total_sessions count AC sessions in that window;
   deficit_amps is the largest shortfall in a flagged session. A flag is a
   prompt to check the supply, cable, connector and onboard charger.';
