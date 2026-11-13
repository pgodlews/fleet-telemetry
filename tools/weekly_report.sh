#!/bin/bash
#
# weekly_report.sh - Monday morning health check + driving summary over Telegram.
#
# Runs on the prod host (see tesla-weekly-report.timer). Two jobs:
#
#   1. Confirm the stack is actually working. Telemetry died silently for 36
#      days in Aug-Sep 2026 because nothing was watching; every health check
#      below exists because it would have caught that outage, or one like it.
#   2. Summarise the week's driving, so the message is worth opening even when
#      everything is green.
#
# Sends nothing to stdout that contains the bot token, and never puts the token
# on a command line (where `ps` shows it). Safe to run by hand:
#   ./weekly_report.sh            # send to Telegram
#   ./weekly_report.sh --dry-run  # print the message instead
#
# Installed as a systemd timer by `make -C deploy install-timers`.
# Settings (environment or /etc/default/tesla-weekly-report):
#   CONFIG, BASELINE, CERT, PSQL   paths / commands, defaults below
#   BACKUP_DIR                     where tools/backup.sh writes (default /u01/backups/tesla)
#   BACKUP_MAX_AGE_H               warn when the newest good backup is older (default 48)
#   EXPECTED_CONTAINERS            space-separated names; default: every container
#                                  of the compose project COMPOSE_PROJECT (tesla-telemetry),
#                                  so a stack run without the `notify` profile is not
#                                  reported as down

set -uo pipefail

CONFIG=${CONFIG:-/u01/fleet-telemetry/deploy/notify-config.json}
BASELINE=${BASELINE:-/u01/fleet-telemetry/deploy/.tls-chain-baseline}
CERT=${CERT:-/u01/fleet-telemetry/deploy/fleet-telemetry/certs/server.crt}
PSQL=${PSQL:-docker exec -i tesla-timescaledb psql -U postgres -d tesla}
BACKUP_DIR=${BACKUP_DIR:-/u01/backups/tesla}
BACKUP_MAX_AGE_H=${BACKUP_MAX_AGE_H:-48}
COMPOSE_PROJECT=${COMPOSE_PROJECT:-tesla-telemetry}
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

jqcfg() { python3 -c "import json,sys;print(json.load(open('$CONFIG')).get('$1',''))"; }

TOKEN=$(jqcfg telegram_token)
CHAT=$(jqcfg telegram_chat_id)
VIN=$(jqcfg vin)
RATE=$(jqcfg cost_per_kwh)
[ -z "$RATE" ] && RATE=0

OK="\xE2\x9C\x85"; WARN="\xE2\x9A\xA0\xEF\xB8\x8F"; BAD="\xF0\x9F\x94\xB4"

lines=()
issues=0
add() { lines+=("$1"); }
flag() { issues=$((issues+1)); }

# ---------------------------------------------------------------- health ----
# Containers. Expected = EXPECTED_CONTAINERS, else whatever the compose project
# has created (running or not), so optional profiles are not required.
expected=${EXPECTED_CONTAINERS:-$(docker ps -a --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ' ')}
down=""
n_expected=0
for c in $expected; do
  n_expected=$((n_expected+1))
  st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  [ "$st" = running ] || down="$down $c($st)"
done
if [ "$n_expected" -eq 0 ]; then
  add "$BAD containers: none found for project $COMPOSE_PROJECT"; flag
elif [ -z "$down" ]; then
  add "$OK containers $n_expected/$n_expected up"
else
  add "$BAD containers down:$down"; flag
fi

# Telemetry freshness - the check that would have caught the 36-day outage
age=$($PSQL -tAc "select coalesce(round(extract(epoch from now()-max(ts))),-1) from telemetry" 2>/dev/null | tr -d ' ')
[ -z "$age" ] && age=-1
if [ "$age" -lt 0 ]; then
  add "$BAD telemetry: cannot query database"; flag
elif [ "$age" -gt 86400 ]; then
  add "$BAD telemetry stale: $((age/3600))h since last row"; flag
elif [ "$age" -gt 7200 ]; then
  add "$WARN telemetry quiet: $((age/60))m since last row (car may be asleep)"
else
  add "$OK telemetry live ($((age/60))m ago)"
fi

# Certificate expiry on the cert the container actually serves
if [ -r "$CERT" ] || sudo -n test -r "$CERT" 2>/dev/null; then
  end=$(sudo -n openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -n "$end" ]; then
    days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
    if   [ "$days" -lt 0 ];  then add "$BAD TLS cert EXPIRED ${days#-} days ago"; flag
    elif [ "$days" -lt 14 ]; then add "$BAD TLS cert expires in $days days"; flag
    elif [ "$days" -lt 30 ]; then add "$WARN TLS cert expires in $days days"
    else add "$OK TLS cert valid ${days}d"
    fi
  fi
fi

# Chain-shape drift. A renewal that changes issuer chain breaks the car even
# when the cert is valid, because the CA is pinned in fleet_telemetry_config.
# No Tesla API auth needed: just watch for the chain changing shape.
chain=$(sudo -n openssl crl2pkcs7 -nocrl -certfile "$CERT" 2>/dev/null \
        | openssl pkcs7 -print_certs -noout 2>/dev/null | grep -c 'issuer=')
issuers=$(sudo -n openssl crl2pkcs7 -nocrl -certfile "$CERT" 2>/dev/null \
        | openssl pkcs7 -print_certs -noout 2>/dev/null | grep '^issuer=' | md5sum | cut -c1-12)
if [ -f "$BASELINE" ]; then
  if [ "$issuers" != "$(cat "$BASELINE")" ]; then
    add "$BAD TLS chain CHANGED - re-push fleet_telemetry_config (deploy/README.md s10)"; flag
  else
    add "$OK TLS chain unchanged (${chain} certs)"
  fi
else
  echo "$issuers" > "$BASELINE" 2>/dev/null && add "$OK TLS chain baseline recorded"
fi

# Rejected handshakes in the last week - early warning of the same failure
badcert=$(docker logs --since 168h tesla-fleet-telemetry 2>&1 | grep -c 'bad certificate')
if [ "$badcert" -gt 100 ]; then add "$WARN $badcert rejected handshakes this week"; fi

# Matview refreshes. 040 logs every refresh in matview_refresh_log; any view
# whose most recent run failed, or that has not refreshed for 3 days, is flagged.
mv=$($PSQL -tAc "
  select coalesce(string_agg(name || case when not ok then ' FAILED' else ' ' || round(extract(epoch from now()-finished_at)/86400) || 'd' end, ', '), '')
  from (
    select distinct on (name) name, ok, finished_at
    from matview_refresh_log
    where name = any(predictive_matview_list())   -- views still in the rotation
    order by name, started_at desc
  ) last
  where not ok or finished_at < now() - interval '3 days'" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
mv_rc=$?
if [ "$mv_rc" -ne 0 ]; then
  add "$WARN matview refresh log unreadable"
elif [ -n "$mv" ]; then
  add "$BAD matview refresh problems: $mv"; flag
else
  add "$OK matviews refreshed"
fi

# TimescaleDB background jobs whose last run failed (refresh policies,
# compression, the trips and matview jobs).
jobs=$($PSQL -tAc "
  select coalesce(string_agg(j.job_id || ':' || coalesce(j.hypertable_name, j.proc_name), ', '), '')
  from timescaledb_information.jobs j
  join timescaledb_information.job_stats s using (job_id)
  where s.last_run_status = 'Failed'" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ -n "$jobs" ]; then
  add "$WARN background jobs failing: $jobs"; flag
else
  add "$OK background jobs ok"
fi

# Backups (tools/backup.sh): newest completed tesla-<stamp>.dump. In-progress
# dumps carry a .partial suffix and do not count.
newest=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'tesla-*.dump' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
if [ -z "$newest" ]; then
  add "$BAD no backup found in $BACKUP_DIR"; flag
else
  bage=$(( ( $(date +%s) - ${newest%.*} ) / 3600 ))
  if [ "$bage" -gt "$BACKUP_MAX_AGE_H" ]; then
    add "$BAD newest backup is ${bage}h old"; flag
  else
    add "$OK backup ${bage}h old"
  fi
fi

# Disk
diskroot=$(df --output=pcent / | tail -1 | tr -d ' %')
disku01=$(df --output=pcent /u01 | tail -1 | tr -d ' %')
if [ "$diskroot" -gt 85 ] || [ "$disku01" -gt 85 ]; then
  add "$WARN disk / ${diskroot}% · /u01 ${disku01}%"; flag
else
  add "$OK disk / ${diskroot}% · /u01 ${disku01}%"
fi

# ------------------------------------------------------------- car stats ----
stats=$($PSQL -tA -F'|' -c "
with wk as (
  select date_trunc('week', now()) - interval '7 days' as s,
         date_trunc('week', now())                     as e
), cur as (
  select coalesce(sum(distance_km),0) km, count(*) trips,
         coalesce(sum(kwh_used),0) kwh, coalesce(max(distance_km),0) longest,
         coalesce(max(max_speed_mph),0) topmph
  from trips, wk where started >= wk.s and started < wk.e and vin = '$VIN'
), prev as (
  select coalesce(sum(distance_km),0) km, count(*) trips
  from trips, wk where started >= wk.s - interval '7 days' and started < wk.s and vin = '$VIN'
), odo as (
  select coalesce(max(num_value),0) v from telemetry where field='Odometer' and vin='$VIN'
), chg_vals as (
  -- ACChargingEnergyIn = energy drawn from an AC supply (onboard-charger
  -- input); DCChargingEnergyIn = energy into the battery from any charger
  -- (onboard charger in AC sessions, the station in DC fast charging). In an
  -- AC session both rise; they are not separate AC and DC totals. Per-session
  -- counters: sum the increases; a fall to under half the previous value is a
  -- reset, a smaller dip is parked-counter drift and adds nothing (same rule
  -- as the notify bot's fetchChargingEnergy).
  select field, ts, num_value,
         lag(num_value) over (partition by field order by ts) prev
  from telemetry, wk
  where ts >= wk.s and ts < wk.e and vin='$VIN'
    and field in ('ACChargingEnergyIn','DCChargingEnergyIn')
    and num_value is not null
), chg_inc as (
  select field, ts,
         case when prev is null then 0
              when num_value < prev * 0.5 then num_value
              when num_value < prev then 0
              else num_value - prev end kwh
  from chg_vals
), chg as (
  select coalesce(sum(kwh) filter (where field='ACChargingEnergyIn'),0) ac_supply,
         coalesce(sum(kwh) filter (where field='DCChargingEnergyIn'),0) battery,
         -- battery-side increase while DC charging power was flowing
         coalesce(sum(kwh) filter (where field='DCChargingEnergyIn' and kwh > 0 and exists (
           select 1 from telemetry p where p.vin='$VIN' and p.field='DCChargingPower' and p.num_value > 0
             and p.ts between chg_inc.ts - interval '10 minutes' and chg_inc.ts + interval '10 minutes')),0) dcfast
  from chg_inc
), bat as (
  select current_capacity_kwh, capacity_degradation_pct, window_days
  from battery_health_summary where vin='$VIN'
), al as (
  select coalesce(active_alert_count,0) n, coalesce(max_alert_severity,'NONE') sev
  from battery_health_summary where vin='$VIN'
)
select round(cur.km,1), cur.trips, round(cur.kwh,1),
       case when cur.km > 0 then round(cur.kwh*1000/cur.km) else 0 end,
       round(cur.kwh*$RATE,2),
       round(prev.km,1), prev.trips,
       round(cur.longest,1), round(cur.topmph),
       round(odo.v), round(chg.ac_supply::numeric,1), round(chg.battery::numeric,1), round(chg.dcfast::numeric,1),
       coalesce(bat.current_capacity_kwh,0), coalesce(bat.capacity_degradation_pct,0),
       coalesce(bat.window_days,0), al.n, al.sev
from cur, prev, odo, chg, al left join bat on true" 2>/dev/null)

IFS='|' read -r km trips kwh whkm cost pkm _ptrips longest topmph odo acsup batt dcfast cap deg win alerts sev <<< "$stats"

body=""
if [ -n "${km:-}" ]; then
  delta=""
  if [ -n "${pkm:-}" ] && [ "${pkm%.*}" -gt 0 ] 2>/dev/null; then
    d=$(python3 -c "print(f'{($km-$pkm)/$pkm*100:+.0f}%')" 2>/dev/null)
    delta=" (${d} vs last week)"
  fi
  body="\n<b>This week</b>\n"
  body="$body\xF0\x9F\x9B\xA3 ${km} km in ${trips} trips${delta}\n"
  [ "${kwh%.*}" -gt 0 ] 2>/dev/null && \
    body="$body\xE2\x9A\xA1 ${kwh} kWh · ${whkm} Wh/km · ~£${cost}\n"
  if [ "${batt%.*}" -gt 0 ] 2>/dev/null || [ "${acsup%.*}" -gt 0 ] 2>/dev/null; then
    # "into the battery" is what the car stored; the AC supply figure is what
    # the wall delivered (the difference is onboard-charger loss).
    chgtxt=$(python3 -c "
b=float('${batt:-0}'); f=float('${dcfast:-0}'); a=float('${acsup:-0}')
fa=max(b-f,0.0)
parts=[]
if f>0.05: parts.append(f'{f:.1f} DC fast')
if a>0.05:
    s=f'{fa:.1f} from AC ({a:.1f} drawn'
    if a>=0.5 and 0<fa<=a: s+=f', {(a-fa)/a*100:.0f}% loss'
    parts.append(s+')')
print(f'{b:.1f} kWh into battery' + (': ' + ' · '.join(parts) if parts else ''))
" 2>/dev/null || echo "${batt} kWh into battery")
    body="$body\xF0\x9F\x94\x8C ${chgtxt}\n"
  fi
  [ "${longest%.*}" -gt 0 ] 2>/dev/null && \
    body="$body\xF0\x9F\x93\x8D longest ${longest} km · top ${topmph} mph\n"
  # deg is positive for capacity loss; avoid rendering "--0.3%" if it ever goes negative
  degtxt=$(python3 -c "d=float('${deg:-0}'); print(f'-{d:.2f}%' if d>=0 else f'+{-d:.2f}%')" 2>/dev/null || echo "${deg}%")
  body="$body\xF0\x9F\x94\x8B pack ${cap} kWh (${degtxt} over ${win}d)\n"
  body="$body\xF0\x9F\x93\x8F odometer ${odo}\n"
  if [ "${alerts:-0}" -gt 0 ]; then
    body="$body\xF0\x9F\x94\xA7 ${alerts} active alert(s), max ${sev}\n"
  else
    body="$body\xF0\x9F\x94\xA7 no active alerts\n"
  fi
fi

# ---------------------------------------------------------------- compose ----
if [ "$issues" -eq 0 ]; then head="\xF0\x9F\x9A\x97 <b>Tesla weekly</b> — all systems normal"
else                          head="\xF0\x9F\x9A\x97 <b>Tesla weekly</b> — ${issues} issue(s) need attention"; fi

msg="$head\n<i>$(date -u '+%a %d %b %Y')</i>\n\n<b>Health</b>\n"
for l in "${lines[@]}"; do msg="$msg$l\n"; done
msg="$msg$body"

if [ "$DRY_RUN" -eq 1 ]; then
  printf "%b\n" "$msg"
  exit 0
fi

resp=$(mktemp)
trap 'rm -f "$resp"' EXIT
# The URL (and with it the token) goes to curl on stdin via --config, not on
# the command line.
code=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TOKEN" \
  | curl -sS -o "$resp" -w '%{http_code}' --config - \
      --data-urlencode "chat_id=${CHAT}" \
      --data-urlencode "text=$(printf '%b' "$msg")" \
      --data-urlencode "parse_mode=HTML" \
      --data-urlencode "disable_web_page_preview=true")

if [ "$code" = 200 ]; then
  logger -t tesla-weekly-report "sent weekly summary ($issues issues)"
else
  logger -t tesla-weekly-report "FAILED to send weekly summary: http $code"
  echo "telegram send failed: http $code" >&2
  exit 1
fi
