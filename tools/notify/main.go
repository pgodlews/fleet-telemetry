// tesla-notify: sends Telegram trip summaries after each completed drive.
//
// Normally runs as a long-lived daemon (--daemon, as deploy/docker-compose.yml
// does): a trip watcher, the Telegram command handler, a Supercharger feed
// watcher and a data-staleness watchdog. Without --daemon it makes one pass
// and exits, which suits cron or a manual --trip-id backfill. One pass:
//  1. Connects to TimescaleDB.
//  2. Queries the trips view for drives that ended > 12 minutes ago and have
//     not yet been recorded in telegram_notifications.
//  3. For each new trip: enriches with geocoding, weather, efficiency comparison
//     and charge status, renders a route map, then sends via Telegram.
//  4. Records the sent trip in telegram_notifications so it is never repeated.
//
// Usage:
//
//	tesla-notify [flags]
//
// Flags:
//
//	--config path      JSON config file (default: notify-config.json)
//	--conn string      DB connection string (overrides config / env NOTIFY_CONN)
//	--token string     Telegram bot token  (overrides config / env NOTIFY_TOKEN)
//	--chat-id string   Telegram chat ID    (overrides config / env NOTIFY_CHAT_ID)
//	--vin string       Vehicle VIN         (overrides config / env NOTIFY_VIN)
//	--cost-per-kwh f   £/kWh rate          (overrides config, default 0.23)
//	--units string     "km" or "miles"     (overrides config, default "km")
//	--temp-units string "c" or "f"         (overrides config, default "c")
//	--trip-id int      Send a specific trip by ID and exit (debug/backfill)
//	--dry-run          Print messages without sending or writing to DB
//	--daemon           Run as long-lived daemon (trip watcher + Telegram commands)
//	--packfade-once    Recompute the experimental capacity-fade estimate
//	                   (Packfade method) once, store it and exit; with
//	                   --dry-run print it without storing. Needs no Telegram
//	                   token and sends nothing.
//	--route-efficiency-once  Same for the experimental frequent-route
//	                   efficiency monitor (--route-covariates overrides the
//	                   covariate list, for diagnostics with --dry-run).
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	// go-staticmaps downloads OSM tiles via http.DefaultClient, which has no
	// timeout — one stalled tile request would block the trip watcher forever.
	// Nothing else in this binary uses the default client (telegram, weather
	// and nominatim each have their own), so a global timeout is safe.
	http.DefaultClient.Timeout = 60 * time.Second

	var (
		configPath = flag.String("config", "notify-config.json", "config file path")
		conn       = flag.String("conn", "", "DB connection string (overrides config)")
		token      = flag.String("token", "", "Telegram bot token (overrides config)")
		chatID     = flag.String("chat-id", "", "Telegram chat ID (overrides config)")
		vin        = flag.String("vin", "", "VIN to monitor (overrides config)")
		costPerKWh = flag.Float64("cost-per-kwh", 0, "£/kWh (0 = use config default)")
		units      = flag.String("units", "", `"km" or "miles" (overrides config)`)
		tempUnits  = flag.String("temp-units", "", `"c" or "f" (overrides config)`)
		tripID     = flag.Int("trip-id", 0, "send a specific trip by ID and exit")
		dryRun     = flag.Bool("dry-run", false, "print messages without sending or writing DB")
		daemon     = flag.Bool("daemon", false, "run as long-lived daemon with Telegram command handler")
		pfOnce     = flag.Bool("packfade-once", false, "recompute the experimental capacity-fade estimate once and exit (no Telegram)")
		reOnce     = flag.Bool("route-efficiency-once", false, "recompute the experimental route-efficiency monitor once and exit (no Telegram)")
		reCovs     = flag.String("route-covariates", "", "diagnostics: comma-separated covariates for --route-efficiency-once (default: the built-in list)")
	)
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	// Apply flag overrides (zero values mean "not set by flag")
	if *conn != "" {
		cfg.Conn = *conn
	}
	if *token != "" {
		cfg.TelegramToken = *token
	}
	if *chatID != "" {
		cfg.ChatID = *chatID
	}
	if *vin != "" {
		cfg.VIN = *vin
	}
	if *costPerKWh != 0 {
		cfg.SetCostPerKWh(*costPerKWh)
	}
	if *units != "" {
		cfg.SetUnits(*units)
	}
	if *tempUnits != "" {
		cfg.SetTempUnits(*tempUnits)
	}

	// --dry-run promises no sends and no writes, but the daemon's command
	// handler, feed watcher and trip watcher all act for real and none of them
	// take the flag. Reject the combination rather than silently breaking the
	// promise.
	if *dryRun && *daemon {
		log.Fatal("--dry-run cannot be combined with --daemon: the daemon's command, feed and trip handlers always send and write")
	}

	// Validate required fields
	if cfg.Conn == "" {
		log.Fatal("DB connection required: set --conn, NOTIFY_CONN env, or conn in config file")
	}
	if cfg.VIN == "" {
		log.Fatal("VIN required: set --vin, NOTIFY_VIN env, or vin in config file")
	}
	if (*pfOnce || *reOnce) && *daemon {
		log.Fatal("--packfade-once / --route-efficiency-once cannot be combined with --daemon")
	}
	if !*dryRun && !*pfOnce && !*reOnce {
		if cfg.TelegramToken == "" {
			log.Fatal("Telegram token required (or use --dry-run): set --token, NOTIFY_TOKEN env, or telegram_token in config")
		}
		if cfg.ChatID == "" {
			log.Fatal("Telegram chat ID required (or use --dry-run): set --chat-id, NOTIFY_CHAT_ID env, or telegram_chat_id in config")
		}
	}

	ctx := context.Background()

	pool, err := newPool(ctx, cfg.Conn)
	if err != nil {
		log.Fatalf("DB connect: %v", err)
	}
	defer pool.Close()

	pingCtx, cancelPing := context.WithTimeout(ctx, 10*time.Second)
	err = pool.Ping(pingCtx)
	cancelPing()
	if err != nil {
		log.Fatalf("DB ping: %v", err)
	}

	// ── One-shot capacity-fade estimate (experimental) ───────────────────────
	if *pfOnce {
		jctx, cancel := context.WithTimeout(ctx, packfadeTimeout)
		summary, err := runPackfade(jctx, pool, cfg.VIN, *dryRun)
		cancel()
		if err != nil {
			log.Fatalf("packfade: %v", err)
		}
		fmt.Println(summary)
		return
	}

	if *reOnce {
		var covs []string
		if *reCovs != "" {
			covs = strings.Split(*reCovs, ",")
		}
		jctx, cancel := context.WithTimeout(ctx, packfadeTimeout)
		summary, err := runRouteEff(jctx, pool, cfg.VIN, *dryRun, covs)
		cancel()
		if err != nil {
			log.Fatalf("route efficiency: %v", err)
		}
		fmt.Println(summary)
		return
	}

	// ── Daemon mode ───────────────────────────────────────────────────────────
	if *daemon {
		runDaemon(ctx, pool, cfg)
		return
	}

	// Cron mode reads the same stored preferences and named places the daemon
	// does. Without this the two execution paths disagreed: a unit or currency
	// changed through the bot applied to daemon-sent messages only, and cron
	// mode reverse-geocoded locations the user had already named.
	// Precedence is config file < database < flags, so flag overrides applied
	// above are re-applied afterwards.
	if err := loadPrefs(ctx, pool, cfg); err != nil {
		log.Printf("warn: load prefs: %v", err)
	}
	if err := loadDBPlaces(ctx, pool, cfg); err != nil {
		log.Printf("warn: load DB places: %v", err)
	}
	if *costPerKWh != 0 {
		cfg.SetCostPerKWh(*costPerKWh)
	}
	if *units != "" {
		cfg.SetUnits(*units)
	}
	if *tempUnits != "" {
		cfg.SetTempUnits(*tempUnits)
	}

	// Determine which trips to process
	var trips []TripRow
	if *tripID > 0 {
		t, err := fetchTripByID(ctx, pool, cfg.VIN, *tripID)
		if err != nil {
			log.Fatalf("fetch trip %d: %v", *tripID, err)
		}
		trips = []TripRow{t}
		log.Printf("manual mode: processing trip %d", *tripID)
	} else {
		trips, err = fetchUnnotifiedTrips(ctx, pool, cfg.VIN)
		if err != nil {
			log.Fatalf("fetch unnotified trips: %v", err)
		}
	}

	if len(trips) == 0 {
		log.Println("no new trips")
		return
	}

	log.Printf("%d trip(s) to notify", len(trips))

	for _, trip := range trips {
		log.Printf("trip %d: %s → %s  %.1f km  %.2f kWh",
			trip.TripID,
			trip.Started.Format("15:04"),
			trip.Ended.Format("15:04"),
			trip.DistanceKM,
			trip.KWhUsed,
		)

		if err := processTrip(ctx, pool, trip, cfg, *dryRun); err != nil {
			log.Printf("trip %d: %v", trip.TripID, err)
			// Continue to next trip — don't abort the whole run
		}
	}
}

// dbQueryTimeout bounds a single short query issued with its own context.
const dbQueryTimeout = 30 * time.Second

// dbStatementTimeout is the server-side ceiling on any statement the bot runs,
// set on every pooled connection unless the connection string already sets
// statement_timeout. It keeps one slow view from pinning a connection and a
// handler forever.
const dbStatementTimeout = "60s"

// newPool opens the connection pool with a statement_timeout default.
func newPool(ctx context.Context, conn string) (*pgxpool.Pool, error) {
	pcfg, err := pgxpool.ParseConfig(conn)
	if err != nil {
		return nil, err
	}
	if _, ok := pcfg.ConnConfig.RuntimeParams["statement_timeout"]; !ok {
		pcfg.ConnConfig.RuntimeParams["statement_timeout"] = dbStatementTimeout
	}
	return pgxpool.NewWithConfig(ctx, pcfg)
}

// processTrip handles one trip: enrichment → message → send → mark notified.
func processTrip(
	ctx context.Context,
	pool *pgxpool.Pool,
	trip TripRow,
	cfg *Config,
	dryRun bool,
) error {
	// ── Enrichments (all optional; errors are logged but don't abort) ────────

	places := cfg.SnapshotPlaces()
	startLabel := resolveLocation(trip.StartLat, trip.StartLon, places)
	endLabel := resolveLocation(trip.EndLat, trip.EndLon, places)

	avgEff, err := fetchAvgEfficiency(ctx, pool, cfg.VIN, trip.TripID)
	if err != nil {
		log.Printf("warn: avg efficiency: %v", err)
	}

	charge, err := fetchChargeState(ctx, pool, cfg.VIN)
	if err != nil {
		log.Printf("warn: charge state: %v", err)
	}

	weather, err := fetchWeather(trip.StartLat, trip.StartLon, trip.Started)
	if err != nil {
		log.Printf("warn: weather: %v", err)
	}

	gpsPoints, err := fetchGPSTrack(ctx, pool, cfg.VIN, trip.Started, trip.Ended)
	if err != nil {
		log.Printf("warn: GPS track: %v", err)
	}

	// ── Format message ───────────────────────────────────────────────────────

	msg := formatMessage(trip, startLabel, endLabel, avgEff, charge, weather, cfg)

	// ── Dry-run mode ─────────────────────────────────────────────────────────

	if dryRun {
		fmt.Println("─── DRY RUN ───────────────────────────────")
		fmt.Println(msg)
		fmt.Printf("[map: %d GPS points]\n\n", len(gpsPoints))
		return nil
	}

	// ── Send to Telegram ─────────────────────────────────────────────────────

	var sendErr error
	if len(gpsPoints) >= 2 {
		mapPNG, err := renderRouteMap(gpsPoints)
		if err != nil {
			log.Printf("warn: map render failed (%v) — sending text only", err)
			sendErr = sendMessage(cfg.TelegramToken, cfg.ChatID, msg)
		} else {
			sendErr = sendPhoto(cfg.TelegramToken, cfg.ChatID, mapPNG, msg)
			if sendErr != nil {
				// Fall back to text. Without this a photo that Telegram
				// rejects (oversized image, caption it will not accept) is
				// retried on every run and the summary is never delivered.
				log.Printf("warn: photo send failed (%v) — retrying as text", sendErr)
				sendErr = sendMessage(cfg.TelegramToken, cfg.ChatID, msg)
			}
		}
	} else {
		log.Printf("warn: only %d GPS point(s) — sending text only", len(gpsPoints))
		sendErr = sendMessage(cfg.TelegramToken, cfg.ChatID, msg)
	}

	if sendErr != nil {
		// Don't mark as notified — it will be retried on the next cron run
		return fmt.Errorf("telegram send: %w", sendErr)
	}

	// ── Mark notified ────────────────────────────────────────────────────────

	if err := markNotified(ctx, pool, cfg.VIN, trip.Started, trip.TripID); err != nil {
		// Non-fatal: the message was sent; if we can't record it we'll just
		// send a duplicate next run. Log loudly so it can be investigated.
		log.Printf("ERROR: failed to mark trip %d as notified: %v", trip.TripID, err)
		return nil
	}

	log.Printf("trip %d: sent and marked", trip.TripID)
	return nil
}
