-- ============================================================
-- 032_service_and_heatpump_fixes.sql
--
-- Three fixes from the 2026-09-09 review.
--
--   1. Service intervals did not match the schedule they cite. Tesla
--      specifies tire rotation every 6,250 miles (10,000 km) and a
--      brake-fluid health check every 4 years; 025 used 10,000 miles
--      and 24 months. The 6-year A/C desiccant interval is specified
--      for 2017-2023 Model 3 without a heat pump, not for every model,
--      so it is scoped rather than applied to "all".
--
--      This still stores one global schedule per item. Model/year/region
--      variants and per-VIN owner overrides need a wider table and are
--      out of scope here.
--
--   2. service_interval_status contradicted itself when a vehicle had
--      no completion history: due_at said "today + interval" while
--      status said OVERDUE (it substituted a 99-year-old completion),
--      and the mileage side projected from the current odometer while
--      status compared against a baseline of zero — so every vehicle was
--      permanently overdue on tire rotation once past 10,000 miles.
--      Unknown history is now reported as HISTORY_UNKNOWN with no
--      invented due date. latest_done also took MAX(completed_at) and
--      MAX(odometer_mi) independently, which could combine the date of
--      one completion with the odometer of another; it now reads both
--      from the same row.
--
--   3. The heat-pump confidence gate counted days while its comment
--      justified hours. See the note in the view below.
--
-- Requires 025_pm_review_fixes.sql and 007_heat_pump_diagnostics.sql.
-- Safe to re-run.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Correct the shipped interval values.
--
-- 025 inserted with ON CONFLICT DO NOTHING, so these rows exist and
-- were never updated. Only the values 025 got wrong are touched, and
-- only where the row still holds 025's value — an operator who has
-- deliberately adjusted an interval keeps their setting.
-- ------------------------------------------------------------------
UPDATE service_intervals
   SET interval_miles = 6250,
       description    = 'Rotate tires every 6,250 mi / 10,000 km (or when tread depth differs by >= 2/32 inch)'
 WHERE item = 'tire_rotation'
   AND interval_miles = 10000;

UPDATE service_intervals
   SET interval_months = 48,
       description     = 'Brake fluid health check every 4 years; replace if contaminated'
 WHERE item = 'brake_fluid'
   AND interval_months = 24;

UPDATE service_intervals
   SET applies_to  = '3',
       description = 'Replace A/C desiccant bag (specified for 2017-2023 Model 3 without heat pump; verify against your model year)'
 WHERE item = 'ac_desiccant'
   AND applies_to = 'all';

-- ------------------------------------------------------------------
-- 2.  service_interval_status — stop inventing history.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW service_interval_status AS
WITH latest_done AS (
  -- DISTINCT ON so the date and the odometer come from the same
  -- completion. MAX() of each column independently could pair the date
  -- of the newest completion with the highest odometer ever recorded.
  SELECT DISTINCT ON (vin, item)
         vin, item, completed_at AS last_done_at, odometer_mi AS last_done_odo
  FROM service_completions
  ORDER BY vin, item, completed_at DESC, id DESC
),
current_odo AS (
  SELECT vin, MAX(num_value) AS odometer_mi
  FROM telemetry
  WHERE field = 'Odometer'
    AND ts > NOW() - INTERVAL '14 days'
  GROUP BY vin
)
SELECT
  v.vin,
  s.item,
  s.description,
  s.severity,
  s.interval_months,
  s.interval_miles,
  ld.last_done_at,
  ld.last_done_odo,
  co.odometer_mi  AS current_odometer_mi,
  -- Time-based due date. NULL when the item has never been recorded as
  -- done: there is no baseline to count the interval from, and
  -- projecting from today only contradicted the status column.
  CASE
    WHEN s.interval_months IS NOT NULL AND ld.last_done_at IS NOT NULL
      THEN ld.last_done_at + (s.interval_months || ' months')::INTERVAL
  END AS due_at,
  -- Mileage-based due odometer, on the same rule.
  CASE
    WHEN s.interval_miles IS NOT NULL AND ld.last_done_odo IS NOT NULL
      THEN ld.last_done_odo + s.interval_miles
  END AS due_odometer_mi,
  -- Status: HISTORY_UNKNOWN / OVERDUE / DUE_SOON / OK
  CASE
    -- Nothing to measure against. Record a completion (or a
    -- commissioning baseline) to start tracking this item.
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
FROM (SELECT DISTINCT vin FROM telemetry) v
CROSS JOIN service_intervals s
LEFT JOIN latest_done ld ON ld.vin = v.vin AND ld.item = s.item
LEFT JOIN current_odo co ON co.vin = v.vin
WHERE s.applies_to = 'all'
   OR s.applies_to LIKE '%' || (SELECT model FROM vehicle_metadata WHERE vin = v.vin) || '%';

-- ------------------------------------------------------------------
-- 3.  heat_pump_diagnostics — gate on qualifying hours, not day count.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW heat_pump_diagnostics AS
WITH daily AS (
  SELECT
    bucket,
    vin,
    avg_power_per_degree,
    avg_temp_delta,
    valid_hours
  FROM heat_pump_cop_1d
  WHERE avg_power_per_degree IS NOT NULL
    AND valid_hours >= 1
),
rolling AS (
  SELECT
    bucket,
    vin,
    avg_power_per_degree,
    avg_temp_delta,
    valid_hours,
    -- 7-day rolling average of PPD
    AVG(avg_power_per_degree) OVER (
      PARTITION BY vin
      ORDER BY bucket
      RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW
    ) AS ppd_7d,
    -- 30-day rolling average of PPD
    AVG(avg_power_per_degree) OVER (
      PARTITION BY vin
      ORDER BY bucket
      RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW
    ) AS ppd_30d,
    -- 7-day rolling average of delta
    AVG(avg_temp_delta) OVER (
      PARTITION BY vin
      ORDER BY bucket
      RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW
    ) AS delta_7d,
    -- 30-day rolling average of delta
    AVG(avg_temp_delta) OVER (
      PARTITION BY vin
      ORDER BY bucket
      RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW
    ) AS delta_30d,
    -- Observation counts for confidence
    COUNT(*) OVER (
      PARTITION BY vin
      ORDER BY bucket
      RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW
    ) AS n_7d,
    COUNT(*) OVER (
      PARTITION BY vin
      ORDER BY bucket
      RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW
    ) AS n_30d,
    -- Qualifying exposure, in hours, over each window. n_7d/n_30d count
    -- daily rows; these count the hours those days actually contributed.
    SUM(valid_hours) OVER (
      PARTITION BY vin
      ORDER BY bucket
      RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW
    ) AS valid_hours_7d,
    SUM(valid_hours) OVER (
      PARTITION BY vin
      ORDER BY bucket
      RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW
    ) AS valid_hours_30d
  FROM daily
)
SELECT
  r.bucket AS ts,
  r.vin,
  ROUND(r.avg_power_per_degree::numeric, 2) AS power_per_degree,
  ROUND(r.avg_temp_delta::numeric, 2) AS temp_delta,
  r.valid_hours,
  ROUND(r.ppd_7d::numeric, 2)  AS ppd_7d_avg,
  ROUND(r.ppd_30d::numeric, 2) AS ppd_30d_avg,
  ROUND(r.delta_7d::numeric, 2)  AS delta_7d_avg,
  ROUND(r.delta_30d::numeric, 2) AS delta_30d_avg,
  r.n_7d,
  r.n_30d,
  vm.model,
  vm.has_heat_pump,
  -- Degradation flag: 7-day avg > 15 % above 30-day avg while temperature
  -- load hasn't shifted by > 3 °C.
  --
  -- The confidence gate now counts qualifying HOURS, which is what its
  -- justification always described. 025 set n_7d >= 8 and n_30d >= 24, but
  -- n_7d counts daily rows and an inclusive 7-day window holds at most
  -- eight of them — so the gate demanded a perfect run of days and a
  -- single missing day disabled detection entirely. valid_hours_7d >= 8
  -- is the intended "about a week of HVAC use"; the day counts stay as a
  -- coverage floor so the hours cannot all come from one day.
  --
  -- Known limitation (unchanged here): heat_pump_cop_1d.valid_hours counts
  -- a looser population than avg_power_per_degree — it omits the gear and
  -- not-charging filters. Tightening it means recreating the matview, which
  -- cascades through heat_pump_diagnostics into the 014 views.
  CASE
    WHEN COALESCE(vm.has_heat_pump, FALSE) IS NOT TRUE THEN 'NOT_APPLICABLE'
    WHEN r.valid_hours_7d  >= 8
     AND r.valid_hours_30d >= 24
     AND r.n_7d  >= 3
     AND r.n_30d >= 10
     AND r.ppd_7d  > 0
     AND r.ppd_30d > 0
     AND r.ppd_7d > r.ppd_30d * 1.15
     AND ABS(r.delta_7d - r.delta_30d) <= 3
    THEN 'HEAT_PUMP_DEGRADATION_LIKELY'
    ELSE 'NORMAL'
  END AS status,
  -- Trend magnitude (% increase of 7d over 30d)
  CASE
    WHEN COALESCE(vm.has_heat_pump, FALSE) IS NOT TRUE THEN 0
    WHEN r.ppd_30d > 0
    THEN ROUND(((r.ppd_7d - r.ppd_30d) / r.ppd_30d * 100)::numeric, 1)
    ELSE 0
  END AS trend_pct
FROM rolling r
LEFT JOIN vehicle_metadata vm ON vm.vin = r.vin;
