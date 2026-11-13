-- Add optional GPS coordinates to service log entries (recorded at time of logging).
ALTER TABLE service_log ADD COLUMN IF NOT EXISTS service_lat DOUBLE PRECISION;
ALTER TABLE service_log ADD COLUMN IF NOT EXISTS service_lon DOUBLE PRECISION;
