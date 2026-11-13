-- Migration 018: state table for Telegram trip notifications
-- Tracks which (vin, trip_id) pairs have already been sent so the cron
-- job never sends a duplicate. Idempotent.

CREATE TABLE IF NOT EXISTS telegram_notifications (
    vin      TEXT        NOT NULL,
    trip_id  INTEGER     NOT NULL,
    sent_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (vin, trip_id)
);
