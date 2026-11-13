-- ============================================================
-- 037_service_intervals.sql — fast, correctly scoped service status
-- (P1 item 3, S4)
--
-- service_interval_status took over 60 s on production:
--   * the vehicle list was SELECT DISTINCT vin FROM telemetry, a scan of
--     the whole (compressed) hypertable;
--   * the current odometer was MAX(Odometer) over a 14-day scan.
-- It now takes vehicles from vehicle_metadata and the odometer from one
-- index lookup (vin, field, ts DESC) per vehicle. A vehicle not yet in
-- vehicle_metadata has no applicability data anyway.
--
-- S4 scoping:
--   * applies_to was matched with LIKE '%' || model || '%', so model
--     '3' would match inside any longer code. It is now a token match
--     on the comma-separated list.
--   * Two new optional columns gate an item on vehicle features:
--       applies_if_heat_pump  NULL = any; false = only cars without a
--                             heat pump; true = only cars with one
--       max_model_year        NULL = any; else only model years <= it
--     ac_desiccant is set to (false, 2023): Tesla specifies the
--     desiccant bag for 2017-2023 Model 3 without a heat pump. An
--     unknown has_heat_pump / model_year does not exclude the item.
--   * The per-VIN override promised in a 025 comment does not exist; that
--     comment is corrected in place (comment-only edit). service_intervals
--     stays one global schedule.
--
-- Columns and their order are unchanged. Idempotent.
-- ============================================================

ALTER TABLE service_intervals ADD COLUMN IF NOT EXISTS applies_if_heat_pump BOOLEAN;
ALTER TABLE service_intervals ADD COLUMN IF NOT EXISTS max_model_year INTEGER;

COMMENT ON COLUMN service_intervals.applies_if_heat_pump IS
  'NULL = applies regardless; false = only vehicles without a heat pump; true = only with one';
COMMENT ON COLUMN service_intervals.max_model_year IS
  'NULL = any model year; otherwise applies only to model_year <= this value';

-- Only where the row still has 032's scoping, so an operator's own
-- setting is kept.
UPDATE service_intervals
   SET applies_if_heat_pump = false,
       max_model_year       = 2023
 WHERE item = 'ac_desiccant'
   AND applies_if_heat_pump IS NULL
   AND max_model_year IS NULL;

-- True when a service_intervals row applies to a vehicle.
CREATE OR REPLACE FUNCTION service_item_applies(
  applies_to TEXT, applies_if_heat_pump BOOLEAN, max_model_year INTEGER,
  model TEXT, has_heat_pump BOOLEAN, model_year INTEGER
) RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
  SELECT
    (lower(btrim(applies_to)) = 'all'
     OR model = ANY (string_to_array(regexp_replace(applies_to, '\s', '', 'g'), ',')))
    AND (applies_if_heat_pump IS NULL OR has_heat_pump IS NULL
         OR has_heat_pump = applies_if_heat_pump)
    AND (max_model_year IS NULL OR model_year IS NULL OR model_year <= max_model_year)
$$;

CREATE OR REPLACE VIEW service_interval_status AS
WITH latest_done AS (
  -- DISTINCT ON so the date and the odometer come from the same completion (032).
  SELECT DISTINCT ON (vin, item)
         vin, item, completed_at AS last_done_at, odometer_mi AS last_done_odo
  FROM service_completions
  ORDER BY vin, item, completed_at DESC, id DESC
)
SELECT
  vm.vin,
  s.item,
  s.description,
  s.severity,
  s.interval_months,
  s.interval_miles,
  ld.last_done_at,
  ld.last_done_odo,
  co.odometer_mi  AS current_odometer_mi,
  CASE
    WHEN s.interval_months IS NOT NULL AND ld.last_done_at IS NOT NULL
      THEN ld.last_done_at + (s.interval_months || ' months')::INTERVAL
  END AS due_at,
  CASE
    WHEN s.interval_miles IS NOT NULL AND ld.last_done_odo IS NOT NULL
      THEN ld.last_done_odo + s.interval_miles
  END AS due_odometer_mi,
  -- Status rules unchanged from 032.
  CASE
    WHEN ld.last_done_at IS NULL AND ld.last_done_odo IS NULL
      THEN 'HISTORY_UNKNOWN'
    WHEN s.interval_months IS NOT NULL
         AND ld.last_done_at IS NOT NULL
         AND NOW() > ld.last_done_at + (s.interval_months || ' months')::INTERVAL
      THEN 'OVERDUE'
    WHEN s.interval_miles IS NOT NULL
         AND ld.last_done_odo IS NOT NULL
         AND co.odometer_mi IS NOT NULL
         AND co.odometer_mi > ld.last_done_odo + s.interval_miles
      THEN 'OVERDUE'
    WHEN s.interval_months IS NOT NULL
         AND ld.last_done_at IS NOT NULL
         AND NOW() + INTERVAL '30 days'
             > ld.last_done_at + (s.interval_months || ' months')::INTERVAL
      THEN 'DUE_SOON'
    WHEN s.interval_miles IS NOT NULL
         AND ld.last_done_odo IS NOT NULL
         AND co.odometer_mi IS NOT NULL
         AND co.odometer_mi + 500 > ld.last_done_odo + s.interval_miles
      THEN 'DUE_SOON'
    ELSE 'OK'
  END AS status
FROM vehicle_metadata vm
CROSS JOIN service_intervals s
LEFT JOIN latest_done ld ON ld.vin = vm.vin AND ld.item = s.item
-- Latest odometer: one backwards index scan on (vin, field, ts DESC).
LEFT JOIN LATERAL (
  SELECT t.num_value AS odometer_mi
  FROM telemetry t
  WHERE t.vin = vm.vin AND t.field = 'Odometer' AND t.num_value IS NOT NULL
  ORDER BY t.ts DESC
  LIMIT 1
) co ON TRUE
WHERE service_item_applies(s.applies_to, s.applies_if_heat_pump, s.max_model_year,
                           vm.model, vm.has_heat_pump, vm.model_year);
