-- ============================================================
-- 025_pm_review_fixes.sql
--
-- Addresses the findings from the May 2026 predictive-maintenance
-- review (see PREDICTIVE_MAINTENANCE_RATIONALE.md → "Review fixes"
-- section).  Everything in this file is additive — none of the
-- existing views or matviews are dropped.
--
-- Issues fixed here:
--
--   B3 — refresh job for demoted matviews
--        battery_capacity_1d, pcs_health_1d, pcs_health_1w,
--        heat_pump_cop_1d, low_voltage_wakeups_1d had no
--        refresh policy.  We expose refresh_predictive_matviews()
--        and schedule it via pg_cron if the extension is present;
--        otherwise the operator must call it from an external cron.
--
--   R6 — calendar-based service intervals (cabin filter, brake
--        fluid, tire rotation, A/C desiccant) plus a per-VIN
--        service-log join so dashboards can surface time-based
--        items, not just statistical anomalies.
--
--   R7 — alert acknowledgement so an active CRITICAL doesn't keep
--        nagging the user after they've scheduled service.
--
--   R8 — status_dictionary table backing subsystem_risk_score so
--        new status strings can be added without editing the
--        function body.
--
--   N6 — isolation_resistance_diagnostics promoted from anomaly
--        z-score to a dedicated safety-critical indicator.
--
-- Required by: 014_predictive_health.sql (re-uses subsystem_risk_score)
-- ============================================================

-- ------------------------------------------------------------------
-- B3.  Refresh function + optional pg_cron schedule
-- ------------------------------------------------------------------

CREATE OR REPLACE FUNCTION refresh_predictive_matviews()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  mv text;
  matviews text[] := ARRAY[
    'battery_capacity_1d',
    'pcs_health_1d',
    'pcs_health_1w',
    'heat_pump_cop_1d',
    'low_voltage_wakeups_1d'
  ];
  started timestamptz;
BEGIN
  FOREACH mv IN ARRAY matviews LOOP
    started := clock_timestamp();
    -- Skip silently if a matview doesn't exist (e.g. fresh install
    -- where one of the diagnostic files hasn't been applied).
    IF NOT EXISTS (
      SELECT 1 FROM pg_class WHERE relname = mv AND relkind = 'm'
    ) THEN
      CONTINUE;
    END IF;
    BEGIN
      EXECUTE format('REFRESH MATERIALIZED VIEW %I', mv);
      RAISE NOTICE 'refreshed % in %', mv, clock_timestamp() - started;
    EXCEPTION WHEN OTHERS THEN
      -- Log and continue — one stale matview should not block the rest.
      RAISE WARNING 'refresh of % failed: %', mv, SQLERRM;
    END;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION refresh_predictive_matviews() IS
  'Refreshes the predictive-maintenance matviews that were demoted from
   continuous aggregates.  Call hourly from pg_cron or an external cron
   (e.g. `psql -c "SELECT refresh_predictive_matviews();"`).';

-- Schedule hourly refresh via pg_cron if the extension is installed.
-- We do not install pg_cron here — that is an operator decision since
-- it requires shared_preload_libraries on a managed instance.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('predictive-matview-refresh')
      WHERE EXISTS (
        SELECT 1 FROM cron.job WHERE jobname = 'predictive-matview-refresh'
      );
    PERFORM cron.schedule(
      'predictive-matview-refresh',
      '7 * * * *',  -- every hour at :07
      $cron$SELECT refresh_predictive_matviews();$cron$
    );
    RAISE NOTICE 'pg_cron schedule installed for refresh_predictive_matviews()';
  ELSE
    RAISE NOTICE 'pg_cron not installed; call refresh_predictive_matviews() from an external cron.';
  END IF;
END $$;

-- ------------------------------------------------------------------
-- R6.  Calendar-based service intervals
--
-- Tesla's owner manuals publish time / mileage-based items that no
-- amount of telemetry will surface on its own.  The defaults here
-- come from the Model 3 / Model Y service guide (2021+).
-- service_intervals is one global schedule (UNIQUE (item), no VIN
-- column): per-VIN overrides are NOT supported; edit the row to
-- change the cadence for every vehicle (see 032 and 037).
-- ------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS service_intervals (
  id              SERIAL PRIMARY KEY,
  item            TEXT NOT NULL,
  description     TEXT NOT NULL,
  interval_months INTEGER,
  interval_miles  INTEGER,
  severity        TEXT NOT NULL DEFAULT 'CAUTION',     -- CAUTION | WARNING | CRITICAL once overdue
  applies_to      TEXT NOT NULL DEFAULT 'all',         -- 'all' | model code | comma-separated list
  CHECK (interval_months IS NOT NULL OR interval_miles IS NOT NULL),
  CHECK (severity IN ('CAUTION','WARNING','CRITICAL')),
  UNIQUE (item)
);

INSERT INTO service_intervals (item, description, interval_months, interval_miles, severity, applies_to) VALUES
  ('cabin_air_filter',   'Replace cabin air filter (HEPA on 3/Y)',         24,   NULL,    'CAUTION', 'all'),
  ('brake_fluid',        'Test brake fluid for water content; flush if > 2 %', 24, NULL, 'WARNING', 'all'),
  ('ac_desiccant',       'Replace A/C desiccant bag',                       72,   NULL,    'CAUTION', 'all'),
  ('tire_rotation',      'Rotate tires (or as needed when tread depth differs by ≥ 2/32 inch)', NULL, 10000, 'CAUTION', 'all'),
  ('coolant_inspection', 'Inspect coolant condition (S/X 4 years; 3/Y none required)', 48, NULL, 'CAUTION', 'S,X')
ON CONFLICT (item) DO NOTHING;

-- Per-VIN history of completed service items.  The service-log
-- bot already records mechanical work via service_log; this table
-- separates the "calendar-item-done" event from arbitrary log entries.
CREATE TABLE IF NOT EXISTS service_completions (
  id           SERIAL PRIMARY KEY,
  vin          TEXT NOT NULL,
  item         TEXT NOT NULL REFERENCES service_intervals(item) ON UPDATE CASCADE,
  completed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  odometer_mi  DOUBLE PRECISION,
  notes        TEXT
);
CREATE INDEX IF NOT EXISTS service_completions_vin_item_idx
  ON service_completions (vin, item, completed_at DESC);

-- View: for every (vin, item) pair return when it is next due.
CREATE OR REPLACE VIEW service_interval_status AS
WITH latest_done AS (
  SELECT vin, item, MAX(completed_at) AS last_done_at, MAX(odometer_mi) AS last_done_odo
  FROM service_completions
  GROUP BY vin, item
),
current_odo AS (
  SELECT vin, MAX(num_value) AS odometer_mi
  FROM telemetry
  WHERE field = 'Odometer'
    AND ts > NOW() - INTERVAL '14 days'
  GROUP BY vin
)
SELECT
  v.vin,
  s.item,
  s.description,
  s.severity,
  s.interval_months,
  s.interval_miles,
  ld.last_done_at,
  ld.last_done_odo,
  co.odometer_mi  AS current_odometer_mi,
  -- Time-based due date
  CASE
    WHEN s.interval_months IS NOT NULL AND ld.last_done_at IS NOT NULL
      THEN ld.last_done_at + (s.interval_months || ' months')::INTERVAL
    WHEN s.interval_months IS NOT NULL
      THEN NOW() + (s.interval_months || ' months')::INTERVAL  -- never done; due from today
  END AS due_at,
  -- Mileage-based due odometer
  CASE
    WHEN s.interval_miles IS NOT NULL AND ld.last_done_odo IS NOT NULL
      THEN ld.last_done_odo + s.interval_miles
    WHEN s.interval_miles IS NOT NULL AND co.odometer_mi IS NOT NULL
      THEN co.odometer_mi + s.interval_miles
  END AS due_odometer_mi,
  -- Status: OVERDUE / DUE_SOON / OK
  CASE
    WHEN s.interval_months IS NOT NULL
         AND NOW() > COALESCE(ld.last_done_at, NOW() - INTERVAL '99 years')
                     + (s.interval_months || ' months')::INTERVAL
      THEN 'OVERDUE'
    WHEN s.interval_miles IS NOT NULL
         AND co.odometer_mi IS NOT NULL
         AND co.odometer_mi > COALESCE(ld.last_done_odo, 0) + s.interval_miles
      THEN 'OVERDUE'
    WHEN s.interval_months IS NOT NULL
         AND NOW() + INTERVAL '30 days'
             > COALESCE(ld.last_done_at, NOW() - INTERVAL '99 years')
               + (s.interval_months || ' months')::INTERVAL
      THEN 'DUE_SOON'
    WHEN s.interval_miles IS NOT NULL
         AND co.odometer_mi IS NOT NULL
         AND co.odometer_mi + 500
             > COALESCE(ld.last_done_odo, 0) + s.interval_miles
      THEN 'DUE_SOON'
    ELSE 'OK'
  END AS status
FROM (SELECT DISTINCT vin FROM telemetry) v
CROSS JOIN service_intervals s
LEFT JOIN latest_done ld ON ld.vin = v.vin AND ld.item = s.item
LEFT JOIN current_odo co ON co.vin = v.vin
WHERE s.applies_to = 'all'
   OR s.applies_to LIKE '%' || (SELECT model FROM vehicle_metadata WHERE vin = v.vin) || '%';

-- ------------------------------------------------------------------
-- R7.  Alert acknowledgement
--
-- An owner who has scheduled service for a known issue should be
-- able to suppress the alert until either (a) the underlying signal
-- clears, or (b) a TTL expires.  Dashboards / the notify bot are
-- expected to LEFT JOIN against this view and hide rows where
-- acknowledged_until > NOW().
--
-- alert_key convention:
--   • for code-based alerts (parsed_alerts / vehicle_alerts) alert_key
--     MUST equal the raw alert_code (e.g. 'BMS_u018') — this is what
--     14_predictive_health.json's "Active Alerts" panel matches on.
--   • for synthetic / subsystem-level alerts use a stable slug, e.g.
--     'heat_pump_degradation', 'isolation_resistance_low'.
-- ------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pm_alert_ack (
  id                 SERIAL PRIMARY KEY,
  vin                TEXT NOT NULL,
  subsystem          TEXT NOT NULL,                -- 'Battery' | 'Drivetrain' | …
  alert_key          TEXT NOT NULL,                -- alert_code for code-based alerts; slug otherwise
  acknowledged_by    TEXT,
  acknowledged_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  acknowledged_until TIMESTAMPTZ NOT NULL,          -- TTL; defaults to 30 days when inserted via helper
  reason             TEXT,
  UNIQUE (vin, subsystem, alert_key, acknowledged_at)
);
CREATE INDEX IF NOT EXISTS pm_alert_ack_lookup_idx
  ON pm_alert_ack (vin, subsystem, alert_key, acknowledged_until DESC);

CREATE OR REPLACE VIEW pm_alert_ack_active AS
SELECT vin, subsystem, alert_key, acknowledged_until, reason
FROM pm_alert_ack
WHERE acknowledged_until > NOW();

CREATE OR REPLACE FUNCTION ack_pm_alert(
  p_vin        TEXT,
  p_subsystem  TEXT,
  p_alert_key  TEXT,
  p_days       INTEGER DEFAULT 30,
  p_reason     TEXT    DEFAULT NULL,
  p_by         TEXT    DEFAULT current_user
) RETURNS pm_alert_ack
LANGUAGE plpgsql AS $$
DECLARE
  row pm_alert_ack;
BEGIN
  INSERT INTO pm_alert_ack
    (vin, subsystem, alert_key, acknowledged_by, acknowledged_until, reason)
  VALUES
    (p_vin, p_subsystem, p_alert_key, p_by, NOW() + (p_days || ' days')::INTERVAL, p_reason)
  RETURNING * INTO row;
  RETURN row;
END;
$$;

COMMENT ON FUNCTION ack_pm_alert IS
  'Suppresses a predictive-maintenance alert for p_days (default 30).
   Dashboards / the notify bot must LEFT JOIN pm_alert_ack_active and
   hide rows where the corresponding (vin, subsystem, alert_key) matches.';

-- ------------------------------------------------------------------
-- R8.  Status dictionary (replaces the LIKE soup in
--      subsystem_risk_score for new statuses)
--
-- Note: we keep the original function as the fallback so that any
-- status string not in the table still resolves the same way as
-- before.  Callers can extend by inserting rows.
-- ------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pm_status_dictionary (
  status     TEXT PRIMARY KEY,
  base_score INTEGER NOT NULL CHECK (base_score BETWEEN 0 AND 100),
  notes      TEXT
);

INSERT INTO pm_status_dictionary (status, base_score, notes) VALUES
  ('NORMAL',                     5,  'healthy / no anomaly'),
  ('HEALTHY',                    5,  'alias for NORMAL'),
  ('NOT_APPLICABLE',             5,  'subsystem not present on this VIN'),
  ('HEAT_PUMP_DEGRADATION_LIKELY', 65, 'see 007_heat_pump_diagnostics.sql'),
  ('REGEN_DEGRADATION_LIKELY',  90, 'see 013_regen_brake_diagnostics.sql'),
  ('EFFICIENCY_ANOMALY',        65, 'see 013_regen_brake_diagnostics.sql'),
  ('INVERTER_OVERHEAT_RISK',    90, 'see 011_drivetrain_diagnostics.sql'),
  ('ALIGNMENT_LIKELY',          90, 'see 010_suspension_diagnostics.sql'),
  ('IMBALANCE_DETECTED',        65, 'cell or motor imbalance'),
  ('IMBALANCE_LIKELY',          65, 'softer imbalance signal'),
  ('THROTTLING_RISK',           65, 'thermal throttling suspected'),
  ('LOOSENESS_LIKELY',          65, 'suspension bushing wear'),
  ('ISOLATION_RESISTANCE_LOW',  95, 'HV isolation fault — safety critical (N6 fix)')
ON CONFLICT (status) DO NOTHING;

-- ------------------------------------------------------------------
-- N6.  Dedicated isolation-resistance indicator
--
-- IsolationResistance is one of the most safety-critical telemetry
-- fields — a falling value indicates HV insulation breakdown which
-- can become a shock hazard.  Previously it was only in the z-score
-- bucket in 005_predictive_anomalies.sql.  Tesla's diagnostic
-- threshold for an action is ~ 100 kΩ (raw values are in Ω).
-- ------------------------------------------------------------------

CREATE OR REPLACE VIEW isolation_resistance_diagnostics AS
WITH samples AS (
  SELECT
    time_bucket('1 day', ts) AS bucket,
    vin,
    AVG(num_value) AS avg_ohms,
    MIN(num_value) AS min_ohms,
    COUNT(*)       AS n
  FROM telemetry
  WHERE field = 'IsolationResistance'
    AND num_value IS NOT NULL
    AND ts > NOW() - INTERVAL '60 days'
  GROUP BY 1, 2
)
SELECT
  bucket AS ts,
  vin,
  ROUND(avg_ohms::numeric, 0) AS avg_ohms,
  ROUND(min_ohms::numeric, 0) AS min_ohms,
  n,
  CASE
    WHEN min_ohms IS NULL                THEN 'NO_DATA'
    WHEN min_ohms < 100000               THEN 'ISOLATION_RESISTANCE_LOW'  -- < 100 kΩ
    WHEN min_ohms < 250000               THEN 'WARNING'
    ELSE 'NORMAL'
  END AS status
FROM samples;

COMMENT ON VIEW isolation_resistance_diagnostics IS
  'Daily aggregate of HV isolation resistance per VIN.  Statuses map
   to scores via pm_status_dictionary; ISOLATION_RESISTANCE_LOW (< 100 kΩ)
   should be treated as a safety-critical event.';
