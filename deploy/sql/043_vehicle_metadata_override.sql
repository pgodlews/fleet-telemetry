-- ============================================================
-- 043_vehicle_metadata_override.sql — manual corrections stick;
-- fewer guessed features (S5)
--
-- Before:
--   * upsert_vehicle_from_telemetry (called by the ingester) rewrote
--     every feature column whenever the row was older than an hour, so a
--     hand-corrected battery type or heat-pump flag did not survive.
--   * cartype_to_model mapped any unrecognised CarType string to '3'.
--   * infer_features_from_model declared every 2021+ Model 3 LFP (Long
--     Range and Performance of those years are not) and every Model Y
--     air-suspended (it is optional on few Y variants).
--
-- Now:
--   * vehicles.manual_override (default false). When true the upsert
--     leaves the row alone entirely. Set it after correcting a row:
--       UPDATE vehicles SET battery_type = '2170', manual_override = true
--        WHERE vin = '<VIN>';
--   * cartype_to_model returns NULL for an unknown string; the upsert
--     then falls back to VIN decoding as it does for a missing CarType.
--   * infer_features_from_model: 2021+ Model 3 battery and Model Y air
--     suspension are NULL (unknown) instead of a guess. The upsert fills
--     the Model 3 battery from the VIN-decoded motor configuration where
--     that is reasonably safe (2022+ RWD -> LFP; Dual Motor / Performance
--     -> 2170) and leaves it NULL otherwise (2021 RWD, unknown motor).
--     The VIN motor decode itself (005) is approximate; set
--     manual_override after correcting a row by hand.
--     Other inferences are unchanged.
--   * vehicle_metadata is re-created as SELECT * FROM vehicles so it
--     gains the new column (appended last; existing columns unchanged).
--
-- Function signatures are unchanged. Idempotent.
-- ============================================================

ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS manual_override BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN vehicles.manual_override IS
  'true = row maintained by hand; upsert_vehicle_from_telemetry does not touch it';

CREATE OR REPLACE VIEW vehicle_metadata AS
SELECT * FROM vehicles;

CREATE OR REPLACE FUNCTION cartype_to_model(cartype TEXT)
RETURNS TEXT LANGUAGE SQL IMMUTABLE AS $$
  SELECT CASE cartype
    WHEN 'CarTypeModelS'     THEN 'S'
    WHEN 'CarTypeModelX'     THEN 'X'
    WHEN 'CarTypeModel3'     THEN '3'
    WHEN 'CarTypeModelY'     THEN 'Y'
    WHEN 'CarTypeSemiTruck'  THEN 'Semi'
    WHEN 'CarTypeCybertruck' THEN 'CT'
    ELSE NULL   -- unknown: caller falls back to VIN decoding
  END;
$$;

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
      -- 2021+ Model 3: LFP only for RWD / Standard Range; decided by the
      -- caller from the VIN-decoded motor, unknown here.
      WHEN m = '3'  AND yr >= 2021 THEN NULL
      WHEN m IN ('S','X') AND yr >= 2021 THEN '18650'
      ELSE '2170'
    END,
    CASE
      WHEN m IN ('Y','CT','Semi') THEN TRUE
      WHEN m = '3' AND yr >= 2021 THEN TRUE
      ELSE FALSE
    END,
    CASE
      WHEN m IN ('S','X','CT') THEN TRUE
      WHEN m = 'Y' THEN NULL   -- optional on few variants: unknown
      ELSE FALSE
    END;
$$;

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
  -- Prefer a recognised CarType; otherwise VIN decoding.
  v_model := CASE WHEN p_car_type IS NOT NULL AND p_car_type <> '' AND p_car_type <> 'CarTypeUnknown'
                  THEN cartype_to_model(p_car_type) END;
  IF v_model IS NOT NULL THEN
    v_year := vin_year_char_to_int(SUBSTRING(p_vin FROM 10 FOR 1));
    SELECT d.motor_config INTO v_motor FROM detect_vehicle_from_vin(p_vin) d;
  ELSE
    SELECT * INTO v_model, v_year, v_motor, v_hp, v_as
      FROM detect_vehicle_from_vin(p_vin);
  END IF;
  SELECT * INTO v_batt, v_hp, v_as
    FROM infer_features_from_model(v_model, v_year);

  IF v_model = '3' AND v_year >= 2021 AND v_batt IS NULL THEN
    -- detect_vehicle_from_vin yields 'RWD' / 'Dual Motor' / 'Performance'.
    -- 2021 RWD (Standard Range Plus) shipped with both chemistries, so
    -- only 2022+ RWD is taken as LFP.
    v_batt := CASE
      WHEN v_motor = 'RWD' AND v_year >= 2022 THEN 'LFP'
      WHEN v_motor IN ('Dual Motor', 'Performance') THEN '2170'
    END;
  END IF;

  INSERT INTO vehicles (
    vin, model, model_year, battery_type, motor_config,
    has_heat_pump, has_air_suspension, first_seen, last_updated
  ) VALUES (
    p_vin, v_model, v_year, v_batt, v_motor,
    v_hp, v_as, NOW(), NOW()
  )
  ON CONFLICT (vin) DO UPDATE SET
    model              = EXCLUDED.model,
    model_year         = EXCLUDED.model_year,
    battery_type       = EXCLUDED.battery_type,
    motor_config       = EXCLUDED.motor_config,
    has_heat_pump      = EXCLUDED.has_heat_pump,
    has_air_suspension = EXCLUDED.has_air_suspension,
    last_updated       = NOW()
  WHERE NOT vehicles.manual_override
    AND (vehicles.last_updated < NOW() - INTERVAL '1 hour'
         OR vehicles.model IS DISTINCT FROM EXCLUDED.model);
END;
$$;
