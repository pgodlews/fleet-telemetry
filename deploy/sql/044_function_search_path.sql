-- ============================================================
-- 044_function_search_path.sql — make the scoring function work
-- during pg_restore
--
-- 038 made subsystem_risk_score() read pm_status_dictionary. pg_dump
-- restores with an empty search_path, and pg_restore refreshes
-- materialized views as part of the restore, so refreshing
-- predictive_health_score_1d_mat / predictive_health_summary_mat
-- failed with "relation pm_status_dictionary does not exist" and both
-- came back unpopulated ("errors ignored on restore: 2"). Found by
-- restoring a production backup into a scratch database.
--
-- Pinning the function's search_path fixes it without changing what it
-- computes. Any function a view or matview calls that reads a table
-- needs the same (this is the only one today).
--
-- Re-running 038 with FORCE=1 replaces the function and drops the
-- setting; this file runs after it and sets it again. Idempotent.
-- ============================================================

ALTER FUNCTION subsystem_risk_score(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION)
  SET search_path = public, pg_catalog;
