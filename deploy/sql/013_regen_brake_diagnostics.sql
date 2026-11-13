-- ============================================================
-- Regen & Brake System Health + Efficiency Anomaly Detection
--
-- Context: Tesla fleet telemetry streams cumulative lifetime
-- Features are gated per docs/FEATURE_MATRIX.md using vehicle_metadata.
-- energy counters (LifetimeEnergyGainedRegen,
-- LifetimeEnergyUsedDrive, LifetimeEnergyUsed) and odometer.
-- From these we derive:
--
--   1. Regen health        — regen energy per mile and peak
--      regen torque trends.  Progressive drop = derating or
--      mechanical degradation.
--   2. Brake wear estimate — linear model based on distance
--      driven adjusted by regen ratio.  High regen users see
--      significantly extended pad life.
--   3. Efficiency anomaly  — Wh/mi trend vs historical
--      baseline.  Sudden rise = tire pressure, alignment,
--      or drivetrain drag issues.
--
-- Architecture:
--   1. regen_brake_samples_1h  — hourly pivot of lifetime
--      counters, odometer, brake pedal, speed, torque.
--   2. regen_brake_daily_1d    — daily CAGG storing the LAST
--      cumulative value of each counter (needed for delta
--      computation in the view layer).
--   3. regen_brake_diagnostics — main view with daily deltas,
--      rolling baselines, and degradation flags.
--   4. brake_wear_estimate     — simple linear wear model
--      producing % remaining per VIN.
--
-- Simulator note:
--   LifetimeEnergyGainedRegen was added to fields.json and
--   the simulator Go code was updated to track cumulative
--   energy counters monotonically (see tools/simulator/main.go).
--   Re-build the simulator after deploying this file.
--
-- Unit compatibility:
--   • Odometer, Range, Speed  → raw miles
--   • Energy counters         → kWh
--   • Temperatures            → °C
--   Grafana panels use inline CASE WHEN for imperial/metric.
--
-- Requires superuser (postgres) to run — creates CAGGs.
-- Run after 001_schema.sql and 002_views.sql.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Hourly pivot CAGG — lifetime counters + brake + torque
--
-- We capture the MAX (i.e., the latest monotonic value) of
-- cumulative counters per hour, plus brake-pedal activity
-- and peak regen torque for that hour.
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS regen_brake_samples_1h CASCADE;

CREATE MATERIALIZED VIEW regen_brake_samples_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin,
  -- Cumulative counters (latest value in hour)
  LAST(num_value, ts) FILTER (WHERE field = 'LifetimeEnergyUsed')          AS lifetime_energy_used,
  LAST(num_value, ts) FILTER (WHERE field = 'LifetimeEnergyUsedDrive')     AS lifetime_energy_used_drive,
  LAST(num_value, ts) FILTER (WHERE field = 'LifetimeEnergyGainedRegen')   AS lifetime_energy_gained_regen,
  LAST(num_value, ts) FILTER (WHERE field = 'Odometer')                    AS odometer,
  -- Brake pedal activity (counts of brake application per hour)
  COUNT(*) FILTER (WHERE field = 'BrakePedal' AND str_value = 'true') AS brake_applications,
  MAX(CASE WHEN field = 'BrakePedalPos' THEN num_value END) AS brake_pedal_pos_max,
  -- Vehicle speed (for filtering highway hours)
  MAX(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS vehicle_speed_max,
  AVG(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS vehicle_speed_avg,
  -- Peak regen torque (most negative) across all axles
  LEAST(
    MIN(CASE WHEN field = 'DiTorqueActualF'  THEN num_value END),
    MIN(CASE WHEN field = 'DiTorqueActualR'  THEN num_value END),
    MIN(CASE WHEN field = 'DiTorqueActualREL' THEN num_value END),
    MIN(CASE WHEN field = 'DiTorqueActualRER' THEN num_value END)
  ) AS peak_regen_torque,
  -- Peak accel torque (most positive)
  GREATEST(
    MAX(CASE WHEN field = 'DiTorqueActualF'  THEN num_value END),
    MAX(CASE WHEN field = 'DiTorqueActualR'  THEN num_value END),
    MAX(CASE WHEN field = 'DiTorqueActualREL' THEN num_value END),
    MAX(CASE WHEN field = 'DiTorqueActualRER' THEN num_value END)
  ) AS peak_accel_torque,
  -- Battery level (for SOC context)
  LAST(num_value, ts) FILTER (WHERE field = 'BatteryLevel') AS battery_level
FROM telemetry
WHERE field IN (
  'LifetimeEnergyUsed', 'LifetimeEnergyUsedDrive',
  'LifetimeEnergyGainedRegen', 'Odometer',
  'BrakePedal', 'BrakePedalPos',
  'VehicleSpeed', 'BatteryLevel',
  'DiTorqueActualF', 'DiTorqueActualR',
  'DiTorqueActualREL', 'DiTorqueActualRER'
)
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 2.  Daily cumulative snapshot CAGG (needed for delta calc)
--
-- Stores the LAST value of each cumulative counter per day.
-- Deltas are computed in the diagnostic view using LAG().
-- ------------------------------------------------------------------
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
DROP MATERIALIZED VIEW IF EXISTS regen_brake_daily_1d CASCADE;

CREATE MATERIALIZED VIEW regen_brake_daily_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  LAST(lifetime_energy_used, bucket)        AS lifetime_energy_used,
  LAST(lifetime_energy_used_drive, bucket)  AS lifetime_energy_used_drive,
  LAST(lifetime_energy_gained_regen, bucket) AS lifetime_energy_gained_regen,
  LAST(odometer, bucket)                    AS odometer,
  SUM(brake_applications)                   AS brake_applications,
  MAX(brake_pedal_pos_max)                  AS brake_pedal_pos_max,
  MAX(vehicle_speed_max)                    AS vehicle_speed_max,
  AVG(vehicle_speed_avg)                    AS vehicle_speed_avg,
  MIN(peak_regen_torque)                    AS peak_regen_torque,
  MAX(peak_accel_torque)                    AS peak_accel_torque,
  LAST(battery_level, bucket)               AS battery_level,
  -- Highway hours filter
  COUNT(*) FILTER (WHERE vehicle_speed_max > 50) AS highway_hours
FROM regen_brake_samples_1h
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 3.  Refresh policies
-- ------------------------------------------------------------------
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('regen_brake_samples_1h');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('regen_brake_samples_1h',
  start_offset  => INTERVAL '7 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- regen_brake_daily_1d is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('regen_brake_daily_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ------------------------------------------------------------------
-- 4.  regen_brake_diagnostics  — deltas, rolling baselines, flags
--
-- Computes daily deltas from the cumulative counters, then
-- applies 7-day and 30-day rolling averages.  Flags regen
-- degradation and efficiency anomalies.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW regen_brake_diagnostics AS
WITH daily AS (
  SELECT
    bucket,
    vin,
    lifetime_energy_used,
    lifetime_energy_used_drive,
    lifetime_energy_gained_regen,
    odometer,
    brake_applications,
    brake_pedal_pos_max,
    vehicle_speed_max,
    vehicle_speed_avg,
    peak_regen_torque,
    peak_accel_torque,
    battery_level,
    highway_hours,
    -- Daily deltas (handle counter resets or NULL by using GREATEST)
    GREATEST(
      lifetime_energy_used
        - LAG(lifetime_energy_used) OVER (PARTITION BY vin ORDER BY bucket),
      0
    ) AS energy_used_delta,
    GREATEST(
      lifetime_energy_used_drive
        - LAG(lifetime_energy_used_drive) OVER (PARTITION BY vin ORDER BY bucket),
      0
    ) AS energy_drive_delta,
    GREATEST(
      lifetime_energy_gained_regen
        - LAG(lifetime_energy_gained_regen) OVER (PARTITION BY vin ORDER BY bucket),
      0
    ) AS energy_regen_delta,
    GREATEST(
      odometer
        - LAG(odometer) OVER (PARTITION BY vin ORDER BY bucket),
      0
    ) AS distance_delta
  FROM regen_brake_daily_1d
),
with_metrics AS (
  SELECT
    *,
    -- Efficiency (Wh/mi) — only when distance > 0
    CASE WHEN distance_delta > 0.1
      THEN ROUND((energy_drive_delta / distance_delta * 1000)::numeric, 1)
      ELSE NULL
    END AS efficiency_wh_mi,
    -- Regen energy per mile (Wh/mi recovered)
    CASE WHEN distance_delta > 0.1
      THEN ROUND((energy_regen_delta / distance_delta * 1000)::numeric, 1)
      ELSE NULL
    END AS regen_wh_mi,
    -- Regen ratio (regen / (regen + drive))
    CASE WHEN (energy_regen_delta + energy_drive_delta) > 0
      THEN ROUND((energy_regen_delta / (energy_regen_delta + energy_drive_delta) * 100)::numeric, 1)
      ELSE NULL
    END AS regen_ratio_pct,
    -- Brake events per 100 miles
    CASE WHEN distance_delta > 0.1
      THEN ROUND((brake_applications / distance_delta * 100)::numeric, 1)
      ELSE NULL
    END AS brake_events_per_100mi
  FROM daily
),
rolling AS (
  SELECT
    *,
    -- 7-day rolling averages
    AVG(efficiency_wh_mi) OVER w7  AS eff_7d,
    AVG(regen_wh_mi) OVER w7       AS regen_7d,
    AVG(regen_ratio_pct) OVER w7   AS regen_ratio_7d,
    AVG(ABS(peak_regen_torque)) OVER w7 AS regen_torque_mag_7d,
    -- 30-day rolling averages (baseline)
    AVG(efficiency_wh_mi) OVER w30 AS eff_30d,
    AVG(regen_wh_mi) OVER w30      AS regen_30d,
    AVG(regen_ratio_pct) OVER w30  AS regen_ratio_30d,
    AVG(ABS(peak_regen_torque)) OVER w30 AS regen_torque_mag_30d,
    -- Observation counts
    COUNT(*) FILTER (WHERE distance_delta > 0.1) OVER w7  AS n_drive_7d,
    COUNT(*) FILTER (WHERE distance_delta > 0.1) OVER w30 AS n_drive_30d
  FROM with_metrics
  WINDOW
    w7  AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY vin ORDER BY bucket
            RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW)
)
SELECT
  bucket AS ts,
  vin,
  highway_hours,
  ROUND(lifetime_energy_used::numeric, 2) AS lifetime_energy_used_kwh,
  ROUND(lifetime_energy_used_drive::numeric, 2) AS lifetime_energy_drive_kwh,
  ROUND(lifetime_energy_gained_regen::numeric, 2) AS lifetime_energy_regen_kwh,
  ROUND(odometer::numeric, 1) AS odometer_mi,
  ROUND(distance_delta::numeric, 1) AS distance_delta_mi,
  ROUND(energy_drive_delta::numeric, 3) AS energy_drive_delta_kwh,
  ROUND(energy_regen_delta::numeric, 3) AS energy_regen_delta_kwh,
  efficiency_wh_mi,
  regen_wh_mi,
  regen_ratio_pct,
  brake_applications,
  brake_events_per_100mi,
  ROUND(peak_regen_torque::numeric, 1) AS peak_regen_torque,
  ROUND(peak_accel_torque::numeric, 1) AS peak_accel_torque,
  ROUND(eff_7d::numeric, 1)  AS eff_7d_avg,
  ROUND(eff_30d::numeric, 1) AS eff_30d_avg,
  ROUND(regen_7d::numeric, 1)  AS regen_7d_avg,
  ROUND(regen_30d::numeric, 1) AS regen_30d_avg,
  ROUND(regen_ratio_7d::numeric, 1)  AS regen_ratio_7d_avg,
  ROUND(regen_ratio_30d::numeric, 1) AS regen_ratio_30d_avg,
  ROUND(regen_torque_mag_7d::numeric, 1)  AS regen_torque_7d_avg,
  ROUND(regen_torque_mag_30d::numeric, 1) AS regen_torque_30d_avg,
  n_drive_7d,
  n_drive_30d,
  -- Trend percentages
  CASE WHEN eff_30d > 0
    THEN ROUND(((eff_7d - eff_30d) / eff_30d * 100)::numeric, 1)
    ELSE NULL
  END AS eff_trend_pct,
  CASE WHEN regen_30d > 0
    THEN ROUND(((regen_7d - regen_30d) / regen_30d * 100)::numeric, 1)
    ELSE NULL
  END AS regen_trend_pct,
  CASE WHEN regen_torque_mag_30d > 0
    THEN ROUND(((regen_torque_mag_7d - regen_torque_mag_30d) / regen_torque_mag_30d * 100)::numeric, 1)
    ELSE NULL
  END AS regen_torque_trend_pct,
  -- Degradation / anomaly flags
  CASE
    WHEN n_drive_7d >= 3 AND n_drive_30d >= 10
     AND regen_torque_mag_30d > 0
     AND regen_torque_mag_7d < regen_torque_mag_30d * 0.90
    THEN 'REGEN_DEGRADATION_LIKELY'
    WHEN n_drive_7d >= 3 AND n_drive_30d >= 10
     AND regen_30d > 0
     AND regen_7d < regen_30d * 0.90
    THEN 'REGEN_DEGRADATION_LIKELY'
    WHEN n_drive_7d >= 3 AND n_drive_30d >= 10
     AND eff_30d > 0
     AND eff_7d > eff_30d * 1.15
    THEN 'EFFICIENCY_ANOMALY'
    ELSE 'NORMAL'
  END AS status
FROM rolling;

-- ------------------------------------------------------------------
-- 5.  brake_wear_estimate  — linear wear model with regen adjustment
--
-- Base pad life assumption: 50,000 miles for a Tesla with
-- moderate regen usage (regen_ratio ~ 20 %).  Heavy regen
-- users (regen_ratio > 30 %) can see 70,000–100,000 miles.
-- Light regen users (< 10 %) may see only 35,000 miles.
--
-- Formula:
--   wear_factor  = 1 - regen_ratio
--                = fraction of braking done by friction pads
--   wear_pct     = (odometer_mi / 50000) * wear_factor * 100
--   remaining_pct = 100 - wear_pct
--
-- This is intentionally conservative.  Actual pad life depends
-- on driving style, terrain, climate, and pad compound.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW brake_wear_estimate AS
WITH latest AS (
  SELECT vin, MAX(bucket) AS last_bucket
  FROM regen_brake_daily_1d
  WHERE odometer IS NOT NULL
  GROUP BY vin
),
snapshot AS (
  SELECT
    d.vin,
    d.odometer,
    d.lifetime_energy_used_drive,
    d.lifetime_energy_gained_regen,
    -- Regen ratio (lifetime)
    CASE WHEN (d.lifetime_energy_gained_regen + d.lifetime_energy_used_drive) > 0
      THEN d.lifetime_energy_gained_regen
           / (d.lifetime_energy_gained_regen + d.lifetime_energy_used_drive)
      ELSE 0
    END AS regen_ratio,
    -- 30-day rolling regen ratio from diagnostics (more current)
    (SELECT regen_ratio_30d_avg / 100
     FROM regen_brake_diagnostics diag
     WHERE diag.vin = d.vin AND diag.ts = d.bucket
     LIMIT 1) AS recent_regen_ratio
  FROM regen_brake_daily_1d d
  JOIN latest l ON l.vin = d.vin AND l.last_bucket = d.bucket
)
SELECT
  vin,
  ROUND(odometer::numeric, 1) AS odometer_mi,
  ROUND((odometer * 1.60934)::numeric, 1) AS odometer_km,
  ROUND(lifetime_energy_used_drive::numeric, 2) AS lifetime_drive_kwh,
  ROUND(lifetime_energy_gained_regen::numeric, 2) AS lifetime_regen_kwh,
  ROUND((regen_ratio * 100)::numeric, 1) AS lifetime_regen_ratio_pct,
  ROUND((COALESCE(recent_regen_ratio, regen_ratio) * 100)::numeric, 1) AS recent_regen_ratio_pct,
  -- Wear calculation.  Clamped to [0, 100] (N1 fix) — for very high-odometer
  -- vehicles the raw expression can exceed 100, which is meaningless and
  -- breaks downstream LEAST/GREATEST consumers in 014.
  ROUND(LEAST(100, GREATEST(0,
      odometer / 50000.0 * (1 - COALESCE(recent_regen_ratio, regen_ratio)) * 100
    ))::numeric, 1) AS wear_pct,
  ROUND(GREATEST(0, 100 - (odometer / 50000.0 * (1 - COALESCE(recent_regen_ratio, regen_ratio)) * 100))::numeric, 1)
    AS remaining_pct,
  -- Estimated pad life remaining (miles)
  ROUND(GREATEST(0, 50000.0 * (1 - COALESCE(recent_regen_ratio, regen_ratio)) - odometer * (1 - COALESCE(recent_regen_ratio, regen_ratio)))::numeric, 0)
    AS estimated_remaining_mi,
  -- Brake style assessment
  CASE
    WHEN COALESCE(recent_regen_ratio, regen_ratio) > 0.30 THEN 'Heavy Regen — extended pad life'
    WHEN COALESCE(recent_regen_ratio, regen_ratio) > 0.20 THEN 'Normal Regen — typical pad life'
    WHEN COALESCE(recent_regen_ratio, regen_ratio) > 0.10 THEN 'Light Regen — reduced pad life'
    ELSE 'Very Light Regen — inspect pads frequently'
  END AS brake_style_assessment
FROM snapshot;

-- ------------------------------------------------------------------
-- 6.  regen_brake_summary  — Grafana-friendly latest snapshot
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW regen_brake_summary AS
WITH latest AS (
  SELECT vin, MAX(ts) AS last_ts
  FROM regen_brake_diagnostics
  WHERE n_drive_7d >= 1
  GROUP BY vin
)
SELECT
  l.vin,
  l.last_ts,
  d.status,
  d.efficiency_wh_mi,
  d.regen_wh_mi,
  d.regen_ratio_pct,
  d.eff_7d_avg,
  d.eff_30d_avg,
  d.eff_trend_pct,
  d.regen_torque_7d_avg,
  d.regen_torque_30d_avg,
  d.regen_torque_trend_pct,
  d.distance_delta_mi,
  d.brake_applications,
  d.brake_events_per_100mi,
  b.remaining_pct AS brake_remaining_pct,
  b.wear_pct AS brake_wear_pct,
  b.estimated_remaining_mi,
  b.brake_style_assessment,
  vm.model
FROM latest l
JOIN regen_brake_diagnostics d
  ON d.vin = l.vin AND d.ts = l.last_ts
LEFT JOIN brake_wear_estimate b ON b.vin = l.vin
LEFT JOIN vehicle_metadata vm ON vm.vin = l.vin;

-- ------------------------------------------------------------------
-- 7.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Regen & Brake Status"  (Stat + colour)
-- --------------------------------------------------------
--
-- SELECT status, regen_ratio_pct, brake_remaining_pct,
--        efficiency_wh_mi, regen_torque_trend_pct
-- FROM regen_brake_summary
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Brake Pad Wear"  (Gauge)
-- --------------------------------------------------------
-- Green  = > 50 % remaining
-- Yellow = 25–50 %
-- Red    = < 25 %
--
-- SELECT remaining_pct, wear_pct, estimated_remaining_mi,
--        brake_style_assessment
-- FROM brake_wear_estimate
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Regen % Trend"  (Time series)
-- --------------------------------------------------------
-- Regen ratio over time with 7-day and 30-day rolling.
--
-- SELECT
--   ts AS time,
--   regen_ratio_pct AS "Daily regen %",
--   regen_ratio_7d_avg AS "7-day avg",
--   regen_ratio_30d_avg AS "30-day avg"
-- FROM regen_brake_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Efficiency Sparkline"  (Time series)
-- --------------------------------------------------------
-- Wh/mi with anomaly bands.  Add Alert rule on status.
--
-- SELECT
--   ts AS time,
--   efficiency_wh_mi AS "Wh/mi",
--   eff_7d_avg AS "7-day avg",
--   eff_30d_avg AS "30-day avg"
-- FROM regen_brake_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Peak Regen Torque"  (Time series)
-- --------------------------------------------------------
-- Most negative torque per day with rolling averages.
--
-- SELECT
--   ts AS time,
--   ABS(peak_regen_torque) AS "Peak regen torque (Nm)",
--   regen_torque_7d_avg AS "7-day avg",
--   regen_torque_30d_avg AS "30-day avg"
-- FROM regen_brake_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Brake Events"  (Time series)
-- --------------------------------------------------------
-- Brake pedal applications per 100 miles.
--
-- SELECT
--   ts AS time,
--   brake_events_per_100mi AS "Brake events / 100 mi",
--   brake_applications AS "Daily applications"
-- FROM regen_brake_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Efficiency with Unit Conversion"  (Time series)
-- --------------------------------------------------------
-- Compatible with existing to_dist helper.  Raw odometer
-- is in miles; for metric display multiply by 1.60934.
--
-- SELECT
--   ts AS time,
--   CASE WHEN '$dist_effective' = 'imperial'
--     THEN efficiency_wh_mi
--     ELSE efficiency_wh_mi * 1.60934
--   END AS "Efficiency",
--   CASE WHEN '$dist_effective' = 'imperial'
--     THEN eff_7d_avg
--     ELSE eff_7d_avg * 1.60934
--   END AS "7-day avg"
-- FROM regen_brake_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- ------------------------------------------------------------------
-- 8.  How to test with the simulator
-- ------------------------------------------------------------------
-- Step 0 — Re-build the simulator (cumulative energy counters
--   were added to main.go and fields.json):
--   cd tools/simulator
--   go build -o simulator .
--   ./simulator \
--     -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
--     -vins "SIMULATEDVIN001" \
--     -interval 30
--
--   Let it run for at least 30 minutes to accumulate driving
--   data (the simulator cycles through Driving → Parked modes).
--
-- Step 1 — Verify cumulative counters are increasing
--   SELECT ts, num_value FROM telemetry
--   WHERE vin = 'SIMULATEDVIN001' AND field = 'LifetimeEnergyGainedRegen'
--   ORDER BY ts DESC LIMIT 10;
--
--   The value should increase monotonically (no drops).
--
-- Step 2 — Verify daily deltas are computed
--   SELECT ts, distance_delta_mi, energy_regen_delta_kwh,
--          regen_ratio_pct, efficiency_wh_mi
--   FROM regen_brake_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 3 — Simulate regen degradation (reduce regen torque)
--   UPDATE telemetry
--   SET num_value = num_value * 0.7
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field LIKE 'DiTorqueActual%'
--     AND ts > NOW() - INTERVAL '7 days';
--
--   CALL refresh_continuous_aggregate('regen_brake_samples_1h',
--     NOW() - INTERVAL '7 days', NOW());
--   CALL refresh_continuous_aggregate('regen_brake_daily_1d',
--     NOW() - INTERVAL '30 days', NOW());
--
--   SELECT ts, regen_torque_7d_avg, regen_torque_30d_avg,
--          regen_torque_trend_pct, status
--   FROM regen_brake_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
--   You should see regen_torque_trend_pct drop below -10 %
--   and status flip to REGEN_DEGRADATION_LIKELY.
--
-- Step 4 — Simulate efficiency anomaly (increase consumption)
--   UPDATE telemetry
--   SET num_value = num_value * 1.3
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field = 'LifetimeEnergyUsedDrive'
--     AND ts > NOW() - INTERVAL '3 days';
--
--   CALL refresh_continuous_aggregate('regen_brake_samples_1h',
--     NOW() - INTERVAL '3 days', NOW());
--   CALL refresh_continuous_aggregate('regen_brake_daily_1d',
--     NOW() - INTERVAL '30 days', NOW());
--
--   SELECT ts, eff_7d_avg, eff_30d_avg, eff_trend_pct, status
--   FROM regen_brake_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
--   You should see eff_trend_pct climb above +15 % and status
--   flip to EFFICIENCY_ANOMALY.
--
-- Step 5 — Check brake wear estimate
--   SELECT * FROM brake_wear_estimate
--   WHERE vin = 'SIMULATEDVIN001';
--
-- Step 6 — Clean up
--   DELETE FROM telemetry WHERE vin = 'SIMULATEDVIN001';
--   SELECT remove_continuous_aggregate_policy('regen_brake_samples_1h');
--   DROP MATERIALIZED VIEW regen_brake_samples_1h CASCADE;
--   -- then re-create from this file.
-- ------------------------------------------------------------------
