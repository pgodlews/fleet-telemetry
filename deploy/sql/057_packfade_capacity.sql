-- ============================================================
-- 057_packfade_capacity.sql — EXPERIMENTAL pack-capacity fade estimate
-- (method adapted from Packfade, https://github.com/pgodlews/packfade,
-- MIT licence, by the same author)
--
-- Observable: for one drive, apparent capacity = energy that left the
-- pack (trapezoidal integral of PackVoltage x PackCurrent) / fraction of
-- SOC used. Route, wind and load cancel because both numerator and
-- denominator come from the same discharge.
--
-- Segment definition: one drive (trips_mat), measured between the first
-- and the last Soc sample inside the drive. The alternative (contiguous
-- discharge between charge sessions, including parked drain) was measured
-- on production data (Nov 2026) and rejected: the car sends no samples
-- while asleep, so only 10-58 % of such a segment is covered by power
-- samples, and the >= 20 % SOC segments scatter about 4x more (IQR 16 %
-- vs 3.5 % for single drives). See deploy/README.md "Experimental:
-- capacity fade (Packfade method)".
--
-- Objects:
--   * packfade_segments — one row per drive with the raw measures; no
--     eligibility decision (the notify daemon applies the rules and
--     records the reason per observation). Read once a day by the daemon,
--     not by dashboards.
--   * packfade_estimate — one row per computation and variant ('all',
--     'calibrated_start').
--   * packfade_points — per-observation normalised capacity of the latest
--     computation (variant 'all').
--   * packfade_curve — fitted curve and 95 % band of the latest
--     computation (variant 'all').
-- Written by tools/notify (daily, and on demand with --packfade-once).
-- Not part of the predictive health score.
--
-- Idempotent.
-- ============================================================

CREATE OR REPLACE VIEW packfade_segments AS
WITH w AS (
  SELECT t.vin, t.trip_id, t.started, t.ended, t.distance_km,
         f.ts AS s0, f.soc AS soc0, l.ts AS s1, l.soc AS soc1
  FROM trips_mat t
  CROSS JOIN LATERAL (
    SELECT x.ts, x.num_value AS soc FROM telemetry x
    WHERE x.vin = t.vin AND x.field = 'Soc' AND x.num_value IS NOT NULL
      AND x.ts BETWEEN t.started AND t.ended
    ORDER BY x.ts LIMIT 1) f
  CROSS JOIN LATERAL (
    SELECT x.ts, x.num_value AS soc FROM telemetry x
    WHERE x.vin = t.vin AND x.field = 'Soc' AND x.num_value IS NOT NULL
      AND x.ts BETWEEN t.started AND t.ended
    ORDER BY x.ts DESC LIMIT 1) l
  WHERE l.ts > f.ts
)
SELECT
  w.vin, w.trip_id,
  w.s0 AS seg_start, w.s1 AS seg_end,
  ROUND(w.soc0::numeric, 3) AS soc_start,
  ROUND(w.soc1::numeric, 3) AS soc_end,
  ROUND((w.soc0 - w.soc1)::numeric, 3) AS soc_drop,
  ROUND(e.e_out_kwh::numeric, 4) AS energy_out_kwh,          -- net energy out of the pack (regen subtracted)
  ROUND(e.e_regen_kwh::numeric, 4) AS energy_in_kwh,         -- energy into the pack (regen, or charging)
  ROUND(e.covered_s::numeric, 0) AS covered_s,
  ROUND((e.covered_s / NULLIF(extract(epoch FROM w.s1 - w.s0), 0))::numeric, 3) AS coverage,
  CASE WHEN w.soc0 - w.soc1 > 0
       THEN ROUND((e.e_out_kwh / ((w.soc0 - w.soc1) / 100.0))::numeric, 3) END AS apparent_capacity_kwh,
  ROUND(COALESCE(tmp.avg_t, tmp.last_t)::numeric, 2) AS outside_temp_c,
  ROUND(((w.soc0 + w.soc1) / 2.0)::numeric, 2) AS mean_soc,
  ROUND((e.e_out_kwh / NULLIF(e.covered_s / 3600.0, 0))::numeric, 3) AS mean_power_kw,
  w.distance_km,
  ROUND((extract(epoch FROM w.s0 - fc.ts) / 3600.0)::numeric, 2) AS hours_since_full_charge,
  ROUND((er0.v - er1.v)::numeric, 3) AS bms_energy_drop_kwh,
  ROUND(rb.rebound::numeric, 3) AS soc_rise_pp,              -- largest SOC rise above the running minimum
  ROUND(chg.kwh::numeric, 3) AS charge_counter_kwh           -- AC/DC charging counters' increase inside the segment
FROM w
CROSS JOIN LATERAL (
  -- trapezoidal integral of P = -V*I (discharge positive), clipped to
  -- [s0, s1]; an interval longer than 90 s (3 missed samples) is not
  -- integrated and not counted as covered
  SELECT
    COALESCE(sum(CASE WHEN ok THEN (plo + phi) / 2.0 * dt END), 0) / 3600.0 AS e_out_kwh,
    COALESCE(sum(CASE WHEN ok THEN GREATEST(0, -(plo + phi) / 2.0) * dt END), 0) / 3600.0 AS e_regen_kwh,
    COALESCE(sum(CASE WHEN ok THEN dt END), 0) AS covered_s
  FROM (
    SELECT (tb - ta) <= 90 AS ok,
           LEAST(tb, b1) - GREATEST(ta, b0) AS dt,
           pa + (pb - pa) * (GREATEST(ta, b0) - ta) / NULLIF(tb - ta, 0) AS plo,
           pa + (pb - pa) * (LEAST(tb, b1) - ta) / NULLIF(tb - ta, 0) AS phi
    FROM (
      SELECT extract(epoch FROM p.ts) AS ta, p.kw AS pa,
             lead(extract(epoch FROM p.ts)) OVER (ORDER BY p.ts) AS tb,
             lead(p.kw) OVER (ORDER BY p.ts) AS pb,
             extract(epoch FROM w.s0) AS b0, extract(epoch FROM w.s1) AS b1
      FROM (
        SELECT i.ts, -(i.num_value * v.num_value) / 1000.0 AS kw
        FROM telemetry i
        JOIN telemetry v ON v.vin = i.vin AND v.ts = i.ts AND v.field = 'PackVoltage'
        WHERE i.vin = w.vin AND i.field = 'PackCurrent'
          AND i.ts BETWEEN w.s0 - INTERVAL '90 seconds' AND w.s1 + INTERVAL '90 seconds'
          AND i.num_value IS NOT NULL AND v.num_value IS NOT NULL
      ) p
    ) iv
    WHERE tb IS NOT NULL
  ) x
  WHERE dt > 0
) e
CROSS JOIN LATERAL (
  SELECT avg(x.num_value) AS avg_t,
         (SELECT y.num_value FROM telemetry y
          WHERE y.vin = w.vin AND y.field = 'OutsideTemp' AND y.ts <= w.s0
            AND y.ts > w.s0 - INTERVAL '2 hours'
          ORDER BY y.ts DESC LIMIT 1) AS last_t
  FROM telemetry x
  WHERE x.vin = w.vin AND x.field = 'OutsideTemp' AND x.ts BETWEEN w.s0 AND w.s1
) tmp
LEFT JOIN LATERAL (
  SELECT x.ts FROM telemetry x
  WHERE x.vin = w.vin AND x.field = 'Soc' AND x.ts <= w.s0 AND x.num_value >= 99
  ORDER BY x.ts DESC LIMIT 1
) fc ON true
LEFT JOIN LATERAL (
  SELECT x.num_value AS v FROM telemetry x
  WHERE x.vin = w.vin AND x.field = 'EnergyRemaining' AND x.ts <= w.s0
  ORDER BY x.ts DESC LIMIT 1
) er0 ON true
LEFT JOIN LATERAL (
  SELECT x.num_value AS v FROM telemetry x
  WHERE x.vin = w.vin AND x.field = 'EnergyRemaining' AND x.ts <= w.s1
  ORDER BY x.ts DESC LIMIT 1
) er1 ON true
CROSS JOIN LATERAL (
  SELECT max(soc - runmin) AS rebound FROM (
    SELECT x.num_value AS soc, min(x.num_value) OVER (ORDER BY x.ts) AS runmin
    FROM telemetry x
    WHERE x.vin = w.vin AND x.field = 'Soc' AND x.ts BETWEEN w.s0 AND w.s1
  ) q
) rb
CROSS JOIN LATERAL (
  -- sum of positive steps (a counter reset is a negative step and is ignored)
  SELECT COALESCE(sum(GREATEST(0, d)), 0) AS kwh FROM (
    SELECT x.num_value - lag(x.num_value) OVER (PARTITION BY x.field ORDER BY x.ts) AS d
    FROM telemetry x
    WHERE x.vin = w.vin AND x.field IN ('ACChargingEnergyIn', 'DCChargingEnergyIn')
      AND x.ts BETWEEN w.s0 AND w.s1
  ) q
) chg;

COMMENT ON VIEW packfade_segments IS
  'EXPERIMENTAL (057). One row per drive: SOC drop, pack energy out (V*I, 90 s gap cap), apparent capacity, covariates and charging indicators. Input to the Packfade-method fade estimate in tools/notify. Method adapted from Packfade (https://github.com/pgodlews/packfade, MIT).';

CREATE TABLE IF NOT EXISTS packfade_estimate (
  vin                   TEXT        NOT NULL,
  computed_at           TIMESTAMPTZ NOT NULL,
  variant               TEXT        NOT NULL,   -- 'all' | 'calibrated_start'
  status                TEXT        NOT NULL,   -- 'OK' | 'INSUFFICIENT_DATA'
  message               TEXT        NOT NULL,
  n_segments            INTEGER     NOT NULL,
  n_used                INTEGER     NOT NULL,
  n_rejected            INTEGER     NOT NULL,
  n_days                INTEGER     NOT NULL,   -- distinct dates among the used observations (bootstrap clusters)
  first_obs             TIMESTAMPTZ,
  last_obs              TIMESTAMPTZ,
  span_days             DOUBLE PRECISION,
  baseline_capacity_kwh DOUBLE PRECISION,       -- fitted capacity at the first observation, reference conditions
  capacity_now_kwh      DOUBLE PRECISION,       -- fitted capacity at the last observation
  index_pct             DOUBLE PRECISION,       -- capacity_now / baseline * 100
  index_lo_pct          DOUBLE PRECISION,       -- 95 % bootstrap interval
  index_hi_pct          DOUBLE PRECISION,
  fade_pct_per_year     DOUBLE PRECISION,       -- (1 - exp(-bt)) * 100; positive = capacity falling
  fade_lo_pct_per_year  DOUBLE PRECISION,
  fade_hi_pct_per_year  DOUBLE PRECISION,
  temp_effect_pct_per_10c DOUBLE PRECISION,
  residual_scale        DOUBLE PRECISION,       -- MAD scale of the log residuals
  n_boot                INTEGER     NOT NULL,
  seed                  BIGINT      NOT NULL,
  method                TEXT        NOT NULL,
  PRIMARY KEY (vin, computed_at, variant)
);
COMMENT ON TABLE packfade_estimate IS
  'EXPERIMENTAL (057). Capacity fade estimate, Packfade method (log-linear Huber-WLS, date-clustered bootstrap); written by tools/notify. Not part of the predictive health score.';

CREATE TABLE IF NOT EXISTS packfade_points (
  vin                   TEXT        NOT NULL,
  seg_start             TIMESTAMPTZ NOT NULL,
  seg_end               TIMESTAMPTZ NOT NULL,
  computed_at           TIMESTAMPTZ NOT NULL,
  soc_drop              DOUBLE PRECISION,
  apparent_capacity_kwh DOUBLE PRECISION,
  normalised_capacity_kwh DOUBLE PRECISION,     -- covariate effects removed (reference conditions)
  bms_capacity_kwh      DOUBLE PRECISION,       -- BMS EnergyRemaining drop / SOC drop, comparison only
  outside_temp_c        DOUBLE PRECISION,
  mean_soc              DOUBLE PRECISION,
  mean_power_kw         DOUBLE PRECISION,
  hours_since_full_charge DOUBLE PRECISION,
  base_weight           DOUBLE PRECISION,
  huber_weight          DOUBLE PRECISION,
  used                  BOOLEAN     NOT NULL,
  reject_reason         TEXT,
  PRIMARY KEY (vin, seg_start)
);

CREATE TABLE IF NOT EXISTS packfade_curve (
  vin          TEXT        NOT NULL,
  ts           TIMESTAMPTZ NOT NULL,
  computed_at  TIMESTAMPTZ NOT NULL,
  fitted_kwh   DOUBLE PRECISION NOT NULL,
  lo_kwh       DOUBLE PRECISION,
  hi_kwh       DOUBLE PRECISION,
  PRIMARY KEY (vin, ts)
);

-- grafana_ro reads these through the default privileges set in 003/042.
