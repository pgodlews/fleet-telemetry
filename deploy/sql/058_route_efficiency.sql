-- ============================================================
-- 058_route_efficiency.sql — EXPERIMENTAL frequent-route efficiency
-- monitor (idea from Packfade's repeated-ride approach,
-- https://github.com/pgodlews/packfade, MIT licence, by the same author)
--
-- Routes the car drives often are a repeatable test of vehicle
-- efficiency: on the same route at matched conditions, Wh/km should be
-- stable, so a sustained drift points at tyres and pressures, alignment,
-- a dragging brake or added load (not at the battery — the capacity
-- estimate in 057 covers that).
--
-- Objects:
--   * pack_energy_between(vin, t0, t1) — trapezoidal integral of
--     -PackVoltage x PackCurrent between two instants (90 s gap cap, as
--     in 057): energy out (net of regen), energy in, covered seconds.
--   * route_trip_observations — one row per drive: endpoints, distance,
--     duration, V*I energy and Wh/km, the trips table's EnergyRemaining
--     figure for comparison, outside and inside temperature, HVAC state,
--     fan level, defrost, tyre pressures at the start, hours since the
--     previous drive. Read once a day by the notify daemon, which
--     identifies routes from the data and fits the drift.
--   * route_efficiency_routes / route_efficiency_points /
--     route_efficiency_curve / route_efficiency_estimate — results,
--     written by tools/notify (daily, and on demand with
--     --route-efficiency-once). Route ids are opaque; endpoint
--     coordinates stay in the database.
-- Not part of the predictive health score.
--
-- Idempotent.
-- ============================================================

CREATE OR REPLACE FUNCTION pack_energy_between(p_vin TEXT, p_t0 TIMESTAMPTZ, p_t1 TIMESTAMPTZ,
  OUT energy_out_kwh DOUBLE PRECISION, OUT energy_in_kwh DOUBLE PRECISION, OUT covered_s DOUBLE PRECISION)
LANGUAGE sql STABLE SET search_path = public, pg_catalog AS $$
  SELECT
    COALESCE(sum(CASE WHEN ok THEN (plo + phi) / 2.0 * dt END), 0) / 3600.0,
    COALESCE(sum(CASE WHEN ok THEN GREATEST(0, -(plo + phi) / 2.0) * dt END), 0) / 3600.0,
    COALESCE(sum(CASE WHEN ok THEN dt END), 0)
  FROM (
    SELECT (tb - ta) <= 90 AS ok,
           LEAST(tb, b1) - GREATEST(ta, b0) AS dt,
           pa + (pb - pa) * (GREATEST(ta, b0) - ta) / NULLIF(tb - ta, 0) AS plo,
           pa + (pb - pa) * (LEAST(tb, b1) - ta) / NULLIF(tb - ta, 0) AS phi
    FROM (
      SELECT extract(epoch FROM p.ts) AS ta, p.kw AS pa,
             lead(extract(epoch FROM p.ts)) OVER (ORDER BY p.ts) AS tb,
             lead(p.kw) OVER (ORDER BY p.ts) AS pb,
             extract(epoch FROM p_t0) AS b0, extract(epoch FROM p_t1) AS b1
      FROM (
        SELECT i.ts, -(i.num_value * v.num_value) / 1000.0 AS kw
        FROM telemetry i
        JOIN telemetry v ON v.vin = i.vin AND v.ts = i.ts AND v.field = 'PackVoltage'
        WHERE i.vin = p_vin AND i.field = 'PackCurrent'
          AND i.ts BETWEEN p_t0 - INTERVAL '90 seconds' AND p_t1 + INTERVAL '90 seconds'
          AND i.num_value IS NOT NULL AND v.num_value IS NOT NULL
      ) p
    ) iv
    WHERE tb IS NOT NULL
  ) x
  WHERE dt > 0
$$;
COMMENT ON FUNCTION pack_energy_between(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) IS
  'EXPERIMENTAL (058). Trapezoidal integral of -PackVoltage*PackCurrent between two instants; intervals longer than 90 s are not integrated (covered_s says how much was).';

-- Energy source for route Wh/km. Compared on production data (Nov 2026,
-- the 12 qualifying routes of 1.3-6 km): the V*I integral scatters about
-- twice as much run to run (median CV 0.70) as the BMS-counted figures
-- (Soc-based 0.33, EnergyRemaining 0.35, trips table 0.41), because 30 s
-- instantaneous power samples cannot integrate a 5-15 minute drive. EnergyRemaining and Soc carry the same BMS count
-- (EnergyRemaining is a fixed multiple of Soc); Soc has 0.039 % steps
-- (about 0.02 kWh) against EnergyRemaining's 0.12 kWh, so the energy is
-- Soc drop x (EnergyRemaining / Soc at the start). Values are taken at or
-- before the trip start and at or before trip end + 60 s (BMS update
-- lag); the trips table's own figure uses the first and last sample
-- inside the trip, which can arrive minutes late on a short drive.
CREATE OR REPLACE VIEW route_trip_observations AS
WITH t AS (
  SELECT tm.vin, tm.trip_id, tm.started, tm.ended, tm.distance_km::float8 AS distance_km,
         tm.start_lat::float8 AS start_lat, tm.start_lon::float8 AS start_lon,
         tm.end_lat::float8 AS end_lat, tm.end_lon::float8 AS end_lon,
         tm.kwh_used::float8 AS trips_kwh_used,
         lag(tm.ended) OVER (PARTITION BY tm.vin ORDER BY tm.started) AS prev_ended
  FROM trips_mat tm
)
SELECT
  t.vin, t.trip_id, t.started, t.ended,
  ROUND((extract(epoch FROM t.ended - t.started) / 60.0)::numeric, 2) AS duration_min,
  ROUND(t.distance_km::numeric, 3) AS distance_km,
  t.start_lat, t.start_lon, t.end_lat, t.end_lon,
  ROUND((s0.v - s1.v)::numeric, 3) AS soc_drop,
  ROUND((er0.v / NULLIF(s0.v, 0) * 100)::numeric, 2) AS pack_kwh_per_100pct,
  ROUND(((s0.v - s1.v) * er0.v / NULLIF(s0.v, 0))::numeric, 4) AS energy_kwh,
  ROUND(((s0.v - s1.v) * er0.v / NULLIF(s0.v, 0) * 1000 / NULLIF(t.distance_km, 0))::numeric, 1) AS wh_per_km,
  ROUND((er0.v - er1.v)::numeric, 3) AS energy_remaining_drop_kwh,   -- comparison
  ROUND(t.trips_kwh_used::numeric, 3) AS trips_kwh_used,               -- comparison
  ROUND(e.energy_out_kwh::numeric, 4) AS vi_energy_kwh,                -- comparison
  ROUND((e.covered_s / NULLIF(extract(epoch FROM t.ended - t.started), 0))::numeric, 3) AS vi_coverage,
  ROUND((t.distance_km / NULLIF(extract(epoch FROM t.ended - t.started) / 3600.0, 0))::numeric, 1) AS mean_speed_kmh,
  ROUND(COALESCE(ot.avg_t, ot.last_t)::numeric, 2) AS outside_temp_c,
  ROUND(it.v::numeric, 2) AS inside_temp_start_c,
  ROUND((it.v - COALESCE(ot.last_t, ot.avg_t))::numeric, 2) AS cabin_minus_outside_start_c,
  hv.on_at_start AS hvac_on_at_start,
  ROUND(fan.mean_fan::numeric, 2) AS mean_fan_level,
  df.defrost AS defrost_used,
  ROUND(tp.bar::numeric, 3) AS tyre_pressure_bar,
  ROUND((extract(epoch FROM t.started - tp.ts) / 3600.0)::numeric, 1) AS tyre_pressure_age_h,
  ROUND((extract(epoch FROM t.started - t.prev_ended) / 3600.0)::numeric, 2) AS hours_since_prev_drive
FROM t
LEFT JOIN LATERAL (SELECT x.num_value AS v FROM telemetry x WHERE x.vin = t.vin AND x.field = 'Soc'
                   AND x.ts <= t.started ORDER BY x.ts DESC LIMIT 1) s0 ON true
LEFT JOIN LATERAL (SELECT x.num_value AS v FROM telemetry x WHERE x.vin = t.vin AND x.field = 'Soc'
                   AND x.ts <= t.ended + INTERVAL '60 seconds' ORDER BY x.ts DESC LIMIT 1) s1 ON true
LEFT JOIN LATERAL (SELECT x.num_value AS v FROM telemetry x WHERE x.vin = t.vin AND x.field = 'EnergyRemaining'
                   AND x.ts <= t.started ORDER BY x.ts DESC LIMIT 1) er0 ON true
LEFT JOIN LATERAL (SELECT x.num_value AS v FROM telemetry x WHERE x.vin = t.vin AND x.field = 'EnergyRemaining'
                   AND x.ts <= t.ended + INTERVAL '60 seconds' ORDER BY x.ts DESC LIMIT 1) er1 ON true
CROSS JOIN LATERAL pack_energy_between(t.vin, t.started, t.ended) e
CROSS JOIN LATERAL (
  SELECT avg(x.num_value) AS avg_t,
         (SELECT y.num_value FROM telemetry y WHERE y.vin = t.vin AND y.field = 'OutsideTemp'
            AND y.ts <= t.started AND y.ts > t.started - INTERVAL '6 hours' ORDER BY y.ts DESC LIMIT 1) AS last_t
  FROM telemetry x WHERE x.vin = t.vin AND x.field = 'OutsideTemp' AND x.ts BETWEEN t.started AND t.ended
) ot
LEFT JOIN LATERAL (SELECT x.num_value AS v FROM telemetry x WHERE x.vin = t.vin AND x.field = 'InsideTemp'
                   AND x.ts <= t.started + INTERVAL '60 seconds' AND x.ts > t.started - INTERVAL '6 hours'
                   ORDER BY x.ts DESC LIMIT 1) it ON true
LEFT JOIN LATERAL (SELECT x.str_value = 'HvacPowerStateOn' AS on_at_start FROM telemetry x
                   WHERE x.vin = t.vin AND x.field = 'HvacPower' AND x.ts <= t.started + INTERVAL '60 seconds'
                     AND x.str_value IN ('HvacPowerStateOn', 'HvacPowerStateOff')
                   ORDER BY x.ts DESC LIMIT 1) hv ON true
CROSS JOIN LATERAL (
  -- fan level at the start and every change during the drive, averaged
  SELECT avg(v) AS mean_fan FROM (
    (SELECT x.num_value AS v FROM telemetry x WHERE x.vin = t.vin AND x.field = 'HvacFanStatus'
       AND x.num_value IS NOT NULL AND x.ts <= t.started ORDER BY x.ts DESC LIMIT 1)
    UNION ALL
    SELECT x.num_value FROM telemetry x WHERE x.vin = t.vin AND x.field = 'HvacFanStatus'
       AND x.num_value IS NOT NULL AND x.ts > t.started AND x.ts <= t.ended
  ) f
) fan
CROSS JOIN LATERAL (
  SELECT COALESCE(bool_or(x.str_value NOT IN ('DefrostModeStateOff', 'invalid')), false) AS defrost
  FROM telemetry x WHERE x.vin = t.vin AND x.field = 'DefrostMode' AND x.ts BETWEEN t.started AND t.ended
) df
LEFT JOIN LATERAL (
  -- mean of the four tyres' latest readings at or before the start
  SELECT avg(p.v) AS bar, min(p.ts) AS ts FROM (
    SELECT DISTINCT ON (x.field) x.num_value AS v, x.ts FROM telemetry x
    WHERE x.vin = t.vin AND x.field IN ('TpmsPressureFl', 'TpmsPressureFr', 'TpmsPressureRl', 'TpmsPressureRr')
      AND x.ts <= t.started + INTERVAL '5 minutes' AND x.num_value IS NOT NULL
    ORDER BY x.field, x.ts DESC
  ) p HAVING count(*) = 4
) tp ON true;

COMMENT ON VIEW route_trip_observations IS
  'EXPERIMENTAL (058). One row per drive with BMS-counted energy (Soc drop x EnergyRemaining/Soc), Wh/km and covariates for the route-efficiency monitor in tools/notify. Coordinates stay in the database.';

CREATE TABLE IF NOT EXISTS route_efficiency_estimate (
  vin                     TEXT        NOT NULL,
  computed_at             TIMESTAMPTZ NOT NULL,
  status                  TEXT        NOT NULL,   -- 'OK' | 'INSUFFICIENT_DATA'
  message                 TEXT        NOT NULL,
  n_routes                INTEGER     NOT NULL,
  n_used                  INTEGER     NOT NULL,
  n_days                  INTEGER     NOT NULL,
  first_obs               TIMESTAMPTZ,
  last_obs                TIMESTAMPTZ,
  span_days               DOUBLE PRECISION,
  drift_pct_per_year      DOUBLE PRECISION,       -- pooled, route fixed effects; positive = more Wh/km
  drift_lo_pct_per_year   DOUBLE PRECISION,
  drift_hi_pct_per_year   DOUBLE PRECISION,
  temp_effect_pct_per_10c DOUBLE PRECISION,
  raw_scale               DOUBLE PRECISION,       -- robust scale of ln(Wh/km) around each route's median
  residual_scale          DOUBLE PRECISION,       -- after the model
  covariates              TEXT        NOT NULL,
  n_boot                  INTEGER     NOT NULL,
  seed                    BIGINT      NOT NULL,
  method                  TEXT        NOT NULL,
  PRIMARY KEY (vin, computed_at)
);
COMMENT ON TABLE route_efficiency_estimate IS
  'EXPERIMENTAL (058). Pooled route-efficiency drift per computation; written by tools/notify. Not part of the predictive health score.';

CREATE TABLE IF NOT EXISTS route_efficiency_routes (
  vin                     TEXT        NOT NULL,
  route_id                TEXT        NOT NULL,   -- opaque hash
  computed_at             TIMESTAMPTZ NOT NULL,
  label                   TEXT        NOT NULL,   -- 'Route A', 'Route B', ... by trip count
  path_index              INTEGER     NOT NULL,   -- 0 = main road between the endpoints
  start_lat               DOUBLE PRECISION NOT NULL,
  start_lon               DOUBLE PRECISION NOT NULL,
  end_lat                 DOUBLE PRECISION NOT NULL,
  end_lon                 DOUBLE PRECISION NOT NULL,
  median_distance_km      DOUBLE PRECISION NOT NULL,
  distance_cv             DOUBLE PRECISION NOT NULL,
  n_trips                 INTEGER     NOT NULL,
  n_used                  INTEGER     NOT NULL,
  n_days                  INTEGER     NOT NULL,
  first_trip              TIMESTAMPTZ,
  last_trip               TIMESTAMPTZ,
  status                  TEXT        NOT NULL,
  message                 TEXT        NOT NULL,
  median_wh_per_km        DOUBLE PRECISION,
  drift_pct_per_year      DOUBLE PRECISION,       -- this route alone
  drift_lo_pct_per_year   DOUBLE PRECISION,
  drift_hi_pct_per_year   DOUBLE PRECISION,
  temp_effect_pct_per_10c DOUBLE PRECISION,
  raw_scale               DOUBLE PRECISION,
  residual_scale          DOUBLE PRECISION,
  PRIMARY KEY (vin, route_id)
);

CREATE TABLE IF NOT EXISTS route_efficiency_points (
  vin                  TEXT        NOT NULL,
  trip_id              BIGINT      NOT NULL,
  started              TIMESTAMPTZ NOT NULL,
  computed_at          TIMESTAMPTZ NOT NULL,
  route_id             TEXT,                       -- NULL = not on a qualifying route
  wh_per_km            DOUBLE PRECISION,
  normalised_wh_per_km DOUBLE PRECISION,           -- pooled covariate effects removed, route level kept
  outside_temp_c       DOUBLE PRECISION,
  tyre_pressure_bar    DOUBLE PRECISION,
  used                 BOOLEAN     NOT NULL,
  reject_reason        TEXT,
  huber_weight         DOUBLE PRECISION,
  PRIMARY KEY (vin, trip_id)
);

CREATE TABLE IF NOT EXISTS route_efficiency_curve (
  vin               TEXT        NOT NULL,
  route_id          TEXT        NOT NULL,
  ts                TIMESTAMPTZ NOT NULL,
  computed_at       TIMESTAMPTZ NOT NULL,
  fitted_wh_per_km  DOUBLE PRECISION NOT NULL,     -- pooled model, reference conditions
  lo_wh_per_km      DOUBLE PRECISION,
  hi_wh_per_km      DOUBLE PRECISION,
  PRIMARY KEY (vin, route_id, ts)
);

-- Display name for a route: the bot's named places (notify_places) that
-- contain its endpoints, looked up at query time; otherwise the neutral
-- label. Nothing in the repository names a place.
CREATE OR REPLACE FUNCTION route_display_name(p_vin TEXT, p_route_id TEXT)
RETURNS TEXT LANGUAGE sql STABLE SET search_path = public, pg_catalog AS $$
  SELECT CASE WHEN s.name IS NOT NULL AND e.name IS NOT NULL THEN s.name || ' → ' || e.name || CASE WHEN r.path_index > 0 THEN ' (road ' || (r.path_index + 1) || ')' ELSE '' END
              ELSE r.label END
  FROM route_efficiency_routes r
  LEFT JOIN LATERAL (
    SELECT p.name FROM notify_places p
    WHERE p.vin = r.vin
      AND 2 * 6371000 * asin(sqrt(power(sin(radians(p.lat - r.start_lat) / 2), 2)
          + cos(radians(r.start_lat)) * cos(radians(p.lat)) * power(sin(radians(p.lon - r.start_lon) / 2), 2))) <= p.radius_m
    ORDER BY p.radius_m LIMIT 1) s ON true
  LEFT JOIN LATERAL (
    SELECT p.name FROM notify_places p
    WHERE p.vin = r.vin
      AND 2 * 6371000 * asin(sqrt(power(sin(radians(p.lat - r.end_lat) / 2), 2)
          + cos(radians(r.end_lat)) * cos(radians(p.lat)) * power(sin(radians(p.lon - r.end_lon) / 2), 2))) <= p.radius_m
    ORDER BY p.radius_m LIMIT 1) e ON true
  WHERE r.vin = p_vin AND r.route_id = p_route_id
$$;
-- grafana_ro reads these through the default privileges set in 003/042.
