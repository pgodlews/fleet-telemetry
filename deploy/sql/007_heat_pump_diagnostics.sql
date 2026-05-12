-- ============================================================
-- Heat Pump / Octovalve Diagnostics Layer
--
-- Feature gating per docs/FEATURE_MATRIX.md: has_heat_pump = true.
--
-- Context: Tesla fleet telemetry does not expose a direct numeric
-- HVAC power draw field.  HvacPower is an enum (On/Off).  We
-- therefore use PackCurrent × PackVoltage as a power proxy while
-- the car is parked with HVAC active.
--
-- Architecture:
--   1. heat_pump_samples_1h  — hourly pivot of climate & pack
--      fields, filtered to parked/HVAC-on conditions.
--   2. heat_pump_cop_1d      — daily CAGG computing average
--      power-per-degree (W/°C) per VIN.
--   3. heat_pump_diagnostics — main view with 7-day / 30-day
--      rolling averages and a degradation flag.
--
-- Degradation logic:
--   power_per_degree = ABS(PackCurrent × PackVoltage) /
--                      NULLIF(ABS(InsideTemp - OutsideTemp), 0)
--   HEAT_PUMP_DEGRADATION_LIKELY when:
--     • 7-day rolling avg PPD is > 15 % higher than 30-day avg
--     • temperature delta has not shifted by > 3 °C (same load)
--     • sample count is sufficient (≥ 20 observations in window)
--
-- Requires superuser (postgres) to run — creates CAGGs.
-- Run after 001_schema.sql and 002_views.sql.
-- ============================================================

-- ------------------------------------------------------------------
-- 1.  Hourly pivot CAGG — climate & pack fields aligned per hour
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS heat_pump_samples_1h CASCADE;

CREATE MATERIALIZED VIEW heat_pump_samples_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  vin,
  -- Temperatures
  MAX(CASE WHEN field = 'InsideTemp'  THEN num_value END) AS inside_temp_max,
  AVG(CASE WHEN field = 'InsideTemp'  THEN num_value END) AS inside_temp_avg,
  MAX(CASE WHEN field = 'OutsideTemp' THEN num_value END) AS outside_temp_max,
  AVG(CASE WHEN field = 'OutsideTemp' THEN num_value END) AS outside_temp_avg,
  -- Pack electrical (proxy for HVAC power when parked)
  MAX(CASE WHEN field = 'PackCurrent' THEN num_value END) AS pack_current_max,
  AVG(CASE WHEN field = 'PackCurrent' THEN num_value END) AS pack_current_avg,
  MAX(CASE WHEN field = 'PackVoltage' THEN num_value END) AS pack_voltage_max,
  AVG(CASE WHEN field = 'PackVoltage' THEN num_value END) AS pack_voltage_avg,
  -- HVAC state
  MAX(CASE WHEN field = 'HvacPower' AND str_value = 'HvacPowerStateOn' THEN 1 ELSE 0 END) AS hvac_on,
  -- Vehicle state (for filtering to parked)
  MAX(CASE WHEN field = 'VehicleSpeed' THEN num_value END) AS vehicle_speed_max,
  MAX(CASE WHEN field = 'Gear' THEN str_value END) AS gear,
  -- Charging state (exclude when charging)
  MAX(CASE WHEN field = 'ACChargingPower' THEN num_value END) AS ac_charge_power_max,
  MAX(CASE WHEN field = 'DCChargingPower' THEN num_value END) AS dc_charge_power_max
FROM telemetry
WHERE field IN (
  'InsideTemp', 'OutsideTemp',
  'PackCurrent', 'PackVoltage',
  'HvacPower', 'VehicleSpeed', 'Gear',
  'ACChargingPower', 'DCChargingPower'
)
GROUP BY bucket, vin;

-- ------------------------------------------------------------------
-- 2.  Daily COP / efficiency trend (regular matview)
--
-- Computes daily average power-per-degree for hours that meet
-- the "parked + HVAC-on" filter criteria.
-- NOTE: converted from continuous aggregate to regular matview
--       (hierarchical CAGGs unsupported after DROP+RECREATE)
-- ------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS heat_pump_cop_1d CASCADE;

CREATE MATERIALIZED VIEW heat_pump_cop_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  -- Average power-per-degree (W/°C)
  AVG(
    ABS(pack_current_avg * pack_voltage_avg) /
    NULLIF(ABS(inside_temp_avg - outside_temp_avg), 0)
  ) FILTER (WHERE
    -- Parked / idle
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND (gear IS NULL OR gear IN ('P', 'ShiftStateP', 'invalid', ''))
    -- HVAC active
    AND hvac_on = 1
    -- Not charging
    AND (ac_charge_power_max IS NULL OR ac_charge_power_max <= 0)
    AND (dc_charge_power_max IS NULL OR dc_charge_power_max <= 0)
    -- Sensible delta (avoid division by tiny numbers)
    AND ABS(inside_temp_avg - outside_temp_avg) >= 3
    -- Power window: excludes phantom drain (<100 W) and driving loads (>5 kW)
    AND ABS(pack_current_avg * pack_voltage_avg) BETWEEN 100 AND 5000
  ) AS avg_power_per_degree,
  -- Average temperature delta for context
  AVG(ABS(inside_temp_avg - outside_temp_avg)) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND hvac_on = 1
    AND ABS(inside_temp_avg - outside_temp_avg) >= 3
  ) AS avg_temp_delta,
  -- Hours included in the average
  COUNT(*) FILTER (WHERE
    (vehicle_speed_max IS NULL OR vehicle_speed_max <= 0)
    AND hvac_on = 1
    AND ABS(inside_temp_avg - outside_temp_avg) >= 3
    AND ABS(pack_current_avg * pack_voltage_avg) BETWEEN 100 AND 5000
  ) AS valid_hours,
  -- Max power seen (for spotting abnormal spikes)
  MAX(ABS(pack_current_avg * pack_voltage_avg)) FILTER (WHERE hvac_on = 1)
    AS max_hvac_power_watts
FROM heat_pump_samples_1h
GROUP BY time_bucket('1 day', bucket), vin;

-- ------------------------------------------------------------------
-- 3.  Refresh policies
-- ------------------------------------------------------------------
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('heat_pump_samples_1h');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT add_continuous_aggregate_policy('heat_pump_samples_1h',
  start_offset  => INTERVAL '7 days',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour'
);

-- heat_pump_cop_1d is now a regular matview; policy not applicable.
DO $$ BEGIN PERFORM remove_continuous_aggregate_policy('heat_pump_cop_1d'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ------------------------------------------------------------------
-- 4.  heat_pump_diagnostics  — rolling trends & degradation flag
--
-- Uses the daily CAGG to compute 7-day and 30-day rolling averages.
-- Flags degradation when the short-term average rises > 15 % above
-- the long-term baseline while temperature load stays similar.
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
    ) AS n_30d
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
  -- Degradation flag: 7-day avg > 15 % above 30-day avg
  -- while temperature load hasn't shifted by > 3 °C
  CASE
    WHEN COALESCE(vm.has_heat_pump, FALSE) IS NOT TRUE THEN 'NOT_APPLICABLE'
    WHEN r.n_7d  >= 3
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

-- ------------------------------------------------------------------
-- 5.  heat_pump_status  — Grafana-friendly latest snapshot
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW heat_pump_status AS
WITH latest AS (
  SELECT vin, MAX(ts) AS last_ts
  FROM heat_pump_diagnostics
  GROUP BY vin
)
SELECT
  l.vin,
  l.last_ts,
  d.status,
  d.power_per_degree  AS latest_ppd,
  d.temp_delta        AS latest_delta,
  d.ppd_7d_avg,
  d.ppd_30d_avg,
  d.trend_pct,
  d.valid_hours,
  vm.model,
  vm.has_heat_pump
FROM latest l
JOIN heat_pump_diagnostics d
  ON d.vin = l.vin AND d.ts = l.last_ts
LEFT JOIN vehicle_metadata vm ON vm.vin = l.vin
WHERE COALESCE(vm.has_heat_pump, FALSE) = TRUE;

-- ------------------------------------------------------------------
-- 6.  Example Grafana queries
-- ------------------------------------------------------------------

-- --------------------------------------------------------
-- Panel: "Heat Pump Efficiency"  (Time series)
-- --------------------------------------------------------
-- Shows power-per-degree (W/°C) with 7-day & 30-day baselines.
-- Add an Alert rule on the "status" column.
--
-- SELECT
--   ts AS time,
--   power_per_degree AS "Daily PPD (W/°C)",
--   ppd_7d_avg       AS "7-day avg",
--   ppd_30d_avg      AS "30-day avg"
-- FROM heat_pump_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts)
-- ORDER BY ts;

-- --------------------------------------------------------
-- Panel: "Degradation Alert"  (Stat + colour threshold)
-- --------------------------------------------------------
-- Red   = HEAT_PUMP_DEGRADATION_LIKELY
-- Green = NORMAL
--
-- SELECT status, trend_pct, latest_ppd, latest_delta
-- FROM heat_pump_status
-- WHERE vin = '$vin';

-- --------------------------------------------------------
-- Panel: "HVAC Power vs Delta"  (Scatter / XY)
-- --------------------------------------------------
-- Helps visualise whether high PPD is due to high power or
-- small delta.  Each point = one daily observation.
--
-- SELECT
--   temp_delta AS "Delta (°C)",
--   power_per_degree AS "PPD (W/°C)"
-- FROM heat_pump_diagnostics
-- WHERE vin = '$vin'
--   AND $__timeFilter(ts);

-- ------------------------------------------------------------------
-- 7.  How to test with the simulator
-- ------------------------------------------------------------------
-- The simulator writes realistic PackCurrent, PackVoltage,
-- InsideTemp and OutsideTemp.  HvacPower toggles On/Off.
--
-- Step 1 — Baseline (run for ≥ 7 days)
--   go run ./tools/simulator \
--     -conn "postgres://grafana_ro:tesla_grafana_ro@localhost:5432/tesla" \
--     -vins "SIMULATEDVIN001" \
--     -interval 30
--
--   Let it run for a week to build 7-day and 30-day rolling
--   baselines in heat_pump_cop_1d.
--
-- Step 2 — Verify baselines exist
--   SELECT ts, power_per_degree, ppd_7d_avg, ppd_30d_avg, status
--   FROM heat_pump_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 10;
--
-- Step 3 — Simulate gradual heat-pump degradation
--   We raise the PackCurrent drawn during HVAC-on hours by
--   ~20 % while keeping temperatures identical.  This mimics
--   a compressor working harder to achieve the same delta.
--
--   -- Find recent HVAC-on samples for this VIN
--   SELECT ts, num_value AS pack_current
--   FROM telemetry
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field = 'PackCurrent'
--     AND ts > NOW() - INTERVAL '1 hour'
--   ORDER BY ts;
--
--   -- Multiply every PackCurrent by 1.2 for the next 3 hours
--   UPDATE telemetry
--   SET num_value = num_value * 1.2
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field = 'PackCurrent'
--     AND ts > NOW()
--     AND ts < NOW() + INTERVAL '3 hours';
--
--   -- Refresh the CAGGs so the new data is materialised
--   CALL refresh_continuous_aggregate('heat_pump_samples_1h',
--     NOW() - INTERVAL '1 day', NOW());
--   CALL refresh_continuous_aggregate('heat_pump_cop_1d',
--     NOW() - INTERVAL '7 days', NOW());
--
--   -- Re-check the diagnostics view
--   SELECT ts, power_per_degree, trend_pct, status
--   FROM heat_pump_diagnostics
--   WHERE vin = 'SIMULATEDVIN001'
--   ORDER BY ts DESC LIMIT 5;
--
--   You should see trend_pct climb above 15 % and status flip
--   to HEAT_PUMP_DEGRADATION_LIKELY.
--
-- Step 4 — Revert
--   UPDATE telemetry
--   SET num_value = num_value / 1.2
--   WHERE vin = 'SIMULATEDVIN001'
--     AND field = 'PackCurrent'
--     AND ts > NOW()
--     AND ts < NOW() + INTERVAL '3 hours';
--
--   Or simply delete the test VIN and rebuild:
--   DELETE FROM telemetry WHERE vin = 'SIMULATEDVIN001';
--   SELECT remove_continuous_aggregate_policy('heat_pump_samples_1h');
--   DROP MATERIALIZED VIEW heat_pump_samples_1h CASCADE;
--   -- then re-create from this file.
-- ------------------------------------------------------------------
