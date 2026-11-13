-- ============================================================
-- 036_notify_watchdog.sql — state for the notify staleness watchdog (N8)
--
-- A 36-day ingestion outage went unnoticed because nothing alerted
-- between weekly reports. The notify daemon now checks once an hour
-- whether the newest telemetry row AND the newest vehicle_connectivity
-- row are both older than its threshold (default 48 h), sends one
-- Telegram warning, and stays quiet until data resumes, when it sends
-- one recovery note.
--
-- stale_alert_sent_at is non-NULL while a warning is outstanding, so a
-- daemon restart does not warn again. Its own table rather than a
-- column on notify_user_prefs: inserting a prefs row from the watchdog
-- would materialise default units/temperature that then override the
-- config file on the next loadPrefs.
--
-- Idempotent.
-- ============================================================

CREATE TABLE IF NOT EXISTS notify_watchdog (
  vin                 TEXT        PRIMARY KEY,
  stale_alert_sent_at TIMESTAMPTZ,
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE notify_watchdog IS
  'Notify daemon staleness watchdog state. stale_alert_sent_at IS NOT NULL
   while a "no data" warning is outstanding for the VIN.';
