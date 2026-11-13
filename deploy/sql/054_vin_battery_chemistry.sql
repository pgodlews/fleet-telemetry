-- ============================================================
-- 054_vin_battery_chemistry.sql — battery chemistry from the VIN
--
-- 043 stopped guessing "every 2021+ Model 3 is LFP" and only inferred
-- LFP for 2022+ rear-drive cars. When the production car (a 2021
-- Shanghai-built rear-drive Model 3, which is LFP) reconnected, the
-- upsert rewrote its battery_type to NULL, and every LFP rule (053's
-- below-90 % brick-spread gate and the no-penalty rule) stopped
-- applying to the one real vehicle.
--
-- The chemistry is encoded in the VIN. For Model 3 and Model Y,
-- position 7 is the battery / energy-storage code:
--   F = lithium iron phosphate (LFP)
--   E = lithium-ion, NCA/NMC (not LFP)
-- Sources (third-party decoders; Tesla publishes no VIN decoder):
-- findmyelectric.com "Tesla VIN Decoder" (position 7: E = NMC/NCA
-- lithium-ion, F = LFP), driveteslacanada.ca and teslatap.com VIN
-- decoders (F = LFP on Model 3/Y). For Model S/X position 7 carried
-- capacity codes (S, V, H, E, ...) that do not identify chemistry
-- (no S/X is LFP), and no reliable table was found for Cybertruck, so
-- those keep the existing year/model rule.
--
-- Rules (vin_battery_type):
--   Model 3/Y, position 7 'F' -> 'LFP'
--   Model 3/Y, position 7 'E' -> not LFP: the year rule's cell format
--     ('4680' for 2024+ Model Y, otherwise '2170')
--   anything else -> the 043 rule (year/model, then 2022+ RWD Model 3
--     -> LFP, Dual Motor / Performance Model 3 -> 2170), unknown = NULL
-- manual_override rows are never touched.
--
-- Existing rows are re-derived here (not manually overridden), so the
-- production row is corrected by `make migrate`, and the matviews that
-- read battery_type are refreshed. Idempotent.
-- ============================================================

CREATE OR REPLACE FUNCTION vin_battery_type(
  p_vin TEXT, p_model TEXT, p_year INTEGER, p_motor TEXT
) RETURNS TEXT LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  code     TEXT := upper(SUBSTRING(p_vin FROM 7 FOR 1));
  by_year  TEXT;
BEGIN
  SELECT battery_type INTO by_year FROM infer_features_from_model(p_model, p_year);

  IF p_model IN ('3', 'Y') AND code = 'F' THEN
    RETURN 'LFP';
  END IF;
  IF p_model IN ('3', 'Y') AND code = 'E' THEN
    RETURN CASE WHEN by_year IS NULL OR by_year = 'LFP' THEN '2170' ELSE by_year END;
  END IF;

  -- no usable code: 043's narrow rule
  IF by_year IS NULL AND p_model = '3' AND p_year >= 2021 THEN
    RETURN CASE
      WHEN p_motor = 'RWD' AND p_year >= 2022 THEN 'LFP'
      WHEN p_motor IN ('Dual Motor', 'Performance') THEN '2170'
    END;
  END IF;
  RETURN by_year;
END $$;

COMMENT ON FUNCTION vin_battery_type(TEXT, TEXT, INTEGER, TEXT) IS
  'Battery chemistry/format for a vehicle: Model 3/Y VIN position 7 (F = LFP,
   E = NCA/NMC) first, else the year/model rule from 043 (054).';

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
  v_batt := vin_battery_type(p_vin, v_model, v_year, v_motor);

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
         OR vehicles.model IS DISTINCT FROM EXCLUDED.model
         OR vehicles.battery_type IS DISTINCT FROM EXCLUDED.battery_type);
END;
$$;

-- Re-derive the chemistry of existing rows (model/year/motor as stored).
UPDATE vehicles
   SET battery_type = vin_battery_type(vin, model, model_year, motor_config),
       last_updated = NOW()
 WHERE NOT manual_override
   AND battery_type IS DISTINCT FROM vin_battery_type(vin, model, model_year, motor_config);

-- Views read battery_type live; the stored ones are refreshed now:
-- battery_capacity_1d (053's LFP gate), then the health matviews.
SELECT refresh_one_matview('battery_capacity_1d')            AS battery_capacity_refreshed;
SELECT refresh_one_matview('predictive_health_score_1d_mat') AS score_1d_refreshed;
SELECT refresh_one_matview('predictive_health_summary_mat')  AS summary_refreshed;
