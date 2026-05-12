-- ============================================================
-- PCS (Power Conversion System) Diagnostics Layer
--
-- The 2021 Tesla Model 3 onboard charger contains three 16 A
-- Features are gated per docs/FEATURE_MATRIX.md using vehicle_metadata.
-- modules (48 A theoretical max).  When one module fails the
-- car can only deliver 32 A (deficit = 16 A).  When two fail
-- the ceiling drops to 16 A (deficit = 32 A).
--
-- This script detects persistent deficits that indicate a
-- failed PCS module, as opposed to normal tapering or EVSE
-- limitations.
--
-- Requires superuser (postgres) to run — creates CAGGs.
-- Run after 001_schema.sql and 002_views.sql.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Hourly pivot CAGG — ChargeAmps / ChargeCurrentRequestMax /
--     ACChargingPower aligned per hour per VIN.
--
-- We use MAX() pivoting because the fields are sampled at
-- slightly different timestamps inside the same hour.
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS pcs_samples_1h CASCADE;

CREATE MATERIALIZED VIEW pcs_samples_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin,
  MAX(CASE WHEN field = 'ChargeAmps'            THEN num_value END) AS charge_amps_max,
  AVG(CASE WHEN field = 'ChargeAmps'            THEN num_value END) AS charge_amps_avg,
  MAX(CASE WHEN field = 'ChargeCurrentRequestMax' THEN num_value END) AS charge_current_request_max,
  MAX(CASE WHEN field = 'ACChargingPower'         THEN num_value END) AS ac_power_max,
  AVG(CASE WHEN field = 'ACChargingPower'         THEN num_value END) AS ac_power_avg,
  COUNT(*) FILTER (WHERE field = 'ChargeAmps')            AS n_amps,
  COUNT(*) FILTER (WHERE field = 'ChargeCurrentRequestMax') AS n_max_req
FROM telemetry
WHERE field IN ('ChargeAmps', 'ChargeCurrentRequestMax', 'ACChargingPower')
  AND num_value IS NOT NULL
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 2.  Daily PCS health summary (built on the hourly pivot)
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS pcs_health_1d CASCADE;

CREATE MATERIALIZED VIEW pcs_health_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  -- Largest observed deficit during any hour with active AC charging
  MAX(charge_current_request_max - charge_amps_max)
    FILTER (WHERE ac_power_max > 0
               AND charge_current_request_max IS NOT NULL
               AND charge_amps_max IS NOT NULL) AS max_deficit_amps,
  -- Hours where the car was actively charging
  COUNT(*) FILTER (WHERE ac_power_max > 0) AS charging_hours,
  -- Hours where deficit rounded to exactly 16 or 32 A
  COUNT(*) FILTER (WHERE ac_power_max > 0
                     AND charge_current_request_max IS NOT NULL
                     AND charge_amps_max IS NOT NULL
                     AND ROUND(charge_current_request_max - charge_amps_max) IN (16, 32))
    AS failure_hours
FROM pcs_samples_1h
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 3.  Weekly PCS health summary (built on the daily matview)
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS pcs_health_1w CASCADE;

CREATE MATERIALIZED VIEW pcs_health_1w AS
SELECT
  time_bucket('7 days', bucket) AS bucket,
  vin,
  MAX(max_deficit_amps) AS max_deficit_amps,
  SUM(charging_hours)   AS charging_hours,
  SUM(failure_hours)    AS failure_hours
FROM pcs_health_1d
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 4.  Refresh policies
-- ------------------------------------------------------------------
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('pcs_samples_1h');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('pcs_samples_1h',
  start_offset  => INTERVAL '7 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- pcs_health_1d and pcs_health_1w are now regular matviews;
-- add_continuous_aggregate_policy does not apply to them.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('pcs_health_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('pcs_health_1w'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ------------------------------------------------------------------
-- 5.  pcs_diagnostics  — sample-level deficit & streak detection
--
-- Logic:
--   1. Detect AC charging sessions from ACChargingPower > 0
--      (gap > 10 min starts a new session).
--   2. For each ChargeAmps sample inside a session, look up the
--      ChargeCurrentRequestMax that was in force at that moment.
--   3. deficit = max_request - actual_amps.
--   4. A "failure streak" = ≥3 consecutive samples (gap ≤ 2 min)
--      where ROUND(deficit) is exactly 16 or 32 A.
--   5. pcs_module_failure_likely is TRUE for every sample that
--      belongs to such a streak.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW pcs_diagnostics AS
WITH
-- a) Detect AC charging sessions from ACChargingPower > 0
ac_raw AS (
  SELECT ts, vin,
    ts - LAG(ts) OVER (PARTITION BY vin ORDER BY ts) AS gap
  FROM telemetry
  WHERE field = 'ACChargingPower'
    AND num_value > 0
),
ac_sessions AS (
  SELECT
    vin,
    session_id,
    MIN(ts) AS started,
    MAX(ts) AS ended
  FROM (
    SELECT
      ts, vin,
      SUM(CASE WHEN gap > INTERVAL '10 minutes' OR gap IS NULL THEN 1 ELSE 0 END)
        OVER (PARTITION BY vin ORDER BY ts) AS session_id
    FROM ac_raw
  ) s
  GROUP BY vin, session_id
),
-- b) Find the ChargeCurrentRequestMax applicable to each session.
--    We look for the nearest sample (before or after session start).
session_max AS (
  SELECT
    s.vin,
    s.session_id,
    s.started,
    s.ended,
    COALESCE(
      -- value at or before session start
      (SELECT num_value FROM telemetry
       WHERE vin = s.vin AND field = 'ChargeCurrentRequestMax'
         AND ts <= s.started
       ORDER BY ts DESC LIMIT 1),
      -- value at or after session start
      (SELECT num_value FROM telemetry
       WHERE vin = s.vin AND field = 'ChargeCurrentRequestMax'
         AND ts >= s.started
       ORDER BY ts ASC LIMIT 1),
      -- fallback to ChargeCurrentRequest (same semantic meaning)
      (SELECT num_value FROM telemetry
       WHERE vin = s.vin AND field = 'ChargeCurrentRequest'
         AND ts <= s.started
       ORDER BY ts DESC LIMIT 1),
      (SELECT num_value FROM telemetry
       WHERE vin = s.vin AND field = 'ChargeCurrentRequest'
         AND ts >= s.started
       ORDER BY ts ASC LIMIT 1)
    ) AS charge_current_request_max
  FROM ac_sessions s
),
-- c) Align every ChargeAmps sample with its session & max request.
aligned AS (
  SELECT
    ca.ts,
    ca.vin,
    sm.session_id,
    sm.started,
    sm.ended,
    sm.charge_current_request_max,
    ca.num_value AS charge_amps,
    sm.charge_current_request_max - ca.num_value AS deficit_amps,
    ROUND(sm.charge_current_request_max - ca.num_value) AS deficit_rounded
  FROM telemetry ca
  JOIN session_max sm ON sm.vin = ca.vin
    AND ca.ts BETWEEN sm.started AND sm.ended
  WHERE ca.field = 'ChargeAmps'
    AND ca.num_value > 0
    AND sm.charge_current_request_max IS NOT NULL
),
-- d) Identify streaks of exactly 16 or 32 A deficit.
--    A new streak starts when:
--      • deficit is not 16 or 32, OR
--      • gap between samples > 2 minutes.
streak_markers AS (
  SELECT
    *,
    CASE
      WHEN deficit_rounded NOT IN (16, 32) THEN 1
      WHEN ts - LAG(ts) OVER (PARTITION BY vin, session_id ORDER BY ts)
           > INTERVAL '2 minutes' THEN 1
      ELSE 0
    END AS is_new_streak
  FROM aligned
),
streaks AS (
  SELECT
    *,
    SUM(is_new_streak) OVER (PARTITION BY vin, session_id ORDER BY ts) AS streak_id
  FROM streak_markers
),
-- e) Count samples in each streak and flag those with ≥3 failures.
streak_summary AS (
  SELECT
    vin,
    session_id,
    streak_id,
    COUNT(*) FILTER (WHERE deficit_rounded IN (16, 32)) AS failure_samples,
    MIN(ts) FILTER (WHERE deficit_rounded IN (16, 32)) AS streak_start,
    MAX(ts) FILTER (WHERE deficit_rounded IN (16, 32)) AS streak_end
  FROM streaks
  GROUP BY vin, session_id, streak_id
  HAVING COUNT(*) FILTER (WHERE deficit_rounded IN (16, 32)) >= 3
)
-- f) Join streak flags back to every sample.
SELECT
  a.ts,
  a.vin,
  a.session_id,
  a.started AS session_started,
  a.ended   AS session_ended,
  a.charge_current_request_max,
  a.charge_amps,
  a.deficit_amps,
  a.deficit_rounded,
  CASE WHEN ss.failure_samples IS NOT NULL THEN TRUE ELSE FALSE END
    AS pcs_module_failure_likely,
  ss.failure_samples,
  ss.streak_start,
  ss.streak_end
FROM aligned a
LEFT JOIN streak_summary ss
  ON ss.vin = a.vin
 AND ss.session_id = a.session_id
 AND ss.streak_id = (
   -- find the streak this sample belongs to
   SELECT sub.streak_id
   FROM streaks sub
   WHERE sub.vin = a.vin
     AND sub.session_id = a.session_id
     AND sub.ts = a.ts
   LIMIT 1
 );

-- ------------------------------------------------------------------
-- 6.  pcs_session_summary  — per-session aggregation
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW pcs_session_summary AS
SELECT
  vin,
  session_id,
  MIN(session_started) AS started,
  MAX(session_ended)   AS ended,
  MAX(charge_current_request_max) AS charge_current_request_max,
  MAX(charge_amps)     AS max_amps,
  MIN(charge_amps)     AS min_amps,
  AVG(charge_amps)     AS avg_amps,
  MAX(deficit_amps)    AS max_deficit,
  COUNT(*) FILTER (WHERE pcs_module_failure_likely) AS failure_samples,
  COUNT(DISTINCT streak_start) AS failure_streaks,
  BOOL_OR(pcs_module_failure_likely) AS pcs_module_failure_likely
FROM pcs_diagnostics
GROUP BY vin, session_id;

-- ------------------------------------------------------------------
-- 7.  pcs_status_summary  — Grafana-friendly current snapshot
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW pcs_status_summary AS
WITH latest AS (
  SELECT vin, MAX(started) AS last_session_started
  FROM pcs_session_summary
  GROUP BY vin
)
SELECT
  l.vin,
  l.last_session_started AS last_session_ts,
  CASE
    WHEN s.pcs_module_failure_likely THEN 'PCS_MODULE_FAILURE_LIKELY'
    ELSE 'NORMAL'
  END AS status,
  ROUND(s.max_deficit::numeric, 1) AS deficit_amps,
  (SELECT COUNT(DISTINCT session_id)
   FROM pcs_session_summary s2
   WHERE s2.vin = l.vin
     AND s2.pcs_module_failure_likely) AS sessions_affected,
  (SELECT COUNT(DISTINCT session_id)
   FROM pcs_session_summary s3
   WHERE s3.vin = l.vin) AS total_sessions,
  vm.model
FROM latest l
LEFT JOIN pcs_session_summary s
  ON s.vin = l.vin AND s.started = l.last_session_started
LEFT JOIN vehicle_metadata vm ON vm.vin = l.vin;

-- ------------------------------------------------------------------
-- 8.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "PCS Status"  (big Stat panel)
-- --------------------------------------------------------
-- Red   = PCS_MODULE_FAILURE_LIKELY
-- Green = NORMAL
--
-- SELECT status, deficit_amps, sessions_affected
-- FROM pcs_status_summary
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "PCS Deficit Trend"  (Time series)
-- --------------------------------------------------
-- SELECT
--   bucket AS time,
--   max_deficit_amps AS "Max Deficit (A)"
-- FROM pcs_health_1d
-- WHERE vin = '$vin'
--   AND $__timeFilter(bucket)
-- ORDER BY bucket;

-- --------------------------------------------------------
-- Panel: "Charging Sessions with PCS Failure"  (Table)
-- --------------------------------------------------
-- SELECT
--   started AS "Session Start",
--   ended   AS "Session End",
--   charge_current_request_max AS "Requested Max (A)",
--   max_amps AS "Actual Max (A)",
--   max_deficit AS "Deficit (A)",
--   failure_streaks AS "Failure Streaks"
-- FROM pcs_session_summary
-- WHERE vin = '$vin'
--   AND pcs_module_failure_likely
-- ORDER BY started DESC;

-- ------------------------------------------------------------------
-- 9.  How to test with the simulator
-- ------------------------------------------------------------------
-- The simulator generates ChargeAmps and ACChargingPower inside
-- the bands defined in bandsFor().  By default it will never
-- produce a persistent 16 A deficit, so we inject a synthetic
-- PCS failure manually.
--
-- Step 1 — Start the simulator
--   go run ./tools/simulator \
--     -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
--     -vins "SIMULATEDVIN001" \
--     -interval 30
--
--   Let it run until ACChargingPower > 0 (simulator enters
--   "Charging" mode after a few minutes).
--
-- Step 2 — Confirm charging is active
--   SELECT ts, num_value FROM telemetry
--   WHERE vin = 'SIMULATEDVIN001' AND field = 'ACChargingPower'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 3 — Inject a one-module failure (16 A deficit)
--   We need ChargeCurrentRequestMax to stay at 48 A while
--   ChargeAmps is locked at 32 A for ≥3 consecutive samples.
--   Because the simulator writes ChargeAmps from a sine wave,
--   the cleanest way is a direct INSERT:
--
--   INSERT INTO telemetry (ts, vin, field, num_value)
--   SELECT generate_series(
--     NOW(),
--     NOW() + INTERVAL '2 minutes',
--     INTERVAL '30 seconds'
--   ), 'SIMULATEDVIN001', 'ChargeAmps', 32.0;
--
--   -- Make sure ChargeCurrentRequestMax is 48 A at the same time:
--   INSERT INTO telemetry (ts, vin, field, num_value)
--   VALUES (NOW(), 'SIMULATEDVIN001', 'ChargeCurrentRequestMax', 48.0);
--
-- Step 4 — Force a two-module failure (32 A deficit)
--   INSERT INTO telemetry (ts, vin, field, num_value)
--   SELECT generate_series(
--     NOW() + INTERVAL '5 minutes',
--     NOW() + INTERVAL '7 minutes',
--     INTERVAL '30 seconds'
--   ), 'SIMULATEDVIN001', 'ChargeAmps', 16.0;
--
-- Step 5 — Verify flags
--   SELECT * FROM pcs_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 10;
--
--   SELECT * FROM pcs_session_summary
--   WHERE vin = 'SIMULATEDVIN001';
--
-- Step 6 — Clean up
--   DELETE FROM telemetry
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field = 'ChargeAmps'
--     AND num_value IN (16.0, 32.0)
--     AND ts > NOW() - INTERVAL '1 hour';
--
--   Or remove the whole test VIN:
--   DELETE FROM telemetry WHERE vin = 'SIMULATEDVIN001';
--   SELECT remove_continuous_aggregate_policy('pcs_samples_1h');
--   DROP MATERIALIZED VIEW pcs_samples_1h CASCADE;
--   -- then re-create from this file.
-- ------------------------------------------------------------------
