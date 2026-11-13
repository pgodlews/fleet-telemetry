-- ============================================================
-- 038_status_dictionary_and_texts.sql — scoring reads the status
-- dictionary; recommendation texts match their signals (S2, S3)
--
-- S2. pm_status_dictionary (025) was populated and never read:
--     subsystem_risk_score() is a LIKE chain, so
--     HEAT_PUMP_DEGRADATION_LIKELY (dictionary: 65) scored 90 because
--     it matches '%DEGRADATION_LIKELY%'. The function now looks the
--     status up in the dictionary first and falls back to the LIKE
--     chain only for strings the dictionary does not know. It reads a
--     table, so it is STABLE, no longer IMMUTABLE. Signature unchanged.
--     isolation_resistance_diagnostics becomes an input to
--     predictive_health_recommendations ('HV Isolation' row), worded as
--     unvalidated.
--
-- S3. * 12V: the score is a DC-DC activity proxy (031); the text asked
--       for a battery replacement. It now asks for a diagnosis.
--     * Suspension: the text promised an "Immediate alignment check" at
--       >= 85 while the severity topped out at WARNING. A CRITICAL band
--       at >= 85 is added (threshold unchanged).
--     * brake_wear_estimate.remaining_pct is clamped to 0-100 like
--       wear_pct.
--
-- Thresholds are unchanged everywhere; only wording, the missing band,
-- and the clamp change. Column lists are unchanged.
--
-- Requires 025, 033. Idempotent.
-- ============================================================

CREATE OR REPLACE FUNCTION subsystem_risk_score(
  status TEXT,
  severity TEXT DEFAULT NULL,
  degradation_pct DOUBLE PRECISION DEFAULT NULL,
  brick_delta DOUBLE PRECISION DEFAULT NULL
)
RETURNS INTEGER LANGUAGE plpgsql STABLE AS $$
DECLARE
  s INTEGER;
BEGIN
  -- Base score: the dictionary is authoritative for every status it lists.
  IF status IS NOT NULL THEN
    SELECT d.base_score INTO s FROM pm_status_dictionary d WHERE d.status = subsystem_risk_score.status;
  END IF;

  IF s IS NULL THEN
    -- Fallback for statuses the dictionary does not know (unchanged from 014).
    IF status IS NULL THEN
      s := 5;
    ELSIF status LIKE '%CRITICAL%' OR status LIKE '%FAILURE%'
       OR status LIKE '%OVERHEAT_RISK%' OR status LIKE '%SERVICE_REQUIRED%'
       OR status LIKE '%DEGRADATION_LIKELY%' OR status LIKE '%ALIGNMENT_LIKELY%'
       OR status = 'INVERTER_OVERHEAT_RISK' OR status = 'ALERT_SPIKE'
       OR status = 'PERSISTENT_ISSUES' THEN
      s := 90;
    ELSIF status LIKE '%DEGRADED%' OR status LIKE '%RECOMMENDED%'
       OR status LIKE '%ANOMALY%' OR status LIKE '%IMBALANCE_DETECTED%'
       OR status LIKE '%IMBALANCE_LIKELY%'
       OR status LIKE '%THROTTLING_RISK%'
       OR status LIKE '%LOOSENESS_LIKELY%' THEN
      s := 65;
    ELSIF status LIKE '%WARNING%' OR status LIKE '%SPIKE%'
       OR status LIKE '%PERSISTENT%' THEN
      s := 40;
    ELSIF status = 'NORMAL' OR status = 'HEALTHY' OR status = 'NOT_APPLICABLE' THEN
      s := 5;
    ELSE
      s := 10;
    END IF;
  END IF;

  -- Severity override
  IF severity = 'CRITICAL' THEN
    s := GREATEST(s, 95);
  ELSIF severity = 'URGENT' THEN
    s := GREATEST(s, 75);
  ELSIF severity = 'WARNING' THEN
    s := GREATEST(s, 40);
  END IF;

  -- Numeric modifier (callers pass a normalised positive value)
  IF degradation_pct IS NOT NULL AND degradation_pct > 0 THEN
    s := LEAST(100, s + (degradation_pct / 3)::INTEGER);
  END IF;

  IF brick_delta IS NOT NULL AND brick_delta > 0.3 THEN
    s := s + 15;
  END IF;

  RETURN LEAST(100, GREATEST(0, s));
END;
$$;

COMMENT ON FUNCTION subsystem_risk_score(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) IS
  'Status/severity -> 0-100 risk. Base score from pm_status_dictionary when the
   status is listed there, otherwise the LIKE-pattern fallback (039).';

-- ------------------------------------------------------------------
-- brake_wear_estimate — as 033, remaining_pct clamped.
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
  -- Clamped to [0, 100] like wear_pct (S3): a regen ratio above 1 used to
  -- give a remaining percentage above 100 next to a wear of 0.
  ROUND(LEAST(100, GREATEST(0,
      100 - (odometer / 50000.0 * (1 - COALESCE(recent_regen_ratio, regen_ratio)) * 100)
    ))::numeric, 1) AS remaining_pct,
  -- Estimated pad life remaining (miles)
  -- Remaining distance derived from the same wear equation.
  --
  -- wear_pct = odometer / 50000 * wear_factor * 100, so wear reaches 100%
  -- at odometer = 50000 / wear_factor and the remainder is
  -- 50000 / wear_factor - odometer. The previous expression was
  -- wear_factor * (50000 - odometer), which contradicts the wear column it
  -- sits next to: at 25,000 mi with a 0.5 regen ratio it reported 12,500 mi
  -- left while wear_pct said 25% used, implying 75,000. A wear_factor of
  -- zero (all braking regenerative) has no finite answer and yields NULL.
  ROUND(GREATEST(0, 50000.0 / NULLIF(1 - COALESCE(recent_regen_ratio, regen_ratio), 0) - odometer)::numeric, 0)
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
-- predictive_health_recommendations — as 033 plus S2/S3 changes.
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW predictive_health_recommendations AS
SELECT
  vin,
  'Battery' AS subsystem,
  battery_risk AS risk_score,
  CASE
    WHEN battery_risk >= 85 THEN 'CRITICAL'
    WHEN battery_risk >= 60 THEN 'WARNING'
    WHEN battery_risk >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END AS severity,
  CASE
    WHEN battery_risk >= 85 THEN 'Schedule battery pack inspection — capacity fade > 10% or brick imbalance > 0.5 V'
    WHEN battery_risk >= 60 THEN 'Monitor battery health — schedule diagnostic scan at next service'
    WHEN battery_risk >= 40 THEN 'Check tire pressure and alignment — slight efficiency drop detected'
    ELSE 'No action required'
  END AS recommendation
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Powertrain',
  powertrain_risk,
  CASE
    WHEN powertrain_risk >= 85 THEN 'CRITICAL'
    WHEN powertrain_risk >= 60 THEN 'WARNING'
    WHEN powertrain_risk >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN powertrain_risk >= 85 THEN 'Schedule drivetrain inspection — inverter overheat or regen degradation detected'
    WHEN powertrain_risk >= 60 THEN 'Monitor motor temps and regen torque — schedule check if trend continues'
    WHEN powertrain_risk >= 40 THEN 'Verify charging performance — possible PCS derating'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Thermal',
  thermal_risk,
  CASE
    WHEN thermal_risk >= 85 THEN 'CRITICAL'
    WHEN thermal_risk >= 60 THEN 'WARNING'
    WHEN thermal_risk >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN thermal_risk >= 85 THEN 'Inspect HVAC system — heat pump degradation or battery thermal imbalance'
    WHEN thermal_risk >= 60 THEN 'Check cabin filter and refrigerant levels — efficiency declining'
    WHEN thermal_risk >= 40 THEN 'Verify pre-conditioning settings — minor thermal inefficiency'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  '12V / Electrical',
  low_voltage_score,
  CASE
    WHEN low_voltage_score >= 60 THEN 'WARNING'
    WHEN low_voltage_score >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    -- The 12V score is a DC-DC activity proxy while parked (031), not a
    -- capacity measurement: it can justify a diagnosis, not a replacement.
    WHEN low_voltage_score >= 60 THEN 'Have the 12V / low-voltage system diagnosed — DC-DC converter active unusually often while parked (activity proxy, not a battery capacity test)'
    WHEN low_voltage_score >= 40 THEN 'Monitor 12V system — DC-DC activity while parked increasing'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Suspension',
  suspension_score,
  -- CRITICAL band added so the severity agrees with the "Immediate" text.
  CASE
    WHEN suspension_score >= 85 THEN 'CRITICAL'
    WHEN suspension_score >= 60 THEN 'WARNING'
    ELSE 'OK'
  END,
  CASE
    WHEN suspension_score >= 85 THEN 'Immediate alignment check — chassis alert UI_a006 active'
    WHEN suspension_score >= 60 THEN 'Schedule alignment and bushing inspection — steering offset increasing'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Air Suspension',
  air_suspension_score,
  CASE
    WHEN air_suspension_score >= 85 THEN 'CRITICAL'
    WHEN air_suspension_score >= 60 THEN 'WARNING'
    WHEN air_suspension_score >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN air_suspension_score >= 85 THEN 'Inspect air suspension immediately — compressor failure or severe leak suspected'
    WHEN air_suspension_score >= 60 THEN 'Schedule air-suspension check — compressor over-cycling or ride-height drift detected'
    WHEN air_suspension_score >= 40 THEN 'Monitor air suspension — slight increase in compressor activity'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Dual Motor',
  dual_motor_score,
  CASE
    WHEN dual_motor_score >= 85 THEN 'CRITICAL'
    WHEN dual_motor_score >= 60 THEN 'WARNING'
    WHEN dual_motor_score >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN dual_motor_score >= 85 THEN 'Inspect dual-motor system immediately — severe imbalance or thermal throttling detected'
    WHEN dual_motor_score >= 60 THEN 'Schedule dual-motor inspection — front-rear imbalance, regen degradation, or throttle limiting'
    WHEN dual_motor_score >= 40 THEN 'Monitor dual-motor balance — slight temp delta or regen trend detected'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Cybertruck',
  cybertruck_score,
  CASE
    WHEN cybertruck_score >= 85 THEN 'CRITICAL'
    WHEN cybertruck_score >= 60 THEN 'WARNING'
    WHEN cybertruck_score >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN cybertruck_score >= 85 THEN 'Inspect Cybertruck immediately — tonneau failure, severe tri-motor imbalance, or 4680 battery degradation'
    WHEN cybertruck_score >= 60 THEN 'Schedule Cybertruck inspection — tonneau, V2L, air suspension, or tri-motor issue detected'
    WHEN cybertruck_score >= 40 THEN 'Monitor Cybertruck subsystems — slight anomaly in tonneau, V2L, or tri-motor'
    ELSE 'No action required'
  END
FROM predictive_health_summary

UNION ALL

SELECT
  vin,
  'Brakes',
  LEAST(100, GREATEST(0, 100 - COALESCE(brake_remaining_pct, 100)))::INTEGER,
  CASE
    WHEN COALESCE(brake_remaining_pct, 100) <= 25 THEN 'CRITICAL'
    WHEN COALESCE(brake_remaining_pct, 100) <= 50 THEN 'WARNING'
    WHEN COALESCE(brake_remaining_pct, 100) <= 75 THEN 'CAUTION'
    ELSE 'OK'
  END,
  -- Wording, not thresholds. brake_remaining_pct is odometer divided by an
  -- assumed 50,000-mile pad life and scaled by a regen-energy ratio: it is
  -- not a measurement of pad thickness or of friction-braking work, and it
  -- never resets when pads are replaced. It cannot support "replace
  -- immediately", so each level now asks for an inspection at a proportionate
  -- urgency and says what the number is.
  CASE
    WHEN COALESCE(brake_remaining_pct, 100) <= 25 THEN 'Have brake pads measured now — mileage-based estimate below 25% (unvalidated: assumes 50,000 mi pad life, ignores past replacements)'
    WHEN COALESCE(brake_remaining_pct, 100) <= 50 THEN 'Have brake pads measured at the next service — mileage-based estimate near 50%'
    WHEN COALESCE(brake_remaining_pct, 100) <= 75 THEN 'Inspect brake pads at next service'
    ELSE 'No action required'
  END
FROM regen_brake_summary

UNION ALL

-- HV isolation (S2). Latest daily minimum from isolation_resistance_diagnostics,
-- scored through the status dictionary. The 100 kOhm / 250 kOhm thresholds in
-- 025 are not tied to a published Tesla specification, so the text says so.
SELECT
  i.vin,
  'HV Isolation',
  subsystem_risk_score(i.status),
  CASE
    WHEN subsystem_risk_score(i.status) >= 85 THEN 'CRITICAL'
    WHEN subsystem_risk_score(i.status) >= 60 THEN 'WARNING'
    WHEN subsystem_risk_score(i.status) >= 40 THEN 'CAUTION'
    ELSE 'OK'
  END,
  CASE
    WHEN i.status = 'ISOLATION_RESISTANCE_LOW' THEN 'Have the HV isolation checked by Tesla service — isolation resistance below 100 kOhm (unvalidated threshold)'
    WHEN i.status = 'WARNING' THEN 'Monitor HV isolation resistance — below 250 kOhm (unvalidated threshold)'
    ELSE 'No action required'
  END
FROM (
  SELECT DISTINCT ON (vin) vin, status
  FROM isolation_resistance_diagnostics
  WHERE status <> 'NO_DATA'
  ORDER BY vin, ts DESC
) i;
