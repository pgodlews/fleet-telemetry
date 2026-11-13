# TeslikTripBot — User Guide

The Telegram bot sends you an automatic message after every completed drive, with a route map, trip stats, weather, and charging status. It also responds to commands so you can query your car's history at any time.

---

## What you get automatically

After each completed drive (detected when the car parks for 5+ minutes) you receive a photo message like this:

```
🚗 Trip complete · 42m

📍 Home → Work
📏 186.3 km  (115.8 mi)
⚡ 31.45 kWh
💰 Est. cost: £7.23  (@ 23p/kWh)
🌡️ 168 Wh/km  (270 Wh/mi)
📊 5% more efficient than 30-day avg
🔋 81% → 47%
🏎️  Avg 68 mph · Max 79 mph
🌤️ 12°C, partly cloudy
🔌 Now charging · full by ~19:30
```

The attached image is a rendered route map (OpenStreetMap tiles, blue polyline, green start pin, red end pin).

---

## Commands

Send any of these to the bot. Commands work any time — the bot is always listening.

### Summaries

| Command | What you get |
|---------|-------------|
| `/summary7d` | Stats for the last 7 days |
| `/summary30d` | Stats for the last 30 days |

Example response:
```
📊 Last 7 days

🚗 8 trips · 312.4 km  (194.2 mi)
⚡ 52.18 kWh used · avg 167 Wh/km
💰 Est. cost: £12.00
🔋 AC: 38.4 kWh  · DC: 0.0 kWh
🏆 Longest trip: 186.3 km
```

### Location

**`/lastknownlocation`** — Sends a map image centred on the car's most recent GPS position, with a red pin. Useful for confirming where you left the car, or checking it's home.

### Superchargers

**`/nearestcharger`** — Finds the 3 nearest **open** Tesla Superchargers to your car's last known location.

```
⚡ Nearest Tesla Superchargers

1. City North · 4.2 km · 8 stalls · 250 kW
2. Riverside Retail Park · 7.8 km · 12 stalls · 250 kW
3. Motorway Services · 18.4 km · 6 stalls · 150 kW

📍 Based on last known location
```

Data comes from [supercharge.info](https://supercharge.info) — a community-maintained database of every Tesla Supercharger worldwide.

### Configuration overview

**`/showconfig`** — Shows all active settings in one place:

```
⚙️ Active configuration

📏 Distance: miles
🌡️ Temperature: °C
💰 Currency: £
⚡ Energy price: £0.2037/kWh
🔍 SC alerts: 50 km radius
📍 Named places: 3 (Home, Work, Primary School)
🗺️ SC cache: 10507 sites, loaded 2h 14m ago
```

### Help

**`/help`** — Lists all available commands.

---

## Settings

All settings are saved to the database and survive bot restarts. They apply to both automatic trip messages and command responses.

### Distance units

```
/setunits km
/setunits miles
```

Affects trip distance, summary totals, Supercharger distances, and longest-trip stats. Defaults to `km`.

### Temperature units

```
/settemp c
/settemp f
```

Affects the weather line on trip messages (e.g. `12°C` vs `54°F`). Defaults to `c`.

### Currency

```
/setcurrency £
/setcurrency €
/setcurrency $
/setcurrency kr
```

Sets the symbol used in all cost displays — trip messages, summaries, and the energy price confirmation. Defaults to `£`. After changing currency you'll likely want to update the energy price too.

### Energy price

```
/setenergyprice 0.2037
```

Sets the cost per kWh in your configured currency (main unit, not subunits — so `0.2037` for £0.2037/kWh, not `20.37`). Applies to **future trips only** — past trip notifications are not recalculated.

Send `/setenergyprice` with no argument to see the current rate.

Useful when you switch tariff or energy provider.

### Named places

When a trip starts or ends near a named place, the bot uses your name instead of a street address (e.g. **Home** instead of "Carr Manor Avenue, Moor Allerton").

**List your places:**
```
/listplaces
```

**Add a place:**
```
/addplace <name> <lat> <lon> [radius_m]
```

- `name` — what to call the place; can contain spaces
- `lat` / `lon` — decimal GPS coordinates (find them in Google Maps by long-pressing a location)
- `radius_m` — optional match radius in metres (default: 100 m; suggested 150 m for home, 300 m for large car parks)

Examples:
```
/addplace Home 51.5007 -0.1246 150
/addplace Work 51.5055 -0.0754 300
/addplace Supermarket 51.503 -0.119 200
```

Places added via the bot are stored in the database and take precedence over any entries in the config file with the same name.

---

## Supercharger opening alerts

If a new Tesla Supercharger **opens** within a configurable distance of any of your named places, you'll automatically receive a notification:

```
⚡ New Supercharger near Home (12.3 km)
Riverside Retail Park
8 stalls · 250 kW
https://supercharge.info/map?siteId=1234
```

The alert radius is set in `notify-config.json` as `sc_alert_radius_km` (default: 50 km). Set it to `0` to disable alerts.

The bot checks the [supercharge.info feed](https://supercharge.info/service/supercharge/feed/atom.xml) every 6 hours — no extra setup needed.

---

## Service Log

The bot can record vehicle maintenance and service events directly from Telegram, with optional photo attachments.

### Starting a log entry

Send `/logservice` or tap **🔧 Log Service** in the keyboard. The bot will:

1. Fetch the current odometer reading from telemetry (shown at the top).
2. Ask for a description of the service.
3. Let you attach one or more photos.
4. Show a confirmation summary before saving.

Example flow:
```
You:  🔧 Log Service

Bot:  🔧 Log Service Entry
      📏 Current odometer: 47,234 km

      Please describe the service performed:

You:  Oil change + filter replacement

Bot:  ✅ Description saved.
      Send photo(s) to attach, or tap /skip to continue without photos.

You:  [sends receipt photo]

Bot:  📎 1 photo attached. Send another or tap /done to continue.

You:  /done

Bot:  📋 Review service entry
      📏 Odometer: 47,234 km
      📝 Oil change + filter replacement
      📎 1 photo attached

      Confirm to save this entry:
      [✅ Confirm] [❌ Cancel]

You:  ✅ Confirm

Bot:  ✅ Service entry #12 saved
      📏 47,234 km
      📝 Oil change + filter replacement
      📎 1 photo
```

### During the flow

| Button / Command | Effect |
|-----------------|--------|
| `/skip` | Skip photos and go straight to confirmation |
| `/done` | Finish adding photos and go to confirmation |
| `/cancel` or **❌ Cancel** | Discard the entry and return to the main keyboard |

> **Idle timeout**: if you start a log entry but don't complete it within **10 minutes**, the session is automatically discarded. Just send `/logservice` again to start over.

### Photo storage

Photos are saved on the host at `/u01/fleet-telemetry/attachments/{vin}/{date}/` — outside the Docker container, so they persist across restarts and binary updates. File paths are stored in the database alongside the log entry.

To change the attachments directory, set `"attachments_dir"` in `notify-config.json` (default: `/attachments`).

---

## Keyboard

The bot shows a persistent reply keyboard with quick-access buttons. If you accidentally dismiss it, send `/menu` to restore it. Send `/hidekeyboard` to hide it without losing any settings.

```
[ 📊 7d summary  ] [ 📊 30d summary ]
[ 🔧 Log Service ] [ 📍 Last location ]
[ ⚡ Nearest charger ] [ ⚙️ Show config ]
```

---

## Privacy notes

- The bot only responds to messages from the configured `telegram_chat_id`. All other senders are silently ignored.
- The bot makes **outbound-only** connections — no ports are exposed on your server.
- Named places (lat/lon) are stored in your own database and are never shared externally.
- Reverse geocoding (for trips that don't match a named place) uses the [Nominatim](https://nominatim.openstreetmap.org) public API; only the trip's end coordinates are sent.
