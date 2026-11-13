-- ============================================================
-- 049_battery_estimator.sql — one battery estimator; honest windows
-- (S7, FINDINGS 10)
--
--   1. battery_health_summary (the headline) uses full-charge weekly
--      medians since 028, while predictive_health_score_1d scored the
--      rest-hour estimator. battery_full_charge_trend gives the
--      full-charge series per week (rolling 3-week median against the
--      baseline), and 050 scores that, so the score and the headline
--      are the same number.
--   2. Baseline = first k weekly peaks, current = last k, with
--      k = least(3, floor(n/2)): the two windows never overlap (below
--      six weeks the old slices shared weeks); under two weeks there is
--      no comparison.
--   3. battery_alerts covered BMS_*, DI_*, UI_a* and CP_* codes, so a
--      dashcam USB warning (UI_a111) was a "battery alert" and raised
--      the battery score. It now covers BMS_* only; drive-inverter,
--      user-interface and charge-port codes are scored once, in the
--      alert subsystem. Active battery alerts use alert_active_window()
--      like parsed_alerts.
--
-- Column lists unchanged (009/028 replace these views on FORCE=1).
-- Idempotent.
-- ============================================================

CREATE OR REPLACE VIEW battery_alerts AS
SELECT ts, vin, name AS alert_code, audience, started_at, ended_at,
  CASE
    WHEN name LIKE 'BMS_f%' THEN 'CRITICAL'
    WHEN name LIKE 'BMS_u%' THEN 'URGENT'
    WHEN name LIKE 'BMS_a%' THEN 'WARNING'
    ELSE 'INFO'
  END AS severity,
  CASE
    WHEN name LIKE 'BMS_f%' THEN 'BMS fault — immediate service required'
    WHEN name LIKE 'BMS_u%' THEN 'BMS issue — schedule service soon'
    WHEN name LIKE 'BMS_a%' THEN 'BMS alert — monitor battery health'
    ELSE 'Battery-related alert'
  END AS description
FROM vehicle_alerts
WHERE name LIKE 'BMS\_%';

CREATE OR REPLACE VIEW battery_health_summary AS
WITH latest_rest AS (
  SELECT vin, MAX(ts) AS last_ts
  FROM battery_rest_capacity
  GROUP BY vin
),
rest_snapshot AS (
  SELECT
    r.vin,
    r.ts AS last_rest_ts,
    r.block_hours AS last_rest_hours
  FROM battery_rest_capacity r
  JOIN latest_rest l ON l.vin = r.vin AND l.last_ts = r.ts
),
full_charge_agg AS (
  -- Baseline = median of the first k weekly peaks, current = median of
  -- the last k, with k = least(3, floor(n/2)) so the two windows never
  -- share a week (with fewer than six weeks the old [1:3] / last [1:3]
  -- slices overlapped and diluted the change). Fewer than two weeks:
  -- no comparison (NULL).
  SELECT
    vin,
    CASE WHEN k >= 1 THEN (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v) FROM UNNEST(e_asc[1:k]) v) END  AS baseline_capacity_kwh,
    CASE WHEN k >= 1 THEN (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v) FROM UNNEST(e_desc[1:k]) v) END AS current_capacity_kwh,
    CASE WHEN k >= 1 THEN (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v) FROM UNNEST(i_asc[1:k]) v) END  AS baseline_ideal_range,
    CASE WHEN k >= 1 THEN (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v) FROM UNNEST(i_desc[1:k]) v) END AS current_ideal_range,
    CASE WHEN k >= 1 THEN (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v) FROM UNNEST(r_asc[1:k]) v) END  AS baseline_rated_range,
    CASE WHEN k >= 1 THEN (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v) FROM UNNEST(r_desc[1:k]) v) END AS current_rated_range,
    first_week, last_week, n_weeks
  FROM (
    SELECT vin,
      ARRAY_AGG(energy_kwh  ORDER BY week)      AS e_asc,
      ARRAY_AGG(energy_kwh  ORDER BY week DESC) AS e_desc,
      ARRAY_AGG(ideal_range ORDER BY week)      AS i_asc,
      ARRAY_AGG(ideal_range ORDER BY week DESC) AS i_desc,
      ARRAY_AGG(rated_range ORDER BY week)      AS r_asc,
      ARRAY_AGG(rated_range ORDER BY week DESC) AS r_desc,
      MIN(week) AS first_week, MAX(week) AS last_week, COUNT(*) AS n_weeks,
      LEAST(3, COUNT(*) / 2)::int AS k
    FROM battery_full_charge_weekly
    GROUP BY vin
  ) w
),
latest_daily AS (
  SELECT vin, MAX(bucket) AS last_bucket
  FROM battery_capacity_1d
  WHERE rest_hours >= 1
  GROUP BY vin
),
daily_snapshot AS (
  SELECT
    d.vin,
    d.rest_hours AS last_day_rest_hours,
    d.brick_delta_max AS last_day_brick_delta_max,
    d.brick_delta_avg AS last_day_brick_delta_avg
  FROM battery_capacity_1d d
  JOIN latest_daily l ON l.vin = d.vin AND l.last_bucket = d.bucket
),
active_alerts AS (
  SELECT
    vin,
    -- Fix #2: distinct alert codes, not sample rows.
    COUNT(DISTINCT alert_code) FILTER (WHERE ended_at IS NULL) AS active_alert_count,
    STRING_AGG(DISTINCT alert_code, ', ' ORDER BY alert_code)
      FILTER (WHERE ended_at IS NULL) AS active_alert_codes,
    -- Fix #1: rank-based max severity, not MAX(text).
    severity_label(MAX(severity_rank(severity)) FILTER (WHERE ended_at IS NULL))
      AS max_severity
  FROM battery_alerts
  WHERE COALESCE(started_at, ts) > NOW() - alert_active_window()
  GROUP BY vin
),
-- Fix #5b: the row must not be gated on a rest block existing.
-- Capacity now comes from full charges (fix #6), but driving the
-- SELECT off rest_snapshot meant a vehicle with plenty of full-charge
-- history and no qualifying >= 4h rest block produced no row at all —
-- and rest blocks are exactly the starved signal fix #5 documents
-- (7 blocks in 78 days on prod, latest 4 weeks stale). Drive off the
-- union of every source instead, and let each LEFT JOIN contribute
-- what it has.
vins AS (
  SELECT vin FROM rest_snapshot
  UNION
  SELECT vin FROM full_charge_agg
  UNION
  SELECT vin FROM daily_snapshot
)
SELECT
  v.vin,
  r.last_rest_ts,
  r.last_rest_hours,
  -- Kept numeric(,2): the previous definition sourced these from
  -- battery_rest_capacity.derived_capacity_kwh, which was already
  -- ROUND(...)::numeric. PERCENTILE_CONT over the full-charge series
  -- returns double precision, and CREATE OR REPLACE VIEW cannot
  -- change a column's type.
  ROUND(fc.current_capacity_kwh::numeric, 2)  AS current_capacity_kwh,
  ROUND(fc.baseline_capacity_kwh::numeric, 2) AS baseline_capacity_kwh,
  CASE WHEN fc.baseline_capacity_kwh > 0
    THEN ROUND(((fc.baseline_capacity_kwh - fc.current_capacity_kwh)
                / fc.baseline_capacity_kwh * 100)::numeric, 2)
    ELSE NULL
  END AS capacity_degradation_pct,
  fc.current_ideal_range,
  fc.baseline_ideal_range,
  CASE WHEN fc.baseline_ideal_range > 0
    THEN ROUND(((fc.baseline_ideal_range - fc.current_ideal_range)
                / fc.baseline_ideal_range * 100)::numeric, 2)
    ELSE NULL
  END AS ideal_range_degradation_pct,
  fc.current_rated_range,
  fc.baseline_rated_range,
  CASE WHEN fc.baseline_rated_range > 0
    THEN ROUND(((fc.baseline_rated_range - fc.current_rated_range)
                / fc.baseline_rated_range * 100)::numeric, 2)
    ELSE NULL
  END AS rated_range_degradation_pct,
  d.last_day_rest_hours,
  d.last_day_brick_delta_max,
  d.last_day_brick_delta_avg,
  COALESCE(a.active_alert_count, 0) AS active_alert_count,
  a.active_alert_codes,
  COALESCE(a.max_severity, 'NONE') AS max_alert_severity,
  CASE
    WHEN COALESCE(a.max_severity, 'NONE') = 'CRITICAL'
      THEN 'BATTERY_SERVICE_REQUIRED'
    WHEN COALESCE(a.max_severity, 'NONE') = 'URGENT'
      THEN 'BATTERY_SERVICE_RECOMMENDED'
    WHEN fc.current_capacity_kwh IS NOT NULL
     AND fc.baseline_capacity_kwh > 0
     AND (fc.baseline_capacity_kwh - fc.current_capacity_kwh)
         / fc.baseline_capacity_kwh > 0.10
      THEN 'BATTERY_CAPACITY_DEGRADED'
    WHEN d.last_day_brick_delta_max > 0.5
      THEN 'BATTERY_IMBALANCE_DETECTED'
    ELSE 'NORMAL'
  END AS overall_status,
  vm.model,
  vm.battery_type,
  -- Appended (fix #6): window size backing the degradation %s above,
  -- so a dashboard can warn "too short to annualise" rather than
  -- silently showing a rate computed over e.g. 2 weeks.
  (fc.last_week - fc.first_week) AS window_days,
  fc.n_weeks AS full_charge_sample_weeks
FROM vins v
LEFT JOIN rest_snapshot r ON r.vin = v.vin
LEFT JOIN full_charge_agg fc ON fc.vin = v.vin
LEFT JOIN daily_snapshot d ON d.vin = v.vin
LEFT JOIN active_alerts a ON a.vin = v.vin
LEFT JOIN vehicle_metadata vm ON vm.vin = v.vin;

-- ------------------------------------------------------------------
-- Weekly full-charge series with the same baseline as the headline.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW battery_full_charge_trend AS
WITH w AS (
  SELECT vin, week, energy_kwh, n,
         ROW_NUMBER() OVER (PARTITION BY vin ORDER BY week) AS idx,
         COUNT(*)     OVER (PARTITION BY vin) AS n_weeks
  FROM battery_full_charge_weekly
), base AS (
  SELECT vin,
         PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY energy_kwh) AS baseline_kwh
  FROM w
  WHERE idx <= LEAST(3, n_weeks / 2)
  GROUP BY vin
)
SELECT w.vin, w.week::timestamptz AS ts, w.energy_kwh,
  (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY x.energy_kwh)
   FROM w x WHERE x.vin = w.vin AND x.idx BETWEEN w.idx - 2 AND w.idx) AS energy_kwh_3wk_median,
  b.baseline_kwh,
  CASE WHEN b.baseline_kwh > 0 AND w.idx > LEAST(3, w.n_weeks / 2) THEN
    ROUND(((b.baseline_kwh -
            (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY x.energy_kwh)
             FROM w x WHERE x.vin = w.vin AND x.idx BETWEEN w.idx - 2 AND w.idx))
           / b.baseline_kwh * 100)::numeric, 2)
  END AS capacity_degradation_pct
FROM w
LEFT JOIN base b ON b.vin = w.vin;

COMMENT ON VIEW battery_full_charge_trend IS
  'Weekly full-charge capacity per vehicle: the week''s best full-charge
   sample, its trailing 3-week median, and degradation against the median of
   the first least(3, n/2) weeks — the same estimator as the
   battery_health_summary headline (049). Scored by predictive_health_score_1d.';
