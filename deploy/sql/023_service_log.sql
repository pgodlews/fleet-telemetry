-- Service log entries recorded via the Telegram bot /logservice command.
-- Each row represents one service event for a vehicle.
CREATE TABLE IF NOT EXISTS service_log (
    id           SERIAL           PRIMARY KEY,
    vin          TEXT             NOT NULL,
    logged_at    TIMESTAMPTZ      NOT NULL DEFAULT now(),
    odometer_km  DOUBLE PRECISION,          -- fetched automatically; NULL if telemetry unavailable
    description  TEXT             NOT NULL,
    photo_paths  TEXT[]           NOT NULL DEFAULT '{}',
    notes        TEXT                       -- reserved for future use
);

CREATE INDEX IF NOT EXISTS service_log_vin_idx ON service_log (vin, logged_at DESC);
