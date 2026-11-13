-- 019_user_prefs.sql — idempotent
-- Stores per-VIN user preferences (units, temperature scale) and
-- named places added interactively via the Telegram bot.

-- User-settable preferences
CREATE TABLE IF NOT EXISTS notify_user_prefs (
  vin        TEXT        NOT NULL PRIMARY KEY,
  units      TEXT        NOT NULL DEFAULT 'km',
  temp_units TEXT        NOT NULL DEFAULT 'c',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Named places added via /addplace bot command
CREATE TABLE IF NOT EXISTS notify_places (
  id         SERIAL           PRIMARY KEY,
  vin        TEXT             NOT NULL,
  name       TEXT             NOT NULL,
  lat        DOUBLE PRECISION NOT NULL,
  lon        DOUBLE PRECISION NOT NULL,
  radius_m   DOUBLE PRECISION NOT NULL DEFAULT 100,
  created_at TIMESTAMPTZ      NOT NULL DEFAULT now(),
  UNIQUE (vin, name)
);
