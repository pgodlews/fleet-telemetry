-- ============================================================
-- 039_drop_anomaly_layer.sql — remove the unused anomaly layer (S9)
--
-- 005_predictive_anomalies.sql built telemetry_anomaly_1h /
-- telemetry_anomaly_1d (continuous aggregates with refresh policies),
-- telemetry_rolling_stats, telemetry_anomalies, telemetry_anomaly_latest
-- and calculate_anomaly_score(). No dashboard and no Go code reads any of
-- them, the rolling view recomputed window functions on every read, and
-- the hourly policy alone failed 729 times on production for lack of
-- background workers. Dropping a continuous aggregate removes its refresh
-- policy with it.
--
-- No CASCADE: if something has started depending on these objects, this
-- file fails instead of silently dropping it.
--
-- 005 still creates the layer on a fresh install (applied migrations are
-- never edited); this file removes it again later in the manifest.
-- Idempotent.
-- ============================================================

DROP VIEW IF EXISTS telemetry_anomaly_latest;
DROP VIEW IF EXISTS telemetry_anomalies;
DROP VIEW IF EXISTS telemetry_rolling_stats;
DROP MATERIALIZED VIEW IF EXISTS telemetry_anomaly_1d;
DROP MATERIALIZED VIEW IF EXISTS telemetry_anomaly_1h;
DROP FUNCTION IF EXISTS calculate_anomaly_score(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION);
