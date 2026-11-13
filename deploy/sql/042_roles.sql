-- ============================================================
-- 042_roles.sql — grafana_ro password and grants (O1)
--
-- 003 creates grafana_ro with the password 'grafana_ro' and never
-- changes it afterwards. This file:
--
--   * sets the role's password from the GRAFANA_RO_PASSWORD environment
--     variable of the psql process running the migration, when it is
--     set. deploy/docker-compose.yml passes GF_TESLA_DB_PASSWORD into the
--     database container under that name, so `make migrate` (and the
--     init script on a fresh volume) keep the role and the Grafana
--     datasource in step. Without the variable the password is left as
--     it is.
--   * re-applies the grants. 003's ALTER DEFAULT PRIVILEGES already
--     covers objects that postgres creates later, so the manual
--     "GRANT ... TO grafana_ro" step after migrations is no longer
--     needed; this file runs last in the manifest so anything created
--     before default privileges existed (or by a restore) is covered too.
--
-- Runs last in migrations.txt. Idempotent. Needs psql 15+ (\getenv).
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro') THEN
    CREATE ROLE grafana_ro WITH LOGIN;
  END IF;
END$$;

\getenv grafana_ro_password GRAFANA_RO_PASSWORD
\if :{?grafana_ro_password}
SELECT length(:'grafana_ro_password') > 0 AS grafana_ro_password_set \gset
\if :grafana_ro_password_set
ALTER ROLE grafana_ro WITH LOGIN PASSWORD :'grafana_ro_password';
\echo 042: grafana_ro password set from GRAFANA_RO_PASSWORD
\endif
\else
\echo 042: GRAFANA_RO_PASSWORD not set, grafana_ro password unchanged
\endif

GRANT CONNECT ON DATABASE tesla TO grafana_ro;
GRANT USAGE  ON SCHEMA public TO grafana_ro;
GRANT SELECT ON ALL TABLES    IN SCHEMA public TO grafana_ro;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO grafana_ro;
