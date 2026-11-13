-- ============================================================
-- 040_matview_refresh.sql — matview refresh that reports failures,
-- does not block readers, and is scheduled from the repo (S8)
--
-- Before: refresh_predictive_matviews() (030) ran a plain REFRESH of 14
-- matviews, swallowed any error as a WARNING nobody read, held an
-- exclusive lock on each view for the duration, and was scheduled only
-- by a crontab line on the production host.
--
-- Now:
--   1. alert_frequency_1w and pcs_health_1w are rebuilt. Both said
--      GROUP BY bucket, which PostgreSQL resolves to the INPUT column
--      (the daily bucket), not the 7-day output alias: they held one row
--      per day labelled with the week. Grouping by the output position
--      makes them weekly. Nothing depends on either view.
--   2. Every matview gets a unique index on its natural key
--      (vin, bucket) — (vin, bucket, subsystem, severity) for the alert
--      rollup — so it can be refreshed CONCURRENTLY: readers keep the
--      old contents during the refresh instead of waiting.
--   3. matview_refresh_log records each refresh (name, start, finish,
--      ok, error). Rows older than 90 days are pruned by the job.
--   4. refresh_predictive_matviews_job (procedure) refreshes each view in
--      its own transaction, logs it, carries on after a failure, and
--      RAISES at the end if any view failed, so the TimescaleDB job is
--      marked failed and timescaledb_information.job_stats /
--      the weekly report show it. Registered hourly with add_job.
--   5. refresh_predictive_matviews() (the function the host crontab
--      calls) is kept for compatibility: same refresh and logging, but
--      it ends with a WARNING rather than an exception, because raising
--      inside one function rolls back every refresh it just made. Remove
--      the crontab line once the job is registered (section 9).
--
-- The list includes predictive_health_score_1d_mat and
-- predictive_health_summary_mat (041); they are skipped until they
-- exist, and refreshed last because they read the other views.
--
-- Idempotent.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Weekly rollups that are actually weekly.
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS alert_frequency_1w;
CREATE MATERIALIZED VIEW alert_frequency_1w AS
SELECT
  time_bucket('7 days', bucket) AS bucket,
  vin,
  subsystem,
  severity,
  SUM(alert_count)  AS alert_count,
  SUM(active_count) AS active_count
FROM alert_frequency_1d
GROUP BY 1, vin, subsystem, severity;

DROP MATERIALIZED VIEW IF EXISTS pcs_health_1w;
CREATE MATERIALIZED VIEW pcs_health_1w AS
SELECT
  time_bucket('7 days', bucket) AS bucket,
  vin,
  MAX(max_deficit_amps) AS max_deficit_amps,
  SUM(charging_hours)   AS charging_hours,
  SUM(failure_hours)    AS failure_hours
FROM pcs_health_1d
GROUP BY 1, vin;

-- ------------------------------------------------------------------
-- 2.  Unique keys (required for REFRESH ... CONCURRENTLY).
-- ------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS battery_capacity_1d_uq      ON battery_capacity_1d      (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS pcs_health_1d_uq            ON pcs_health_1d            (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS pcs_health_1w_uq            ON pcs_health_1w            (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS heat_pump_cop_1d_uq         ON heat_pump_cop_1d         (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS low_voltage_wakeups_1d_uq   ON low_voltage_wakeups_1d   (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS suspension_steering_1d_uq   ON suspension_steering_1d   (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS drivetrain_highway_1d_uq    ON drivetrain_highway_1d    (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS regen_brake_daily_1d_uq     ON regen_brake_daily_1d     (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS alert_frequency_1w_uq       ON alert_frequency_1w       (vin, bucket, subsystem, severity);
CREATE UNIQUE INDEX IF NOT EXISTS air_suspension_health_1d_uq ON air_suspension_health_1d (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS dual_motor_highway_1d_uq    ON dual_motor_highway_1d    (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS tri_motor_highway_1d_uq     ON tri_motor_highway_1d     (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS ct_tonneau_daily_1d_uq      ON ct_tonneau_daily_1d      (vin, bucket);
CREATE UNIQUE INDEX IF NOT EXISTS ct_v2l_daily_1d_uq          ON ct_v2l_daily_1d          (vin, bucket);

-- ------------------------------------------------------------------
-- 3.  Refresh log.
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS matview_refresh_log (
  id          BIGSERIAL   PRIMARY KEY,
  name        TEXT        NOT NULL,
  started_at  TIMESTAMPTZ NOT NULL,
  finished_at TIMESTAMPTZ NOT NULL,
  ok          BOOLEAN     NOT NULL,
  error       TEXT
);
CREATE INDEX IF NOT EXISTS matview_refresh_log_name_started
  ON matview_refresh_log (name, started_at DESC);

COMMENT ON TABLE matview_refresh_log IS
  'One row per matview refresh by refresh_predictive_matviews[_job]. The weekly
   report flags views whose latest row is not ok or is older than 3 days.';

-- The authoritative refresh order. CAGG consumers first (independent of
-- each other), then the 041 health matviews, which read the views above.
CREATE OR REPLACE FUNCTION predictive_matview_list()
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY[
    'battery_capacity_1d',
    'pcs_health_1d',
    'pcs_health_1w',
    'heat_pump_cop_1d',
    'low_voltage_wakeups_1d',
    'suspension_steering_1d',
    'drivetrain_highway_1d',
    'regen_brake_daily_1d',
    'alert_frequency_1w',
    'air_suspension_health_1d',
    'dual_motor_highway_1d',
    'tri_motor_highway_1d',
    'ct_tonneau_daily_1d',
    'ct_v2l_daily_1d',
    'predictive_health_score_1d_mat',
    'predictive_health_summary_mat'
  ]::text[]
$$;

-- Refresh one matview, log the outcome, return true on success. Never
-- raises: the error is caught (and the refresh rolled back to the
-- savepoint) so the caller can continue with the next view.
CREATE OR REPLACE FUNCTION refresh_one_matview(mv text)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  started timestamptz := clock_timestamp();
  concurrent boolean;
  err text;
BEGIN
  SELECT c.relispopulated
         AND EXISTS (SELECT 1 FROM pg_index i
                     WHERE i.indrelid = c.oid AND i.indisunique AND i.indisvalid
                       AND i.indpred IS NULL)
    INTO concurrent
  FROM pg_class c
  WHERE c.relname = mv AND c.relkind = 'm'
    AND c.relnamespace = 'public'::regnamespace;

  IF NOT FOUND THEN
    RETURN true;  -- not created on this install; nothing to do
  END IF;

  BEGIN
    IF concurrent THEN
      EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %I', mv);
    ELSE
      EXECUTE format('REFRESH MATERIALIZED VIEW %I', mv);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
  END;

  INSERT INTO matview_refresh_log (name, started_at, finished_at, ok, error)
  VALUES (mv, started, clock_timestamp(), err IS NULL, err);

  IF err IS NOT NULL THEN
    RAISE WARNING 'refresh of % failed: %', mv, err;
    RETURN false;
  END IF;
  RAISE NOTICE 'refreshed % in %', mv, clock_timestamp() - started;
  RETURN true;
END;
$$;

-- ------------------------------------------------------------------
-- 4.  Scheduled path: one transaction per view, fail the job at the end.
-- ------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE refresh_predictive_matviews_job(job_id INT DEFAULT NULL, config JSONB DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
  mv text;
  failed text[] := '{}';
BEGIN
  FOREACH mv IN ARRAY predictive_matview_list() LOOP
    IF NOT refresh_one_matview(mv) THEN
      failed := failed || mv;
    END IF;
    COMMIT;  -- keep each refresh (and its log row) whatever happens next
  END LOOP;

  DELETE FROM matview_refresh_log WHERE started_at < now() - INTERVAL '90 days';
  COMMIT;

  IF cardinality(failed) > 0 THEN
    RAISE EXCEPTION 'matview refresh failed for: %', array_to_string(failed, ', ')
      USING HINT = 'See matview_refresh_log for the error of each view.';
  END IF;
END;
$$;

-- ------------------------------------------------------------------
-- 5.  Compatibility path for the host crontab (single transaction).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION refresh_predictive_matviews()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  mv text;
  failed text[] := '{}';
BEGIN
  FOREACH mv IN ARRAY predictive_matview_list() LOOP
    IF NOT refresh_one_matview(mv) THEN
      failed := failed || mv;
    END IF;
  END LOOP;
  IF cardinality(failed) > 0 THEN
    -- Not an exception: that would roll back every successful refresh
    -- above and the log rows with them. The scheduled procedure raises.
    RAISE WARNING 'matview refresh failed for: % (see matview_refresh_log)',
      array_to_string(failed, ', ');
  END IF;
END;
$$;

COMMENT ON FUNCTION refresh_predictive_matviews() IS
  'Refreshes the predictive-maintenance matviews (predictive_matview_list()),
   CONCURRENTLY where possible, logging each to matview_refresh_log. Scheduled
   hourly as the TimescaleDB job refresh_predictive_matviews_job (040); this
   function remains for manual use and the legacy host crontab.';

-- Hourly, at minute 7, matching the old crontab line. Registered once.
SELECT add_job('refresh_predictive_matviews_job', INTERVAL '1 hour',
               initial_start => date_trunc('hour', now()) + INTERVAL '1 hour 7 minutes')
WHERE NOT EXISTS (
  SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'refresh_predictive_matviews_job'
);
