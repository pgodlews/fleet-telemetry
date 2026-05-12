-- Read-only role used by the Grafana datasource.
-- Run as superuser. Idempotent.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro') THEN
    CREATE ROLE grafana_ro WITH LOGIN PASSWORD 'grafana_ro';
  END IF;
END$$;

GRANT CONNECT ON DATABASE tesla TO grafana_ro;
GRANT USAGE  ON SCHEMA public TO grafana_ro;
GRANT SELECT ON ALL TABLES    IN SCHEMA public TO grafana_ro;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO grafana_ro;
