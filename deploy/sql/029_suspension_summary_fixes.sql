-- ============================================================
-- 029_suspension_summary_fixes.sql
--
-- suspension_summary returns zero rows on production despite
-- suspension_diagnostics having data and 62 trips being recorded.
-- Three compounding causes, all fixed here.
--
--   1. suspension_steering_1d is a plain MATERIALIZED VIEW (demoted
--      from a CAGG by 010) but was never added to the refresh list in
--      025_pm_review_fixes.sql. It has therefore held the same six
--      rows since it was created on 2026-05-12 — roughly 2.5 months
--      stale as of 2026-07-24. suspension_diagnostics reads straight
--      from it, so the whole suspension pipeline was frozen.
--
--   2. suspension_trip_offsets.straight_highway_minutes required
--      steering_avg IS NOT NULL. SteeringAngle is not in the
--      production stream (0 of 8208 samples carry it — 010's own
--      header comment anticipates this), so the count was structurally
--      always 0 and could never reach the >= 5 gate.
--
--   3. Consequently latest_diag (WHERE straight_highway_minutes >= 5)
--      matched nothing, and because suspension_summary is driven off
--      diag_snapshot with an inner JOIN, the view produced no rows at
--      all rather than a row with NULL trend columns.
--
-- Fixes 1 and 2 are the substantive ones; with the matview refreshing
-- and the steering requirement dropped, days of 10/38/45 straight
-- highway minutes exist in the sample data and clear the gate.
--
-- Requires 010_suspension_diagnostics.sql and 025_pm_review_fixes.sql.
-- Safe to re-run.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Add suspension_steering_1d to the refresh rotation.
--
-- Same function as 025, with the one missing matview appended. Kept
-- as a full redefinition rather than an ALTER so the authoritative
-- list stays readable in one place.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION refresh_predictive_matviews()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  mv text;
  matviews text[] := ARRAY[
    'battery_capacity_1d',
    'pcs_health_1d',
    'pcs_health_1w',
    'heat_pump_cop_1d',
    'low_voltage_wakeups_1d',
    -- Added by 029: was demoted from a CAGG by 010 but never wired
    -- into this rotation, leaving suspension_diagnostics frozen at
    -- whatever day the matview happened to be created.
    'suspension_steering_1d'
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
  'Refreshes the predictive-maintenance matviews that were demoted from
   continuous aggregates.  Call hourly from pg_cron or an external cron
   (e.g. `psql -c "SELECT refresh_predictive_matviews();"`).';

-- ------------------------------------------------------------------
-- 2.  suspension_trip_offsets — stop gating the straight-highway
--     minute count on a field the stream does not carry.
--
-- steering_offset_median keeps its steering_avg IS NOT NULL guard:
-- there the NULL check is meaningful, because a median over no
-- samples should be NULL. The minute *count* describes the driving,
-- not the steering instrumentation, so it must not vanish when
-- SteeringAngle is absent. lat_accel_drift already documents itself
-- as "works without steering angle" — this makes the count agree.
--
-- Column list, order and types are unchanged, so 010's dependents
-- (suspension_summary) keep working without a CASCADE.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW suspension_trip_offsets AS
WITH trip_buckets AS (
  SELECT
    t.vin,
    t.trip_id,
    t.started,
    t.ended,
    t.distance_km,
    t.max_speed_mph,
    m.bucket,
    m.speed_avg,
    m.lat_accel_avg,
    m.steering_avg
  FROM trips t
  JOIN suspension_samples_1m m
    ON m.vin = t.vin
   AND m.bucket BETWEEN t.started AND t.ended
  WHERE t.max_speed_mph > 50
)
SELECT
  vin,
  trip_id,
  started,
  ended,
  distance_km,
  max_speed_mph,
  -- Steering offset (NULL if SteeringAngle absent)
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY steering_avg)
    FILTER (WHERE
      speed_avg > 50
      AND ABS(lat_accel_avg) < 0.05
      AND steering_avg IS NOT NULL
    ) AS steering_offset_median,
  -- Minutes of straight highway driving in this trip.
  -- Fix (029): no longer requires steering_avg IS NOT NULL.
  COUNT(*) FILTER (WHERE
    speed_avg > 50
    AND ABS(lat_accel_avg) < 0.05
  ) AS straight_highway_minutes,
  -- Drift proxy (works without steering angle)
  AVG(lat_accel_avg) FILTER (WHERE
    speed_avg > 50
    AND ABS(lat_accel_avg) < 0.05
  ) AS lat_accel_drift,
  STDDEV(lat_accel_avg) FILTER (WHERE speed_avg > 50) AS lat_accel_stddev
FROM trip_buckets
GROUP BY vin, trip_id, started, ended, distance_km, max_speed_mph;

-- ------------------------------------------------------------------
-- 3.  Catch the frozen matview up once, now.
--
-- The rotation added above will keep it current from here on, but it
-- is 2.5 months behind and the operator should not have to wait for
-- the next cron tick to see the fix take effect.
-- ------------------------------------------------------------------
REFRESH MATERIALIZED VIEW suspension_steering_1d;
