-- Views and helper functions used by Grafana dashboards.

-- ============================================================
-- Latest user-preference per vin (drives unit display)
-- ============================================================
CREATE OR REPLACE VIEW vehicle_prefs AS
SELECT DISTINCT ON (vin, field)
  vin, field, str_value AS value, ts AS updated_at
FROM telemetry
WHERE field IN (
  'SettingDistanceUnit', 'SettingTemperatureUnit',
  'SettingChargeUnit',   'SettingTirePressureUnit',
  'Setting24HourTime'
)
ORDER BY vin, field, ts DESC;

CREATE OR REPLACE VIEW vehicle_prefs_pivot AS
SELECT
  vin,
  MAX(value) FILTER (WHERE field='SettingDistanceUnit')     AS distance_unit,
  MAX(value) FILTER (WHERE field='SettingTemperatureUnit')  AS temp_unit,
  MAX(value) FILTER (WHERE field='SettingChargeUnit')       AS charge_unit,
  MAX(value) FILTER (WHERE field='SettingTirePressureUnit') AS tire_unit,
  MAX(value) FILTER (WHERE field='Setting24HourTime')       AS time_24h
FROM vehicle_prefs
GROUP BY vin;

-- ============================================================
-- Unit conversion helpers (called from Grafana panel queries)
-- ============================================================
CREATE OR REPLACE FUNCTION to_dist(km DOUBLE PRECISION, unit TEXT)
RETURNS DOUBLE PRECISION LANGUAGE SQL IMMUTABLE AS $$
  SELECT CASE WHEN unit = 'imperial' THEN km * 0.621371 ELSE km END;
$$;

CREATE OR REPLACE FUNCTION to_temp(c DOUBLE PRECISION, unit TEXT)
RETURNS DOUBLE PRECISION LANGUAGE SQL IMMUTABLE AS $$
  SELECT CASE WHEN unit = 'imperial' THEN c * 9.0/5.0 + 32 ELSE c END;
$$;

CREATE OR REPLACE FUNCTION to_pressure(bar DOUBLE PRECISION, unit TEXT)
RETURNS DOUBLE PRECISION LANGUAGE SQL IMMUTABLE AS $$
  SELECT CASE WHEN unit = 'PressureUnitPsi' THEN bar * 14.5038 ELSE bar END;
$$;

-- ============================================================
-- Trip sessionization — Location-gap based (v2)
--
-- Algorithm: a gap > 10 min between consecutive GPS points
-- signals the start of a new trip. Micro-movements < 200 m
-- are filtered out. Per-trip stats include speed (from
-- VehicleSpeed field) and energy (from BatteryLevel /
-- EnergyRemaining / RatedRange).
-- ============================================================
CREATE OR REPLACE VIEW trips AS
WITH loc AS (
  SELECT
    ts, vin, geo_value,
    ts - LAG(ts) OVER (PARTITION BY vin ORDER BY ts) AS gap
  FROM telemetry
  WHERE field = 'Location'
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
    -- State of Charge (%)
    ROUND(first(b.num_value, b.ts)::numeric, 1)                              AS soc_start_pct,
    ROUND(last(b.num_value,  b.ts)::numeric, 1)                              AS soc_end_pct,
    ROUND((first(b.num_value, b.ts) - last(b.num_value, b.ts))::numeric, 1) AS soc_used_pct,
    -- Energy Remaining (kWh) — direct battery kWh meter
    ROUND(first(e.num_value, e.ts)::numeric, 2)                              AS kwh_start,
    ROUND(last(e.num_value,  e.ts)::numeric, 2)                              AS kwh_end,
    ROUND((first(e.num_value, e.ts) - last(e.num_value, e.ts))::numeric, 2) AS kwh_used,
    -- Rated range (miles) at start/end
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
),
ranked AS (
  SELECT
    tb.vin,
    ROW_NUMBER() OVER (PARTITION BY tb.vin ORDER BY tb.started) AS trip_id,
    tb.trip_id_raw,
    tb.started, tb.ended, tb.duration,
    tb.distance_km, tb.gps_points,
    COALESCE(ss.max_speed_mph, 0)        AS max_speed_mph,
    COALESCE(ss.avg_speed_mph, 0)        AS avg_speed_mph,
    es.soc_start_pct, es.soc_end_pct,   es.soc_used_pct,
    es.kwh_start,     es.kwh_end,        es.kwh_used,
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
)
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
FROM ranked
ORDER BY started;

-- ============================================================
-- Charge sessions (ChargeState IN ('Charging','Starting'))
-- ============================================================
CREATE OR REPLACE VIEW charge_sessions AS
WITH s AS (
  SELECT ts, vin, str_value AS state,
         LAG(str_value) OVER (PARTITION BY vin ORDER BY ts) AS prev_state
  FROM telemetry
  WHERE field = 'ChargeState'
), starts AS (
  SELECT ts, vin, state,
         CASE WHEN state IN ('Charging','Starting')
              AND (prev_state NOT IN ('Charging','Starting') OR prev_state IS NULL)
              THEN ts END AS sess_start
  FROM s
), numbered AS (
  SELECT ts, vin, state,
    COUNT(sess_start) OVER (PARTITION BY vin ORDER BY ts) AS session_id
  FROM starts
)
SELECT
  vin,
  session_id,
  MIN(ts) AS started,
  MAX(ts) AS ended,
  MAX(ts) - MIN(ts) AS duration
FROM numbered
WHERE state IN ('Charging','Starting')
GROUP BY vin, session_id;

-- ============================================================
-- Latest snapshot per vin/field (handy for stat panels)
-- ============================================================
CREATE OR REPLACE VIEW telemetry_latest AS
SELECT DISTINCT ON (vin, field)
  vin, field, ts, num_value, str_value, geo_value
FROM telemetry
ORDER BY vin, field, ts DESC;
