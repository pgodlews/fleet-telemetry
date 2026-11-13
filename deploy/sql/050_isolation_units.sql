-- ============================================================
-- 050_isolation_units.sql — IsolationResistance is in kilo-ohms
--
-- 025 compared IsolationResistance with 100,000 / 250,000 as if it were
-- in ohms. Tesla's field list gives no unit ("Resistance between HV bus
-- and chassis"), but the values the car sends (production: 4,270 to
-- 10,220, median about 5,070, 32k samples) are kilo-ohms: about 5 MOhm,
-- a healthy pack. Read as ohms, every day was ISOLATION_RESISTANCE_LOW,
-- and since 038 that showed as a CRITICAL "HV Isolation" recommendation
-- on dashboard 14. A false alarm.
--
-- The thresholds keep their meaning (100 kOhm low, 250 kOhm warning,
-- still not tied to a published Tesla specification) and are now
-- applied to the value as sent. Columns are unchanged; avg_ohms /
-- min_ohms keep their names for compatibility but hold kilo-ohms
-- (dashboard 14 now labels them kOhm). Idempotent.
-- ============================================================

CREATE OR REPLACE VIEW isolation_resistance_diagnostics AS
WITH samples AS (
  SELECT
    time_bucket('1 day', ts) AS bucket,
    vin,
    AVG(num_value) AS avg_ohms,
    MIN(num_value) AS min_ohms,
    COUNT(*)       AS n
  FROM telemetry
  WHERE field = 'IsolationResistance'
    AND num_value IS NOT NULL
    AND ts > NOW() - INTERVAL '60 days'
  GROUP BY 1, 2
)
SELECT
  bucket AS ts,
  vin,
  ROUND(avg_ohms::numeric, 0) AS avg_ohms,
  ROUND(min_ohms::numeric, 0) AS min_ohms,
  n,
  CASE
    WHEN min_ohms IS NULL THEN 'NO_DATA'
    WHEN min_ohms < 100   THEN 'ISOLATION_RESISTANCE_LOW'  -- < 100 kOhm
    WHEN min_ohms < 250   THEN 'WARNING'                   -- < 250 kOhm
    ELSE 'NORMAL'
  END AS status
FROM samples;

COMMENT ON VIEW isolation_resistance_diagnostics IS
  'Daily HV isolation resistance per VIN. Values are kilo-ohms as sent by the
   car (the avg_ohms/min_ohms column names are historical). Below 100 kOhm is
   ISOLATION_RESISTANCE_LOW, below 250 kOhm WARNING; thresholds unvalidated
   against a Tesla specification (050).';
