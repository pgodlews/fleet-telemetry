-- ============================================================
-- 052_dashframe_role.sql — the second read-only consumer, in the repo
--
-- Production has a role dashframe_ro that nothing in this repo created
-- (only 027 grants it SELECT on trips_mat when it exists). Inspected
-- read-only on 13 Nov 2026: LOGIN, not superuser, no role memberships,
-- owns nothing, SELECT on telemetry and trips_mat only (plus the
-- telemetry chunks, which TimescaleDB grants with the hypertable), no
-- function grants, no session at the time; connection logging is off,
-- so past use cannot be seen. A read-only consumer of those two
-- relations.
--
-- This file makes a fresh install match: the role is created only if
-- missing, as NOLOGIN, so no password lives in the repo (an operator who
-- wants it to log in sets a password with ALTER ROLE ... LOGIN PASSWORD).
-- An existing role keeps its attributes and password; the two grants are
-- (re)applied. Nothing else is granted. Idempotent.
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dashframe_ro') THEN
    CREATE ROLE dashframe_ro NOLOGIN;
  END IF;
END $$;

GRANT CONNECT ON DATABASE tesla TO dashframe_ro;
GRANT USAGE ON SCHEMA public TO dashframe_ro;
GRANT SELECT ON telemetry TO dashframe_ro;
GRANT SELECT ON trips_mat TO dashframe_ro;
