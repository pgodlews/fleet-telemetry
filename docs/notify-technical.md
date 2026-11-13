# TeslikTripBot — Technical Reference

`tools/notify` is a Go CLI binary (`tesla-notify`) that reads trip data from TimescaleDB and sends Telegram notifications. It runs either as a **one-shot cron job** or as a **long-running daemon** with an interactive Telegram command handler.

---

## Architecture

### Cron mode (legacy, replaced by daemon)

```
cron (every 2 min)
  └── tesla-notify
        ├── fetchUnnotifiedTrips()
        └── for each trip → processTrip() → Telegram sendPhoto/sendMessage
```

### Daemon mode (`--daemon` flag)

```
tesla-notify --daemon
  ├── loadPrefs()          — overlay DB-stored units/temp preferences onto config
  ├── loadDBPlaces()       — merge bot-added named places with config file places
  ├── SuperchargerCache.Ensure()  — eagerly load 10,507 sites from supercharge.info
  │
  ├── goroutine: tripWatcher      — polls DB every 2 min, calls processTrip()
  ├── goroutine: commandHandler   — Telegram getUpdates long-poll loop (30 s timeout)
  ├── goroutine: feedWatcher      — polls Atom feed every 6 h, sends proximity alerts
  ├── goroutine: staleWatchdog    — hourly; one warning when no telemetry AND no
  │                                 connectivity row for stale_after_hours (default 48),
  │                                 one recovery note when data resumes (state: notify_watchdog)
  └── goroutine: sessionCleaner   — drops idle service-log sessions after 10 min
```

Graceful shutdown: `SIGINT`/`SIGTERM` cancels the shared context; all goroutines drain and `sync.WaitGroup` ensures clean exit.

---

## Source files

| File | Responsibility |
|------|---------------|
| `main.go` | CLI flags, config loading, DB connection, cron-mode loop, `--daemon` branch |
| `config.go` | `Config` and `Place` structs; JSON config file + env var loading |
| `db.go` | All DB queries: trips, GPS track, efficiency avg, charge state, summary stats, charging kWh, last GPS fix, odometer, service log insert |
| `message.go` | `formatMessage()` — builds Telegram caption from a `TripRow` and enrichments |
| `maprender.go` | `renderRouteMap()` and `renderSinglePointMap()` — GPS points → PNG via go-staticmaps |
| `geocode.go` | `resolveLocation()` — named-place radius match (haversine) then Nominatim fallback |
| `weather.go` | `fetchWeather()` — open-meteo hourly API → WMO code → emoji + description |
| `telegram.go` | `sendMessage()`, `sendPhoto()`, `sendMessageWithKeyboard()`, `telegramGetUpdates()`, `telegramGetFilePath()` — plain net/http, no library |
| `daemon.go` | `runDaemon()`, `tripWatcher()`, `commandHandler()`, `sessionCleaner()`, `pollTrips()` |
| `commands.go` | `handleUpdate()` dispatcher, all `/cmd` handler functions, keyboard button label routing |
| `supercharger.go` | `SuperchargerCache`, `findNearest()`, Atom feed parsing, `feedWatcher()`, `checkFeed()` |
| `prefs.go` | `loadPrefs()`, `savePrefs()`, `loadDBPlaces()`, `addDBPlace()` — DB persistence for settings |
| `servicelog.go` | `SessionStore`, `ServiceLogSession`, multi-turn service log flow, photo download |

---

## Configuration

### Config file (`notify-config.json`, gitignored)

```json
{
  "conn":              "postgres://postgres:<pw>@localhost:5432/tesla?sslmode=disable",
  "telegram_token":    "<TOKEN>",
  "telegram_chat_id":  "123456789",
  "vin":               "<YOUR_VIN>",
  "cost_per_kwh":      0.23,
  "units":             "km",
  "temp_units":        "c",
  "sc_alert_radius_km": 50,
  "places": [
    { "name": "Home", "lat": 51.5007, "lon": -0.1246, "radius_m": 150 },
    { "name": "Work", "lat": 51.5055, "lon": -0.0754, "radius_m": 300 }
  ]
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `conn` | — | PostgreSQL connection string (required) |
| `telegram_token` | — | Bot token from @BotFather (required unless `--dry-run`) |
| `telegram_chat_id` | — | Chat ID to send messages to (required unless `--dry-run`) |
| `vin` | — | Vehicle VIN to monitor (required) |
| `cost_per_kwh` | `0.23` | Electricity cost in £/kWh for trip cost estimates |
| `units` | `"km"` | Distance units: `"km"` or `"miles"` |
| `temp_units` | `"c"` | Temperature units: `"c"` or `"f"` |
| `currency` | `"£"` | Currency symbol for cost displays, e.g. `"£"`, `"€"`, `"$"` |
| `sc_alert_radius_km` | `50` | Radius (km) for new Supercharger opening alerts; `0` disables |
| `places` | `[]` | Named locations — matched by haversine before reverse geocoding |
| `stale_after_hours` | `48` | Staleness watchdog threshold; `0` disables (env `NOTIFY_STALE_AFTER_HOURS`) |

`telegram_token` is the bare BotFather token (`<digits>:<secret>`). A leading
`bot` is stripped with a warning, because every URL builder adds it.

All fields except `places` can be overridden by CLI flag or environment variable:

| Env var | CLI flag | Field |
|---------|----------|-------|
| `NOTIFY_CONN` | `--conn` | `conn` |
| `NOTIFY_TOKEN` | `--token` | `telegram_token` |
| `NOTIFY_CHAT_ID` | `--chat-id` | `telegram_chat_id` |
| `NOTIFY_VIN` | `--vin` | `vin` |

---

## CLI flags

```
--config string      Config file path          (default: notify-config.json)
--conn string        DB connection string      (overrides config / NOTIFY_CONN)
--token string       Telegram bot token        (overrides config / NOTIFY_TOKEN)
--chat-id string     Telegram chat ID          (overrides config / NOTIFY_CHAT_ID)
--vin string         Vehicle VIN               (overrides config / NOTIFY_VIN)
--cost-per-kwh f     £/kWh rate                (overrides config)
--units string       "km" or "miles"           (overrides config)
--temp-units string  "c" or "f"               (overrides config)
--trip-id int        Send specific trip and exit (debug / backfill)
--dry-run            Print to stdout, no Telegram send, no DB writes
--daemon             Run as long-lived daemon
```

---

## Database schema

### Tables created by `tesla-notify`

**`telegram_notifications`** (`deploy/sql/018_telegram_state.sql`)
```sql
CREATE TABLE IF NOT EXISTS telegram_notifications (
  vin      TEXT        NOT NULL,
  trip_id  INTEGER     NOT NULL,
  sent_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (vin, trip_id)
);
```

**`notify_user_prefs`** (`deploy/sql/019_user_prefs.sql` + migrations `020`–`022`)
```sql
CREATE TABLE IF NOT EXISTS notify_user_prefs (
  vin               TEXT             NOT NULL PRIMARY KEY,
  units             TEXT             NOT NULL DEFAULT 'km',
  temp_units        TEXT             NOT NULL DEFAULT 'c',
  cost_per_kwh      DOUBLE PRECISION NOT NULL DEFAULT 0,      -- 0 = use config file
  currency          TEXT             NOT NULL DEFAULT '',      -- '' = use config file
  last_sc_change_id INTEGER          NOT NULL DEFAULT 0,
  updated_at        TIMESTAMPTZ      NOT NULL DEFAULT now()
);
```

**`notify_places`** (`deploy/sql/019_user_prefs.sql`)
```sql
CREATE TABLE IF NOT EXISTS notify_places (
  id         SERIAL           PRIMARY KEY,
  vin        TEXT             NOT NULL,
  name       TEXT             NOT NULL,
  lat        DOUBLE PRECISION NOT NULL,
  lon        DOUBLE PRECISION NOT NULL,
  radius_m   DOUBLE PRECISION NOT NULL DEFAULT 100,
  created_at TIMESTAMPTZ      NOT NULL DEFAULT now(),
  UNIQUE (vin, name)
);
```

**`service_log`** (`deploy/sql/023_service_log.sql`)
```sql
CREATE TABLE IF NOT EXISTS service_log (
  id           SERIAL           PRIMARY KEY,
  vin          TEXT             NOT NULL,
  logged_at    TIMESTAMPTZ      NOT NULL DEFAULT now(),
  odometer_km  DOUBLE PRECISION,
  description  TEXT             NOT NULL,
  photo_paths  TEXT[]           NOT NULL DEFAULT '{}',
  notes        TEXT
);
CREATE INDEX IF NOT EXISTS service_log_vin_idx ON service_log (vin, logged_at DESC);
```

### Tables read by `tesla-notify`

| Table / View | Fields used |
|---|---|
| `trips` | `vin`, `trip_id`, `started`, `ended`, `distance_km`, `kwh_used`, `wh_per_km`, `soc_start/end_pct`, `max/avg_speed_mph`, `start/end_lat/lon` |
| `telemetry` | `Location` (GPS), `ChargeState`, `TimeToFullCharge`, `ACChargingEnergyIn`, `DCChargingEnergyIn` |

---

## External APIs

| Service | URL | Usage | Auth |
|---------|-----|-------|------|
| Telegram Bot API | `api.telegram.org` | Send messages/photos, long-poll updates | Bot token |
| open-meteo | `api.open-meteo.com` | Hourly temperature + WMO weather code | None |
| Nominatim | `nominatim.openstreetmap.org` | Reverse geocoding (lat/lon → address) | None (User-Agent required) |
| OpenStreetMap tiles | `tile.openstreetmap.org` | Route map and location map tile renders | None |
| supercharge.info allSites | `supercharge.info/service/supercharge/allSites` | Full Supercharger dataset (10,507 sites, cached 7 days) | None |
| supercharge.info feed | `supercharge.info/service/supercharge/feed/atom.xml` | Change feed for new/updated Superchargers (polled every 6 h) | None |

The daemon makes **no inbound connections** and exposes **no ports**.

---

## Key data flows

### Trip notification

```
tripWatcher (every 2 min)
  → fetchUnnotifiedTrips (DB)
  → for each trip:
      resolveLocation (haversine → Nominatim)
      fetchAvgEfficiency (DB)
      fetchChargeState (DB)
      fetchWeather (open-meteo)
      fetchGPSTrack (DB)
      formatMessage (in-memory)
      renderRouteMap (go-staticmaps + OSM tiles)
      sendPhoto / sendMessage (Telegram)
      markNotified (DB)
```

### Supercharger feed check

```
feedWatcher (every 6 h)
  → fetchFeedEntries (Atom XML)
  → for each entry with changeID > last_sc_change_id:
      if OPEN event:
        SuperchargerCache.siteByID (in-memory)
        if not found → force cache refresh (allSites)
        haversineM to each named place
        if within sc_alert_radius_km → sendMessage (Telegram)
  → saveLastSCChangeID (DB)
```

### Command handling

```
commandHandler
  → telegramGetUpdates (long-poll 30 s)
  → filter by chat_id
  → handleServiceLogStep (if session active for chat) → consumed / not consumed
  → dispatch by command string (or keyboard button label → mapped to command)
      /summary*d       → fetchSummaryStats + fetchChargingEnergy (DB)
      /lastknown..     → fetchLastGPS (DB) → renderSinglePointMap → sendPhoto
      /nearestcharger  → fetchLastGPS (DB) → SuperchargerCache.FindNearest
      /logservice      → startServiceLog → fetchCurrentOdometer (DB) → session created
      /setunits|settemp|setcurrency|setenergyprice → update cfg + savePrefs (DB)
      /addplace        → validate → addDBPlace (DB) + update cfg.Places
      /listplaces      → format cfg.Places
      /menu            → sendMessageWithKeyboard (mainMenuKeyboard)
      /hidekeyboard    → sendMessageRemoveKeyboard
```

### Service log session state machine

```
SessionStore (map[chatID]*ServiceLogSession, protected by sync.Mutex)
  ├── sessionCleaner goroutine (ticks every 1 min)
  │     → purgeStale(): remove sessions idle for > 10 min
  │
  └── ServiceLogSession states:
        stateAwaitingDescription
          user sends text → save description → stateAwaitingServiceItem
        stateAwaitingServiceItem
          user picks a service_intervals item or "Other / none" → stateAwaitingPhoto
        stateAwaitingPhoto
          user sends photo → download to host → append path → stay in state
          user sends /done or /skip → stateAwaitingConfirm
        stateAwaitingConfirm
          user sends ✅ Confirm → insertServiceLog (DB) → clear session → main keyboard
          user sends ❌ Cancel → clear session → main keyboard
        (any state) /cancel or the ❌ Cancel button (exact match; text that merely
        contains "cancel" is ordinary input) → clear session → main keyboard
```

### Scheduled service items

After the description the bot offers every `service_intervals` item as a button
(plus "Other / none of these"). Picking one makes the confirm step insert a
`service_completions` row (date, odometer converted to miles, item, note
`service_log #<id>`) in the **same transaction** as the `service_log` row, so
`service_interval_status` starts counting that item's interval from this
service. Before, a logged service never reset any interval.

### Photo storage

Photos are downloaded from Telegram's file server (`api.telegram.org/file/bot{token}/{path}`) via `telegramGetFilePath` → GET and written to:

```
{attachments_dir}/{vin}/{YYYY-MM-DD}/{unix_ns}_{idx}.jpg
```

Each download is capped at 20 MB (the partial file is removed on any error), and
an entry holds at most 10 photos.

Default `attachments_dir` is `/attachments`, mounted from `/u01/fleet-telemetry/attachments` on the host. File paths are stored in `service_log.photo_paths` (PostgreSQL `TEXT[]`).

---

## Errors, tokens and timeouts

- Every Telegram HTTP call goes through `telegramDo`, the only place a URL with
  the bot token is built. Its errors drop the request URL (Go's `*url.Error`
  embeds it) and mask any remaining token occurrence, so logs never contain the
  token. Chat replies carry only a short generic reason; detail is in the log.
- Only the configured chat is served: updates from any other chat id (messages
  and inline-button callbacks alike) are dropped before a queue or goroutine is
  created for them. Updates with neither a message nor a callback (edited
  messages, channel posts) are ignored.
- Database: every pooled connection gets `statement_timeout = 60s` unless the
  connection string sets one; the startup ping has a 10 s timeout; each update
  handler runs under a 2-minute context, each trip under 3 minutes.

## Accepted behaviours (documented, not fixed)

- **Duplicate trip message after a crash.** `pollTrips` holds an advisory lock,
  so two runners never send the same trip concurrently, but sending and
  `markNotified` are separate steps. A crash after Telegram accepted the message
  and before the insert re-sends that trip on the next pass. A claim/lease table
  would close this; a rare duplicate was judged cheaper.
- **Update acknowledged before it is handled.** `commandHandler` advances the
  `getUpdates` offset as soon as an update is queued. If the process dies before
  the handler finishes, Telegram does not redeliver it; the user has to repeat
  the command.
- **Supercharger feed checkpoint.** On the very first run for a VIN the feed is
  treated as history: the newest change id is stored and nothing is alerted. If
  the checkpoint cannot be read (DB error) the pass is skipped rather than
  replaying the feed.

## Supercharger cache

The supercharger dataset is loaded from `supercharge.info/service/supercharge/allSites` into memory as `[]scSite` (~2 MB, ~10,500 sites). The cache is refreshed automatically when:
- The daemon starts
- `/nearestcharger` is called and the cache is older than 7 days
- The feed watcher finds a new entry for a site not present in the current cache (force-refresh)

`findNearest` filters to `status == "OPEN"`, computes haversine distance from the given point to every open site, sorts, and returns the top N.

---

## Charging energy

What the two counters measure (Tesla's field list and the production data agree):

- `ACChargingEnergyIn` — energy taken from an AC supply, measured at the
  onboard charger's input. Not meaningful during DC fast charging.
- `DCChargingEnergyIn` — energy delivered into the battery by any charger: the
  onboard charger in an AC session, the station in a DC fast-charge session.

In an AC session both rise (the AC figure about 2–3 % higher: charger loss); in
a DC session only the DC counter does. They are not "AC" and "DC" totals.
`/summary` (and the weekly report) therefore print energy into the battery,
split into DC fast charging and AC charging, with the energy drawn from the AC
supply and the loss between them (`fetchChargingEnergy`, `formatChargingLine`).

Both are per-session counters. The window total is the sum of increases; a fall
to under half the previous value is a reset (the new value counts), a smaller
dip is parked drift of the battery-side counter and adds nothing. An increase of
the battery-side counter counts as DC fast charging when `DCChargingPower` was
above zero within 10 minutes of it.

## Build and deploy

### Local build

```bash
go build -o tesla-notify ./tools/notify
```

### Cross-compile for Linux (server deployment)

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
  go build -o deploy/tesla-notify-linux-amd64 ./tools/notify
```

The binary is statically linked (`CGO_ENABLED=0`) — no dependencies on the target system.

### Apply database migrations

```bash
# Run once on the server (idempotent — safe to re-run)
docker exec tesla-timescaledb psql -U postgres -d tesla \
  -f /docker-entrypoint-initdb.d/018_telegram_state.sql
docker exec tesla-timescaledb psql -U postgres -d tesla \
  -f /docker-entrypoint-initdb.d/019_user_prefs.sql
docker exec tesla-timescaledb psql -U postgres -d tesla \
  -f /docker-entrypoint-initdb.d/020_sc_feed.sql
docker exec tesla-timescaledb psql -U postgres -d tesla \
  -f /docker-entrypoint-initdb.d/023_service_log.sql
```

All migrations are idempotent (`CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`).

### Docker Compose (daemon mode)

The daemon runs as a Docker Compose service with the `notify` profile:

```bash
# Start
docker compose --profile notify up -d tesla-notify-daemon

# Logs
docker logs -f tesla-notify-daemon

# Restart after binary update (stop first to release the file lock)
docker stop tesla-notify-daemon
scp deploy/tesla-notify-linux-amd64 server:/u01/fleet-telemetry/deploy/
docker start tesla-notify-daemon
```

The service definition in `deploy/docker-compose.yml`:

```yaml
tesla-notify-daemon:
  profiles: ["notify"]
  image: alpine:3.19
  container_name: tesla-notify-daemon
  restart: unless-stopped
  depends_on:
    timescaledb:
      condition: service_healthy
  network_mode: host
  volumes:
    - ./tesla-notify-linux-amd64:/app/tesla-notify:ro
    - ./notify-config.json:/app/notify-config.json:ro
  command: ["/app/tesla-notify", "--daemon", "--config", "/app/notify-config.json"]
```

`network_mode: host` is required so the daemon can reach TimescaleDB on `localhost:5432`.

### One-shot / debug mode

```bash
# Test against last 3 trips without sending (dry run)
./tesla-notify --dry-run --config ./notify-config.json

# Send a specific trip by ID (real send)
./tesla-notify --trip-id 42 --config ./notify-config.json

# Send a specific trip without writing to DB
./tesla-notify --trip-id 42 --dry-run --config ./notify-config.json
```

---

## Preferences merge order

On daemon startup, preferences are applied in this order (later overrides earlier):

1. Built-in defaults (`units=km`, `temp_units=c`, `sc_alert_radius_km=50`)
2. `notify-config.json` values
3. CLI flags (`--units`, `--temp-units`, etc.)
4. DB row in `notify_user_prefs` (set via `/setunits`, `/settemp`, `/setcurrency`, `/setenergyprice` bot commands)
5. DB rows in `notify_places` (set via `/addplace` bot command, merged into `cfg.Places`)

Named places from the DB override config-file entries with the same name.

---

## Map rendering

Route maps and location pins are rendered in-process using [`go-staticmaps`](https://github.com/flopp/go-staticmaps), which fetches OSM tiles over HTTPS and composites them with the route polyline and markers. The output is a PNG encoded into a `[]byte` and sent directly to Telegram via multipart form upload — no temporary files are written to disk.

- Route map: 800×450 px, blue polyline (3 px), green start marker, red end marker
- Location map: 600×400 px, zoom 15, single red pin

If fewer than 2 GPS points are available for a trip (very short drive or GPS loss), the map render is skipped and only the text caption is sent.
