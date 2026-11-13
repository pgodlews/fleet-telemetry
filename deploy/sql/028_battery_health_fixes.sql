-- ============================================================
-- 028_battery_health_fixes.sql
--
-- Six defects found while measuring battery degradation against
-- production data on the production vehicle (see the July 2026 battery
-- degradation review).  Everything here is a fix-up over
-- 009_battery_health.sql and 010_suspension_diagnostics.sql —
-- no existing view is dropped, and 014_predictive_health.sql /
-- 017_cybertruck_diagnostics.sql keep working unchanged because
-- every touched view only has expressions changed in place plus
-- new columns appended at the end.
--
-- Issues fixed here:
--
--   1 — MAX(severity) sorts alphabetically, so 'WARNING' beats
--       'CRITICAL'.  A real BMS fault could be masked by an
--       unrelated active warning.  Fixed with a new
--       severity_rank() helper used by both battery_health_summary
--       and suspension_summary.
--
--   2 — active_alert_count used COUNT(*), counting one row per
--       alert *sample* instead of per distinct alert.  Observed
--       802 on prod for 3 real active alerts.  Fixed to
--       COUNT(DISTINCT alert_code).
--
--   3 — ideal_range_degradation_pct / rated_range_degradation_pct
--       compared baseline and current range readings taken at
--       different SOC without normalising, so the "degradation"
--       was mostly just the SOC difference (9.42% observed vs.
--       ~1.2% true).  Fixed by normalising range to 100% SOC
--       (range / battery_level * 100) before differencing in
--       battery_health_diagnostics, with new audit columns
--       appended.  battery_health_summary gets the more robust
--       full-charge-sample version from fix #6.
--
--   4 — derived_capacity_kwh (EnergyRemaining / BatteryLevel * 100)
--       inflates badly at low SOC (66+ kWh at <20% SOC vs. ~51 kWh
--       near full charge), and the baseline was a single
--       unsmoothed first sample.  Both feed the alert thresholds.
--       Minimum fix applied here: an SOC floor on the derivation,
--       and a median-of-first-3 baseline, in both
--       battery_rest_capacity and battery_health_diagnostics.
--       (battery_health_summary gets the durable fix — #6.)
--
--   5 — Rest-block detection is structurally starved (the car only
--       streams while awake, so genuine long rests produce no rows
--       at all) — noted, not "fixable" here. While in the view,
--       we also close a latent gaps-and-islands bug: the streak
--       grouping trusted row-count over *present* hours, so a
--       block spanning a sleep gap could report >= 4 "consecutive"
--       hours that were not actually contiguous. Not observed to
--       have fired on current data (verified: all 7 existing rest
--       blocks have zero missing hours), but we guard it anyway by
--       requiring elapsed wall-clock time to match the counted
--       hours.
--
--   6 — New battery_full_charge / battery_full_charge_weekly views
--       sourced directly from near-100%-SOC telemetry samples
--       (bypasses the BMS SOC-scaling artifact in #4 entirely).
--       battery_health_summary's capacity_degradation_pct,
--       ideal_range_degradation_pct and rated_range_degradation_pct
--       are rewired to use median-of-first-3 vs. median-of-last-3
--       weekly peaks from this view. Verified against prod:
--       capacity 51.25 -> 50.96 kWh (0.57%), rated range
--       250.15 -> 247.22 mi (1.17%), over a 77-day window.
--
-- Explicitly NOT done here (see handoff / PR notes):
--   • Alert thresholds (0.10 in battery_health_summary, > 10 in
--     014_predictive_health.sql:137, 7/10/15 in
--     017_cybertruck_diagnostics.sql:744-765) are unchanged.
--     They were tuned against a noisy signal and may want
--     tightening now that capacity is trustworthy — that is
--     Piotr's call, not folded into this bugfix migration.
--   • No DROP ... CASCADE — 014 and 017 depend on the views
--     touched here and must keep working untouched.
--
-- Requires superuser (postgres) to run. Run after 001-027.
-- ============================================================

-- ------------------------------------------------------------------
-- 0.  severity_rank()  — shared helper for fix #1
--
-- Alert severities are CRITICAL / URGENT / WARNING / INFO (see
-- 012_alert_parser.sql). We rank them explicitly instead of relying
-- on lexical MAX(text), which puts WARNING above CRITICAL.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION severity_rank(sev text)
RETURNS int
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE sev
    WHEN 'CRITICAL' THEN 5
    WHEN 'URGENT'   THEN 4
    WHEN 'WARNING'  THEN 3
    WHEN 'INFO'     THEN 2
    ELSE 1
  END;
$$;

COMMENT ON FUNCTION severity_rank(text) IS
  'Explicit severity ordering for CRITICAL/URGENT/WARNING/INFO so
   MAX(severity_rank(sev)) picks the worst active alert. Do not use
   MAX(severity) directly — alphabetical order inverts CRITICAL and
   WARNING. Used by battery_health_summary and suspension_summary.';

CREATE OR REPLACE FUNCTION severity_label(rank int)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT (ARRAY['NONE','INFO','WARNING','URGENT','CRITICAL'])[GREATEST(rank, 1)];
$$;

-- ------------------------------------------------------------------
-- 4 + 5.  battery_rest_capacity — SOC floor, and gap-consistency
--         guard on the rest-block streak detector.
--
-- Fix #4a: derived_capacity_kwh is only trustworthy near full
-- charge (see header). We only compute it when the rest reading's
-- SOC is >= 80%; below that we still surface the raw range/energy
-- readings (needed for the SOC-normalised range calc elsewhere) but
-- null out derived_capacity_kwh rather than publish a number known
-- to be inflated.
--
-- Fix #5: block_hours previously just counted rows in the streak
-- group. A sleep gap (car fully off, no telemetry rows at all —
-- not even non-rest rows) can make two non-adjacent rest hours look
-- consecutive under the `bucket - row_number() * interval` trick,
-- since that trick only detects gaps among *present* rows. We now
-- require the elapsed wall-clock span of the block to equal
-- (block_hours - 1) hours; blocks where a gap has been papered over
-- are rejected. Verified against prod: all 7 existing rest blocks
-- pass this check unchanged (zero missing hours in each), so this
-- is a latent-bug guard, not a behavior change on current data.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW battery_rest_capacity AS
WITH rest_hours AS (
  SELECT
    bucket,
    vin,
    energy_remaining_last,
    battery_level_last,
    ideal_range_last,
    rated_range_last,
    pack_current_avg,
    pack_voltage_avg
  FROM battery_samples_1h
  WHERE (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND ABS(COALESCE(pack_current_avg, 0) * COALESCE(pack_voltage_avg, 0)) < 500
),
streaks AS (
  SELECT
    *,
    bucket
      - (ROW_NUMBER() OVER (PARTITION BY vin ORDER BY bucket)
         * INTERVAL '1 hour') AS streak_group
  FROM rest_hours
),
blocks AS (
  SELECT
    vin,
    streak_group,
    MIN(bucket) AS block_start,
    MAX(bucket) AS block_end,
    COUNT(*) AS block_hours,
    LAST(energy_remaining_last, bucket) AS energy_remaining,
    LAST(battery_level_last, bucket)     AS battery_level,
    LAST(ideal_range_last, bucket)       AS ideal_range,
    LAST(rated_range_last, bucket)       AS rated_range
  FROM streaks
  GROUP BY vin, streak_group
  HAVING COUNT(*) >= 4
     -- Fix #5: reject a "streak" whose elapsed span disagrees with
     -- its counted hours — that disagreement means a sleep gap was
     -- silently bridged by the gaps-and-islands trick.
     AND MAX(bucket) - MIN(bucket) = (COUNT(*) - 1) * INTERVAL '1 hour'
)
SELECT
  vin,
  block_end AS ts,
  block_start,
  block_end,
  block_hours,
  energy_remaining,
  battery_level,
  -- Fix #4a: SOC floor — below 80% SOC the EnergyRemaining/BatteryLevel
  -- ratio is known (measured on prod) to inflate by several kWh.
  CASE WHEN battery_level >= 80
    THEN ROUND((energy_remaining / battery_level * 100)::numeric, 2)
    ELSE NULL
  END AS derived_capacity_kwh,
  ideal_range,
  rated_range
FROM blocks;

-- ------------------------------------------------------------------
-- 3 + 4b.  battery_health_diagnostics — SOC-normalised range
--          degradation, SOC-floored capacity, median-of-3 baselines.
--
-- Fix #3: ideal_range_degradation_pct / rated_range_degradation_pct
-- compared a baseline and a current range reading taken at whatever
-- SOC each rest block happened to end at. Rated/ideal range is
-- proportional to SOC, so the "degradation" mostly measured the SOC
-- gap, not the pack. We now normalise both readings to 100% SOC
-- (range / battery_level * 100) before differencing, and append the
-- normalised values themselves so the calculation is auditable.
--
-- Fix #4b: derived_capacity_kwh gets the same >= 80% SOC floor as
-- battery_rest_capacity, and the baseline for capacity/ideal/rated
-- range is now the median of the first 3 qualifying readings
-- instead of a single unsmoothed ARRAY_AGG[1] sample.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW battery_health_diagnostics AS
WITH daily_raw AS (
  SELECT
    bucket,
    vin,
    rest_hours,
    energy_remaining_rest,
    battery_level_rest,
    -- Fix #4b: SOC floor on the derivation.
    CASE WHEN battery_level_rest >= 80
      THEN energy_remaining_rest / battery_level_rest * 100
      ELSE NULL
    END AS derived_capacity_kwh,
    ideal_range_rest,
    rated_range_rest,
    -- Fix #3: range normalised to 100% SOC for both baseline and
    -- current-value use downstream.
    CASE WHEN battery_level_rest > 0
      THEN ideal_range_rest / battery_level_rest * 100
      ELSE NULL
    END AS ideal_range_soc,
    CASE WHEN battery_level_rest > 0
      THEN rated_range_rest / battery_level_rest * 100
      ELSE NULL
    END AS rated_range_soc,
    brick_delta_max,
    brick_delta_avg
  FROM battery_capacity_1d
),
first_values AS (
  SELECT
    vin,
    MIN(bucket) FILTER (WHERE derived_capacity_kwh IS NOT NULL)
      AS first_capacity_bucket,
    -- Fix #4b: median of the first 3 qualifying readings, not [1].
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
     FROM UNNEST((ARRAY_AGG(derived_capacity_kwh ORDER BY bucket)
                    FILTER (WHERE derived_capacity_kwh IS NOT NULL))[1:3]) AS v)
      AS baseline_capacity_kwh,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
     FROM UNNEST((ARRAY_AGG(ideal_range_rest ORDER BY bucket)
                    FILTER (WHERE ideal_range_rest IS NOT NULL))[1:3]) AS v)
      AS baseline_ideal_range,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
     FROM UNNEST((ARRAY_AGG(rated_range_rest ORDER BY bucket)
                    FILTER (WHERE rated_range_rest IS NOT NULL))[1:3]) AS v)
      AS baseline_rated_range,
    -- Fix #3: SOC-normalised baselines (appended columns).
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
     FROM UNNEST((ARRAY_AGG(ideal_range_soc ORDER BY bucket)
                    FILTER (WHERE ideal_range_soc IS NOT NULL))[1:3]) AS v)
      AS baseline_ideal_range_soc,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
     FROM UNNEST((ARRAY_AGG(rated_range_soc ORDER BY bucket)
                    FILTER (WHERE rated_range_soc IS NOT NULL))[1:3]) AS v)
      AS baseline_rated_range_soc
  FROM daily_raw
  GROUP BY vin
),
rolling AS (
  SELECT
    d.*,
    f.baseline_capacity_kwh,
    f.baseline_ideal_range,
    f.baseline_rated_range,
    f.baseline_ideal_range_soc,
    f.baseline_rated_range_soc,
    -- Capacity degradation since baseline
    CASE WHEN f.baseline_capacity_kwh > 0
      THEN ROUND(((f.baseline_capacity_kwh - d.derived_capacity_kwh)
                  / f.baseline_capacity_kwh * 100)::numeric, 2)
      ELSE NULL
    END AS capacity_degradation_pct,
    -- Fix #3: range degradation since baseline, SOC-normalised.
    CASE WHEN f.baseline_ideal_range_soc > 0
      THEN ROUND(((f.baseline_ideal_range_soc - d.ideal_range_soc)
                  / f.baseline_ideal_range_soc * 100)::numeric, 2)
      ELSE NULL
    END AS ideal_range_degradation_pct,
    CASE WHEN f.baseline_rated_range_soc > 0
      THEN ROUND(((f.baseline_rated_range_soc - d.rated_range_soc)
                  / f.baseline_rated_range_soc * 100)::numeric, 2)
      ELSE NULL
    END AS rated_range_degradation_pct,
    -- 30-day rolling averages
    AVG(d.derived_capacity_kwh) OVER w30 AS capacity_30d_avg,
    AVG(d.brick_delta_max) OVER w30 AS brick_delta_30d_avg,
    -- 90-day rolling averages
    AVG(d.derived_capacity_kwh) OVER w90 AS capacity_90d_avg,
    AVG(d.brick_delta_max) OVER w90 AS brick_delta_90d_avg,
    -- Observation counts
    COUNT(*) OVER w30 AS n_30d,
    COUNT(*) OVER w90 AS n_90d
  FROM daily_raw d
  LEFT JOIN first_values f ON f.vin = d.vin
  WINDOW
    w30 AS (PARTITION BY d.vin ORDER BY d.bucket
            RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW),
    w90 AS (PARTITION BY d.vin ORDER BY d.bucket
            RANGE BETWEEN INTERVAL '90 days' PRECEDING AND CURRENT ROW)
)
SELECT
  bucket AS ts,
  vin,
  rest_hours,
  ROUND(derived_capacity_kwh::numeric, 2) AS derived_capacity_kwh,
  ROUND(battery_level_rest::numeric, 1) AS battery_level_rest,
  ROUND(ideal_range_rest::numeric, 1) AS ideal_range_rest,
  ROUND(rated_range_rest::numeric, 1) AS rated_range_rest,
  ROUND(brick_delta_max::numeric, 3) AS brick_delta_max,
  ROUND(brick_delta_avg::numeric, 3) AS brick_delta_avg,
  baseline_capacity_kwh,
  baseline_ideal_range,
  baseline_rated_range,
  capacity_degradation_pct,
  ideal_range_degradation_pct,
  rated_range_degradation_pct,
  ROUND(capacity_30d_avg::numeric, 2) AS capacity_30d_avg,
  ROUND(capacity_90d_avg::numeric, 2) AS capacity_90d_avg,
  ROUND(brick_delta_30d_avg::numeric, 3) AS brick_delta_30d_avg,
  ROUND(brick_delta_90d_avg::numeric, 3) AS brick_delta_90d_avg,
  n_30d,
  n_90d,
  -- Trend direction (comparing 30d vs 90d avg)
  CASE
    WHEN capacity_90d_avg > 0
    THEN ROUND(((capacity_30d_avg - capacity_90d_avg)
                / capacity_90d_avg * 100)::numeric, 2)
    ELSE NULL
  END AS capacity_trend_pct,
  -- Appended (fix #3): SOC-normalised range readings, for audit.
  ROUND(baseline_ideal_range_soc::numeric, 2) AS baseline_ideal_range_soc,
  ROUND(baseline_rated_range_soc::numeric, 2) AS baseline_rated_range_soc,
  ROUND(ideal_range_soc::numeric, 2) AS current_range_soc
FROM rolling;

-- ------------------------------------------------------------------
-- 6.  battery_full_charge / battery_full_charge_weekly
--
-- Durable capacity signal: sample EnergyRemaining/RatedRange/
-- IdealBatteryRange only when SOC >= 99%, bypassing the BMS
-- SOC-scaling artifact entirely (no division by a variable SOC).
--
-- Performance: EXPLAIN ANALYZE against prod (78 days, ~70k matching
-- telemetry rows) shows ~16.6ms execution / ~5.8ms planning — a
-- plain view is fine; promote to a matview on the
-- refresh_predictive_matviews() list (025_pm_review_fixes.sql:44)
-- if this ever regresses on a larger fleet.
--
-- battery_full_charge_weekly picks one coherent slice per
-- (vin, week) — the slice with the highest energy_kwh — via
-- DISTINCT ON, rather than independent MAX() per column. Taking
-- MAX(energy_kwh) and MAX(rated_range) separately (as the original
-- proposal did) can pair values from two different 15-minute
-- slices; this is the same defect flagged in
-- tools/battery_degradation.sh's weekly aggregation.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW battery_full_charge AS
WITH slices AS (
  SELECT vin,
         time_bucket('15 min', ts) AS bk,
         avg(num_value) FILTER (WHERE field = 'EnergyRemaining')   AS er,
         avg(num_value) FILTER (WHERE field = 'Soc')               AS soc,
         avg(num_value) FILTER (WHERE field = 'RatedRange')        AS rr,
         avg(num_value) FILTER (WHERE field = 'IdealBatteryRange') AS ir
  FROM telemetry
  WHERE field IN ('EnergyRemaining', 'Soc', 'RatedRange', 'IdealBatteryRange')
  GROUP BY 1, 2
)
SELECT vin, bk AS ts, er AS energy_kwh, soc, rr AS rated_range, ir AS ideal_range
FROM slices
WHERE er IS NOT NULL AND soc >= 99;

COMMENT ON VIEW battery_full_charge IS
  'Near-100% SOC telemetry slices (15-min buckets). This is the
   trustworthy capacity/range signal — no BMS SOC-scaling artifact,
   because SOC is pinned near 100 for every row. Source for
   battery_full_charge_weekly and battery_health_summary capacity
   fields (fix #6, migration 028).';

CREATE OR REPLACE VIEW battery_full_charge_weekly AS
WITH ranked AS (
  SELECT
    vin,
    date_trunc('week', ts)::date AS week,
    ts,
    energy_kwh,
    rated_range,
    ideal_range,
    COUNT(*) OVER (PARTITION BY vin, date_trunc('week', ts)::date) AS n,
    ROW_NUMBER() OVER (
      PARTITION BY vin, date_trunc('week', ts)::date
      ORDER BY energy_kwh DESC
    ) AS rn
  FROM battery_full_charge
)
SELECT vin, week, ts AS peak_ts, energy_kwh, rated_range, ideal_range, n
FROM ranked
WHERE rn = 1;

COMMENT ON VIEW battery_full_charge_weekly IS
  'One best-calibrated full-charge slice per (vin, week) — the
   highest-energy sample of the week, with its own rated/ideal
   range carried along so the row is a real observation, not an
   independently-maxed pair.';

-- ------------------------------------------------------------------
-- 2.  battery_alerts-derived active_alert_count fix is folded into
--     battery_health_summary below (there is no standalone
--     "battery_active_alerts" view to patch separately).
-- ------------------------------------------------------------------

-- ------------------------------------------------------------------
-- 1 + 2 + 6.  battery_health_summary — combined snapshot, rewired.
--
-- Fix #1: max_severity now uses severity_rank()/severity_label()
-- instead of MAX(text).
-- Fix #2: active_alert_count now counts DISTINCT alert_code.
-- Fix #6: capacity_degradation_pct, ideal_range_degradation_pct and
-- rated_range_degradation_pct are rewired to the median-of-first-3
-- vs. median-of-last-3 weekly full-charge peaks. current_capacity_kwh
-- / baseline_capacity_kwh / current_ideal_range / baseline_ideal_range
-- / current_rated_range / baseline_rated_range are repointed to the
-- same source so the raw values and the percentages stay consistent
-- with each other. last_rest_ts / last_rest_hours are kept from
-- battery_rest_capacity — rest blocks remain the right tool for
-- brick-imbalance / thermal-equilibrium context (brick_delta_* below),
-- just not for the headline capacity number any more.
--
-- window_days is appended so dashboards can flag when the
-- first-vs-last-3-week window is too short to trust an annualised
-- rate.
-- ------------------------------------------------------------------
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
  SELECT
    vin,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
     FROM UNNEST((ARRAY_AGG(energy_kwh ORDER BY week))[1:3]) v)
      AS baseline_capacity_kwh,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
     FROM UNNEST((ARRAY_AGG(energy_kwh ORDER BY week DESC))[1:3]) v)
      AS current_capacity_kwh,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
     FROM UNNEST((ARRAY_AGG(ideal_range ORDER BY week))[1:3]) v)
      AS baseline_ideal_range,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
     FROM UNNEST((ARRAY_AGG(ideal_range ORDER BY week DESC))[1:3]) v)
      AS current_ideal_range,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
     FROM UNNEST((ARRAY_AGG(rated_range ORDER BY week))[1:3]) v)
      AS baseline_rated_range,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v)
     FROM UNNEST((ARRAY_AGG(rated_range ORDER BY week DESC))[1:3]) v)
      AS current_rated_range,
    MIN(week) AS first_week,
    MAX(week) AS last_week,
    COUNT(*) AS n_weeks
  FROM battery_full_charge_weekly
  GROUP BY vin
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
  WHERE ts > NOW() - INTERVAL '30 days'
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
-- 1 + 2.  suspension_summary (010) — same severity + count fixes.
-- Structure otherwise unchanged from 010_suspension_diagnostics.sql.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW suspension_summary AS
WITH latest_diag AS (
  SELECT vin, MAX(ts) AS last_ts
  FROM suspension_diagnostics
  WHERE straight_highway_minutes >= 5
  GROUP BY vin
),
diag_snapshot AS (
  SELECT d.*
  FROM suspension_diagnostics d
  JOIN latest_diag l ON l.vin = d.vin AND l.last_ts = d.ts
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
  FROM suspension_alerts
  WHERE ts > NOW() - INTERVAL '30 days'
  GROUP BY vin
),
latest_trip AS (
  SELECT vin, MAX(started) AS last_started
  FROM suspension_trip_offsets
  WHERE straight_highway_minutes >= 5
  GROUP BY vin
),
trip_snapshot AS (
  SELECT t.*
  FROM suspension_trip_offsets t
  JOIN latest_trip l ON l.vin = t.vin AND l.last_started = t.started
)
SELECT
  d.vin,
  d.ts AS last_diag_ts,
  d.steering_offset_median AS last_offset_median,
  d.steering_offset_abs_median AS last_offset_abs_median,
  d.offset_abs_30d_avg,
  d.offset_abs_90d_avg,
  d.offset_trend_pct,
  d.lat_accel_stddev AS last_lat_accel_stddev,
  d.steering_status,
  t.started AS last_trip_started,
  t.steering_offset_median AS last_trip_offset,
  t.straight_highway_minutes AS last_trip_straight_minutes,
  COALESCE(a.active_alert_count, 0) AS active_alert_count,
  a.active_alert_codes,
  COALESCE(a.max_severity, 'NONE') AS max_alert_severity,
  CASE
    WHEN COALESCE(a.max_severity, 'NONE') = 'CRITICAL'
      THEN 'SUSPENSION_SERVICE_REQUIRED'
    WHEN COALESCE(a.max_severity, 'NONE') = 'URGENT'
      THEN 'SUSPENSION_SERVICE_RECOMMENDED'
    WHEN d.steering_status = 'SUSPENSION_ALIGNMENT_LIKELY'
      THEN 'SUSPENSION_ALIGNMENT_LIKELY'
    WHEN d.steering_status = 'SUSPENSION_LOOSENESS_LIKELY'
      THEN 'SUSPENSION_LOOSENESS_LIKELY'
    ELSE 'NORMAL'
  END AS overall_status,
  vm.model,
  vm.has_air_suspension
FROM diag_snapshot d
LEFT JOIN trip_snapshot t ON t.vin = d.vin
LEFT JOIN active_alerts a ON a.vin = d.vin
LEFT JOIN vehicle_metadata vm ON vm.vin = d.vin;

-- ------------------------------------------------------------------
-- Add battery_full_charge_1d to the demoted-matview refresh list?
-- No — battery_full_charge / battery_full_charge_weekly are plain
-- views (see EXPLAIN ANALYZE note above), so nothing to add to
-- refresh_predictive_matviews() (025_pm_review_fixes.sql:44) unless
-- this regresses on a larger fleet later.
-- ------------------------------------------------------------------
