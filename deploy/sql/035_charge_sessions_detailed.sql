-- ============================================================
-- 035_charge_sessions_detailed.sql — charge sessions from
-- DetailedChargeState, ended by the terminating row (P2)
--
-- 002 built charge_sessions on ChargeState IN ('Charging','Starting').
-- Fleet Telemetry's ChargeState is the charger state machine
-- (ChargeStateIdle / Enable / ClearFaults / Shutdown / Startup /
-- QualifyLineConfig, stored with the proto prefix); it never carries
-- 'Charging', so the view returned no rows. It also ended a session at
-- the last *charging* sample, which on a change-based stream (one row
-- when charging starts, one when it stops) collapses the duration to
-- about zero.
--
-- New definition:
--   * Source is DetailedChargeState. The proto prefix is stripped, so
--     both 'DetailedChargeStateCharging' and a bare 'Charging' match.
--   * A session starts at a transition into Starting or Charging.
--   * It ends at the first later row whose state is neither (Complete,
--     Stopped, Disconnected, NoPower, Unknown ...). That row's ts is
--     `ended`.
--   * A session with no terminating row yet is OPEN: `ended` is NULL
--     and `duration` is the time charged so far (now() - started), so
--     the energy dashboard shows a growing minute count for the
--     session in progress rather than a blank.
--
-- Column names, order and types are unchanged (vin text, session_id
-- bigint, started/ended timestamptz, duration interval), so
-- 04_energy.json keeps working.
--
-- parsed_alerts.charge_state_at_alert was switched to
-- DetailedChargeState in 034 (same full-view rewrite as the P3 fix).
--
-- Idempotent.
-- ============================================================

CREATE OR REPLACE VIEW charge_sessions AS
WITH s AS (
  SELECT ts, vin,
         regexp_replace(str_value, '^DetailedChargeState', '') AS state
  FROM telemetry
  WHERE field = 'DetailedChargeState'
    AND str_value IS NOT NULL
), flagged AS (
  SELECT ts, vin, state,
         state IN ('Starting', 'Charging') AS charging,
         LAG(state IN ('Starting', 'Charging'))
           OVER (PARTITION BY vin ORDER BY ts) AS prev_charging
  FROM s
), numbered AS (
  SELECT ts, vin, charging,
         -- every transition into a charging state opens a new session;
         -- rows before the first one get session 0 and are dropped
         COUNT(*) FILTER (WHERE charging AND prev_charging IS DISTINCT FROM TRUE)
           OVER (PARTITION BY vin ORDER BY ts) AS session_id
  FROM flagged
), sessions AS (
  SELECT
    vin,
    session_id,
    MIN(ts) AS started,
    -- the first non-charging row after the start terminates the session
    MIN(ts) FILTER (WHERE NOT charging) AS ended
  FROM numbered
  WHERE session_id > 0
  GROUP BY vin, session_id
)
SELECT
  vin,
  session_id,
  started,
  ended,
  COALESCE(ended, now()) - started AS duration
FROM sessions;

COMMENT ON VIEW charge_sessions IS
  'One row per charging session from DetailedChargeState. Starts at a
   transition into Starting/Charging, ends at the first later row in any
   other state. ended IS NULL means the session is still open; duration is
   then the time charged so far.';
