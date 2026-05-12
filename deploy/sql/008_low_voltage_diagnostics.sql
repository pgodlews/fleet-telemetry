-- ============================================================
-- 12V Battery / Low-Voltage System Diagnostics Layer
--
-- Context: Tesla fleet telemetry does not expose a dedicated
-- Features are gated per docs/FEATURE_MATRIX.md using vehicle_metadata.
-- 12V (auxiliary) battery voltage field.  The only available
-- proxy is DCDCEnable — a boolean indicating whether the PCS
-- DC-DC converter is active.  When the car is parked and not
-- charging, DCDCEnable should remain false; the vehicle sleeps.
-- A failing 12V battery causes the car to wake frequently to
-- recharge it via the DC-DC converter, producing DCDCEnable=true
-- events during sleep.
--
-- 30-second polling limitation:
--   Fleet telemetry samples at 30 s intervals.  A brief wake-up
--   (e.g., 60–180 s) may be captured as 2–6 consecutive true
--   samples.  We cannot resolve sub-30 s events.  We therefore
--   approximate "wake-up events" as sleep hours that contain
--   at least one DCDCEnable=true sample.  This is directionally
--   correct and stable enough for trend detection.
--
-- Why DCDCEnable instead of voltage sags:
--   12V voltage is not streamed.  Even if it were, detecting
--   a failing battery from voltage alone requires high-frequency
--   sampling (>1 Hz) to catch millisecond-level sag events during
--   cranking.  The 30 s telemetry cadence is far too coarse for
--   that.  DCDCEnable state changes are the only signal available
--   at this resolution that correlates with 12V battery health.
--
-- Architecture:
--   1. low_voltage_samples_1h  — hourly pivot of DCDCEnable +
--      vehicle state (speed, gear, charging power).
--   2. low_voltage_wakeups_1d  — daily CAGG counting sleep hours,
--      cycling hours (DCDCEnable cycled during sleep), and
--      always-on hours (DCDCEnable stayed true).
--   3. low_voltage_diagnostics — main view with 7-day / 30-day
--      rolling averages and degradation flag.
--
-- Alert logic:
--   LOW_VOLTAGE_BATTERY_DEGRADATION_LIKELY when:
--     • 7-day avg cycling hours/day  > 2 × 30-day avg
--     • OR 30-day baseline is 0 and 7-day avg ≥ 2 hours/day
--     • AND sufficient observations (≥ 3 days in 7d, ≥ 10 in 30d)
--
-- Requires superuser (postgres) to run — creates CAGGs.
-- Run after 001_schema.sql and 002_views.sql.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Hourly pivot CAGG — DCDCEnable + vehicle state
--
-- DCDCEnable is stored in str_value as 'true'/'false' (confirmed
-- by datastore/postgres/postgres.go boolStr()).  We count both
-- states per hour so we can distinguish:
--   • Cycling  (both true and false observed)  → wake-up events
--   • Always-on (only true observed)             → sentry / failure
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS low_voltage_samples_1h CASCADE;

CREATE MATERIALIZED VIEW low_voltage_samples_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin,
  -- DCDCEnable sample counts
  COUNT(*) FILTER (WHERE field = 'DCDCEnable' AND str_value = 'true')  AS dcdc_true_samples,
  COUNT(*) FILTER (WHERE field = 'DCDCEnable' AND str_value = 'false') AS dcdc_false_samples,
  COUNT(*) FILTER (WHERE field = 'DCDCEnable')                         AS dcdc_total_samples,
  -- Vehicle state (for filtering to parked / sleep)
  MAX(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS vehicle_speed_max,
  MAX(CASE WHEN field = 'Gear'         THEN str_value END) AS gear,
  -- Charging state (for filtering to not-charging)
  MAX(CASE WHEN field = 'ACChargingPower' THEN num_value END) AS ac_charge_power_max,
  MAX(CASE WHEN field = 'DCChargingPower' THEN num_value END) AS dc_charge_power_max
FROM telemetry
WHERE field IN ('DCDCEnable', 'VehicleSpeed', 'Gear', 'ACChargingPower', 'DCChargingPower')
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 2.  Daily wake-up count CAGG (built on the hourly pivot)
--
-- A "sleep hour" requires:
--   • vehicle_speed_max ≤ 0  (car did not move during the hour)
--   • gear in Park / invalid / NULL
--   • ac_charge_power_max ≤ 0  AND  dc_charge_power_max ≤ 0
--   • at least one DCDCEnable sample present
--
-- We distinguish three classes of sleep hour:
--   • clean sleep        — dcdc_false only (or no dcdc data)
--   • cycling sleep      — both true and false observed
--   • always-on sleep    — only true observed (never shut off)
-- ------------------------------------------------------------------
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
DROP MATERIALIZED VIEW IF EXISTS low_voltage_wakeups_1d CASCADE;

CREATE MATERIALIZED VIEW low_voltage_wakeups_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  -- Hours that qualify as "sleep"
  COUNT(*) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND dcdc_total_samples > 0
  ) AS sleep_hours,
  -- Sleep hours where DCDCEnable cycled (both true and false)
  -- This is our proxy for "wake-up events".
  COUNT(*) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND dcdc_true_samples > 0
    AND dcdc_false_samples > 0
  ) AS dcdc_cycling_sleep_hours,
  -- Sleep hours where DCDCEnable was always true (no false samples)
  -- Indicates Sentry Mode, camping, or severe 12V failure.
  COUNT(*) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND dcdc_true_samples > 0
    AND dcdc_false_samples = 0
  ) AS dcdc_always_on_sleep_hours,
  -- Total DCDCEnable=true samples during sleep (context only)
  SUM(dcdc_true_samples) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
  ) AS dcdc_true_samples_during_sleep
FROM low_voltage_samples_1h
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 3.  Refresh policies
-- ------------------------------------------------------------------
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('low_voltage_samples_1h');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('low_voltage_samples_1h',
  start_offset  => INTERVAL '7 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- low_voltage_wakeups_1d is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('low_voltage_wakeups_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ------------------------------------------------------------------
-- 4.  low_voltage_diagnostics  — rolling trends & degradation flag
--
-- Uses the daily CAGG to compute 7-day and 30-day rolling averages
-- of cycling sleep hours.  Flags degradation when the short-term
-- average more than doubles the long-term baseline.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW low_voltage_diagnostics AS
WITH daily AS (
  SELECT
    bucket,
    vin,
    sleep_hours,
    dcdc_cycling_sleep_hours,
    dcdc_always_on_sleep_hours,
    dcdc_true_samples_during_sleep,
    -- Wake-up rate: cycling hours per sleep hour (0.0 = perfect sleep)
    CASE WHEN sleep_hours > 0
      THEN dcdc_cycling_sleep_hours::numeric / sleep_hours
      ELSE 0
    END AS wakeup_rate
  FROM low_voltage_wakeups_1d
  WHERE sleep_hours >= 1
),
rolling AS (
  SELECT
    bucket,
    vin,
    sleep_hours,
    dcdc_cycling_sleep_hours,
    dcdc_always_on_sleep_hours,
    dcdc_true_samples_during_sleep,
    wakeup_rate,
    -- 7-day rolling averages
    AVG(dcdc_cycling_sleep_hours) OVER w7 AS cycling_7d,
    AVG(dcdc_true_samples_during_sleep) OVER w7 AS samples_7d,
    AVG(wakeup_rate) OVER w7 AS rate_7d,
    -- 30-day rolling averages
    AVG(dcdc_cycling_sleep_hours) OVER w30 AS cycling_30d,
    AVG(dcdc_true_samples_during_sleep) OVER w30 AS samples_30d,
    AVG(wakeup_rate) OVER w30 AS rate_30d,
    -- Observation counts for confidence
    COUNT(*) OVER w7 AS n_7d,
    COUNT(*) OVER w30 AS n_30d
  FROM daily
  WINDOW
    w7  AS (PARTITION BY vin ORDER BY bucket RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY vin ORDER BY bucket RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW)
)
SELECT
  bucket AS ts,
  vin,
  sleep_hours,
  dcdc_cycling_sleep_hours,
  dcdc_always_on_sleep_hours,
  dcdc_true_samples_during_sleep,
  ROUND(wakeup_rate::numeric, 3) AS wakeup_rate,
  ROUND(cycling_7d::numeric, 2) AS cycling_7d_avg,
  ROUND(cycling_30d::numeric, 2) AS cycling_30d_avg,
  ROUND(rate_7d::numeric, 3) AS rate_7d_avg,
  ROUND(rate_30d::numeric, 3) AS rate_30d_avg,
  n_7d,
  n_30d,
  -- Degradation flag: >2× baseline OR sudden onset from zero baseline
  CASE
    WHEN n_7d >= 3 AND n_30d >= 10
     AND cycling_30d > 0
     AND cycling_7d > cycling_30d * 2.0
    THEN 'LOW_VOLTAGE_BATTERY_DEGRADATION_LIKELY'
    WHEN n_7d >= 3 AND n_30d >= 10
     AND cycling_30d = 0
     AND cycling_7d >= 2
    THEN 'LOW_VOLTAGE_BATTERY_DEGRADATION_LIKELY'
    ELSE 'NORMAL'
  END AS status,
  -- Trend magnitude (% increase of 7d over 30d)
  CASE
    WHEN cycling_30d > 0
    THEN ROUND(((cycling_7d - cycling_30d) / cycling_30d * 100)::numeric, 1)
    ELSE NULL
  END AS trend_pct
FROM rolling;

-- ------------------------------------------------------------------
-- 5.  low_voltage_status  — Grafana-friendly latest snapshot
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW low_voltage_status AS
WITH latest AS (
  SELECT vin, MAX(ts) AS last_ts
  FROM low_voltage_diagnostics
  GROUP BY vin
)
SELECT
  l.vin,
  l.last_ts,
  d.status,
  d.cycling_7d_avg,
  d.cycling_30d_avg,
  d.rate_7d_avg,
  d.rate_30d_avg,
  d.trend_pct,
  d.sleep_hours,
  d.dcdc_cycling_sleep_hours,
  d.dcdc_always_on_sleep_hours,
  vm.model
FROM latest l
JOIN low_voltage_diagnostics d
  ON d.vin = l.vin AND d.ts = l.last_ts
LEFT JOIN vehicle_metadata vm ON vm.vin = l.vin;

-- ------------------------------------------------------------------
-- 6.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "12V Battery Status"  (Stat + colour threshold)
-- --------------------------------------------------------
-- Red   = LOW_VOLTAGE_BATTERY_DEGRADATION_LIKELY
-- Green = NORMAL
--
-- SELECT status, trend_pct, cycling_7d_avg, cycling_30d_avg
-- FROM low_voltage_status
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Sleep Wake-up Events"  (Time series)
-- --------------------------------------------------------
-- Shows daily cycling sleep hours with 7-day & 30-day baselines.
-- Add an Alert rule on the "status" column.
--
-- SELECT
--   ts AS time,
--   dcdc_cycling_sleep_hours AS "Cycling sleep hours",
--   cycling_7d_avg AS "7-day avg",
--   cycling_30d_avg AS "30-day avg"
-- FROM low_voltage_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Wake-up Rate"  (Time series)
-- --------------------------------------------------------
-- Fraction of sleep hours that contained a DCDCEnable cycle.
-- Threshold line at 0.5 (50 % of sleep hours).
--
-- SELECT
--   ts AS time,
--   wakeup_rate AS "Wake-ups / sleep hour",
--   rate_7d_avg AS "7-day avg",
--   rate_30d_avg AS "30-day avg"
-- FROM low_voltage_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Sleep Quality Breakdown"  (Stacked bar)
-- --------------------------------------------------------
-- Shows how sleep hours are distributed:
--   • Clean sleep (no DCDC activity)
--   • Cycling (wake-ups)
--   • Always-on (DC-DC never shut off)
--
-- SELECT
--   ts AS time,
--   GREATEST(sleep_hours - dcdc_cycling_sleep_hours - dcdc_always_on_sleep_hours, 0)
--     AS "Clean sleep hours",
--   dcdc_cycling_sleep_hours AS "Cycling hours",
--   dcdc_always_on_sleep_hours AS "Always-on hours"
-- FROM low_voltage_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- ------------------------------------------------------------------
-- 7.  How to test with the simulator
-- ------------------------------------------------------------------
-- The simulator writes DCDCEnable with a slow boolean toggle
-- (flips every ~10 minutes).  To test 12V degradation detection,
-- we inject synthetic DCDCEnable=true samples during sleep hours.
--
-- Step 1 — Start the simulator
--   go run ./tools/simulator \
--     -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
--     -vins "SIMULATEDVIN001" \
--     -interval 30
--
--   Let it run until there are several hours of parked data.
--
-- Step 2 — Verify sleep hours exist
--   SELECT bucket, sleep_hours, dcdc_cycling_sleep_hours
--   FROM low_voltage_wakeups_1d
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY bucket DESC LIMIT 5;
--
-- Step 3 — Inject synthetic wake-ups (DCDCEnable cycling during sleep)
--   -- Pick a recent sleep hour, e.g.:
--   INSERT INTO telemetry (ts, vin, field, str_value)
--   SELECT generate_series(
--     '2026-05-10 02:00:00'::timestamptz,
--     '2026-05-10 02:30:00'::timestamptz,
--     INTERVAL '4 minutes'
--   ), 'SIMULATEDVIN001', 'DCDCEnable', 'true';
--
--   INSERT INTO telemetry (ts, vin, field, str_value)
--   SELECT generate_series(
--     '2026-05-10 02:02:00'::timestamptz,
--     '2026-05-10 02:30:00'::timestamptz,
--     INTERVAL '4 minutes'
--   ), 'SIMULATEDVIN001', 'DCDCEnable', 'false';
--
--   -- Refresh CAGGs so the new data is materialised
--   CALL refresh_continuous_aggregate('low_voltage_samples_1h',
--     NOW() - INTERVAL '1 day', NOW());
--   CALL refresh_continuous_aggregate('low_voltage_wakeups_1d',
--     NOW() - INTERVAL '7 days', NOW());
--
-- Step 4 — Verify diagnostics
--   SELECT ts, sleep_hours, dcdc_cycling_sleep_hours, status, trend_pct
--   FROM low_voltage_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 5 — Clean up
--   DELETE FROM telemetry
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field = 'DCDCEnable'
--     AND ts > NOW() - INTERVAL '1 hour';
--
--   Or remove the whole test VIN and rebuild:
--   DELETE FROM telemetry WHERE vin = 'SIMULATEDVIN001';
--   SELECT remove_continuous_aggregate_policy('low_voltage_samples_1h');
--   DROP MATERIALIZED VIEW low_voltage_samples_1h CASCADE;
--   -- then re-create from this file.
-- ------------------------------------------------------------------
