-- ============================================================
-- 045_remove_unsupported_fields.sql — remove everything built on
-- fields no Tesla vehicle sends through Fleet Telemetry
--
-- AirSuspensionHeightFL/FR/RL/RR, AirSuspensionCompressorState,
-- AirSuspensionMode and SteeringAngle are not in this fork's
-- protos/vehicle_data.proto, not in upstream's current proto
-- (teslamotors/fleet-telemetry main, checked 13 Nov 2026), and not in
-- Tesla's published Fleet Telemetry available-data list for any model
-- (the only steering fields there are HvacSteeringWheelHeatAuto/Level).
-- The production database has no row for any of them. Only the
-- simulator ever wrote them.
--
-- Removed here:
--   * 015: air_suspension_samples_1h (continuous aggregate),
--     air_suspension_health_1d, air_suspension_diagnostics,
--     air_suspension_summary.
--   * 017: ct_air_suspension_diagnostics and the air-suspension arm of
--     cybertruck_diagnostics; cybertruck_summary is rebuilt without its
--     air_suspension_* columns.
--   * 010/028/029: the steering-angle columns and the steering-offset
--     ("SUSPENSION_ALIGNMENT_LIKELY") logic. suspension_samples_1m is
--     rebuilt without steering_avg / steering_last / n_steering;
--     suspension_steering_1d, suspension_trip_offsets,
--     suspension_diagnostics and suspension_summary are rebuilt on the
--     fields the car does send (VehicleSpeed, LateralAcceleration,
--     GpsHeading). The lateral-acceleration looseness check and the
--     UI_a006 / CH_* alert path stay. suspension_steering_1d keeps its
--     name so the refresh rotation and history stay continuous.
--   * The predictive-health chain (predictive_health_score_1d,
--     predictive_health_summary, their _live/_mat objects and
--     predictive_health_recommendations) is dropped here because it
--     reads the objects above; 050 recreates it without the air-
--     suspension score.
--
-- Kept: vehicles.has_air_suspension (a VIN-derived flag, not
-- telemetry), field_catalog (it has no rows for these fields).
--
-- Each drop is explicit and without CASCADE, in dependency order, so an
-- unexpected dependent makes this file fail instead of silently
-- disappearing. Idempotent: on re-run (FORCE=1) 010/015/017 have
-- recreated the old objects first and this file removes them again.
-- ============================================================

-- ------------------------------------------------------------------
-- 1. Predictive-health chain (recreated by 050).
-- ------------------------------------------------------------------
DROP VIEW IF EXISTS predictive_health_recommendations;
DROP VIEW IF EXISTS predictive_health_summary;
DROP MATERIALIZED VIEW IF EXISTS predictive_health_summary_mat;
DROP VIEW IF EXISTS predictive_health_summary_live;
DROP VIEW IF EXISTS predictive_health_score_1d;
DROP MATERIALIZED VIEW IF EXISTS predictive_health_score_1d_mat;
DROP VIEW IF EXISTS predictive_health_score_1d_live;

-- ------------------------------------------------------------------
-- 2. Cybertruck views without the air-suspension subsystem.
-- ------------------------------------------------------------------
DROP VIEW IF EXISTS cybertruck_summary;

CREATE OR REPLACE VIEW cybertruck_diagnostics AS
SELECT vin, ts, 'CT'::text AS model, 'tonneau'::text AS subsystem,
       status, severity, anomaly_reason, value, baseline
FROM ct_tonneau_diagnostics
UNION ALL
SELECT vin, ts, 'CT'::text, 'v2l'::text,
       status, severity, anomaly_reason, value, baseline
FROM ct_v2l_diagnostics
UNION ALL
SELECT vin, ts, 'CT'::text, 'tri_motor'::text,
       status, severity, anomaly_reason, value, baseline
FROM tri_motor_diagnostics
WHERE motor_config = 'Tri Motor'
UNION ALL
SELECT vin, ts, model, 'battery_4680'::text,
       status, severity, anomaly_reason, value, baseline
FROM ct_battery_4680_diagnostics;

DROP VIEW IF EXISTS ct_air_suspension_diagnostics;

CREATE VIEW cybertruck_summary AS
WITH latest_per_subsystem AS (
  SELECT DISTINCT ON (vin, subsystem)
         vin, subsystem, ts, status, severity, anomaly_reason, value, baseline
  FROM cybertruck_diagnostics
  WHERE status <> 'NOT_APPLICABLE'
  ORDER BY vin, subsystem, ts DESC
), pivoted AS (
  SELECT vin,
    MAX(ts) AS last_ts,
    MAX(CASE severity WHEN 'CRITICAL' THEN 4 WHEN 'URGENT' THEN 3
                      WHEN 'WARNING' THEN 2 WHEN 'CAUTION' THEN 1 ELSE 0 END) AS worst_severity_rank,
    MAX(status)         FILTER (WHERE subsystem = 'tonneau')      AS tonneau_status,
    MAX(severity)       FILTER (WHERE subsystem = 'tonneau')      AS tonneau_severity,
    MAX(anomaly_reason) FILTER (WHERE subsystem = 'tonneau')      AS tonneau_reason,
    MAX(status)         FILTER (WHERE subsystem = 'v2l')          AS v2l_status,
    MAX(severity)       FILTER (WHERE subsystem = 'v2l')          AS v2l_severity,
    MAX(anomaly_reason) FILTER (WHERE subsystem = 'v2l')          AS v2l_reason,
    MAX(status)         FILTER (WHERE subsystem = 'tri_motor')    AS tri_motor_status,
    MAX(severity)       FILTER (WHERE subsystem = 'tri_motor')    AS tri_motor_severity,
    MAX(anomaly_reason) FILTER (WHERE subsystem = 'tri_motor')    AS tri_motor_reason,
    MAX(status)         FILTER (WHERE subsystem = 'battery_4680') AS battery_4680_status,
    MAX(severity)       FILTER (WHERE subsystem = 'battery_4680') AS battery_4680_severity,
    MAX(anomaly_reason) FILTER (WHERE subsystem = 'battery_4680') AS battery_4680_reason
  FROM latest_per_subsystem
  GROUP BY vin
)
SELECT p.vin, p.last_ts,
  p.tonneau_status, p.tonneau_severity, p.tonneau_reason,
  p.v2l_status, p.v2l_severity, p.v2l_reason,
  p.tri_motor_status, p.tri_motor_severity, p.tri_motor_reason,
  p.battery_4680_status, p.battery_4680_severity, p.battery_4680_reason,
  CASE p.worst_severity_rank
    WHEN 4 THEN 'CRITICAL' WHEN 3 THEN 'URGENT' WHEN 2 THEN 'WARNING'
    WHEN 1 THEN 'CAUTION' ELSE 'NORMAL' END AS overall_severity,
  COALESCE(
    NULLIF(p.battery_4680_reason, '4680 structural pack within CT-specific thresholds'),
    NULLIF(p.tri_motor_reason, 'Tri-motor system balanced and within thermal limits'),
    NULLIF(p.v2l_reason, 'Powershare operating within normal limits'),
    NULLIF(p.tonneau_reason, 'Tonneau operating normally'),
    'All Cybertruck subsystems nominal') AS overall_reason,
  vm.model, vm.motor_config, vm.battery_type
FROM pivoted p
LEFT JOIN vehicle_metadata vm ON vm.vin = p.vin
WHERE vm.model = 'CT';

-- ------------------------------------------------------------------
-- 3. Air-suspension layer (015).
-- ------------------------------------------------------------------
DROP VIEW IF EXISTS air_suspension_summary;
DROP VIEW IF EXISTS air_suspension_diagnostics;
DROP MATERIALIZED VIEW IF EXISTS air_suspension_health_1d;
DROP MATERIALIZED VIEW IF EXISTS air_suspension_samples_1h;   -- continuous aggregate; its policy goes with it

-- ------------------------------------------------------------------
-- 4. Suspension chain without SteeringAngle.
-- ------------------------------------------------------------------
DROP VIEW IF EXISTS suspension_summary;
DROP VIEW IF EXISTS suspension_diagnostics;
DROP VIEW IF EXISTS suspension_trip_offsets;
DROP MATERIALIZED VIEW IF EXISTS suspension_steering_1d;
DROP MATERIALIZED VIEW IF EXISTS suspension_samples_1m;      -- continuous aggregate; its policy goes with it

CREATE MATERIALIZED VIEW suspension_samples_1m
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 minute', ts) AS bucket,
  vin,
  AVG(CASE WHEN field = 'VehicleSpeed' THEN num_value END)             AS speed_avg,
  MAX(CASE WHEN field = 'VehicleSpeed' THEN num_value END)             AS speed_max,
  AVG(CASE WHEN field = 'LateralAcceleration' THEN num_value END)      AS lat_accel_avg,
  MAX(ABS(CASE WHEN field = 'LateralAcceleration' THEN num_value END)) AS lat_accel_max_abs,
  LAST(num_value, ts) FILTER (WHERE field = 'GpsHeading')              AS heading_last,
  COUNT(*) FILTER (WHERE field = 'VehicleSpeed')                       AS n_speed,
  COUNT(*) FILTER (WHERE field = 'LateralAcceleration')                AS n_lat
FROM telemetry
WHERE field IN ('VehicleSpeed', 'LateralAcceleration', 'GpsHeading')
GROUP BY bucket, vin
WITH NO DATA;

SELECT add_continuous_aggregate_policy('suspension_samples_1m',
  start_offset      => INTERVAL '3 days',
  end_offset        => INTERVAL '1 minute',
  schedule_interval => INTERVAL '5 minutes',
  if_not_exists     => TRUE);

-- Fill the history now (outside any transaction block).
CALL refresh_continuous_aggregate('suspension_samples_1m', NULL, NULL);

-- Daily highway lateral-acceleration statistics (regular matview, as in
-- 010: hierarchical continuous aggregates are not used here).
CREATE MATERIALIZED VIEW suspension_steering_1d AS
SELECT
  time_bucket('1 day', bucket) AS bucket,
  vin,
  COUNT(*) FILTER (WHERE speed_avg > 50) AS highway_minutes,
  COUNT(*) FILTER (WHERE speed_avg > 50 AND ABS(lat_accel_avg) < 0.05) AS straight_highway_minutes,
  AVG(lat_accel_avg) FILTER (WHERE speed_avg > 50 AND ABS(lat_accel_avg) < 0.05) AS lat_accel_drift,
  STDDEV(lat_accel_avg) FILTER (WHERE speed_avg > 50) AS lat_accel_stddev,
  MAX(lat_accel_max_abs) FILTER (WHERE speed_avg > 50) AS lat_accel_max_abs
FROM suspension_samples_1m
GROUP BY 1, vin;
CREATE UNIQUE INDEX IF NOT EXISTS suspension_steering_1d_uq ON suspension_steering_1d (vin, bucket);

COMMENT ON MATERIALIZED VIEW suspension_steering_1d IS
  'Daily highway lateral-acceleration statistics. The name is historical: the
   steering-angle columns were removed in 045 (SteeringAngle is not a Fleet
   Telemetry field).';

CREATE VIEW suspension_trip_offsets AS
WITH trip_buckets AS (
  SELECT t.vin, t.trip_id, t.started, t.ended, t.distance_km, t.max_speed_mph,
         m.bucket, m.speed_avg, m.lat_accel_avg
  FROM trips t
  JOIN suspension_samples_1m m
    ON m.vin = t.vin AND m.bucket >= t.started AND m.bucket <= t.ended
  WHERE t.max_speed_mph > 50
)
SELECT vin, trip_id, started, ended, distance_km, max_speed_mph,
  COUNT(*) FILTER (WHERE speed_avg > 50 AND ABS(lat_accel_avg) < 0.05) AS straight_highway_minutes,
  AVG(lat_accel_avg) FILTER (WHERE speed_avg > 50 AND ABS(lat_accel_avg) < 0.05) AS lat_accel_drift,
  STDDEV(lat_accel_avg) FILTER (WHERE speed_avg > 50) AS lat_accel_stddev
FROM trip_buckets
GROUP BY vin, trip_id, started, ended, distance_km, max_speed_mph;

-- Looseness proxy only: rising highway lateral-acceleration variance.
-- Thresholds unchanged from 010.
CREATE VIEW suspension_diagnostics AS
WITH rolling AS (
  SELECT d.bucket, d.vin, d.highway_minutes, d.straight_highway_minutes,
         d.lat_accel_drift, d.lat_accel_stddev, d.lat_accel_max_abs,
         AVG(d.lat_accel_stddev) OVER w30 AS lat_std_30d,
         AVG(d.lat_accel_stddev) OVER w90 AS lat_std_90d,
         COUNT(*) OVER w7  AS n_7d,
         COUNT(*) OVER w30 AS n_30d,
         COUNT(*) OVER w90 AS n_90d
  FROM suspension_steering_1d d
  WINDOW
    w7  AS (PARTITION BY d.vin ORDER BY d.bucket RANGE BETWEEN INTERVAL '7 days'  PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY d.vin ORDER BY d.bucket RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW),
    w90 AS (PARTITION BY d.vin ORDER BY d.bucket RANGE BETWEEN INTERVAL '90 days' PRECEDING AND CURRENT ROW)
)
SELECT
  bucket AS ts, vin, highway_minutes, straight_highway_minutes,
  ROUND(lat_accel_drift::numeric, 4)   AS lat_accel_drift,
  ROUND(lat_accel_stddev::numeric, 4)  AS lat_accel_stddev,
  ROUND(lat_accel_max_abs::numeric, 3) AS lat_accel_max_abs,
  ROUND(lat_std_30d::numeric, 4) AS lat_std_30d_avg,
  ROUND(lat_std_90d::numeric, 4) AS lat_std_90d_avg,
  n_7d, n_30d, n_90d,
  CASE WHEN lat_std_90d > 0
       THEN ROUND(((lat_std_30d - lat_std_90d) / lat_std_90d * 100)::numeric, 1) END AS lat_std_trend_pct,
  CASE
    WHEN n_30d >= 10 AND lat_accel_stddev > 0.03 AND lat_std_30d > lat_std_90d * 1.5
      THEN 'SUSPENSION_LOOSENESS_LIKELY'
    ELSE 'NORMAL'
  END AS suspension_status
FROM rolling;

CREATE VIEW suspension_summary AS
WITH latest_diag AS (
  SELECT vin, MAX(ts) AS last_ts
  FROM suspension_diagnostics
  WHERE straight_highway_minutes >= 5
  GROUP BY vin
), diag_snapshot AS (
  SELECT d.* FROM suspension_diagnostics d
  JOIN latest_diag l ON l.vin = d.vin AND l.last_ts = d.ts
), active_alerts AS (
  SELECT vin,
    COUNT(DISTINCT alert_code) FILTER (WHERE ended_at IS NULL) AS active_alert_count,
    STRING_AGG(DISTINCT alert_code, ', ' ORDER BY alert_code) FILTER (WHERE ended_at IS NULL) AS active_alert_codes,
    severity_label(MAX(severity_rank(severity)) FILTER (WHERE ended_at IS NULL)) AS max_severity
  FROM suspension_alerts
  WHERE COALESCE(started_at, ts) > NOW() - alert_active_window()
  GROUP BY vin
), vins AS (
  SELECT vin FROM diag_snapshot UNION SELECT vin FROM active_alerts
)
SELECT
  v.vin,
  d.ts AS last_diag_ts,
  d.lat_accel_stddev AS last_lat_accel_stddev,
  d.lat_std_30d_avg,
  d.lat_std_90d_avg,
  d.lat_std_trend_pct,
  d.suspension_status,
  COALESCE(a.active_alert_count, 0) AS active_alert_count,
  a.active_alert_codes,
  COALESCE(a.max_severity, 'NONE') AS max_alert_severity,
  CASE
    WHEN COALESCE(a.max_severity, 'NONE') = 'CRITICAL' THEN 'SUSPENSION_SERVICE_REQUIRED'
    WHEN COALESCE(a.max_severity, 'NONE') = 'URGENT'   THEN 'SUSPENSION_SERVICE_RECOMMENDED'
    WHEN d.suspension_status = 'SUSPENSION_LOOSENESS_LIKELY' THEN 'SUSPENSION_LOOSENESS_LIKELY'
    WHEN d.vin IS NULL THEN 'NO_DATA'
    ELSE 'NORMAL'
  END AS overall_status,
  vm.model
FROM vins v
LEFT JOIN diag_snapshot d ON d.vin = v.vin
LEFT JOIN active_alerts a ON a.vin = v.vin
LEFT JOIN vehicle_metadata vm ON vm.vin = v.vin;

COMMENT ON VIEW suspension_summary IS
  'Suspension evidence that Fleet Telemetry can supply: UI_a006/CH_* alerts and
   highway lateral-acceleration variance (looseness proxy). The steering-offset
   alignment check was removed in 045: SteeringAngle is not a Fleet Telemetry
   field. last_diag_ts is the evidence age used by the health score.';
