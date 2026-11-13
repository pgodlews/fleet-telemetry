-- ============================================================
-- 041_health_matviews.sql — store the expensive top of the
-- predictive-health stack (P1)
--
-- On production, dashboard 14 did not load: planning
-- predictive_health_score_1d took 53 s, predictive_health_summary
-- ran 64 s, and predictive_health_recommendations (which expands the
-- whole summary once per UNION arm, eight times) was cancelled after
-- 2.5 min. The cost is eleven diagnostic views stacked on views and
-- re-expanded per reference.
--
-- Pattern (same idea as trips / trips_mat in 027):
--
--   <name>_live   a plain view holding the full current body
--   <name>_mat    a matview: SELECT * FROM <name>_live, unique index,
--                 refreshed hourly by refresh_predictive_matviews_job
--                 (040), CONCURRENTLY so readers never wait
--   <name>        the public name, now a thin view over <name>_mat with
--                 exactly the same columns and types, so every
--                 dashboard and dependent view keeps working
--
-- for predictive_health_score_1d (key vin, ts) and
-- predictive_health_summary (key vin). predictive_health_recommendations
-- stays a plain view: it is cheap once the summary is stored.
--
-- predictive_health_summary keeps two columns live instead of stored:
-- telemetry_last_ts and telemetry_age_h are recomputed on read from the
-- newest telemetry row of the vehicle (one backwards scan of the newest
-- chunk), so "Data Freshness" is not up to an hour stale.
-- Everything else in the summary — scores, alert counts, recommended
-- action — is as of the last hourly refresh.
--
-- The _live body is copied from the public view's current definition
-- with pg_get_viewdef, not restated here. That keeps this file correct
-- whatever 014/031/038 last wrote, including on a FORCE=1 re-run, where
-- 014 and 031 put a live body back into the public views before this
-- file runs again. A later migration that changes scoring should
-- CREATE OR REPLACE the <name>_live view (same columns) and refresh the
-- matview.
--
-- Run last among the scoring migrations. Idempotent.
-- ============================================================

-- ------------------------------------------------------------------
-- 1. _live views from the current public bodies.
-- ------------------------------------------------------------------
DO $$
DECLARE
  base text;
  def  text;
BEGIN
  FOREACH base IN ARRAY ARRAY['predictive_health_score_1d', 'predictive_health_summary'] LOOP
    def := pg_get_viewdef(base::regclass, true);
    -- Already the thin wrapper (normal re-run): the _live view holds the body.
    IF def ~ (base || '_mat') THEN
      CONTINUE;
    END IF;
    EXECUTE format('CREATE OR REPLACE VIEW %I AS %s', base || '_live', def);
    RAISE NOTICE '041: % body copied to %_live', base, base;
  END LOOP;
END $$;

-- ------------------------------------------------------------------
-- 2. Matviews with unique keys.
-- ------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS predictive_health_score_1d_mat AS
  SELECT * FROM predictive_health_score_1d_live
WITH NO DATA;
CREATE UNIQUE INDEX IF NOT EXISTS predictive_health_score_1d_mat_uq
  ON predictive_health_score_1d_mat (vin, ts);

CREATE MATERIALIZED VIEW IF NOT EXISTS predictive_health_summary_mat AS
  SELECT * FROM predictive_health_summary_live
WITH NO DATA;
CREATE UNIQUE INDEX IF NOT EXISTS predictive_health_summary_mat_uq
  ON predictive_health_summary_mat (vin);

-- First fill (or refresh on re-run), logged like the hourly job.
SELECT refresh_one_matview('predictive_health_score_1d_mat') AS score_1d_refreshed;
SELECT refresh_one_matview('predictive_health_summary_mat')  AS summary_refreshed;

-- ------------------------------------------------------------------
-- 3. Public names become thin views over the matviews.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW predictive_health_score_1d AS
  SELECT * FROM predictive_health_score_1d_mat;

-- Column list generated from the matview so order and types match the
-- original exactly; the two freshness columns are computed on read.
DO $$
DECLARE
  cols text;
BEGIN
  SELECT string_agg(
           CASE a.attname
             WHEN 'telemetry_last_ts' THEN 'lt.ts AS telemetry_last_ts'
             WHEN 'telemetry_age_h'   THEN
               'ROUND((EXTRACT(EPOCH FROM (now() - lt.ts)) / 3600.0)::numeric, 1) AS telemetry_age_h'
             ELSE 'm.' || quote_ident(a.attname)
           END, ', ' ORDER BY a.attnum)
    INTO cols
  FROM pg_attribute a
  WHERE a.attrelid = 'predictive_health_summary_mat'::regclass
    AND a.attnum > 0 AND NOT a.attisdropped;

  EXECUTE 'CREATE OR REPLACE VIEW predictive_health_summary AS SELECT ' || cols || '
    FROM predictive_health_summary_mat m
    LEFT JOIN LATERAL (
      SELECT t.ts FROM telemetry t
      WHERE t.vin = m.vin
      ORDER BY t.ts DESC
      LIMIT 1
    ) lt ON TRUE';
END $$;

COMMENT ON VIEW predictive_health_score_1d IS
  'Daily per-subsystem risk scores. Stored in predictive_health_score_1d_mat
   (refreshed hourly); body in predictive_health_score_1d_live (041).';
COMMENT ON VIEW predictive_health_summary IS
  'Current per-VIN risk summary. Stored in predictive_health_summary_mat
   (refreshed hourly) except telemetry_last_ts / telemetry_age_h, computed on
   read; body in predictive_health_summary_live (041).';
