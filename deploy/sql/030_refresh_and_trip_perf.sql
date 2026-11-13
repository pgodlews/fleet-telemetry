-- ============================================================
-- 030_refresh_and_trip_perf.sql
--
-- Three fixes from the 2026-09-09 review, all in the refresh path:
--
--   1. refresh_predictive_matviews() only listed 6 of the 14 plain
--      materialized views. The other 8 (drivetrain_highway_1d,
--      regen_brake_daily_1d, air_suspension_health_1d,
--      dual_motor_highway_1d, tri_motor_highway_1d, ct_tonneau_daily_1d,
--      ct_v2l_daily_1d, alert_frequency_1w) have been frozen at
--      whatever content they had when they were created — exactly the
--      failure 029 fixed for suspension_steering_1d, repeated eight
--      times. Every diagnostic reading from them is stale.
--
--   2. refresh_trips() built energy_stats by joining BatteryLevel,
--      EnergyRemaining and RatedRange rows to the same trip in one
--      FROM clause, so the three series multiplied out before being
--      aggregated: 120 rows per field per trip is 1.7M intermediate
--      rows for a single trip, re-evaluated every minute by the
--      background job. Each field is now aggregated once and the small
--      per-field results pivoted, which is equivalent but linear.
--
--   3. refresh_trips() had no mutual exclusion. The one-minute
--      background job, a manual call and a bounded rebuild can all run
--      at once, deleting and reinserting the same mutable tail. It now
--      takes a transaction-scoped advisory lock and returns without
--      doing anything if another refresh holds it.
--
-- Requires 027_trips_incremental.sql and 029_suspension_summary_fixes.sql.
-- Safe to re-run.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Complete the matview refresh rotation.
--
-- Full redefinition rather than an ALTER so the authoritative list
-- stays readable in one place, as in 025 and 029. Order is CAGG
-- consumers first; none of these depend on each other (they all read
-- the hourly/minutely continuous aggregates, which TimescaleDB
-- refreshes through its own policies).
--
-- The existence check and per-view exception handler are unchanged:
-- one missing or failing matview must not stop the rotation.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION refresh_predictive_matviews()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  mv text;
  matviews text[] := ARRAY[
    -- present since 025
    'battery_capacity_1d',
    'pcs_health_1d',
    'pcs_health_1w',
    'heat_pump_cop_1d',
    'low_voltage_wakeups_1d',
    -- added by 029
    'suspension_steering_1d',
    -- added by 030: created 011-017, never scheduled
    'drivetrain_highway_1d',
    'regen_brake_daily_1d',
    'alert_frequency_1w',
    'air_suspension_health_1d',
    'dual_motor_highway_1d',
    'tri_motor_highway_1d',
    'ct_tonneau_daily_1d',
    'ct_v2l_daily_1d'
  ];
  started timestamptz;
BEGIN
  FOREACH mv IN ARRAY matviews LOOP
    started := clock_timestamp();
    -- Skip silently if a matview doesn't exist (e.g. fresh install
    -- where one of the diagnostic files hasn't been applied).
    IF NOT EXISTS (
      SELECT 1 FROM pg_class WHERE relname = mv AND relkind = 'm'
    ) THEN
      CONTINUE;
    END IF;
    BEGIN
      EXECUTE format('REFRESH MATERIALIZED VIEW %I', mv);
      RAISE NOTICE 'refreshed % in %', mv, clock_timestamp() - started;
    EXCEPTION WHEN OTHERS THEN
      -- Log and continue — one stale matview should not block the rest.
      RAISE WARNING 'refresh of % failed: %', mv, SQLERRM;
    END;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION refresh_predictive_matviews() IS
  'Refreshes all 14 predictive-maintenance matviews that are not continuous
   aggregates.  Call hourly from pg_cron or an external cron
   (e.g. `psql -c "SELECT refresh_predictive_matviews();"`).  Check
   pg_matviews / the NOTICE output to confirm a run actually happened —
   nothing else reports staleness.';

-- ------------------------------------------------------------------
-- 2 + 3.  refresh_trips(): serialize, and stop multiplying the three
--         energy series together.
--
-- Signature, column list and semantics are otherwise unchanged, so the
-- background job (027) and any manual callers keep working.
--
-- energy_src aggregates each field independently to one row per
-- (vin, trip, field); energy_stats pivots those with FILTER. Because
-- there is at most one row per group, MAX() is just "the value". Trips
-- with no rows for a field yield NULL for its columns, matching the
-- previous LEFT JOIN behaviour.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION refresh_trips(lookback INTERVAL DEFAULT INTERVAL '7 days')
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  -- Transaction-scoped: released on COMMIT/ROLLBACK, including when the
  -- caller dies. A second concurrent refresh is a no-op rather than a
  -- competing delete/reinsert of the same mutable tail.
  IF NOT pg_try_advisory_xact_lock(hashtext('refresh_trips')::bigint) THEN
    RAISE NOTICE 'refresh_trips: another refresh is running, skipping';
    RETURN;
  END IF;

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
  -- One aggregate pass per (trip, field). Previously these three series
  -- were joined to trip_bounds together, so every BatteryLevel row was
  -- paired with every EnergyRemaining row and every RatedRange row before
  -- first()/last() collapsed them again.
  energy_src AS (
    SELECT tb.vin, tb.trip_id_raw, t.field,
      first(t.num_value, t.ts) AS first_val,
      last(t.num_value,  t.ts) AS last_val
    FROM trip_bounds tb
    JOIN telemetry t ON t.vin = tb.vin
      AND t.field IN ('BatteryLevel', 'EnergyRemaining', 'RatedRange')
      AND t.ts BETWEEN tb.started AND tb.ended
    GROUP BY tb.vin, tb.trip_id_raw, t.field
  ),
  energy_stats AS (
    SELECT vin, trip_id_raw,
      ROUND(MAX(first_val) FILTER (WHERE field = 'BatteryLevel')::numeric, 1)    AS soc_start_pct,
      ROUND(MAX(last_val)  FILTER (WHERE field = 'BatteryLevel')::numeric, 1)    AS soc_end_pct,
      ROUND((MAX(first_val) FILTER (WHERE field = 'BatteryLevel')
           - MAX(last_val)  FILTER (WHERE field = 'BatteryLevel'))::numeric, 1)  AS soc_used_pct,
      ROUND(MAX(first_val) FILTER (WHERE field = 'EnergyRemaining')::numeric, 2) AS kwh_start,
      ROUND(MAX(last_val)  FILTER (WHERE field = 'EnergyRemaining')::numeric, 2) AS kwh_end,
      ROUND((MAX(first_val) FILTER (WHERE field = 'EnergyRemaining')
           - MAX(last_val)  FILTER (WHERE field = 'EnergyRemaining'))::numeric, 2) AS kwh_used,
      ROUND(MAX(first_val) FILTER (WHERE field = 'RatedRange')::numeric, 1)      AS rated_range_start_mi,
      ROUND(MAX(last_val)  FILTER (WHERE field = 'RatedRange')::numeric, 1)      AS rated_range_end_mi
    FROM energy_src
    GROUP BY vin, trip_id_raw
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

COMMENT ON FUNCTION refresh_trips(INTERVAL) IS
  'Incrementally re-sessionizes trips_mat for the mutable tail (default 7 days).
   Serialized by a transaction-scoped advisory lock: concurrent calls return
   immediately with a NOTICE instead of racing. Pass a longer lookback to
   rebuild further back (e.g. after a bulk import or a telemetry correction);
   note that notifications keyed on (vin, started) are not reconciled by this
   function.';
