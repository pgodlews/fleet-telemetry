package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	tripPollInterval       = 2 * time.Minute
	commandLongPoll        = 30              // seconds — Telegram long-poll timeout
	sessionCleanupInterval = 1 * time.Minute // how often to sweep stale sessions
	chatQueueDepth         = 32              // pending updates buffered per chat
	updatesMinBackoff      = 1 * time.Second
	updatesMaxBackoff      = 60 * time.Second
	handlerTimeout         = 2 * time.Minute // ceiling on one update's handler
	tripTimeout            = 3 * time.Minute // ceiling on one trip's enrichment + send
)

// chatDispatcher runs updates in arrival order within each chat, and
// concurrently across chats.
//
// Spawning a goroutine per update and serialising them with a per-chat mutex
// bounded concurrency but not order: goroutines for consecutive updates can
// acquire the mutex in either order, so a photo, a /done or a confirmation
// could be applied against the wrong conversation state. Each chat instead gets
// one worker draining a FIFO queue.
type chatDispatcher struct {
	mu     sync.Mutex
	queues map[int64]chan func()
	wg     sync.WaitGroup
	ctx    context.Context
}

func newChatDispatcher(ctx context.Context) *chatDispatcher {
	return &chatDispatcher{queues: make(map[int64]chan func()), ctx: ctx}
}

// submit enqueues fn for chatID. It blocks only if that chat's queue is full,
// which applies backpressure to the poll loop for a flooding chat without
// stalling any other.
func (d *chatDispatcher) submit(chatID int64, fn func()) {
	d.mu.Lock()
	q, ok := d.queues[chatID]
	if !ok {
		q = make(chan func(), chatQueueDepth)
		d.queues[chatID] = q
		d.wg.Add(1)
		go d.worker(q)
	}
	d.mu.Unlock()

	select {
	case q <- fn:
	case <-d.ctx.Done():
	}
}

func (d *chatDispatcher) worker(q chan func()) {
	defer d.wg.Done()
	for {
		select {
		case fn := <-q:
			fn()
		case <-d.ctx.Done():
			// Drain what is already queued so in-flight conversations finish.
			for {
				select {
				case fn := <-q:
					fn()
				default:
					return
				}
			}
		}
	}
}

// wait blocks until every chat worker has drained and exited. Only meaningful
// after the dispatcher's context is cancelled.
func (d *chatDispatcher) wait() { d.wg.Wait() }

// runDaemon starts the background goroutines (trip watcher, command handler,
// supercharger feed watcher, staleness watchdog, packfade estimate, route
// efficiency, session cleaner) and blocks until SIGINT or SIGTERM is received.
func runDaemon(ctx context.Context, pool *pgxpool.Pool, cfg *Config) {
	log.Println("daemon starting")

	// Load user preferences and DB-stored named places (overlays config file)
	if err := loadPrefs(ctx, pool, cfg); err != nil {
		log.Printf("warn: load prefs: %v", err)
	}
	if err := loadDBPlaces(ctx, pool, cfg); err != nil {
		log.Printf("warn: load DB places: %v", err)
	}
	log.Printf("units=%s temp=%s places=%d", cfg.Units, cfg.TempUnits, len(cfg.Places))

	// Supercharger data — load eagerly so the first /nearestcharger is fast
	scCache := &SuperchargerCache{}
	if err := scCache.Ensure(); err != nil {
		log.Printf("warn: supercharger data not loaded at startup: %v", err)
	} else {
		count, _ := scCache.Stats()
		log.Printf("supercharger cache loaded: %d sites", count)
	}

	// Session store for multi-turn service log conversations
	sessions := newSessionStore()

	cancelCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	var wg sync.WaitGroup

	// ── Trip watcher ────────────────────────────────────────────────────────
	wg.Add(1)
	go func() {
		defer wg.Done()
		tripWatcher(cancelCtx, pool, cfg)
	}()

	// ── Telegram command handler ─────────────────────────────────────────────
	wg.Add(1)
	go func() {
		defer wg.Done()
		commandHandler(cancelCtx, pool, cfg, scCache, sessions)
	}()

	// ── Supercharger feed watcher ────────────────────────────────────────────
	wg.Add(1)
	go func() {
		defer wg.Done()
		feedWatcher(cancelCtx, pool, cfg, scCache)
	}()

	// ── Staleness watchdog ───────────────────────────────────────────────────
	wg.Add(1)
	go func() {
		defer wg.Done()
		staleWatchdog(cancelCtx, pool, cfg)
	}()

	// ── Experimental capacity-fade estimate (daily, no messages) ────────────
	wg.Add(1)
	go func() {
		defer wg.Done()
		packfadeWatcher(cancelCtx, pool, cfg)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		routeEffWatcher(cancelCtx, pool, cfg)
	}()

	// ── Session cleanup ──────────────────────────────────────────────────────
	wg.Add(1)
	go func() {
		defer wg.Done()
		sessionCleaner(cancelCtx, sessions)
	}()

	// ── Wait for shutdown signal ─────────────────────────────────────────────
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigCh
	log.Printf("received signal %v — shutting down", sig)
	cancel()
	wg.Wait()
	log.Println("daemon stopped")
}

// tripWatcher polls the DB every tripPollInterval for unnotified trips and
// processes each one exactly as the cron-mode binary does.
func tripWatcher(ctx context.Context, pool *pgxpool.Pool, cfg *Config) {
	log.Println("trip watcher started")
	ticker := time.NewTicker(tripPollInterval)
	defer ticker.Stop()

	// Run once immediately at startup, then on each tick
	for {
		pollTrips(ctx, pool, cfg)

		select {
		case <-ctx.Done():
			log.Println("trip watcher stopped")
			return
		case <-ticker.C:
		}
	}
}

// pollTrips is the single-shot trip check extracted from main() cron mode.
//
// The whole pass runs under an advisory lock so a second runner (another
// daemon, or a cron entry left in place alongside it) cannot fetch and send the
// same trips concurrently.
func pollTrips(ctx context.Context, pool *pgxpool.Pool, cfg *Config) {
	lock, err := acquireTripNotifyLock(ctx, pool, cfg.VIN)
	if err != nil {
		log.Printf("trip watcher: %v", err)
		return
	}
	if lock == nil {
		log.Println("trip watcher: another notifier holds the trip lock, skipping this pass")
		return
	}
	defer lock.release(ctx, cfg.VIN)

	trips, err := fetchUnnotifiedTrips(ctx, pool, cfg.VIN)
	if err != nil {
		log.Printf("trip watcher: fetch unnotified trips: %v", err)
		return
	}
	if len(trips) == 0 {
		return
	}
	log.Printf("trip watcher: %d new trip(s)", len(trips))
	for _, trip := range trips {
		if ctx.Err() != nil {
			return
		}
		tctx, cancel := context.WithTimeout(ctx, tripTimeout)
		err := processTrip(tctx, pool, trip, cfg, false)
		cancel()
		if err != nil {
			log.Printf("trip watcher: trip %d: %v", trip.TripID, err)
		}
	}
}

// updateChatID returns the chat an update belongs to, or false for updates
// that carry neither a message nor a callback query.
func updateChatID(u telegramUpdate) (int64, bool) {
	if u.CallbackQuery != nil {
		id := u.CallbackQuery.Message.Chat.ID
		return id, id != 0
	}
	if u.Message.MessageID == 0 && u.Message.Chat.ID == 0 {
		return 0, false
	}
	return u.Message.Chat.ID, u.Message.Chat.ID != 0
}

// isConfiguredChat reports whether chatID is the one chat the bot serves.
func isConfiguredChat(cfg *Config, chatID int64) bool {
	return strconv.FormatInt(chatID, 10) == cfg.ChatID
}

// commandHandler runs the Telegram getUpdates long-poll loop. Each chat's
// updates run in order on that chat's worker (see chatDispatcher).
// On poll failures it backs off exponentially so a revoked token / network
// outage doesn't turn into a hot retry loop.
func commandHandler(ctx context.Context, pool *pgxpool.Pool, cfg *Config, scCache *SuperchargerCache, sessions *SessionStore) {
	log.Println("command handler started")
	offset := 0
	backoff := updatesMinBackoff
	dispatcher := newChatDispatcher(ctx)
	defer dispatcher.wait()

	for {
		if ctx.Err() != nil {
			log.Println("command handler stopped")
			return
		}

		updates, err := telegramGetUpdates(cfg.TelegramToken, offset, commandLongPoll)
		if err != nil {
			log.Printf("command handler: getUpdates: %v (backoff %s)", err, backoff)
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			if backoff < updatesMaxBackoff {
				backoff *= 2
				if backoff > updatesMaxBackoff {
					backoff = updatesMaxBackoff
				}
			}
			continue
		}
		backoff = updatesMinBackoff

		for _, u := range updates {
			// The offset advances before the handler runs: an update whose
			// handler crashes is not redelivered. Accepted and documented in
			// docs/notify-technical.md.
			offset = u.UpdateID + 1

			chatID, ok := updateChatID(u)
			if !ok {
				// Edited messages, channel posts and other update kinds arrive
				// with a zero Message; there is nothing to handle.
				continue
			}
			// Only the configured chat gets a queue and a worker. Checking
			// here, before submit, keeps a stranger who messages the bot from
			// creating a permanent goroutine per chat id, and applies the same
			// check to inline-button callbacks, which handleUpdate's own check
			// never saw.
			if !isConfiguredChat(cfg, chatID) {
				log.Printf("ignoring update from unknown chat %d", chatID)
				continue
			}

			u := u
			if u.CallbackQuery != nil {
				cq := *u.CallbackQuery
				dispatcher.submit(chatID, func() {
					hctx, cancel := context.WithTimeout(ctx, handlerTimeout)
					defer cancel()
					handleCallbackQuery(hctx, pool, cfg, scCache, sessions, cq)
				})
			} else {
				dispatcher.submit(chatID, func() {
					hctx, cancel := context.WithTimeout(ctx, handlerTimeout)
					defer cancel()
					handleUpdate(hctx, pool, cfg, scCache, sessions, u)
				})
			}
		}
	}
}

// sessionCleaner ticks every sessionCleanupInterval and removes sessions that
// have been inactive for longer than sessionTimeout (10 minutes).
func sessionCleaner(ctx context.Context, sessions *SessionStore) {
	log.Println("session cleaner started")
	ticker := time.NewTicker(sessionCleanupInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Println("session cleaner stopped")
			return
		case <-ticker.C:
			if n := sessions.purgeStale(); n > 0 {
				log.Printf("session cleaner: removed %d stale session(s)", n)
			}
		}
	}
}
