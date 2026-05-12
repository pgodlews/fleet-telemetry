-- ============================================================
-- High-Voltage Battery Health Diagnostics Layer
--
-- Context: Tesla fleet telemetry does not expose a direct
-- Features are gated per docs/FEATURE_MATRIX.md using vehicle_metadata.
-- "nominal_full_pack_energy" field.  We therefore derive capacity
-- from the ratio of EnergyRemaining (kWh) to BatteryLevel (%):
--
--     derived_capacity_kwh = EnergyRemaining / (BatteryLevel / 100)
--
-- This is mathematically equivalent to full-pack energy and is
-- most accurate when BatteryLevel is high and the pack is at
-- thermal equilibrium (rest > 4 h, low power draw).
--
-- Architecture:
--   1. battery_samples_1h        — hourly pivot of energy, SOC,
--      range, brick voltages, pack electrical, vehicle state.
--   2. battery_capacity_1d       — daily CAGG with rest-hour
--      capacity metrics and brick-voltage delta.
--   3. battery_rest_capacity     — view that identifies 4+ hour
--      rest blocks and extracts the most stable capacity reading.
--   4. battery_alerts            — view over vehicle_alerts that
--      surfaces BMS / battery-related alert codes.
--   5. battery_health_diagnostics — rolling trend view with
--      degradation % since first recorded value.
--   6. battery_health_summary    — combined snapshot: capacity
--      fade, brick imbalance, and active alerts.
--
-- Thermal equilibrium criteria (rest hour):
--   • vehicle_speed_max ≤ 0  AND  gear in Park / invalid / NULL
--   • ac_charge_power_max ≤ 0  AND  dc_charge_power_max ≤ 0
--   • |pack_current_avg × pack_voltage_avg| < 500 W (0.5 kW)
--
-- Unit compatibility:
--   • EnergyRemaining  → kWh  (no conversion needed)
--   • IdealBatteryRange / RatedRange  → raw miles
--     Grafana panels use inline CASE WHEN for imperial/metric
--   • Brick voltages  → V  (no conversion)
--
-- Requires superuser (postgres) to run — creates CAGGs.
-- Run after 001_schema.sql and 002_views.sql.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Hourly pivot CAGG — battery fields aligned per hour
--
-- We use LAST(value, ts) to capture the final sample of each hour,
-- which is the reading closest to thermal equilibrium for a rest
-- block that spans multiple hours.
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS battery_samples_1h CASCADE;

CREATE MATERIALIZED VIEW battery_samples_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin,
  -- Energy & SOC (capacity proxies)
  AVG(CASE WHEN field = 'EnergyRemaining' THEN num_value END) AS energy_remaining_avg,
  LAST(num_value, ts) FILTER (WHERE field = 'EnergyRemaining') AS energy_remaining_last,
  AVG(CASE WHEN field = 'BatteryLevel'    THEN num_value END) AS battery_level_avg,
  LAST(num_value, ts) FILTER (WHERE field = 'BatteryLevel') AS battery_level_last,
  -- Range (fade tracking)
  AVG(CASE WHEN field = 'IdealBatteryRange' THEN num_value END) AS ideal_range_avg,
  LAST(num_value, ts) FILTER (WHERE field = 'IdealBatteryRange') AS ideal_range_last,
  AVG(CASE WHEN field = 'RatedRange'        THEN num_value END) AS rated_range_avg,
  LAST(num_value, ts) FILTER (WHERE field = 'RatedRange') AS rated_range_last,
  -- Brick voltages (imbalance detection)
  MAX(CASE WHEN field = 'BrickVoltageMax' THEN num_value END) AS brick_v_max,
  MIN(CASE WHEN field = 'BrickVoltageMin' THEN num_value END) AS brick_v_min,
  AVG(CASE WHEN field = 'BrickVoltageMax' THEN num_value END) AS brick_v_max_avg,
  AVG(CASE WHEN field = 'BrickVoltageMin' THEN num_value END) AS brick_v_min_avg,
  -- Pack electrical (for power-draw filtering)
  AVG(CASE WHEN field = 'PackCurrent' THEN num_value END) AS pack_current_avg,
  AVG(CASE WHEN field = 'PackVoltage' THEN num_value END) AS pack_voltage_avg,
  -- Vehicle state (for rest detection)
  MAX(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS vehicle_speed_max,
  MAX(CASE WHEN field = 'Gear'         THEN str_value END) AS gear,
  -- Charging state (exclude when charging)
  MAX(CASE WHEN field = 'ACChargingPower' THEN num_value END) AS ac_charge_power_max,
  MAX(CASE WHEN field = 'DCChargingPower' THEN num_value END) AS dc_charge_power_max
FROM telemetry
WHERE field IN (
  'EnergyRemaining', 'BatteryLevel',
  'IdealBatteryRange', 'RatedRange',
  'BrickVoltageMax', 'BrickVoltageMin',
  'PackCurrent', 'PackVoltage',
  'VehicleSpeed', 'Gear',
  'ACChargingPower', 'DCChargingPower'
)
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 2.  Daily capacity & brick-health CAGG (built on hourly pivot)
--
-- Rest-hour filter (repeated inline because CAGGs do not support
-- referencing computed booleans inside FILTER clauses):
--   • parked  (speed = 0, gear = P)
--   • not charging  (AC/DC power = 0)
--   • low power draw  (|I·V| < 500 W)
-- ------------------------------------------------------------------
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
DROP MATERIALIZED VIEW IF EXISTS battery_capacity_1d CASCADE;

CREATE MATERIALIZED VIEW battery_capacity_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  -- Rest hours count
  COUNT(*) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND ABS(COALESCE(pack_current_avg, 0) * COALESCE(pack_voltage_avg, 0)) < 500
  ) AS rest_hours,
  -- Derived capacity: EnergyRemaining / (BatteryLevel/100) during rest
  -- We use the LAST rest-hour reading of the day (most stable).
  LAST(energy_remaining_last, bucket) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND ABS(COALESCE(pack_current_avg, 0) * COALESCE(pack_voltage_avg, 0)) < 500
    AND battery_level_last > 0
  ) AS energy_remaining_rest,
  LAST(battery_level_last, bucket) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND ABS(COALESCE(pack_current_avg, 0) * COALESCE(pack_voltage_avg, 0)) < 500
    AND battery_level_last > 0
  ) AS battery_level_rest,
  -- Range at rest (last reading of the day)
  LAST(ideal_range_last, bucket) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND ABS(COALESCE(pack_current_avg, 0) * COALESCE(pack_voltage_avg, 0)) < 500
  ) AS ideal_range_rest,
  LAST(rated_range_last, bucket) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    AND ABS(COALESCE(pack_current_avg, 0) * COALESCE(pack_voltage_avg, 0)) < 500
  ) AS rated_range_rest,
  -- Brick imbalance (max delta seen any time during the day)
  MAX(brick_v_max - brick_v_min) FILTER (WHERE
    brick_v_max IS NOT NULL AND brick_v_min IS NOT NULL
  ) AS brick_delta_max,
  AVG(brick_v_max - brick_v_min) FILTER (WHERE
    brick_v_max IS NOT NULL AND brick_v_min IS NOT NULL
  ) AS brick_delta_avg
FROM battery_samples_1h
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 3.  Refresh policies
-- ------------------------------------------------------------------
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('battery_samples_1h');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('battery_samples_1h',
  start_offset  => INTERVAL '7 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- battery_capacity_1d is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('battery_capacity_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ------------------------------------------------------------------
-- 4.  battery_rest_capacity  — rest-block detection
--
-- Uses gaps-and-islands to find consecutive rest hours (≥ 4 h).
-- Takes the LAST hour of each block as the thermally-equilibrated
-- reading.  This is the highest-quality capacity data available.
--
-- Rest-hour criteria match those in battery_capacity_1d.
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
)
SELECT
  vin,
  block_end AS ts,
  block_start,
  block_end,
  block_hours,
  energy_remaining,
  battery_level,
  CASE WHEN battery_level > 0
    THEN ROUND((energy_remaining / battery_level * 100)::numeric, 2)
    ELSE NULL
  END AS derived_capacity_kwh,
  ideal_range,
  rated_range
FROM blocks;

-- ------------------------------------------------------------------
-- 5.  battery_alerts  — BMS / battery-related alert codes
--
-- Sources from the vehicle_alerts side-channel table (not telemetry
-- EAV).  Severity is inferred from alert-code prefixes:
--   BMS_f*  = fault      → CRITICAL  (immediate service)
--   BMS_u*  = urgent     → URGENT    (schedule service soon)
--   BMS_a*  = alert      → WARNING   (monitor)
--   UI_a*   = UI alert   → WARNING
--   DI_*    = drive inv  → URGENT
--   CP_*    = charge port→ WARNING
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW battery_alerts AS
SELECT
  ts,
  vin,
  name AS alert_code,
  audience,
  started_at,
  ended_at,
  CASE
    WHEN name LIKE 'BMS_f%' THEN 'CRITICAL'
    WHEN name LIKE 'BMS_u%' THEN 'URGENT'
    WHEN name LIKE 'DI_f%'  THEN 'CRITICAL'
    WHEN name LIKE 'DI_u%'  THEN 'URGENT'
    WHEN name IN ('BMS_a001','BMS_a002','BMS_a003','BMS_a004',
                  'BMS_a005','BMS_a006','BMS_a007','BMS_a008')
      THEN 'WARNING'
    WHEN name LIKE 'UI_a%'  THEN 'WARNING'
    WHEN name LIKE 'CP_%'   THEN 'WARNING'
    ELSE 'INFO'
  END AS severity,
  CASE
    WHEN name LIKE 'BMS_f%' THEN 'BMS fault — immediate service required'
    WHEN name LIKE 'BMS_u%' THEN 'BMS issue — schedule service soon'
    WHEN name LIKE 'DI_f%'  THEN 'Drive inverter fault — stop driving'
    WHEN name LIKE 'DI_u%'  THEN 'Drive inverter issue — service required'
    WHEN name LIKE 'BMS_a%' THEN 'BMS alert — monitor battery health'
    WHEN name LIKE 'UI_a%'  THEN 'Vehicle alert — check dashboard'
    WHEN name LIKE 'CP_%'   THEN 'Charge port alert — inspect connector'
    ELSE 'Battery-related alert'
  END AS description
FROM vehicle_alerts
WHERE name LIKE 'BMS_%'
   OR name LIKE 'DI_%'
   OR name LIKE 'UI_a%'
   OR name LIKE 'CP_%';

-- ------------------------------------------------------------------
-- 6.  battery_health_diagnostics  — rolling trends & degradation
--
-- Computes derived capacity for every day with rest data, then
-- calculates degradation % versus the first recorded capacity for
-- each VIN.  Also includes 30-day / 90-day rolling averages and
-- brick-delta trends.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW battery_health_diagnostics AS
WITH daily_raw AS (
  SELECT
    bucket,
    vin,
    rest_hours,
    energy_remaining_rest,
    battery_level_rest,
    CASE WHEN battery_level_rest > 0
      THEN energy_remaining_rest / battery_level_rest * 100
      ELSE NULL
    END AS derived_capacity_kwh,
    ideal_range_rest,
    rated_range_rest,
    brick_delta_max,
    brick_delta_avg
  FROM battery_capacity_1d
),
first_values AS (
  SELECT
    vin,
    MIN(bucket) FILTER (WHERE derived_capacity_kwh IS NOT NULL)
      AS first_capacity_bucket,
    (ARRAY_AGG(derived_capacity_kwh ORDER BY bucket)
      FILTER (WHERE derived_capacity_kwh IS NOT NULL))[1]
      AS baseline_capacity_kwh,
    (ARRAY_AGG(ideal_range_rest ORDER BY bucket)
      FILTER (WHERE ideal_range_rest IS NOT NULL))[1]
      AS baseline_ideal_range,
    (ARRAY_AGG(rated_range_rest ORDER BY bucket)
      FILTER (WHERE rated_range_rest IS NOT NULL))[1]
      AS baseline_rated_range
  FROM daily_raw
  GROUP BY vin
),
rolling AS (
  SELECT
    d.*,
    f.baseline_capacity_kwh,
    f.baseline_ideal_range,
    f.baseline_rated_range,
    -- Capacity degradation since baseline
    CASE WHEN f.baseline_capacity_kwh > 0
      THEN ROUND(((f.baseline_capacity_kwh - d.derived_capacity_kwh)
                  / f.baseline_capacity_kwh * 100)::numeric, 2)
      ELSE NULL
    END AS capacity_degradation_pct,
    -- Range degradation since baseline
    CASE WHEN f.baseline_ideal_range > 0
      THEN ROUND(((f.baseline_ideal_range - d.ideal_range_rest)
                  / f.baseline_ideal_range * 100)::numeric, 2)
      ELSE NULL
    END AS ideal_range_degradation_pct,
    CASE WHEN f.baseline_rated_range > 0
      THEN ROUND(((f.baseline_rated_range - d.rated_range_rest)
                  / f.baseline_rated_range * 100)::numeric, 2)
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
  END AS capacity_trend_pct
FROM rolling;

-- ------------------------------------------------------------------
-- 7.  battery_health_summary  — combined snapshot
--
-- Latest rest-capacity reading, degradation %, brick imbalance,
-- and active alerts rolled into a single Grafana-friendly row.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW battery_health_summary AS
WITH latest_rest AS (
  SELECT vin, MAX(ts) AS last_ts
  FROM battery_rest_capacity
  WHERE derived_capacity_kwh IS NOT NULL
  GROUP BY vin
),
rest_snapshot AS (
  SELECT
    r.vin,
    r.ts AS last_rest_ts,
    r.block_hours AS last_rest_hours,
    r.derived_capacity_kwh AS current_capacity_kwh,
    r.ideal_range AS current_ideal_range,
    r.rated_range AS current_rated_range
  FROM battery_rest_capacity r
  JOIN latest_rest l ON l.vin = r.vin AND l.last_ts = r.ts
),
baseline AS (
  SELECT
    vin,
    (ARRAY_AGG(derived_capacity_kwh ORDER BY ts)
      FILTER (WHERE derived_capacity_kwh IS NOT NULL))[1]
      AS baseline_capacity_kwh,
    (ARRAY_AGG(ideal_range ORDER BY ts)
      FILTER (WHERE ideal_range IS NOT NULL))[1]
      AS baseline_ideal_range,
    (ARRAY_AGG(rated_range ORDER BY ts)
      FILTER (WHERE rated_range IS NOT NULL))[1]
      AS baseline_rated_range
  FROM battery_rest_capacity
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
    COUNT(*) FILTER (WHERE ended_at IS NULL) AS active_alert_count,
    STRING_AGG(DISTINCT alert_code, ', ' ORDER BY alert_code)
      FILTER (WHERE ended_at IS NULL) AS active_alert_codes,
    MAX(severity) FILTER (WHERE ended_at IS NULL) AS max_severity
  FROM battery_alerts
  WHERE ts > NOW() - INTERVAL '30 days'
  GROUP BY vin
)
SELECT
  r.vin,
  r.last_rest_ts,
  r.last_rest_hours,
  r.current_capacity_kwh,
  b.baseline_capacity_kwh,
  CASE WHEN b.baseline_capacity_kwh > 0
    THEN ROUND(((b.baseline_capacity_kwh - r.current_capacity_kwh)
                / b.baseline_capacity_kwh * 100)::numeric, 2)
    ELSE NULL
  END AS capacity_degradation_pct,
  r.current_ideal_range,
  b.baseline_ideal_range,
  CASE WHEN b.baseline_ideal_range > 0
    THEN ROUND(((b.baseline_ideal_range - r.current_ideal_range)
                / b.baseline_ideal_range * 100)::numeric, 2)
    ELSE NULL
  END AS ideal_range_degradation_pct,
  r.current_rated_range,
  b.baseline_rated_range,
  CASE WHEN b.baseline_rated_range > 0
    THEN ROUND(((b.baseline_rated_range - r.current_rated_range)
                / b.baseline_rated_range * 100)::numeric, 2)
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
    WHEN r.current_capacity_kwh IS NOT NULL
     AND b.baseline_capacity_kwh > 0
     AND (b.baseline_capacity_kwh - r.current_capacity_kwh)
         / b.baseline_capacity_kwh > 0.10
      THEN 'BATTERY_CAPACITY_DEGRADED'
    WHEN d.last_day_brick_delta_max > 0.5
      THEN 'BATTERY_IMBALANCE_DETECTED'
    ELSE 'NORMAL'
  END AS overall_status,
  vm.model,
  vm.battery_type
FROM rest_snapshot r
LEFT JOIN baseline b ON b.vin = r.vin
LEFT JOIN daily_snapshot d ON d.vin = r.vin
LEFT JOIN active_alerts a ON a.vin = r.vin
LEFT JOIN vehicle_metadata vm ON vm.vin = r.vin;

-- ------------------------------------------------------------------
-- 8.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Battery Health Status"  (Stat + colour threshold)
-- --------------------------------------------------------
-- Red   = BATTERY_SERVICE_REQUIRED
-- Orange= BATTERY_SERVICE_RECOMMENDED
-- Yellow= BATTERY_CAPACITY_DEGRADED / BATTERY_IMBALANCE_DETECTED
-- Green = NORMAL
--
-- SELECT
--   overall_status,
--   capacity_degradation_pct,
--   ideal_range_degradation_pct,
--   active_alert_count,
--   max_alert_severity
-- FROM battery_health_summary
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "Capacity Fade Trend"  (Time series)
-- --------------------------------------------------------
-- Shows derived capacity (kWh) with 30-day / 90-day rolling
-- averages and degradation % annotations.
--
-- SELECT
--   ts AS time,
--   derived_capacity_kwh AS "Derived capacity (kWh)",
--   capacity_30d_avg AS "30-day avg",
--   capacity_90d_avg AS "90-day avg"
-- FROM battery_health_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Degradation %"  (Time series)
-- --------------------------------------------------------
-- Capacity, ideal range, and rated range degradation over time.
-- Threshold at 10 % (industry-standard end-of-life for EV packs).
--
-- SELECT
--   ts AS time,
--   capacity_degradation_pct AS "Capacity %",
--   ideal_range_degradation_pct AS "Ideal range %",
--   rated_range_degradation_pct AS "Rated range %"
-- FROM battery_health_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Brick Imbalance"  (Time series)
-- --------------------------------------------------------
-- Daily max brick-voltage delta with 30-day / 90-day trends.
-- Threshold at 0.5 V (significant imbalance warning).
--
-- SELECT
--   ts AS time,
--   brick_delta_max AS "Max delta (V)",
--   brick_delta_30d_avg AS "30-day avg",
--   brick_delta_90d_avg AS "90-day avg"
-- FROM battery_health_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Active Battery Alerts"  (Table)
-- --------------------------------------------------------
-- Current active alerts with severity colours.
--
-- SELECT
--   alert_code AS "Alert",
--   severity AS "Severity",
--   description AS "Description",
--   started_at AS "Started"
-- FROM battery_alerts
-- WHERE vin = '$vin'
--   AND ended_at IS NULL
-- ORDER BY
--   CASE severity
--     WHEN 'CRITICAL' THEN 1
--     WHEN 'URGENT'   THEN 2
--     WHEN 'WARNING'  THEN 3
--     ELSE 4
--   END,
--   started_at DESC;

-- --------------------------------------------------------
-- Panel: "Rest Capacity History"  (Table)
-- --------------------------------------------------------
-- High-quality capacity readings from 4+ hour rest blocks.
--
-- SELECT
--   ts AS "Rest end",
--   block_hours AS "Rest hours",
--   derived_capacity_kwh AS "Derived capacity (kWh)",
--   battery_level AS "SOC %",
--   ideal_range AS "Ideal range (mi)"
-- FROM battery_rest_capacity
-- WHERE vin = '$vin'
-- ORDER BY ts DESC
-- LIMIT 50;

-- --------------------------------------------------------
-- Panel: "Range with Unit Conversion"  (Time series)
-- --------------------------------------------------------
-- Compatible with existing imperial/metric unit helpers.
-- Raw IdealBatteryRange / RatedRange are in miles.
--
-- SELECT
--   ts AS time,
--   CASE WHEN '$dist_effective' = 'imperial'
--     THEN ideal_range_rest
--     ELSE ideal_range_rest * 1.60934
--   END AS "Ideal range",
--   CASE WHEN '$dist_effective' = 'imperial'
--     THEN rated_range_rest
--     ELSE rated_range_rest * 1.60934
--   END AS "Rated range"
-- FROM battery_health_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- ------------------------------------------------------------------
-- 9.  How to test with the simulator
-- ------------------------------------------------------------------
-- The simulator generates EnergyRemaining, BatteryLevel,
-- IdealBatteryRange, RatedRange, BrickVoltageMax/Min, etc.
--
-- Step 1 — Start the simulator
--   go run ./tools/simulator \
--     -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
--     -vins "SIMULATEDVIN001" \
--     -interval 30
--
-- Step 2 — Verify rest hours are detected
--   SELECT bucket, rest_hours,
--     energy_remaining_rest, battery_level_rest,
--     energy_remaining_rest / NULLIF(battery_level_rest, 0) * 100
--       AS derived_capacity
--   FROM battery_capacity_1d
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY bucket DESC LIMIT 5;
--
-- Step 3 — Simulate capacity fade (reduce EnergyRemaining by 10 %)
--   UPDATE telemetry
--   SET num_value = num_value * 0.9
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field = 'EnergyRemaining'
--     AND ts > NOW() - INTERVAL '7 days';
--
--   CALL refresh_continuous_aggregate('battery_samples_1h',
--     NOW() - INTERVAL '7 days', NOW());
--   CALL refresh_continuous_aggregate('battery_capacity_1d',
--     NOW() - INTERVAL '30 days', NOW());
--
--   SELECT ts, derived_capacity_kwh, capacity_degradation_pct
--   FROM battery_health_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
-- Step 4 — Simulate a BMS alert
--   INSERT INTO vehicle_alerts (ts, vin, name, started_at)
--   VALUES (NOW(), 'SIMULATEDVIN001', 'BMS_u018', NOW());
--
--   SELECT * FROM battery_health_summary
--   WHERE vin = 'SIMULATEDVIN001';
--
-- Step 5 — Simulate brick imbalance
--   UPDATE telemetry
--   SET num_value = num_value + 0.8
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field = 'BrickVoltageMax'
--     AND ts > NOW() - INTERVAL '1 day';
--
--   CALL refresh_continuous_aggregate('battery_samples_1h',
--     NOW() - INTERVAL '1 day', NOW());
--
--   SELECT last_day_brick_delta_max, overall_status
--   FROM battery_health_summary
--   WHERE vin = 'SIMULATEDVIN001';
--
-- Step 6 — Clean up
--   DELETE FROM telemetry WHERE vin = 'SIMULATEDVIN001';
--   DELETE FROM vehicle_alerts WHERE vin = 'SIMULATEDVIN001';
--   SELECT remove_continuous_aggregate_policy('battery_samples_1h');
--   DROP MATERIALIZED VIEW battery_samples_1h CASCADE;
--   -- then re-create from this file.
-- ------------------------------------------------------------------
