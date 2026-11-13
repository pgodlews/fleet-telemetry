-- ============================================================
-- 046_vehicle_state_carry_forward.sql — rest/sleep hours from the
-- last known vehicle state; brick spread from simultaneous samples
-- (plan section 10.1, FINDINGS 3)
--
-- Fleet Telemetry sends a field when it changes. battery_capacity_1d
-- (009) and low_voltage_wakeups_1d (008) decided "parked and not
-- charging" from the speed, gear and charge power seen *inside* each
-- hour, and an hour without those fields passed every test. The brick
-- spread was MAX(BrickVoltageMax) - MIN(BrickVoltageMin) over the hour,
-- two extremes taken at different moments.
--
-- Now:
--   * vehicle_state_1h (plain matview, one row per vehicle-hour from
--     the first to the last telemetry hour) carries forward the last
--     known Gear, VehicleSpeed and DetailedChargeState from before the
--     hour, and records whether the hour itself contains a non-park
--     gear, a speed above zero, a Charging/Starting state or charge
--     power above zero. A carried value is trusted for
--     state_validity_window() (72 h); an hour whose last known gear is
--     older is "unknown" (at_rest NULL) and counts as neither rest nor
--     not-rest. On this fleet the car reports Gear = 'invalid' while
--     parked or asleep, so 'invalid' (as before) counts as parked.
--   * battery_capacity_1d / low_voltage_wakeups_1d count a rest/sleep
--     hour only when vehicle_state_1h says at_rest. Output columns are
--     unchanged.
--   * battery_capacity_1d.brick_delta_max/avg come from
--     BrickVoltageMax - BrickVoltageMin pairs with the same timestamp
--     (they arrive together in one payload), aggregated per day.
--
-- Measured on a production copy (189 days, one vehicle):
--   battery rest hours 257 -> 252 (removed: 1 charging, 2 moving at the
--   start of the hour, 2 unknown); 12 V sleep hours 203 -> 197;
--   median daily brick spread 0.340 V -> 0.093 V, days above 0.3 V
--   101 -> 64, last rest day 0.434 V -> 0.042 V.
--
-- Dependent views are captured, dropped with the matview and recreated
-- unchanged by ft_rebuild_* (generic helpers, kept for later files).
-- Idempotent.
-- ============================================================

-- One place for how long a carried-forward state is trusted.
CREATE OR REPLACE FUNCTION state_validity_window()
RETURNS interval LANGUAGE sql IMMUTABLE AS $$ SELECT INTERVAL '72 hours' $$;

-- ------------------------------------------------------------------
-- Helpers: capture the definitions of every view/matview that depends
-- (directly or not) on a set of relations, and recreate them later.
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ft_view_rebuild (
  name      text PRIMARY KEY,
  kind      "char" NOT NULL,          -- 'v' view, 'm' matview
  depth     int  NOT NULL,
  def       text NOT NULL,
  indexdefs text[] NOT NULL DEFAULT '{}',
  comment   text
);
COMMENT ON TABLE ft_view_rebuild IS
  'Scratch space for migrations that must drop and recreate a materialized
   view: dependent view definitions are parked here between
   ft_rebuild_capture() and ft_rebuild_restore(). Normally empty.';

CREATE OR REPLACE FUNCTION ft_rebuild_capture(roots text[])
RETURNS int LANGUAGE plpgsql SET search_path = public, pg_catalog AS $$
DECLARE n int;
BEGIN
  WITH RECURSIVE deps AS (
    SELECT c.oid, 0 AS lvl
    FROM pg_class c
    WHERE c.relnamespace = 'public'::regnamespace AND c.relname = ANY (roots)
    UNION ALL
    SELECT dep.oid, d.lvl + 1
    FROM deps d
    JOIN pg_depend pd ON pd.refobjid = d.oid AND pd.classid = 'pg_rewrite'::regclass
    JOIN pg_rewrite r ON r.oid = pd.objid
    JOIN pg_class dep ON dep.oid = r.ev_class
    WHERE dep.oid <> d.oid AND d.lvl < 20
  ), dd AS (
    SELECT oid, MAX(lvl) AS depth FROM deps WHERE lvl > 0 GROUP BY oid
  )
  INSERT INTO ft_view_rebuild (name, kind, depth, def, indexdefs, comment)
  SELECT c.relname, c.relkind, dd.depth, pg_get_viewdef(c.oid, true),
         COALESCE((SELECT array_agg(pg_get_indexdef(i.indexrelid)) FROM pg_index i WHERE i.indrelid = c.oid), '{}'),
         obj_description(c.oid, 'pg_class')
  FROM dd JOIN pg_class c ON c.oid = dd.oid
  WHERE c.relkind IN ('v', 'm')
    AND NOT (c.relname = ANY (roots))
  ON CONFLICT (name) DO UPDATE
    SET depth = GREATEST(ft_view_rebuild.depth, EXCLUDED.depth);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION ft_rebuild_drop(names text[])
RETURNS void LANGUAGE plpgsql SET search_path = public, pg_catalog AS $$
DECLARE r record;
BEGIN
  -- dependents deepest first, then the roots
  FOR r IN SELECT name, kind FROM ft_view_rebuild ORDER BY depth DESC LOOP
    IF r.kind = 'm' THEN
      EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %I', r.name);
    ELSE
      EXECUTE format('DROP VIEW IF EXISTS %I', r.name);
    END IF;
  END LOOP;
  FOR r IN SELECT c.relname, c.relkind FROM pg_class c
           WHERE c.relnamespace = 'public'::regnamespace AND c.relname = ANY (names) LOOP
    IF r.relkind = 'm' THEN
      EXECUTE format('DROP MATERIALIZED VIEW %I', r.relname);
    ELSE
      EXECUTE format('DROP VIEW %I', r.relname);
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION ft_rebuild_restore()
RETURNS int LANGUAGE plpgsql SET search_path = public, pg_catalog AS $$
DECLARE r record; ix text; n int := 0;
BEGIN
  FOR r IN SELECT * FROM ft_view_rebuild ORDER BY depth, name LOOP
    IF r.kind = 'm' THEN
      EXECUTE format('CREATE MATERIALIZED VIEW %I AS %s WITH NO DATA', r.name, rtrim(r.def, '; '));
      FOREACH ix IN ARRAY r.indexdefs LOOP EXECUTE ix; END LOOP;
    ELSE
      EXECUTE format('CREATE VIEW %I AS %s', r.name, r.def);
    END IF;
    IF r.comment IS NOT NULL THEN
      EXECUTE format('COMMENT ON %s %I IS %L',
                     CASE r.kind WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'VIEW' END, r.name, r.comment);
    END IF;
    n := n + 1;
  END LOOP;
  FOR r IN SELECT name FROM ft_view_rebuild WHERE kind = 'm' ORDER BY depth LOOP
    EXECUTE format('REFRESH MATERIALIZED VIEW %I', r.name);
  END LOOP;
  DELETE FROM ft_view_rebuild;
  RETURN n;
END $$;

-- ------------------------------------------------------------------
-- vehicle_state_1h
-- ------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS vehicle_state_1h AS
WITH bounds AS (
  SELECT vin, date_trunc('hour', MIN(bucket)) AS first_h, date_trunc('hour', MAX(bucket)) AS last_h
  FROM telemetry_1h
  GROUP BY vin
), hours AS (
  SELECT b.vin, g AS bucket
  FROM bounds b, generate_series(b.first_h, b.last_h, INTERVAL '1 hour') g
), raw AS (
  SELECT h.vin, h.bucket,
    gs.str_value AS gear_start, gs.ts AS gear_start_ts,
    EXISTS (SELECT 1 FROM telemetry t
            WHERE t.vin = h.vin AND t.field = 'Gear'
              AND t.ts >= h.bucket AND t.ts < h.bucket + INTERVAL '1 hour'
              AND t.str_value NOT IN ('P', 'ShiftStateP', 'invalid', '')) AS gear_moved,
    ss.num_value AS speed_start, ss.ts AS speed_start_ts,
    EXISTS (SELECT 1 FROM telemetry t
            WHERE t.vin = h.vin AND t.field = 'VehicleSpeed'
              AND t.ts >= h.bucket AND t.ts < h.bucket + INTERVAL '1 hour'
              AND t.num_value > 0) AS moving_in_hour,
    cs.state AS charge_start, cs.ts AS charge_start_ts,
    EXISTS (SELECT 1 FROM telemetry t
            WHERE t.vin = h.vin AND t.field = 'DetailedChargeState'
              AND t.ts >= h.bucket AND t.ts < h.bucket + INTERVAL '1 hour'
              AND regexp_replace(t.str_value, '^DetailedChargeState', '') IN ('Charging', 'Starting')) AS charging_state_in_hour,
    EXISTS (SELECT 1 FROM telemetry t
            WHERE t.vin = h.vin AND t.field IN ('ACChargingPower', 'DCChargingPower')
              AND t.ts >= h.bucket AND t.ts < h.bucket + INTERVAL '1 hour'
              AND t.num_value > 0) AS charge_power_in_hour
  FROM hours h
  LEFT JOIN LATERAL (SELECT t.str_value, t.ts FROM telemetry t
                     WHERE t.vin = h.vin AND t.field = 'Gear' AND t.ts < h.bucket
                     ORDER BY t.ts DESC LIMIT 1) gs ON TRUE
  LEFT JOIN LATERAL (SELECT t.num_value, t.ts FROM telemetry t
                     WHERE t.vin = h.vin AND t.field = 'VehicleSpeed' AND t.ts < h.bucket
                     ORDER BY t.ts DESC LIMIT 1) ss ON TRUE
  LEFT JOIN LATERAL (SELECT regexp_replace(t.str_value, '^DetailedChargeState', '') AS state, t.ts FROM telemetry t
                     WHERE t.vin = h.vin AND t.field = 'DetailedChargeState' AND t.ts < h.bucket
                     ORDER BY t.ts DESC LIMIT 1) cs ON TRUE
), classified AS (
  SELECT r.*,
    COALESCE(r.gear_start_ts >= r.bucket - state_validity_window(), FALSE) AS known,
    (COALESCE(r.gear_start, '') IN ('P', 'ShiftStateP', 'invalid', '')
     AND NOT r.gear_moved
     AND NOT r.moving_in_hour
     AND NOT COALESCE(r.speed_start_ts >= r.bucket - state_validity_window() AND r.speed_start > 0, FALSE)) AS parked,
    (COALESCE(r.charge_start IN ('Charging', 'Starting') AND r.charge_start_ts >= r.bucket - state_validity_window(), FALSE)
     OR r.charging_state_in_hour
     OR r.charge_power_in_hour) AS charging
  FROM raw r
)
SELECT vin, bucket,
  gear_start, gear_start_ts, gear_moved, speed_start, speed_start_ts, moving_in_hour,
  charge_start, charge_start_ts, charging_state_in_hour, charge_power_in_hour,
  known, parked, charging,
  CASE WHEN known THEN parked AND NOT charging END AS at_rest
FROM classified
WITH NO DATA;

CREATE UNIQUE INDEX IF NOT EXISTS vehicle_state_1h_uq ON vehicle_state_1h (vin, bucket);
COMMENT ON MATERIALIZED VIEW vehicle_state_1h IS
  'Per vehicle-hour state from the last known Gear / VehicleSpeed /
   DetailedChargeState (carried forward for state_validity_window()) plus
   what changed inside the hour. at_rest is NULL when the state is unknown.
   Refreshed with the predictive matviews, before the views that read it (046).';

REFRESH MATERIALIZED VIEW vehicle_state_1h;

-- ------------------------------------------------------------------
-- battery_capacity_1d and low_voltage_wakeups_1d on the carried state.
-- ------------------------------------------------------------------
SELECT ft_rebuild_capture(ARRAY['battery_capacity_1d', 'low_voltage_wakeups_1d']) AS captured_dependents;
SELECT ft_rebuild_drop(ARRAY['battery_capacity_1d', 'low_voltage_wakeups_1d']);

CREATE MATERIALIZED VIEW battery_capacity_1d AS
WITH tagged AS (
  SELECT s.bucket, s.vin,
    s.energy_remaining_last, s.battery_level_last, s.ideal_range_last, s.rated_range_last,
    (st.at_rest IS TRUE
     AND ABS(COALESCE(s.pack_current_avg, 0) * COALESCE(s.pack_voltage_avg, 0)) < 500) AS is_rest
  FROM battery_samples_1h s
  LEFT JOIN vehicle_state_1h st ON st.vin = s.vin AND st.bucket = s.bucket
), brick AS (
  -- BrickVoltageMax and BrickVoltageMin from the same payload only.
  SELECT a.vin, time_bucket('1 day', a.ts) AS bucket,
         MAX(a.num_value - b.num_value) AS brick_delta_max,
         AVG(a.num_value - b.num_value) AS brick_delta_avg
  FROM telemetry a
  JOIN telemetry b ON b.vin = a.vin AND b.ts = a.ts AND b.field = 'BrickVoltageMin'
  WHERE a.field = 'BrickVoltageMax' AND a.num_value IS NOT NULL AND b.num_value IS NOT NULL
  GROUP BY 1, 2
), daily AS (
  SELECT time_bucket('1 day', bucket) AS bucket, vin,
    COUNT(*) FILTER (WHERE is_rest) AS rest_hours,
    LAST(energy_remaining_last, bucket) FILTER (WHERE is_rest AND battery_level_last > 0) AS energy_remaining_rest,
    LAST(battery_level_last, bucket)    FILTER (WHERE is_rest AND battery_level_last > 0) AS battery_level_rest,
    LAST(ideal_range_last, bucket)      FILTER (WHERE is_rest) AS ideal_range_rest,
    LAST(rated_range_last, bucket)      FILTER (WHERE is_rest) AS rated_range_rest
  FROM tagged
  GROUP BY 1, 2
)
SELECT d.bucket, d.vin, d.rest_hours, d.energy_remaining_rest, d.battery_level_rest,
       d.ideal_range_rest, d.rated_range_rest, b.brick_delta_max, b.brick_delta_avg
FROM daily d
LEFT JOIN brick b ON b.vin = d.vin AND b.bucket = d.bucket;
CREATE UNIQUE INDEX IF NOT EXISTS battery_capacity_1d_uq ON battery_capacity_1d (vin, bucket);

CREATE MATERIALIZED VIEW low_voltage_wakeups_1d AS
WITH tagged AS (
  SELECT s.bucket, s.vin, s.dcdc_true_samples, s.dcdc_false_samples, s.dcdc_total_samples,
         st.at_rest IS TRUE AS asleep
  FROM low_voltage_samples_1h s
  LEFT JOIN vehicle_state_1h st ON st.vin = s.vin AND st.bucket = s.bucket
)
SELECT time_bucket('1 day', bucket) AS bucket, vin,
  COUNT(*) FILTER (WHERE asleep AND dcdc_total_samples > 0) AS sleep_hours,
  COUNT(*) FILTER (WHERE asleep AND dcdc_true_samples > 0 AND dcdc_false_samples > 0) AS dcdc_cycling_sleep_hours,
  COUNT(*) FILTER (WHERE asleep AND dcdc_true_samples > 0 AND dcdc_false_samples = 0) AS dcdc_always_on_sleep_hours,
  SUM(dcdc_true_samples) FILTER (WHERE asleep) AS dcdc_true_samples_during_sleep
FROM tagged
GROUP BY 1, 2;
CREATE UNIQUE INDEX IF NOT EXISTS low_voltage_wakeups_1d_uq ON low_voltage_wakeups_1d (vin, bucket);

SELECT ft_rebuild_restore() AS recreated_dependents;
