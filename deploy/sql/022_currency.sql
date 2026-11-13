-- 022_currency.sql — idempotent
-- Adds per-VIN currency symbol so /setCurrency applies to all cost displays.
-- Empty string means "use config file default" (same sentinel pattern as other prefs).

ALTER TABLE notify_user_prefs
  ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT '';
