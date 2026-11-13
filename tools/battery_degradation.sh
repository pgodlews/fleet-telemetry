#!/bin/bash
#
# battery_degradation.sh - estimate pack capacity fade from telemetry history.
#
# Method: the only trustworthy capacity signal is EnergyRemaining sampled at
# near-full charge. Deriving capacity as EnergyRemaining/Soc*100 across the
# whole SoC range is biased - below ~40% SoC the BMS energy estimate inflates
# badly (see the "bias check" section this script prints). So we bucket
# telemetry into 15-minute slices, keep only slices at >= --soc-min (default
# 99%), and fit a line through those.
#
# Two fits are reported: one over every qualifying sample, and one over the
# weekly maximum (the best-calibrated full charge of each week, which is the
# more robust series). Both are annualised, but see the caveats printed at the
# end - a short window multiplies measurement noise.
#
# Usage:
#   tools/battery_degradation.sh [--vin VIN] [--since DATE] [--soc-min PCT]
#
#   --vin      restrict to one VIN (default: every VIN, reported separately)
#   --since    only consider telemetry at or after this timestamp (default: all)
#   --soc-min  SoC floor for a sample to count as "full charge" (default: 99)
#
# Connection: by default runs psql inside the tesla-timescaledb container. Set
# $PSQL to override, e.g. to run against a remote host:
#   PSQL="ssh user@your-host docker exec -i tesla-timescaledb psql -U postgres -d tesla" \
#     tools/battery_degradation.sh

set -euo pipefail

c_red="\033[0;31m"
c_yellow="\033[0;33m"
c_reset="\033[0m"

die() {
    >&2 echo -e "${c_red}$*${c_reset}"
    exit 1
}

warning() {
    echo -e "${c_yellow}$1${c_reset}"
}

VIN=""
SINCE="-infinity"
SOC_MIN="99"

while [ $# -gt 0 ]; do
    case "$1" in
        --vin)      [ $# -ge 2 ] || die "--vin requires a value"; VIN="$2"; shift 2 ;;
        --since)    [ $# -ge 2 ] || die "--since requires a value"; SINCE="$2"; shift 2 ;;
        --soc-min)  [ $# -ge 2 ] || die "--soc-min requires a value"; SOC_MIN="$2"; shift 2 ;;
        -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          die "unknown argument: $1" ;;
    esac
done

case "$SOC_MIN" in
    ''|*[!0-9.]*) die "--soc-min must be numeric, got: $SOC_MIN" ;;
esac

PSQL="${PSQL:-docker exec -i tesla-timescaledb psql -U postgres -d tesla}"

$PSQL -v ON_ERROR_STOP=1 -v vin="$VIN" -v since="$SINCE" -v soc_min="$SOC_MIN" <<'SQL'
\set QUIET on
\pset footer off
\timing off

-- 15-minute slices with the three fields we care about co-located.
CREATE TEMP TABLE slices AS
SELECT vin,
       time_bucket('15 min', ts)                                    AS bk,
       avg(num_value) FILTER (WHERE field = 'EnergyRemaining')      AS er,
       avg(num_value) FILTER (WHERE field = 'Soc')                  AS soc,
       avg(num_value) FILTER (WHERE field = 'RatedRange')           AS rr
FROM telemetry
WHERE field IN ('EnergyRemaining', 'Soc', 'RatedRange')
  AND ts >= :'since'::timestamptz
  AND (:'vin' = '' OR vin = :'vin')
GROUP BY 1, 2;

DELETE FROM slices WHERE er IS NULL OR soc IS NULL;

-- Full-charge samples, with days elapsed since that VIN's first observation.
CREATE TEMP TABLE fullchg AS
SELECT s.vin, s.bk, s.er, s.rr, s.soc,
       extract(epoch FROM s.bk - f.first_bk) / 86400.0 AS day
FROM slices s
JOIN (SELECT vin, min(bk) AS first_bk FROM slices GROUP BY 1) f USING (vin)
WHERE s.soc >= :soc_min;

-- One point per week: the highest full-charge reading that week. er and rr
-- must come from the SAME slice (a real observation), not independent maxima,
-- and `day` is that slice's own elapsed-days value, not an average across the
-- week's samples.
CREATE TEMP TABLE weekly AS
WITH counts AS (
    SELECT vin, date_trunc('week', bk)::date AS week, count(*) AS n
    FROM fullchg
    GROUP BY 1, 2
),
peak AS (
    SELECT DISTINCT ON (vin, date_trunc('week', bk)::date)
           vin,
           date_trunc('week', bk)::date AS week,
           er, rr, day
    FROM fullchg
    ORDER BY vin, date_trunc('week', bk)::date, er DESC
)
SELECT p.vin, p.week, p.er, p.rr, p.day, c.n
FROM peak p
JOIN counts c USING (vin, week);

\set QUIET off

\echo ''
\echo '=== Coverage ==='
SELECT vin,
       min(bk)::date                                        AS first_seen,
       max(bk)::date                                        AS last_seen,
       round(extract(epoch FROM max(bk) - min(bk))::numeric / 86400, 1) AS days,
       count(*)                                             AS slices,
       count(*) FILTER (WHERE soc >= :soc_min)              AS full_charge_slices,
       round(min(soc)::numeric, 1)                          AS soc_min_seen
FROM slices
GROUP BY vin
ORDER BY vin;

\echo ''
\echo '=== Bias check: why we filter on SoC ==='
\echo '(naive EnergyRemaining/Soc*100 by SoC band - note how it inflates when the pack is low)'
SELECT vin,
       CASE WHEN soc < 20 THEN 'a. <20%'
            WHEN soc < 40 THEN 'b. 20-40%'
            WHEN soc < 60 THEN 'c. 40-60%'
            WHEN soc < 80 THEN 'd. 60-80%'
            ELSE               'e. >=80%'
       END                                                        AS soc_band,
       count(*)                                                   AS n,
       round(avg(er / soc * 100)::numeric, 2)                     AS derived_kwh_avg,
       round(max(er / soc * 100)::numeric, 2)                     AS derived_kwh_max
FROM slices
WHERE soc > 1
GROUP BY 1, 2
ORDER BY 1, 2;

\echo ''
\echo '=== Full-charge capacity by month ==='
\echo '(kwh_p90 and rated_range_p90 are read off the same slice - the one nearest'
\echo ' the 90th percentile rank of er - not independent percentiles of er and rr)'
WITH ranked AS (
    SELECT vin, date_trunc('month', bk)::date AS month, er, rr,
           percent_rank() OVER (PARTITION BY vin, date_trunc('month', bk)::date
                                 ORDER BY er) AS pr
    FROM fullchg
),
monthly_p90 AS (
    SELECT DISTINCT ON (vin, month)
           vin, month, er AS kwh_p90, rr AS rated_range_p90
    FROM ranked
    ORDER BY vin, month, abs(pr - 0.9)
),
monthly_stats AS (
    SELECT vin, date_trunc('month', bk)::date AS month,
           count(*)                                                          AS n,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY er)                    AS kwh_median
    FROM fullchg
    GROUP BY 1, 2
)
SELECT s.vin, s.month, s.n,
       round(p.kwh_p90::numeric, 2)          AS kwh_p90,
       round(s.kwh_median::numeric, 2)       AS kwh_median,
       round(p.rated_range_p90::numeric, 1)  AS rated_range_p90
FROM monthly_stats s
JOIN monthly_p90 p USING (vin, month)
ORDER BY s.vin, s.month;

\echo ''
\echo '=== Weekly peak full charge ==='
SELECT vin, week, n,
       round(er::numeric, 2) AS kwh,
       round(rr::numeric, 1) AS rated_range
FROM weekly
ORDER BY vin, week;

\echo ''
\echo '=== Degradation fits (annualised) ==='
\echo '(the "all full-charge samples" fit is density-weighted - a week with more'
\echo ' qualifying 15-min slices counts more toward the slope than a sparse week.'
\echo ' "weekly peaks" gives each week one vote and is the more robust figure;'
\echo ' the two are expected to disagree for this reason.)'
WITH fits AS (
    SELECT 'all full-charge samples (density-weighted)' AS series, 1 AS ord, vin,
           count(*)                   AS n,
           regr_slope(er, day)        AS er_slope,
           regr_intercept(er, day)    AS er_base,
           corr(er, day)              AS er_r,
           regr_slope(rr, day)        AS rr_slope,
           regr_intercept(rr, day)    AS rr_base
    FROM fullchg GROUP BY vin
    UNION ALL
    SELECT 'weekly peaks', 2, vin,
           count(*),
           regr_slope(er, day), regr_intercept(er, day), corr(er, day),
           regr_slope(rr, day), regr_intercept(rr, day)
    FROM weekly GROUP BY vin
)
SELECT vin, series, n,
       round((er_slope * 365)::numeric, 3)                     AS kwh_per_year,
       round((er_slope * 365 / nullif(er_base, 0) * 100)::numeric, 2) AS pct_per_year,
       round(er_base::numeric, 2)                              AS kwh_at_start,
       round(er_r::numeric, 3)                                 AS r,
       round((rr_slope * 365)::numeric, 2)                     AS range_per_year,
       round(rr_base::numeric, 1)                              AS range_at_start
FROM fits
ORDER BY vin, ord;

\echo ''
\echo '=== Observed change over the window (weekly peaks, first vs last) ==='
WITH ends AS (
    SELECT vin,
           (array_agg(er ORDER BY week))[1]                        AS er_first,
           (array_agg(er ORDER BY week DESC))[1]                   AS er_last,
           (array_agg(rr ORDER BY week))[1]                        AS rr_first,
           (array_agg(rr ORDER BY week DESC))[1]                   AS rr_last,
           max(day) - min(day)                                     AS span_days
    FROM weekly GROUP BY vin
)
SELECT vin,
       round(span_days::numeric, 1)                                AS days,
       round(er_first::numeric, 2)                                 AS kwh_first,
       round(er_last::numeric, 2)                                  AS kwh_last,
       round((er_last - er_first)::numeric, 2)                     AS kwh_delta,
       round(((er_last - er_first) / nullif(er_first, 0) * 100)::numeric, 2) AS pct_delta,
       round((rr_last - rr_first)::numeric, 1)                     AS range_delta
FROM ends
ORDER BY vin;

\echo ''
\echo '=== Window health ==='
SELECT vin,
       round((max(day) - min(day))::numeric, 0) AS span_days,
       count(*)                                 AS weekly_points,
       CASE WHEN max(day) - min(day) < 180 THEN 'SHORT WINDOW - annualised figures are an upper bound, not a forecast'
            ELSE 'window length OK'
       END                                      AS note
FROM weekly
GROUP BY vin
ORDER BY vin;
SQL

echo ""
warning "Caveats:"
cat <<'EOF'
  * Degradation is sub-linear (fast early, then flattening). Annualising a short
    window overstates the yearly rate - treat it as an upper bound.
  * The rated-range trend usually falls faster than the kWh trend. That gap is
    the BMS re-estimating its Wh/mile constant, not physical capacity loss;
    weight the kWh figure.
  * LFP packs estimate SoC poorly and rely on periodic full charges to
    recalibrate. Cross-check that BmsFullchargecomplete fired during the window:
      SELECT count(*) FROM telemetry
       WHERE field = 'BmsFullchargecomplete' AND str_value ILIKE 'true';
  * Ambient temperature moves capacity by a few percent on its own. A window
    spanning a seasonal swing will carry that in the slope.
EOF
