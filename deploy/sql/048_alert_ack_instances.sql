-- ============================================================
-- 048_alert_ack_instances.sql — acknowledgements belong to one alert
-- instance and stop applying when it ends (S6, FINDINGS 13)
--
-- 025's pm_alert_ack matched on (vin, alert_key) for 30 days: one ack
-- hid every later occurrence of the same code, outlived the alert it
-- was given for, and only the dashboard-14 table honoured it — the
-- summary and alert_critical_active still counted the alert.
--
-- Now:
--   * pm_alert_ack.alert_started_at ties an ack to one instance
--     (vehicle_alerts.started_at, which 034 made the row key). A new
--     occurrence has a new started_at and is not covered.
--   * alert_is_acknowledged(vin, code, started_at) is the single test,
--     used by alert_critical_active (so the summary and dashboard 12)
--     and by the dashboard-14 table: an unexpired ack for that
--     instance, or a legacy code-wide ack (alert_started_at NULL, as
--     ack_pm_alert writes) given after the instance started.
--   * An ack only matters while the instance is active (parsed_alerts
--     .is_active needs ended_at IS NULL); pm_alert_ack_active also drops
--     instance acks whose alert has ended.
--   * ack_alert_instance(vin, code, started_at, days, reason) writes the
--     new form.
--
-- Column lists of parsed_alerts, alert_critical_active and
-- pm_alert_ack_active are unchanged on purpose: 012/025/034 replace
-- those views on a FORCE=1 re-run and would fail on a different list.
-- Production had no acknowledgement rows when this was written.
-- Idempotent.
-- ============================================================

ALTER TABLE pm_alert_ack ADD COLUMN IF NOT EXISTS alert_started_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS pm_alert_ack_instance_idx
  ON pm_alert_ack (vin, alert_key, alert_started_at);
COMMENT ON COLUMN pm_alert_ack.alert_started_at IS
  'started_at of the vehicle_alerts instance this ack covers; NULL = legacy code-wide ack (048)';

CREATE OR REPLACE FUNCTION alert_is_acknowledged(p_vin TEXT, p_alert_code TEXT, p_started_at TIMESTAMPTZ)
RETURNS boolean LANGUAGE sql STABLE SET search_path = public, pg_catalog AS $$
  SELECT EXISTS (
    SELECT 1 FROM pm_alert_ack k
    WHERE k.vin = p_vin AND k.alert_key = p_alert_code
      AND k.acknowledged_until > now()
      AND (k.alert_started_at = p_started_at
           OR (k.alert_started_at IS NULL AND k.acknowledged_at >= p_started_at)))
$$;
COMMENT ON FUNCTION alert_is_acknowledged(TEXT, TEXT, TIMESTAMPTZ) IS
  'True when alert instance (vin, code, started_at) has an unexpired acknowledgement (048).
   Pass COALESCE(started_at, ts) from parsed_alerts / vehicle_alerts.';

CREATE OR REPLACE VIEW pm_alert_ack_active AS
SELECT k.vin, k.subsystem, k.alert_key, k.acknowledged_until, k.reason
FROM pm_alert_ack k
WHERE k.acknowledged_until > now()
  AND (k.alert_started_at IS NULL
       OR EXISTS (SELECT 1 FROM vehicle_alerts a
                  WHERE a.vin = k.vin AND a.name = k.alert_key
                    AND a.ts = k.alert_started_at AND a.ended_at IS NULL));

CREATE OR REPLACE FUNCTION ack_alert_instance(
  p_vin        TEXT,
  p_alert_code TEXT,
  p_started_at TIMESTAMPTZ,
  p_days       INTEGER DEFAULT 30,
  p_reason     TEXT    DEFAULT NULL,
  p_by         TEXT    DEFAULT current_user
) RETURNS pm_alert_ack
LANGUAGE plpgsql SET search_path = public, pg_catalog AS $$
DECLARE
  r pm_alert_ack;
  sub text;
BEGIN
  SELECT pa.subsystem INTO sub FROM parsed_alerts pa
  WHERE pa.vin = p_vin AND pa.alert_code = p_alert_code
    AND COALESCE(pa.started_at, pa.ts) = p_started_at
  LIMIT 1;
  IF sub IS NULL THEN
    RAISE EXCEPTION 'no alert % for this vehicle started at %', p_alert_code, p_started_at;
  END IF;
  INSERT INTO pm_alert_ack (vin, subsystem, alert_key, alert_started_at, acknowledged_by, acknowledged_until, reason)
  VALUES (p_vin, sub, p_alert_code, p_started_at, p_by, now() + make_interval(days => p_days), p_reason)
  RETURNING * INTO r;
  RETURN r;
END $$;
COMMENT ON FUNCTION ack_alert_instance IS
  'Acknowledge one alert instance (vin, code, started_at) for p_days (default 30).
   It stops applying when the instance ends or the days run out (048).';

-- Active = is_active and not acknowledged. Same columns as 012.
CREATE OR REPLACE VIEW alert_critical_active AS
WITH a AS (
  SELECT pa.*,
         pa.is_active AND NOT alert_is_acknowledged(pa.vin, pa.alert_code, COALESCE(pa.started_at, pa.ts)) AS open_unacked
  FROM parsed_alerts pa
)
SELECT
  vin,
  COUNT(*) FILTER (WHERE severity = 'CRITICAL' AND open_unacked) AS critical_active,
  COUNT(*) FILTER (WHERE severity = 'URGENT'   AND open_unacked) AS urgent_active,
  COUNT(*) FILTER (WHERE severity = 'WARNING'  AND open_unacked) AS warning_active,
  COUNT(*) FILTER (WHERE open_unacked) AS total_active,
  STRING_AGG(DISTINCT alert_code, ', ' ORDER BY alert_code)
    FILTER (WHERE severity = 'CRITICAL' AND open_unacked) AS critical_codes,
  STRING_AGG(DISTINCT alert_code, ', ' ORDER BY alert_code)
    FILTER (WHERE severity = 'URGENT' AND open_unacked) AS urgent_codes,
  MAX(ts) FILTER (WHERE severity = 'CRITICAL' AND open_unacked) AS latest_critical_ts,
  MAX(ts) FILTER (WHERE open_unacked) AS latest_active_ts
FROM a
GROUP BY vin;
