-- ============================================================
-- Vehicle Metadata Layer
--
-- Detects vehicle model, year, battery type, and feature flags
-- from telemetry streams.  Enables cross-model dashboards and
-- model-specific predictive thresholds.
--
-- Design goals:
--   1. Non-breaking — existing Model 3 data continues to work.
--   2. Self-healing — metadata is updated automatically when
--      new telemetry arrives; no manual VIN registration.
--   3. CarType-first — the streamed `CarType` enum is authoritative.
--      VIN parsing is a deterministic fallback for vehicles that
--      haven't sent CarType yet (or for legacy streams).
--   4. Idempotent — safe to re-run; ON CONFLICT updates only
--      changed columns and bumps last_updated.
--
-- Why CarType is preferred over VIN parsing:
--   - CarType is an explicit enum from the vehicle's own firmware
--     (Model3, ModelY, Cybertruck, SemiTruck, etc.). It is never
--     ambiguous and correctly handles special editions, refreshes,
--     and export-market VIN variations.
--   - VIN position 4 (index 3) encodes the model, but Tesla has
--     used overlapping codes across years and regions. VIN parsing
--     is deterministic and useful as a fallback, but CarType should
--     always win when both are available.
--
-- Run after 001_schema.sql and 002_views.sql.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  vehicles table — one row per VIN
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vehicles (
  vin              TEXT PRIMARY KEY,
  model            TEXT NOT NULL DEFAULT '3',
  model_year       INTEGER,
  battery_type     TEXT,          -- '2170', '4680', 'LFP', '18650'
  motor_config     TEXT,          -- 'RWD', 'Dual Motor', 'Performance', 'Tri Motor'
  has_heat_pump    BOOLEAN DEFAULT FALSE,
  has_air_suspension BOOLEAN DEFAULT FALSE,
  has_fsd_hardware TEXT,          -- 'HW3', 'HW4', 'AI4'
  first_seen       TIMESTAMPTZ DEFAULT NOW(),
  last_updated     TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS vehicles_model_idx ON vehicles (model);
CREATE INDEX IF NOT EXISTS vehicles_battery_type_idx ON vehicles (battery_type);

-- ------------------------------------------------------------------
-- 2.  Convenience view (exact same columns, stable API for dashboards)
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW vehicle_metadata AS
SELECT * FROM vehicles;

-- ------------------------------------------------------------------
-- 3.  Helper: decode model year from VIN position 10 (index 9)
--
-- Standard VIN year codes (Tesla uses the same mapping):
--   M=2021, N=2022, P=2023, R=2024, S=2025, T=2026
--   (skips I, O, Q, U, Z to avoid confusion)
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vin_year_char_to_int(ch TEXT)
RETURNS INTEGER LANGUAGE SQL IMMUTABLE AS $$
  SELECT CASE ch
    WHEN 'M' THEN 2021
    WHEN 'N' THEN 2022
    WHEN 'P' THEN 2023
    WHEN 'R' THEN 2024
    WHEN 'S' THEN 2025
    WHEN 'T' THEN 2026
    WHEN 'V' THEN 2027
    WHEN 'W' THEN 2028
    WHEN 'X' THEN 2029
    WHEN 'Y' THEN 2030
    WHEN '1' THEN 2031
    WHEN '2' THEN 2032
    WHEN '3' THEN 2033
    WHEN '4' THEN 2034
    WHEN '5' THEN 2035
    WHEN '6' THEN 2036
    WHEN '7' THEN 2037
    WHEN '8' THEN 2038
    WHEN '9' THEN 2039
    WHEN 'A' THEN 2010
    WHEN 'B' THEN 2011
    WHEN 'C' THEN 2012
    WHEN 'D' THEN 2013
    WHEN 'E' THEN 2014
    WHEN 'F' THEN 2015
    WHEN 'G' THEN 2016
    WHEN 'H' THEN 2017
    WHEN 'J' THEN 2018
    WHEN 'K' THEN 2019
    WHEN 'L' THEN 2020
    ELSE NULL
  END;
$$;

-- ------------------------------------------------------------------
-- 4.  Helper: decode model from VIN position 4 (index 3)
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vin_model_char_to_text(ch TEXT)
RETURNS TEXT LANGUAGE SQL IMMUTABLE AS $$
  SELECT CASE ch
    WHEN 'S' THEN 'S'
    WHEN 'X' THEN 'X'
    WHEN '3' THEN '3'
    WHEN 'Y' THEN 'Y'
    WHEN 'C' THEN 'CT'
    WHEN 'R' THEN 'R'
    WHEN 'T' THEN 'Semi'
    ELSE '3'   -- conservative default
  END;
$$;

-- ------------------------------------------------------------------
-- 5.  Helper: full VIN parsing (fallback when CarType is absent)
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION detect_vehicle_from_vin(vin TEXT)
RETURNS TABLE(
  model TEXT,
  model_year INTEGER,
  motor_config TEXT,
  has_heat_pump BOOLEAN,
  has_air_suspension BOOLEAN
)
LANGUAGE SQL IMMUTABLE AS $$
  SELECT
    vin_model_char_to_text(SUBSTRING(vin FROM 4 FOR 1)),
    vin_year_char_to_int(SUBSTRING(vin FROM 10 FOR 1)),
    CASE
      WHEN LENGTH(vin) < 8 THEN 'RWD'
      WHEN SUBSTRING(vin FROM 8 FOR 1) IN ('A','B') THEN 'RWD'
      WHEN SUBSTRING(vin FROM 8 FOR 1) IN ('C','D','E') THEN 'Dual Motor'
      WHEN SUBSTRING(vin FROM 8 FOR 1) IN ('F','G') THEN 'Performance'
      WHEN SUBSTRING(vin FROM 8 FOR 1) IN ('H','J') THEN 'Tri Motor'
      ELSE 'Dual Motor'
    END,
    CASE
      WHEN vin_model_char_to_text(SUBSTRING(vin FROM 4 FOR 1)) IN ('Y','CT','Semi') THEN TRUE
      WHEN vin_model_char_to_text(SUBSTRING(vin FROM 4 FOR 1)) = '3'
       AND vin_year_char_to_int(SUBSTRING(vin FROM 10 FOR 1)) >= 2021 THEN TRUE
      ELSE FALSE
    END,
    CASE
      WHEN vin_model_char_to_text(SUBSTRING(vin FROM 4 FOR 1)) IN ('S','X','CT','Y') THEN TRUE
      ELSE FALSE
    END;
$$;

-- ------------------------------------------------------------------
-- 6.  Helper: map CarType enum string to internal model code
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cartype_to_model(cartype TEXT)
RETURNS TEXT LANGUAGE SQL IMMUTABLE AS $$
  SELECT CASE cartype
    WHEN 'CarTypeModelS'     THEN 'S'
    WHEN 'CarTypeModelX'     THEN 'X'
    WHEN 'CarTypeModel3'     THEN '3'
    WHEN 'CarTypeModelY'     THEN 'Y'
    WHEN 'CarTypeSemiTruck'  THEN 'Semi'
    WHEN 'CarTypeCybertruck' THEN 'CT'
    ELSE '3'
  END;
$$;

-- ------------------------------------------------------------------
-- 7.  Helper: infer feature flags from model + year
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION infer_features_from_model(
  m TEXT,
  yr INTEGER
)
RETURNS TABLE(
  battery_type TEXT,
  has_heat_pump BOOLEAN,
  has_air_suspension BOOLEAN
)
LANGUAGE SQL IMMUTABLE AS $$
  SELECT
    CASE
      WHEN m = 'CT' THEN '4680'
      WHEN m = 'Y'  AND yr >= 2024 THEN '4680'
      WHEN m = '3'  AND yr >= 2021 THEN 'LFP'
      WHEN m IN ('S','X') AND yr >= 2021 THEN '18650'
      ELSE '2170'
    END,
    CASE
      WHEN m IN ('Y','CT','Semi') THEN TRUE
      WHEN m = '3' AND yr >= 2021 THEN TRUE
      ELSE FALSE
    END,
    CASE
      WHEN m IN ('S','X','CT','Y') THEN TRUE
      ELSE FALSE
    END;
$$;

-- ------------------------------------------------------------------
-- 8.  Upsert vehicle from telemetry (called by Go producer)
--
-- car_type is the raw CarType enum string (e.g. 'CarTypeModelY').
-- If NULL or empty, the function falls back to VIN parsing.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION upsert_vehicle_from_telemetry(
  p_vin TEXT,
  p_car_type TEXT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_model TEXT;
  v_year  INTEGER;
  v_motor TEXT;
  v_hp    BOOLEAN;
  v_as    BOOLEAN;
  v_batt  TEXT;
BEGIN
  -- Prefer CarType; fallback to VIN parsing
  IF p_car_type IS NOT NULL AND p_car_type != '' AND p_car_type != 'CarTypeUnknown' THEN
    v_model := cartype_to_model(p_car_type);
    v_year  := vin_year_char_to_int(SUBSTRING(p_vin FROM 10 FOR 1));
    SELECT * INTO v_batt, v_hp, v_as
      FROM infer_features_from_model(v_model, v_year);
    -- Motor config: use VIN position 8 when CarType doesn't encode it
    SELECT motor_config INTO v_motor
      FROM detect_vehicle_from_vin(p_vin);
  ELSE
    SELECT * INTO v_model, v_year, v_motor, v_hp, v_as
      FROM detect_vehicle_from_vin(p_vin);
    SELECT * INTO v_batt, v_hp, v_as
      FROM infer_features_from_model(v_model, v_year);
  END IF;

  INSERT INTO vehicles (
    vin, model, model_year, battery_type, motor_config,
    has_heat_pump, has_air_suspension, first_seen, last_updated
  ) VALUES (
    p_vin, v_model, v_year, v_batt, v_motor,
    v_hp, v_as, NOW(), NOW()
  )
  ON CONFLICT (vin) DO UPDATE SET
    model            = EXCLUDED.model,
    model_year       = EXCLUDED.model_year,
    battery_type     = EXCLUDED.battery_type,
    motor_config     = EXCLUDED.motor_config,
    has_heat_pump    = EXCLUDED.has_heat_pump,
    has_air_suspension = EXCLUDED.has_air_suspension,
    last_updated     = NOW()
  WHERE vehicles.last_updated < NOW() - INTERVAL '1 hour'
     OR vehicles.model IS DISTINCT FROM EXCLUDED.model;
END;
$$;

-- ------------------------------------------------------------------
-- 9.  Back-fill helper: populate vehicles for existing telemetry VINs
--
-- Run this once after deploying the table if you already have data.
-- ------------------------------------------------------------------
-- INSERT INTO vehicles (vin, model, model_year, battery_type, motor_config, has_heat_pump, has_air_suspension, first_seen, last_updated)
-- SELECT DISTINCT ON (vin)
--   vin,
--   (detect_vehicle_from_vin(vin)).model,
--   (detect_vehicle_from_vin(vin)).model_year,
--   (infer_features_from_model((detect_vehicle_from_vin(vin)).model, (detect_vehicle_from_vin(vin)).model_year)).battery_type,
--   (detect_vehicle_from_vin(vin)).motor_config,
--   (infer_features_from_model((detect_vehicle_from_vin(vin)).model, (detect_vehicle_from_vin(vin)).model_year)).has_heat_pump,
--   (infer_features_from_model((detect_vehicle_from_vin(vin)).model, (detect_vehicle_from_vin(vin)).model_year)).has_air_suspension,
--   NOW(),
--   NOW()
-- FROM telemetry
-- ON CONFLICT (vin) DO NOTHING;

-- ------------------------------------------------------------------
-- 10.  Update summary views to expose model info (non-breaking LEFT JOINs)
-- ------------------------------------------------------------------

-- The core diagnostic views (telemetry_anomalies, battery_health_diagnostics,
-- drivetrain_diagnostics, etc.) are kept unchanged so their rolling-window
-- logic remains untouched.  We add model columns to the *summary* views
-- that Grafana queries directly.

-- NOTE: predictive_health_summary is defined in 014_predictive_health.sql.
-- The previous override that lived here has been removed to avoid
-- clobbering the full master view (which includes air_suspension,
-- dual_motor, cybertruck, and updated weights).  Do NOT recreate
-- predictive_health_summary in this file — run 014 after 005.

-- ------------------------------------------------------------------
-- 11.  Example Grafana queries using vehicle_metadata
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Fleet Health by Model"  (Table / Bar chart)
-- --------------------------------------------------------
-- SELECT
--   model AS "Model",
--   COUNT(*) AS "Vehicles",
--   ROUND(AVG(overall_risk_score)::numeric, 1) AS "Avg Risk",
--   MAX(overall_risk_score) AS "Max Risk"
-- FROM predictive_health_summary
-- WHERE model IS NOT NULL
-- GROUP BY model
-- ORDER BY "Avg Risk" DESC;

-- --------------------------------------------------------
-- Panel: "Model-Specific Threshold Note"  (Text panel)
-- --------------------------------------------------------
-- Use Grafana's "Text" panel with Markdown mode, querying:
--
-- SELECT
--   CASE model
--     WHEN 'CT' THEN 'Cybertruck — Tri Motor, 4680 cells, air suspension'
--     WHEN 'Y'  THEN 'Model Y — Dual Motor or Performance, 2170/4680'
--     WHEN '3'  THEN 'Model 3 — RWD or Performance, 2170/LFP'
--     WHEN 'S'  THEN 'Model S — Dual or Tri Motor, 18650/2170'
--     WHEN 'X'  THEN 'Model X — Dual or Tri Motor, 18650/2170'
--     ELSE 'Unknown model'
--   END AS notes
-- FROM vehicle_metadata
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Template variable $model (query type)
-- --------------------------------------------------------
-- SELECT DISTINCT model AS __text, model AS __value
-- FROM vehicle_metadata
-- ORDER BY 1;

-- ------------------------------------------------------------------
-- 12.  How to test
-- ------------------------------------------------------------------
-- Step 1 — Verify functions
--   SELECT detect_vehicle_from_vin('5YJ3E1EA8PF000001');
--   SELECT upsert_vehicle_from_telemetry('5YJ3E1EA8PF000001', 'CarTypeModel3');
--   SELECT * FROM vehicle_metadata WHERE vin = '5YJ3E1EA8PF000001';
--
-- Step 2 — Verify CarType fallback
--   SELECT upsert_vehicle_from_telemetry('7SA3E1EA8PF000001', NULL);
--   SELECT * FROM vehicle_metadata WHERE vin = '7SA3E1EA8PF000001';
--
-- Step 3 — Verify predictive_health_summary now has model columns
--   SELECT vin, model, battery_type, motor_config, overall_risk_score
--   FROM predictive_health_summary
--   LIMIT 5;
