-- Migration 026: re-key telegram_notifications on (vin, started)
--
-- trip_id in the trips view is ROW_NUMBER() over all history, so it shifts
-- whenever late-arriving telemetry merges/extends past trips. Keying the
-- dedup table on the positional id let a mid-trip notification permanently
-- mask the real end-of-trip one (observed 2026-05-23..31: trips 66, 68, 73,
-- 83, 90, 91 never notified). The trip start timestamp is stable once the
-- first GPS point of a trip has been ingested, so use (vin, started) instead.
-- trip_id is kept as an informational column only.
--
-- Idempotent: safe to re-run.

BEGIN;

ALTER TABLE telegram_notifications ADD COLUMN IF NOT EXISTS started TIMESTAMPTZ;

-- Backfill from the current trips view. Materialize the view once into a
-- temp table first — joining the view directly makes the planner re-evaluate
-- its window functions per outer row, which takes hours. Rows whose trip_id
-- no longer resolves to a trip (history reflow) are dropped — those trips
-- are long past the notification window anyway.
CREATE TEMP TABLE _trip_starts AS
SELECT vin, trip_id, started FROM trips;

UPDATE telegram_notifications n
SET started = t.started
FROM _trip_starts t
WHERE n.started IS NULL AND t.vin = n.vin AND t.trip_id = n.trip_id;

DROP TABLE _trip_starts;

DELETE FROM telegram_notifications WHERE started IS NULL;

DO $$
BEGIN
  IF (SELECT array_agg(a.attname::text ORDER BY ck.ord)
      FROM pg_constraint c
      JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS ck(attnum, ord) ON true
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ck.attnum
      WHERE c.conrelid = 'telegram_notifications'::regclass
        AND c.contype = 'p') IS DISTINCT FROM ARRAY['vin', 'started'] THEN
    ALTER TABLE telegram_notifications DROP CONSTRAINT telegram_notifications_pkey;
    ALTER TABLE telegram_notifications ALTER COLUMN started SET NOT NULL;
    ALTER TABLE telegram_notifications ADD PRIMARY KEY (vin, started);
  END IF;
END $$;

COMMIT;
