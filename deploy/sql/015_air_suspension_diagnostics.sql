-- ============================================================
-- Air-Suspension Compressor Health Diagnostics Layer
--
-- Feature gating per docs/FEATURE_MATRIX.md: has_air_suspension = true.
--
-- Context: Tesla vehicles with adaptive air suspension (Model S,
--   Model X, Cybertruck, and Model Y Juniper / Performance with
--   optional air suspension) rely on an onboard compressor to
--   maintain ride height.  Compressor over-cycling is the earliest
--   indicator of:
--     • Air-leak in a spring, line, or valve block
--     • Failing compressor dryer (moisture ingress)
--     • Worn piston seal (reduced output per cycle)
--     • Ride-height sensor drift causing false corrections
--
-- Why mirror the 12V diagnostics pattern:
--   The 12V layer counts DCDCEnable activations during sleep to
--   detect battery degradation.  Air-suspension compressor health
--   is structurally identical: we count compressor ON events during
--   parked periods when the car should be holding height passively.
--   A healthy system cycles only after door openings, load changes,
--   or temperature-driven pressure shifts.  Persistent cycling while
--   parked indicates the compressor is working harder than designed.
--
-- Schema limitation:
--   Fleet Telemetry does not expose native air-suspension fields in
--   the production protobuf.  This layer assumes the following fields
--   are present (injected by the simulator or future firmware):
--     • AirSuspensionHeightFL/FR/RL/RR  — ride height per corner (mm)
--     • AirSuspensionCompressorState    — 'On' / 'Off'
--     • AirSuspensionMode               — 'Standard' / 'Comfort' /
--                                         'Sport' / 'OffRoad' / 'Entry'
--   When these fields are absent the CAGGs produce empty buckets and
--   the diagnostics view returns no rows — zero impact on vehicles
--   without air suspension.
--
-- Architecture:
--   1. air_suspension_samples_1h  — hourly pivot of ride height,
--      compressor state, suspension mode, and vehicle state.
--   2. air_suspension_health_1d   — daily CAGG counting parked hours,
--      compressor events, always-on hours, and ride-height drift.
--   3. air_suspension_diagnostics — main view with 7-day / 30-day
--      rolling averages and degradation flags.
--   4. air_suspension_summary     — Grafana-friendly latest snapshot.
--
-- Model-aware gating:
--   All views LEFT JOIN vehicle_metadata and filter to
--   has_air_suspension = TRUE.  Non-air-suspension vehicles
--   (Model 3 RWD, etc.) are excluded at the CAGG level by
--   missing telemetry fields, and at the view level by the
--   metadata gate.  Both paths are safe and non-breaking.
--
-- Alert logic:
--   AIR_SUSPENSION_COMPRESSOR_OVERWORK_LIKELY when:
--     • 7-day avg compressor events/day  > 2 × 30-day avg
--     • OR duty cycle (always-on hours / parked hours) > 15 %
--     • AND sufficient observations (≥ 3 days in 7d, ≥ 10 in 30d)
--
--   AIR_LEAK_SUSPECTED when:
--     • 7-day avg ride-height drift  > 2 × 30-day avg
--     • AND drift exceeds 5 mm during parked Standard-mode hours
--     • AND sufficient observations
--
-- Requires superuser (postgres) to run — creates CAGGs.
-- Run after 001_schema.sql, 002_views.sql, and 005_vehicle_metadata.sql.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Hourly pivot CAGG — ride height, compressor state, mode,
--     plus vehicle state for parked filtering.
--
-- We aggregate at 1-hour buckets so that the four corner heights
-- and the compressor state are aligned in time.  AVG() smooths
-- jitter from individual samples; LAST() captures the final
-- reading of the hour (closest to equilibrium).
--
-- Compressor event detection:
--   • compressor_on_samples  — count of 'On' states in the hour
--   • compressor_off_samples — count of 'Off' states in the hour
--   • When both > 0 the compressor cycled during that hour.
--   • When only on > 0 the compressor ran continuously.
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS air_suspension_samples_1h CASCADE;

CREATE MATERIALIZED VIEW air_suspension_samples_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin,
  -- Ride height per corner (mm above ground)
  AVG(CASE WHEN field = 'AirSuspensionHeightFL' THEN num_value END) AS height_fl_avg,
  LAST(num_value, ts) FILTER (WHERE field = 'AirSuspensionHeightFL') AS height_fl_last,
  AVG(CASE WHEN field = 'AirSuspensionHeightFR' THEN num_value END) AS height_fr_avg,
  LAST(num_value, ts) FILTER (WHERE field = 'AirSuspensionHeightFR') AS height_fr_last,
  AVG(CASE WHEN field = 'AirSuspensionHeightRL' THEN num_value END) AS height_rl_avg,
  LAST(num_value, ts) FILTER (WHERE field = 'AirSuspensionHeightRL') AS height_rl_last,
  AVG(CASE WHEN field = 'AirSuspensionHeightRR' THEN num_value END) AS height_rr_avg,
  LAST(num_value, ts) FILTER (WHERE field = 'AirSuspensionHeightRR') AS height_rr_last,
  -- Average ride height (all four corners)
  AVG(CASE WHEN field IN ('AirSuspensionHeightFL','AirSuspensionHeightFR',
                          'AirSuspensionHeightRL','AirSuspensionHeightRR')
       THEN num_value END) AS height_avg,
  -- Compressor state counts
  COUNT(*) FILTER (WHERE field = 'AirSuspensionCompressorState'
                     AND str_value = 'On')  AS compressor_on_samples,
  COUNT(*) FILTER (WHERE field = 'AirSuspensionCompressorState'
                     AND str_value = 'Off') AS compressor_off_samples,
  COUNT(*) FILTER (WHERE field = 'AirSuspensionCompressorState') AS compressor_total_samples,
  -- Suspension mode (last mode of the hour)
  LAST(str_value, ts) FILTER (WHERE field = 'AirSuspensionMode') AS mode_last,
  -- Vehicle state (for filtering to parked)
  MAX(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS vehicle_speed_max,
  MAX(CASE WHEN field = 'Gear'         THEN str_value END) AS gear,
  -- Charging state (for filtering to not-charging)
  MAX(CASE WHEN field = 'ACChargingPower' THEN num_value END) AS ac_charge_power_max,
  MAX(CASE WHEN field = 'DCChargingPower' THEN num_value END) AS dc_charge_power_max
FROM telemetry
WHERE field IN (
  'AirSuspensionHeightFL', 'AirSuspensionHeightFR',
  'AirSuspensionHeightRL', 'AirSuspensionHeightRR',
  'AirSuspensionCompressorState', 'AirSuspensionMode',
  'VehicleSpeed', 'Gear',
  'ACChargingPower', 'DCChargingPower'
)
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 2.  Daily air-suspension health CAGG (built on hourly pivot)
--
-- A "parked hour" requires:
--   • vehicle_speed_max ≤ 0  (car did not move during the hour)
--   • gear in Park / invalid / NULL
--   • ac_charge_power_max ≤ 0  AND  dc_charge_power_max ≤ 0
--   • at least one compressor sample present
--
-- We classify parked hours into three compressor behaviours:
--   • clean parked   — compressor off (or no compressor data)
--   • cycling parked — compressor cycled On→Off (or Off→On)
--   • always-on parked — compressor stayed On the whole hour
--
-- Ride-height drift is computed as max - min across the four
-- corners during Standard-mode parked hours.
-- ------------------------------------------------------------------
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
DROP MATERIALIZED VIEW IF EXISTS air_suspension_health_1d CASCADE;

CREATE MATERIALIZED VIEW air_suspension_health_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  -- Parked hours with air-suspension data
  COUNT(*) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND compressor_total_samples > 0
  ) AS parked_hours,
  -- Hours where compressor cycled (both On and Off observed)
  COUNT(*) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND compressor_on_samples > 0
    AND compressor_off_samples > 0
  ) AS compressor_cycling_hours,
  -- Hours where compressor was always On (no Off samples)
  COUNT(*) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND compressor_on_samples > 0
    AND compressor_off_samples = 0
  ) AS compressor_always_on_hours,
  -- Total compressor ON samples during parked hours
  SUM(compressor_on_samples) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
  ) AS compressor_on_samples_parked,
  -- Average ride height during Standard-mode parked hours
  AVG(height_avg) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND mode_last IN ('Standard', 'Comfort')
  ) AS height_avg_standard,
  -- Max ride-height drift (max corner - min corner) during Standard
  -- parked hours.  A large drift means one corner is sagging.
  MAX(
    GREATEST(
      COALESCE(height_fl_last, 0),
      COALESCE(height_fr_last, 0),
      COALESCE(height_rl_last, 0),
      COALESCE(height_rr_last, 0)
    ) - LEAST(
      COALESCE(height_fl_last, 0),
      COALESCE(height_fr_last, 0),
      COALESCE(height_rl_last, 0),
      COALESCE(height_rr_last, 0)
    )
  ) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND mode_last IN ('Standard', 'Comfort')
  ) AS height_drift_max_mm
FROM air_suspension_samples_1h
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 3.  Refresh policies
-- ------------------------------------------------------------------
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('air_suspension_samples_1h');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('air_suspension_samples_1h',
  start_offset  => INTERVAL '7 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- air_suspension_health_1d is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('air_suspension_health_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ------------------------------------------------------------------
-- 4.  air_suspension_diagnostics  — rolling trends & degradation flags
--
-- Computes 7-day and 30-day rolling averages of:
--   • compressor cycling frequency (events per day)
--   • duty cycle (always-on hours / parked hours)
--   • ride-height drift (max corner delta in mm)
--
-- Two independent degradation paths:
--   A. Compressor over-work — short-term frequency or duty cycle
--      more than doubles the long-term baseline.
--   B. Air leak suspected — short-term ride-height drift more than
--      doubles baseline while parked in Standard mode.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW air_suspension_diagnostics AS
WITH daily AS (
  SELECT
    bucket,
    vin,
    parked_hours,
    compressor_cycling_hours,
    compressor_always_on_hours,
    compressor_on_samples_parked,
    height_avg_standard,
    height_drift_max_mm,
    -- Event frequency: cycling hours per parked hour
    CASE WHEN parked_hours > 0
      THEN compressor_cycling_hours::numeric / parked_hours
      ELSE 0
    END AS event_rate,
    -- Duty cycle: always-on hours per parked hour
    CASE WHEN parked_hours > 0
      THEN compressor_always_on_hours::numeric / parked_hours
      ELSE 0
    END AS duty_cycle
  FROM air_suspension_health_1d
  WHERE parked_hours >= 1
),
rolling AS (
  SELECT
    bucket,
    vin,
    parked_hours,
    compressor_cycling_hours,
    compressor_always_on_hours,
    compressor_on_samples_parked,
    height_avg_standard,
    height_drift_max_mm,
    event_rate,
    duty_cycle,
    -- 7-day rolling averages
    AVG(compressor_cycling_hours) OVER w7 AS cycling_7d,
    AVG(duty_cycle) OVER w7 AS duty_cycle_7d,
    AVG(height_drift_max_mm) OVER w7 AS drift_7d,
    -- 30-day rolling averages
    AVG(compressor_cycling_hours) OVER w30 AS cycling_30d,
    AVG(duty_cycle) OVER w30 AS duty_cycle_30d,
    AVG(height_drift_max_mm) OVER w30 AS drift_30d,
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
  parked_hours,
  compressor_cycling_hours,
  compressor_always_on_hours,
  ROUND(height_avg_standard::numeric, 1) AS height_avg_standard_mm,
  ROUND(height_drift_max_mm::numeric, 2) AS height_drift_max_mm,
  ROUND(event_rate::numeric, 3) AS event_rate,
  ROUND(duty_cycle::numeric, 3) AS duty_cycle,
  ROUND(cycling_7d::numeric, 2) AS cycling_7d_avg,
  ROUND(cycling_30d::numeric, 2) AS cycling_30d_avg,
  ROUND(duty_cycle_7d::numeric, 3) AS duty_cycle_7d_avg,
  ROUND(duty_cycle_30d::numeric, 3) AS duty_cycle_30d_avg,
  ROUND(drift_7d::numeric, 2) AS drift_7d_avg,
  ROUND(drift_30d::numeric, 2) AS drift_30d_avg,
  n_7d,
  n_30d,
  -- Degradation flags
  CASE
    WHEN n_7d >= 3 AND n_30d >= 10
     AND cycling_30d > 0
     AND cycling_7d > cycling_30d * 2.0
    THEN 'AIR_SUSPENSION_COMPRESSOR_OVERWORK_LIKELY'
    WHEN n_7d >= 3 AND n_30d >= 10
     AND duty_cycle_30d > 0
     AND duty_cycle_7d > GREATEST(duty_cycle_30d * 2.0, 0.15)
    THEN 'AIR_SUSPENSION_COMPRESSOR_OVERWORK_LIKELY'
    WHEN n_7d >= 3 AND n_30d >= 10
     AND drift_30d > 0
     AND drift_7d > drift_30d * 2.0
     AND drift_7d > 5.0
    THEN 'AIR_LEAK_SUSPECTED'
    ELSE 'NORMAL'
  END AS status,
  -- Trend magnitude (% increase of 7d over 30d)
  CASE
    WHEN cycling_30d > 0
    THEN ROUND(((cycling_7d - cycling_30d) / cycling_30d * 100)::numeric, 1)
    ELSE NULL
  END AS cycling_trend_pct,
  CASE
    WHEN drift_30d > 0
    THEN ROUND(((drift_7d - drift_30d) / drift_30d * 100)::numeric, 1)
    ELSE NULL
  END AS drift_trend_pct
FROM rolling;

-- ------------------------------------------------------------------
-- 5.  air_suspension_summary  — Grafana-friendly latest snapshot
--
-- Only returns rows for vehicles with has_air_suspension = TRUE.
-- Non-air-suspension vehicles naturally return no rows because
-- the daily CAGG has no data for them.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW air_suspension_summary AS
WITH latest AS (
  SELECT vin, MAX(ts) AS last_ts
  FROM air_suspension_diagnostics
  GROUP BY vin
)
SELECT
  l.vin,
  l.last_ts,
  d.status,
  d.parked_hours,
  d.compressor_cycling_hours AS compressor_events_24h,
  d.cycling_7d_avg AS baseline_events_24h,
  d.duty_cycle_7d_avg AS duty_cycle_avg,
  d.height_drift_max_mm AS ride_height_drift_mm,
  d.cycling_trend_pct,
  d.drift_trend_pct,
  vm.model,
  vm.has_air_suspension
FROM latest l
JOIN air_suspension_diagnostics d
  ON d.vin = l.vin AND d.ts = l.last_ts
LEFT JOIN vehicle_metadata vm ON vm.vin = l.vin
WHERE COALESCE(vm.has_air_suspension, FALSE) = TRUE;

-- ------------------------------------------------------------------
-- 6.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Compressor Health"  (Stat + colour threshold)
-- --------------------------------------------------------
-- Green  = NORMAL
-- Yellow = AIR_SUSPENSION_COMPRESSOR_OVERWORK_LIKELY
-- Red    = AIR_LEAK_SUSPECTED
--
-- SELECT
--   status,
--   compressor_events_24h,
--   baseline_events_24h,
--   duty_cycle_avg,
--   ride_height_drift_mm,
--   cycling_trend_pct
-- FROM air_suspension_summary
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Compressor Events vs Baseline"  (Time series)
-- --------------------------------------------------------
-- Shows daily cycling hours with 7-day & 30-day baselines.
-- Add an Alert rule on the "status" column.
--
-- SELECT
--   ts AS time,
--   compressor_cycling_hours AS "Daily events",
--   cycling_7d_avg AS "7-day avg",
--   cycling_30d_avg AS "30-day avg"
-- FROM air_suspension_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Duty Cycle Trend"  (Time series)
-- --------------------------------------------------------
-- Fraction of parked hours where compressor stayed On.
-- Threshold line at 0.15 (15 %).
--
-- SELECT
--   ts AS time,
--   duty_cycle AS "Daily duty cycle",
--   duty_cycle_7d_avg AS "7-day avg",
--   duty_cycle_30d_avg AS "30-day avg"
-- FROM air_suspension_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Ride Height Stability"  (Time series)
-- --------------------------------------------------------
-- Max corner-to-corner drift during Standard-mode parked hours.
-- Threshold line at 5 mm.
--
-- SELECT
--   ts AS time,
--   height_drift_max_mm AS "Max drift (mm)",
--   drift_7d_avg AS "7-day avg",
--   drift_30d_avg AS "30-day avg"
-- FROM air_suspension_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Ride Height by Corner"  (Time series)
-- --------------------------------------------------------
-- Individual corner heights from the hourly CAGG.
-- Only meaningful when per-corner fields are present.
--
-- SELECT
--   bucket AS time,
--   height_fl_avg AS "Front Left",
--   height_fr_avg AS "Front Right",
--   height_rl_avg AS "Rear Left",
--   height_rr_avg AS "Rear Right"
-- FROM air_suspension_samples_1h
-- WHERE vin = '$vin'
--   AND $__timeFilter(bucket)
-- ORDER BY bucket;

-- --------------------------------------------------------
-- Panel: "Air Suspension Fleet Overview"  (Table)
-- --------------------------------------------------------
-- Fleet-wide snapshot with model filter.
--
-- SELECT
--   vin,
--   model,
--   status,
--   compressor_events_24h,
--   duty_cycle_avg,
--   ride_height_drift_mm
-- FROM air_suspension_summary
-- WHERE has_air_suspension = TRUE
--   AND model = '$model'
-- ORDER BY
--   CASE status
--     WHEN 'AIR_LEAK_SUSPECTED' THEN 1
--     WHEN 'AIR_SUSPENSION_COMPRESSOR_OVERWORK_LIKELY' THEN 2
--     ELSE 3
--   END;

-- ------------------------------------------------------------------
-- 7.  How to test with the simulator
-- ------------------------------------------------------------------
-- The simulator generates air-suspension telemetry for vehicles
-- with has_air_suspension = true (Model S, X, Y, Cybertruck).
--
-- Step 1 — Start the simulator with a Model Y VIN
--   go run ./tools/simulator \
--     -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
--     -vins "7SAYGDEE9PF000001" \
--     -interval 30
--
--   The simulator auto-detects Model Y from VIN[3] = 'Y' and
--   generates AirSuspensionHeight*, AirSuspensionCompressorState,
--   and AirSuspensionMode samples.
--
-- Step 2 — Verify the vehicle metadata flag
--   SELECT vin, model, has_air_suspension FROM vehicle_metadata
--   WHERE vin = '7SAYGDEE9PF000001';
--
--   If has_air_suspension is false, set it manually for testing:
--   UPDATE vehicles SET has_air_suspension = TRUE
--   WHERE vin = '7SAYGDEE9PF000001';
--
-- Step 3 — Wait for CAGGs to materialise (≤ 1 hour)
--   SELECT bucket, parked_hours, compressor_cycling_hours,
--          height_drift_max_mm
--   FROM air_suspension_health_1d
--   WHERE vin = '7SAYGDEE9PF000001'
--   ORDER BY bucket DESC LIMIT 5;
--
-- Step 4 — Simulate compressor over-cycling
--   Insert synthetic compressor ON samples during parked hours:
--
--   INSERT INTO telemetry (ts, vin, field, str_value)
--   SELECT generate_series(
--     NOW(),
--     NOW() + INTERVAL '2 hours',
--     INTERVAL '1 minute'
--   ), '7SAYGDEE9PF000001', 'AirSuspensionCompressorState', 'On';
--
--   CALL refresh_continuous_aggregate('air_suspension_samples_1h',
--     NOW() - INTERVAL '1 day', NOW());
--   CALL refresh_continuous_aggregate('air_suspension_health_1d',
--     NOW() - INTERVAL '7 days', NOW());
--
--   SELECT ts, status, cycling_7d_avg, cycling_30d_avg, duty_cycle
--   FROM air_suspension_diagnostics
--   WHERE vin = '7SAYGDEE9PF000001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 5 — Simulate ride-height leak
--   Gradually lower one corner by 8 mm over 3 hours:
--
--   INSERT INTO telemetry (ts, vin, field, num_value)
--   SELECT generate_series(
--     NOW(),
--     NOW() + INTERVAL '3 hours',
--     INTERVAL '5 minutes'
--   ), '7SAYGDEE9PF000001', 'AirSuspensionHeightFL',
--   140 - (EXTRACT(EPOCH FROM (generate_series - NOW())) / 3600.0 * 8);
--
--   CALL refresh_continuous_aggregate('air_suspension_samples_1h',
--     NOW() - INTERVAL '1 day', NOW());
--   CALL refresh_continuous_aggregate('air_suspension_health_1d',
--     NOW() - INTERVAL '7 days', NOW());
--
--   SELECT ts, status, drift_7d_avg, drift_30d_avg, height_drift_max_mm
--   FROM air_suspension_diagnostics
--   WHERE vin = '7SAYGDEE9PF000001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 6 — Confirm non-air-suspension vehicles show nothing
--   SELECT * FROM air_suspension_summary
--   WHERE vin = '5YJ3E1EA8PF000001';  -- Model 3
--   -- Expected: no rows (or NULLs if LEFT JOINed)
--
-- Step 7 — Clean up
--   DELETE FROM telemetry
--   WHERE vin = '7SAYGDEE9PF000001'
--     AND field LIKE 'AirSuspension%'
--     AND ts > NOW() - INTERVAL '4 hours';
--
--   Or remove the whole test VIN and rebuild:
--   DELETE FROM telemetry WHERE vin = '7SAYGDEE9PF000001';
--   SELECT remove_continuous_aggregate_policy('air_suspension_samples_1h');
--   DROP MATERIALIZED VIEW air_suspension_samples_1h CASCADE;
--   -- then re-create from this file.
-- ------------------------------------------------------------------
