-- ============================================================
-- 056_brake_info_only.sql — the brake pad row is information, never a
-- warning
--
-- The pad figure is odometer miles against an assumed 50,000 mi pad life
-- scaled by the regen ratio. Nothing in the telemetry measures pad wear,
-- and regen-heavy cars often run well past 100k mi on a set, so the
-- assumption has no standing. Pad condition is checked at the periodic
-- safety inspection.
--
--   * predictive_health_recommendations (columns unchanged): the Brakes
--     row has no risk score (NULL; it is not a measurement) and its
--     severity is INFO in every state (no record, owner-confirmed
--     original pads, since a recorded replacement). A recorded
--     brake_inspection under 12 months old (and not older than the last
--     replacement) shows OK. The text states the facts (pad history,
--     miles on the set, recorded dates) and never asks for a measurement
--     or presents a wear percentage.
--   * brake_wear_estimate (columns unchanged): brake_style_assessment
--     describes the regen share only, with no pad-life claim. wear_pct,
--     remaining_pct and estimated_remaining_mi stay for compatibility as
--     the mileage model (assumed 50,000 mi pad life).
--   * Service items brake_pads and brake_inspection become record-only
--     (applies_to 'none'): the bot still offers them (its list is every
--     service_intervals item), but service_interval_status no longer
--     shows them, so nothing is ever due or OVERDUE for them.
--   * regen_brake_score (regen torque / efficiency trend) is unchanged.
--
-- Idempotent.
-- ============================================================

-- ------------------------------------------------------------------
-- Service items: record-only
-- ------------------------------------------------------------------
UPDATE service_intervals
   SET applies_to = 'none',
       description = 'Brake pads replaced (record only; no interval)'
 WHERE item = 'brake_pads';
UPDATE service_intervals
   SET applies_to = 'none',
       description = 'Brake inspection — pads checked (record only; no reminder)'
 WHERE item = 'brake_inspection';

-- ------------------------------------------------------------------
-- brake_wear_estimate — 055 body; neutral regen assessment
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW brake_wear_estimate AS
WITH latest AS (
  SELECT vin, MAX(bucket) AS last_bucket
  FROM regen_brake_daily_1d
  WHERE odometer IS NOT NULL
  GROUP BY vin
),
pads AS (   -- newest recorded brake-pad replacement (bot: service item brake_pads)
  SELECT DISTINCT ON (vin) vin, completed_at, odometer_mi
  FROM service_completions
  WHERE item = 'brake_pads'
  ORDER BY vin, completed_at DESC, id DESC
),
inspections AS (   -- newest recorded "pads checked" (bot: service item brake_inspection)
  SELECT DISTINCT ON (vin) vin, completed_at
  FROM service_completions
  WHERE item = 'brake_inspection'
  ORDER BY vin, completed_at DESC, id DESC
),
snapshot AS (
  SELECT
    d.vin,
    d.odometer,
    d.lifetime_energy_used_drive,
    d.lifetime_energy_gained_regen,
    CASE WHEN (d.lifetime_energy_gained_regen + d.lifetime_energy_used_drive) > 0
      THEN d.lifetime_energy_gained_regen
           / (d.lifetime_energy_gained_regen + d.lifetime_energy_used_drive)
      ELSE 0
    END AS regen_ratio,
    (SELECT regen_ratio_30d_avg / 100
     FROM regen_brake_diagnostics diag
     WHERE diag.vin = d.vin AND diag.ts = d.bucket
     LIMIT 1) AS recent_regen_ratio,
    i.completed_at AS last_inspection_at,
    o.confirmed_at AS original_pads_confirmed_at,
    p.completed_at AS pad_replaced_at,
    p.odometer_mi  AS pad_replaced_odometer_mi,
    -- miles on the current pads: since the recorded replacement when there
    -- is one with a usable odometer, otherwise the whole odometer
    CASE WHEN p.odometer_mi IS NOT NULL AND p.odometer_mi <= d.odometer
         THEN d.odometer - p.odometer_mi ELSE d.odometer END AS pad_miles
  FROM regen_brake_daily_1d d
  JOIN latest l ON l.vin = d.vin AND l.last_bucket = d.bucket
  LEFT JOIN pads p ON p.vin = d.vin
  LEFT JOIN inspections i ON i.vin = d.vin
  LEFT JOIN brake_pads_baseline o ON o.vin = d.vin
)
SELECT
  vin,
  ROUND(odometer::numeric, 1) AS odometer_mi,
  ROUND((odometer * 1.60934)::numeric, 1) AS odometer_km,
  ROUND(lifetime_energy_used_drive::numeric, 2) AS lifetime_drive_kwh,
  ROUND(lifetime_energy_gained_regen::numeric, 2) AS lifetime_regen_kwh,
  ROUND((regen_ratio * 100)::numeric, 1) AS lifetime_regen_ratio_pct,
  ROUND((COALESCE(recent_regen_ratio, regen_ratio) * 100)::numeric, 1) AS recent_regen_ratio_pct,
  ROUND(LEAST(100, GREATEST(0,
      pad_miles / 50000.0 * (1 - COALESCE(recent_regen_ratio, regen_ratio)) * 100
    ))::numeric, 1) AS wear_pct,
  ROUND(LEAST(100, GREATEST(0,
      100 - (pad_miles / 50000.0 * (1 - COALESCE(recent_regen_ratio, regen_ratio)) * 100)
    ))::numeric, 1) AS remaining_pct,
  ROUND(GREATEST(0, 50000.0 / NULLIF(1 - COALESCE(recent_regen_ratio, regen_ratio), 0) - pad_miles)::numeric, 0)
    AS estimated_remaining_mi,
  CASE
    WHEN COALESCE(recent_regen_ratio, regen_ratio) > 0.30 THEN 'Heavy regen'
    WHEN COALESCE(recent_regen_ratio, regen_ratio) > 0.20 THEN 'Normal regen'
    WHEN COALESCE(recent_regen_ratio, regen_ratio) > 0.10 THEN 'Light regen'
    ELSE 'Very light regen'
  END AS brake_style_assessment,
  -- appended (053)
  pad_replaced_at,
  ROUND(pad_replaced_odometer_mi::numeric, 1) AS pad_replaced_odometer_mi,
  CASE WHEN pad_replaced_odometer_mi IS NOT NULL AND pad_replaced_odometer_mi <= odometer
         THEN 'SINCE_PAD_REPLACEMENT'
       WHEN original_pads_confirmed_at IS NOT NULL
         THEN 'ORIGINAL_PADS_CONFIRMED'
       ELSE 'NO_PAD_RECORD' END AS wear_basis,
  -- appended (055)
  last_inspection_at,
  original_pads_confirmed_at,
  ROUND(pad_miles::numeric, 0) AS pad_miles
FROM snapshot;

-- ------------------------------------------------------------------
-- recommendations — 055 body; Brakes row information only
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW predictive_health_recommendations AS
WITH s AS (SELECT * FROM predictive_health_summary),
arms AS (
  SELECT vin, 'Battery'::text AS subsystem, battery_risk AS risk_score, battery_last_ts AS evidence_ts,
    CASE WHEN battery_risk >= 85 THEN 'Schedule battery pack inspection — capacity fade > 10% or brick imbalance > 0.5 V'
         WHEN battery_risk >= 60 THEN 'Monitor battery health — schedule diagnostic scan at next service'
         WHEN battery_risk >= 40 THEN 'Watch the full-charge capacity trend; no action yet'
         ELSE 'No action required' END AS recommendation
  FROM s
  UNION ALL
  SELECT vin, 'Powertrain', powertrain_risk, GREATEST(drivetrain_last_ts, regen_brake_last_ts, pcs_last_ts),
    CASE WHEN powertrain_risk >= 85 THEN 'Schedule drivetrain inspection — inverter overheat or regen degradation detected'
         WHEN powertrain_risk >= 60 THEN 'Monitor motor temps and regen torque — schedule check if trend continues'
         WHEN powertrain_risk >= 40 THEN 'Keep an eye on drivetrain and charging trends'
         ELSE 'No action required' END
  FROM s
  UNION ALL
  SELECT vin, 'Thermal', thermal_risk, GREATEST(heat_pump_last_ts, battery_last_ts),
    CASE WHEN thermal_risk >= 85 THEN 'Inspect HVAC system — heat pump degradation or battery thermal imbalance'
         WHEN thermal_risk >= 60 THEN 'Check cabin filter and refrigerant levels — efficiency declining'
         WHEN thermal_risk >= 40 THEN 'Verify pre-conditioning settings — minor thermal inefficiency'
         ELSE 'No action required' END
  FROM s
  UNION ALL
  SELECT vin, '12V / Electrical', low_voltage_score, low_voltage_last_ts,
    CASE WHEN low_voltage_score >= 60 THEN 'Have the 12V / low-voltage system diagnosed — DC-DC converter active unusually often while parked (activity proxy, not a battery capacity test)'
         WHEN low_voltage_score >= 40 THEN 'Monitor 12V system — DC-DC activity while parked increasing'
         ELSE 'No action required' END
  FROM s
  UNION ALL
  SELECT vin, 'Suspension', suspension_score, suspension_last_ts,
    CASE WHEN suspension_score >= 85 THEN 'Immediate suspension check — chassis alert active'
         WHEN suspension_score >= 60 THEN 'Schedule suspension inspection — lateral-acceleration variance rising'
         ELSE 'No action required' END
  FROM s
  UNION ALL
  SELECT vin, 'Charging (PCS)', pcs_score, pcs_last_ts,
    CASE WHEN pcs_score >= 60 THEN 'Check the charging setup — AC charging drew well below the requested current in more than one session'
         WHEN pcs_score >= 40 THEN 'One AC session drew well below the requested current — watch the next sessions'
         ELSE 'No action required' END
  FROM s
  UNION ALL
  SELECT vin, 'Dual Motor', dual_motor_score, dual_motor_last_ts,
    CASE WHEN dual_motor_score >= 85 THEN 'Inspect dual-motor system immediately — severe imbalance or thermal throttling detected'
         WHEN dual_motor_score >= 60 THEN 'Schedule dual-motor inspection — front-rear imbalance, regen degradation, or throttle limiting'
         WHEN dual_motor_score >= 40 THEN 'Monitor dual-motor balance — slight temp delta or regen trend detected'
         ELSE 'No action required' END
  FROM s WHERE dual_motor_last_ts IS NOT NULL OR dual_motor_score IS NOT NULL
  UNION ALL
  SELECT vin, 'Cybertruck', cybertruck_score, cybertruck_last_ts,
    CASE WHEN cybertruck_score >= 85 THEN 'Inspect Cybertruck immediately — tonneau failure, severe tri-motor imbalance, or 4680 battery degradation'
         WHEN cybertruck_score >= 60 THEN 'Schedule Cybertruck inspection — tonneau, V2L or tri-motor issue detected'
         WHEN cybertruck_score >= 40 THEN 'Monitor Cybertruck subsystems — slight anomaly in tonneau, V2L, or tri-motor'
         ELSE 'No action required' END
  FROM s WHERE model = 'CT'
  UNION ALL
  -- Brakes: no score (the pad figure is a mileage model, not a measurement)
  SELECT vin, 'Brakes', NULL::numeric, regen_brake_last_ts, NULL::text
  FROM s
  UNION ALL
  SELECT i.vin, 'HV Isolation', subsystem_risk_score(i.status)::numeric, i.ts,
    CASE WHEN i.status = 'ISOLATION_RESISTANCE_LOW' THEN 'Have the HV isolation checked by Tesla service — isolation resistance below 100 kOhm (unvalidated threshold)'
         WHEN i.status = 'WARNING' THEN 'Monitor HV isolation resistance — below 250 kOhm (unvalidated threshold)'
         ELSE 'No action required' END
  FROM (SELECT DISTINCT ON (vin) vin, status, ts FROM isolation_resistance_diagnostics
        WHERE status <> 'NO_DATA' ORDER BY vin, ts DESC) i
)
SELECT arms.vin, subsystem, risk_score,
  CASE
    -- Brakes (056): OK with a current recorded inspection, otherwise INFO
    WHEN subsystem = 'Brakes' AND brake_inspection_current(bw.last_inspection_at, bw.pad_replaced_at) THEN 'OK'
    WHEN subsystem = 'Brakes' THEN 'INFO'
    WHEN risk_score IS NULL THEN 'NO DATA'
    WHEN subsystem IN ('12V / Electrical', 'Charging (PCS)') AND risk_score >= 60 THEN 'WARNING'
    ELSE COALESCE(NULLIF(risk_band(risk_score), 'NORMAL'), 'OK')
  END AS severity,
  CASE
    WHEN subsystem = 'Brakes' AND bw.vin IS NULL
    THEN 'No odometer data yet'
    WHEN subsystem = 'Brakes' THEN
      CASE
        WHEN bw.wear_basis = 'SINCE_PAD_REPLACEMENT'
        THEN 'Pads replaced ' || to_char(bw.pad_replaced_at, 'YYYY-MM-DD')
             || ' at ' || to_char(bw.pad_replaced_odometer_mi, 'FM999,999') || ' mi; '
             || to_char(bw.pad_miles, 'FM999,999') || ' mi on this set. '
        WHEN bw.wear_basis = 'ORIGINAL_PADS_CONFIRMED'
        THEN 'Original pads at ' || to_char(bw.odometer_mi, 'FM999,999') || ' mi (owner-confirmed). '
        ELSE 'No pad history recorded (' || to_char(bw.odometer_mi, 'FM999,999') || ' mi on the odometer). '
      END
      || CASE WHEN bw.last_inspection_at IS NOT NULL
                   AND (bw.pad_replaced_at IS NULL OR bw.last_inspection_at >= bw.pad_replaced_at)
              THEN 'Pads checked OK on ' || to_char(bw.last_inspection_at, 'YYYY-MM-DD') || '. '
              ELSE '' END
      || 'No wear signal is available from telemetry; regen-heavy cars commonly exceed 100k mi on a set. Pad condition is checked at the periodic safety inspection.'
    WHEN risk_score IS NULL
    THEN 'No recent data for this subsystem (or it does not apply to this vehicle)'
    ELSE recommendation END AS recommendation,
  evidence_ts
FROM arms
LEFT JOIN brake_wear_estimate bw ON bw.vin = arms.vin AND arms.subsystem = 'Brakes';

SELECT refresh_one_matview('predictive_health_score_1d_mat') AS score_1d_refreshed;
SELECT refresh_one_matview('predictive_health_summary_mat')  AS summary_refreshed;
