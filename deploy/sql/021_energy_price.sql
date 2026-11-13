-- 021_energy_price.sql — idempotent
-- Adds per-VIN energy price to user prefs so /setenergyprice changes
-- apply to future trips without editing the config file.
-- 0 means "not set via bot — use the config file value".

ALTER TABLE notify_user_prefs
  ADD COLUMN IF NOT EXISTS cost_per_kwh DOUBLE PRECISION NOT NULL DEFAULT 0;
