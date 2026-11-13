#!/usr/bin/env python3
"""EXPLAIN every Grafana panel and variable query against a migrated database.

Extracts each `rawSql` (panel targets) and each SQL query variable from
deploy/grafana/dashboards/*.json, substitutes the Grafana macros and dashboard
variables with fixed values, and runs `EXPLAIN` on it through psql. EXPLAIN
plans the query without executing it, so this catches references to missing
relations, columns and functions, and type errors, on an empty database.

Usage:
    tools/explain_panels.py [--dashboards DIR] [--psql "psql -X -U postgres -d tesla"]

The psql command can also come from $PSQL. Exit status is 1 if any query
fails, with one line per failure naming the dashboard and panel.
"""

import argparse
import glob
import json
import os
import re
import shlex
import subprocess
import sys

# Values substituted for dashboard variables. Unknown variables fall back to
# the first option of a custom variable, else to 'x'.
VARS = {
    "vin": "5YJ3E1EA7NF000001",
    "model": "3",
    "motor_config": "RWD",
    "units_override": "auto",
    "units_effective": "metric",
    "dist_effective": "metric",
    "temp_effective": "metric",
    "pressure_effective": "metric",
    "distance_unit": "DistanceUnitKm",
    "dist_unit": "km",
    "temp_unit": "C",
    "pressure_unit": "bar",
    "speed_unit": "km/h",
    "field_filter": "%",
}

TIME_FROM = "'2026-01-01T00:00:00Z'::timestamptz"
TIME_TO = "'2026-01-08T00:00:00Z'::timestamptz"


def substitute(sql, local_vars):
    sql = re.sub(r"\$__timeFilter\(([^)]+)\)",
                 lambda m: f"{m.group(1).strip()} BETWEEN {TIME_FROM} AND {TIME_TO}", sql)
    sql = re.sub(r"\$__timeGroupAlias\(([^,]+),\s*'?([^)']+)'?\)",
                 lambda m: f"time_bucket('{m.group(2)}', {m.group(1).strip()}) AS time", sql)
    sql = re.sub(r"\$__timeGroup\(([^,]+),\s*'?([^)']+)'?\)",
                 lambda m: f"time_bucket('{m.group(2)}', {m.group(1).strip()})", sql)
    sql = sql.replace("$__timeFrom()", TIME_FROM).replace("$__timeTo()", TIME_TO)
    sql = re.sub(r"\$__unixEpochFrom\(\)", "1767225600", sql)
    sql = re.sub(r"\$__unixEpochTo\(\)", "1767830400", sql)
    sql = re.sub(r"\$__interval_ms", "60000", sql)
    sql = re.sub(r"\$__interval", "1m", sql)

    def var(m):
        name = m.group(1) or m.group(2)
        name = name.split(":")[0]
        return local_vars.get(name, VARS.get(name, "x"))

    sql = re.sub(r"\$\{(\w+(?::\w+)?)\}|\$(\w+)", var, sql)
    return sql


def walk(panels):
    for p in panels or []:
        yield p
        yield from walk(p.get("panels"))


def collect(path):
    d = json.load(open(path))
    local_vars = {}
    queries = []
    for v in d.get("templating", {}).get("list", []):
        if v.get("type") == "custom" and v.get("query"):
            local_vars.setdefault(v["name"], str(v["query"]).split(",")[0].strip())
        if v.get("type") == "query":
            q = v.get("query")
            if isinstance(q, dict):
                q = q.get("rawSql") or q.get("query")
            if q:
                queries.append((f"variable ${v['name']}", q))
    for p in walk(d.get("panels")):
        for t in p.get("targets", []) or []:
            if t.get("rawSql"):
                queries.append((f"panel '{p.get('title', '?')}' ref {t.get('refId', '?')}", t["rawSql"]))
    return local_vars, queries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dashboards", default=os.path.join(os.path.dirname(__file__), "..", "deploy", "grafana", "dashboards"))
    ap.add_argument("--psql", default=os.environ.get("PSQL", "psql -X -U postgres -d tesla"))
    args = ap.parse_args()

    psql = shlex.split(args.psql) + ["-v", "ON_ERROR_STOP=1", "-q", "-At"]
    files = sorted(glob.glob(os.path.join(args.dashboards, "*.json")))
    if not files:
        print("explain_panels: no dashboards found", file=sys.stderr)
        return 1
    failures = total = 0
    for f in files:
        local_vars, queries = collect(f)
        for where, raw in queries:
            total += 1
            sql = substitute(raw, local_vars).strip().rstrip(";")
            r = subprocess.run(psql, input=f"EXPLAIN {sql};\n", text=True, capture_output=True)
            if r.returncode != 0:
                failures += 1
                err = " ".join(line for line in r.stderr.splitlines() if "ERROR" in line) or r.stderr.strip()
                print(f"FAIL {os.path.basename(f)}: {where}: {err}")
    print(f"explain_panels: {total - failures}/{total} queries planned, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
