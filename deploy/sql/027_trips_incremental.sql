-- Migration 027: incremental trip sessionization
--
-- The trips view (002_views.sql) recomputes window functions over the entire
-- telemetry hypertable on every query — 6+ minutes on prod as of 2026-06,
-- evaluated every 2 minutes by the notify daemon and again by every Grafana
-- panel that touches trips. Cost grows with history and with fleet size.
--
-- This migration materializes trips into a real table (trips_mat) refreshed
-- incrementally: per VIN, only telemetry newer than the last trip that ended
-- outside the mutable window (default 7 days) is re-sessionized. Older trips
-- are immutable — the car cannot buffer telemetry that long. The trips VIEW
-- is replaced in place with SELECT * FROM trips_mat, keeping the exact column
-- list/types, so notify, the diagnostics views (010, 011) and dashboards work
-- unchanged. trip_id numbering continues per VIN from the frozen prefix;
-- ids inside the mutable window can still shift on merge (notifications are
-- keyed on (vin, started) since migration 026, so this is cosmetic).
--
-- A background job (timescaledb add_job) refreshes every minute.
-- Idempotent: safe to re-run.

BEGIN;

-- ── Materialized trips table ────────────────────────────────────────────────
-- Column names/types mirror the original view exactly (CREATE OR REPLACE VIEW
-- below requires it).
CREATE TABLE IF NOT EXISTS trips_mat (
    vin                  text NOT NULL,
    trip_id              bigint NOT NULL,
    trip_id_raw          bigint,
    started              timestamptz NOT NULL,
    ended                timestamptz NOT NULL,
    duration             interval,
    distance_km          numeric,
    gps_points           bigint,
    max_speed_mph        numeric,
    avg_speed_mph        numeric,
    soc_start_pct        numeric,
    soc_end_pct          numeric,
    soc_used_pct         numeric,
    kwh_start            numeric,
    kwh_end              numeric,
    kwh_used             numeric,
    wh_per_km            numeric,
    rated_range_start_mi numeric,
    rated_range_end_mi   numeric,
    start_lat            numeric,
    start_lon            numeric,
    end_lat              numeric,
    end_lon              numeric,
    start_geo            geography,
    end_geo              geography,
    PRIMARY KEY (vin, started)
);

CREATE INDEX IF NOT EXISTS trips_mat_vin_ended ON trips_mat (vin, ended DESC);

-- ── Incremental refresh ─────────────────────────────────────────────────────
-- Per VIN: anchor = end of the newest trip that ended before now()-lookback.
-- Everything after the anchor is deleted and re-sessionized from telemetry.
-- VINs with no anchor (new vehicle, or first run) are recomputed from scratch.
-- The telemetry scan is driven through LATERAL so it uses the
-- (vin, field, ts) index instead of a full Location scan.
CREATE OR REPLACE FUNCTION refresh_trips(lookback INTERVAL DEFAULT INTERVAL '7 days')
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  DELETE FROM trips_mat t
  WHERE t.started > COALESCE((
      SELECT max(a.ended) FROM trips_mat a
      WHERE a.vin = t.vin AND a.ended < now() - lookback
    ), '-infinity'::timestamptz);

  INSERT INTO trips_mat (
    vin, trip_id, trip_id_raw, started, ended, duration, distance_km,
    gps_points, max_speed_mph, avg_speed_mph,
    soc_start_pct, soc_end_pct, soc_used_pct,
    kwh_start, kwh_end, kwh_used, wh_per_km,
    rated_range_start_mi, rated_range_end_mi,
    start_lat, start_lon, end_lat, end_lon, start_geo, end_geo)
  WITH anchors AS (
    SELECT vin, max(ended) AS anchor
    FROM trips_mat
    WHERE ended < now() - lookback
    GROUP BY vin
  ),
  -- VINs needing recompute: every VIN with an anchor (its tail was just
  -- deleted) plus any VIN with recent Location data (covers new vehicles).
  vins AS (
    SELECT vin, anchor FROM anchors
    UNION
    SELECT t.vin, '-infinity'::timestamptz
    FROM (SELECT DISTINCT vin FROM telemetry
          WHERE field = 'Location' AND ts > now() - lookback) t
    WHERE NOT EXISTS (SELECT 1 FROM anchors a WHERE a.vin = t.vin)
  ),
  -- per-VIN trip_id continues after the frozen prefix
  base AS (
    SELECT vin, COALESCE(max(trip_id), 0) AS base_id
    FROM trips_mat
    GROUP BY vin
  ),
  -- ── same sessionization as 002_views.sql, windowed per VIN ────────────────
  loc AS (
    SELECT l.ts, v.vin, l.geo_value,
      l.ts - LAG(l.ts) OVER (PARTITION BY v.vin ORDER BY l.ts) AS gap
    FROM vins v
    CROSS JOIN LATERAL (
      SELECT ts, geo_value FROM telemetry
      WHERE vin = v.vin AND field = 'Location' AND ts > v.anchor
    ) l
  ),
  boundaries AS (
    SELECT ts, vin, geo_value,
      CASE WHEN gap > INTERVAL '10 minutes' OR gap IS NULL THEN 1 ELSE 0 END AS is_start
    FROM loc
  ),
  numbered AS (
    SELECT ts, vin, geo_value,
      SUM(is_start) OVER (PARTITION BY vin ORDER BY ts) AS trip_id_raw
    FROM boundaries
  ),
  segments AS (
    SELECT ts, vin, trip_id_raw, geo_value,
      ST_Distance(
        geo_value::geography,
        LAG(geo_value) OVER (PARTITION BY vin, trip_id_raw ORDER BY ts)::geography
      ) AS seg_dist_m
    FROM numbered
  ),
  trip_bounds AS (
    SELECT
      vin, trip_id_raw,
      MIN(ts)               AS started,
      MAX(ts)               AS ended,
      MAX(ts) - MIN(ts)     AS duration,
      COUNT(*)              AS gps_points,
      ROUND((COALESCE(SUM(seg_dist_m), 0) / 1000)::numeric, 3) AS distance_km,
      first(geo_value, ts)  AS start_geo,
      last(geo_value, ts)   AS end_geo
    FROM segments
    GROUP BY vin, trip_id_raw
    HAVING COALESCE(SUM(seg_dist_m), 0) > 200   -- ignore micro-movements < 200 m
  ),
  speed_stats AS (
    SELECT tb.vin, tb.trip_id_raw,
      ROUND(MAX(s.num_value)::numeric, 1)                                    AS max_speed_mph,
      ROUND(AVG(CASE WHEN s.num_value > 2 THEN s.num_value END)::numeric, 1) AS avg_speed_mph
    FROM trip_bounds tb
    JOIN telemetry s ON s.vin = tb.vin
      AND s.field = 'VehicleSpeed'
      AND s.ts BETWEEN tb.started AND tb.ended
    GROUP BY tb.vin, tb.trip_id_raw
  ),
  energy_stats AS (
    SELECT
      tb.vin, tb.trip_id_raw,
      ROUND(first(b.num_value, b.ts)::numeric, 1)                              AS soc_start_pct,
      ROUND(last(b.num_value,  b.ts)::numeric, 1)                              AS soc_end_pct,
      ROUND((first(b.num_value, b.ts) - last(b.num_value, b.ts))::numeric, 1) AS soc_used_pct,
      ROUND(first(e.num_value, e.ts)::numeric, 2)                              AS kwh_start,
      ROUND(last(e.num_value,  e.ts)::numeric, 2)                              AS kwh_end,
      ROUND((first(e.num_value, e.ts) - last(e.num_value, e.ts))::numeric, 2) AS kwh_used,
      ROUND(first(r.num_value, r.ts)::numeric, 1)                              AS rated_range_start_mi,
      ROUND(last(r.num_value,  r.ts)::numeric, 1)                              AS rated_range_end_mi
    FROM trip_bounds tb
    LEFT JOIN telemetry b ON b.vin = tb.vin AND b.field = 'BatteryLevel'
      AND b.ts BETWEEN tb.started AND tb.ended
    LEFT JOIN telemetry e ON e.vin = tb.vin AND e.field = 'EnergyRemaining'
      AND e.ts BETWEEN tb.started AND tb.ended
    LEFT JOIN telemetry r ON r.vin = tb.vin AND r.field = 'RatedRange'
      AND r.ts BETWEEN tb.started AND tb.ended
    GROUP BY tb.vin, tb.trip_id_raw
  )
  SELECT
    tb.vin,
    ROW_NUMBER() OVER (PARTITION BY tb.vin ORDER BY tb.started)
      + COALESCE(bs.base_id, 0)            AS trip_id,
    tb.trip_id_raw,
    tb.started, tb.ended, tb.duration,
    tb.distance_km, tb.gps_points,
    COALESCE(ss.max_speed_mph, 0)          AS max_speed_mph,
    COALESCE(ss.avg_speed_mph, 0)          AS avg_speed_mph,
    es.soc_start_pct, es.soc_end_pct, es.soc_used_pct,
    es.kwh_start, es.kwh_end, es.kwh_used,
    CASE WHEN tb.distance_km > 0.5 AND es.kwh_used > 0
      THEN ROUND((es.kwh_used * 1000 / tb.distance_km)::numeric, 0)
      ELSE NULL
    END AS wh_per_km,
    es.rated_range_start_mi, es.rated_range_end_mi,
    ROUND(ST_Y(tb.start_geo::geometry)::numeric, 6) AS start_lat,
    ROUND(ST_X(tb.start_geo::geometry)::numeric, 6) AS start_lon,
    ROUND(ST_Y(tb.end_geo::geometry)::numeric, 6)   AS end_lat,
    ROUND(ST_X(tb.end_geo::geometry)::numeric, 6)   AS end_lon,
    tb.start_geo, tb.end_geo
  FROM trip_bounds tb
  LEFT JOIN speed_stats  ss USING (vin, trip_id_raw)
  LEFT JOIN energy_stats es USING (vin, trip_id_raw)
  LEFT JOIN base         bs ON bs.vin = tb.vin;
END $fn$;

-- ── Initial population ──────────────────────────────────────────────────────
-- Only when the table is empty: a 100-year lookback forces a full rebuild
-- (one last full-history evaluation, ~6 min on prod).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM trips_mat) THEN
    PERFORM refresh_trips(INTERVAL '100 years');
  END IF;
END $$;

-- ── Verify equivalence with the old view before swapping it ────────────────
-- Compares all settled trips (ended > 1 h ago — in-flight trips can differ
-- between statement snapshots). Aborts the whole migration on any mismatch.
-- Skipped once trips is already backed by trips_mat (re-run case).
DO $$
DECLARE diffs bigint;
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_depend d
    JOIN pg_rewrite r ON r.oid = d.objid
    WHERE r.ev_class = 'trips'::regclass AND d.refobjid = 'trips_mat'::regclass
  ) THEN
    RETURN; -- already swapped on a previous run
  END IF;

  -- evaluate the expensive old view exactly once
  CREATE TEMP TABLE _trips_old ON COMMIT DROP AS
  SELECT vin, trip_id, started, ended, distance_km, gps_points FROM trips
  WHERE ended < now() - INTERVAL '1 hour';

  SELECT count(*) INTO diffs FROM (
    (SELECT * FROM _trips_old
     EXCEPT
     SELECT vin, trip_id, started, ended, distance_km, gps_points FROM trips_mat
       WHERE ended < now() - INTERVAL '1 hour')
    UNION ALL
    (SELECT vin, trip_id, started, ended, distance_km, gps_points FROM trips_mat
       WHERE ended < now() - INTERVAL '1 hour'
     EXCEPT
     SELECT * FROM _trips_old)
  ) d;

  IF diffs > 0 THEN
    RAISE EXCEPTION 'trips_mat differs from trips view on % settled row(s) — aborting swap', diffs;
  END IF;
END $$;

-- ── Swap: trips becomes a thin view over the table ──────────────────────────
-- CREATE OR REPLACE keeps the relation OID, so dependent views (010, 011)
-- and Grafana queries are untouched.
CREATE OR REPLACE VIEW trips AS
SELECT
  vin, trip_id, trip_id_raw,
  started, ended, duration,
  distance_km, gps_points,
  max_speed_mph, avg_speed_mph,
  soc_start_pct, soc_end_pct, soc_used_pct,
  kwh_start, kwh_end, kwh_used,
  wh_per_km,
  rated_range_start_mi, rated_range_end_mi,
  start_lat, start_lon, end_lat, end_lon,
  start_geo, end_geo
FROM trips_mat
ORDER BY started;

-- ── Grants ──────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro') THEN
    GRANT SELECT ON trips_mat TO grafana_ro;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dashframe_ro') THEN
    GRANT SELECT ON trips_mat TO dashframe_ro;
  END IF;
END $$;

-- ── Background refresh job (every minute) ───────────────────────────────────
CREATE OR REPLACE PROCEDURE refresh_trips_job(job_id INT, config JSONB)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM refresh_trips();
END $$;

SELECT add_job('refresh_trips_job', INTERVAL '1 minute')
WHERE NOT EXISTS (
  SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'refresh_trips_job'
);

COMMIT;
