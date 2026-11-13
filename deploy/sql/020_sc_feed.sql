-- 020_sc_feed.sql — idempotent
-- Adds persistence for the supercharger feed watcher so it doesn't
-- re-alert after daemon restarts.

ALTER TABLE notify_user_prefs
  ADD COLUMN IF NOT EXISTS last_sc_change_id INTEGER NOT NULL DEFAULT 0;
