package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// watchdogInterval is how often the staleness watchdog looks at the data.
const watchdogInterval = time.Hour

// watchdogAction is what one watchdog pass decided to do.
type watchdogAction int

const (
	watchdogNone    watchdogAction = iota
	watchdogWarn                   // data went stale; send one warning
	watchdogRecover                // data resumed after a warning; send one note
)

// watchdogDecide is the pure decision for one pass. newest is the newest of
// the latest telemetry and connectivity rows (nil when the VIN has no data at
// all, which is a fresh install rather than an outage, so it never warns).
func watchdogDecide(newest *time.Time, now time.Time, threshold time.Duration, alerted bool) watchdogAction {
	if threshold <= 0 || newest == nil {
		if alerted && newest != nil {
			return watchdogRecover
		}
		return watchdogNone
	}
	stale := now.Sub(*newest) > threshold
	switch {
	case stale && !alerted:
		return watchdogWarn
	case !stale && alerted:
		return watchdogRecover
	}
	return watchdogNone
}

// staleWatchdog runs watchdogPass every watchdogInterval until ctx ends.
func staleWatchdog(ctx context.Context, pool *pgxpool.Pool, cfg *Config) {
	threshold := cfg.StaleThreshold()
	if threshold <= 0 {
		log.Println("staleness watchdog disabled (stale_after_hours = 0)")
		return
	}
	log.Printf("staleness watchdog started (threshold %s, every %s)", threshold, watchdogInterval)
	ticker := time.NewTicker(watchdogInterval)
	defer ticker.Stop()
	for {
		if err := watchdogPass(ctx, pool, cfg, threshold, time.Now()); err != nil {
			log.Printf("staleness watchdog: %v", err)
		}
		select {
		case <-ctx.Done():
			log.Println("staleness watchdog stopped")
			return
		case <-ticker.C:
		}
	}
}

// watchdogPass checks data freshness once and sends at most one message.
func watchdogPass(ctx context.Context, pool *pgxpool.Pool, cfg *Config, threshold time.Duration, now time.Time) error {
	qctx, cancel := context.WithTimeout(ctx, dbQueryTimeout)
	defer cancel()

	// ORDER BY ts DESC LIMIT 1 lets TimescaleDB stop at the newest chunk.
	var lastTelemetry, lastConn *time.Time
	if err := pool.QueryRow(qctx, `
		SELECT
		  (SELECT ts FROM telemetry            WHERE vin = $1 ORDER BY ts DESC LIMIT 1),
		  (SELECT ts FROM vehicle_connectivity WHERE vin = $1 ORDER BY ts DESC LIMIT 1)`,
		cfg.VIN).Scan(&lastTelemetry, &lastConn); err != nil {
		return fmt.Errorf("query newest rows: %w", err)
	}
	newest := latestOf(lastTelemetry, lastConn)

	var sentAt *time.Time
	err := pool.QueryRow(qctx,
		`SELECT stale_alert_sent_at FROM notify_watchdog WHERE vin = $1`, cfg.VIN).Scan(&sentAt)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("query watchdog state: %w", err)
	}

	switch watchdogDecide(newest, now, threshold, sentAt != nil) {
	case watchdogWarn:
		msg := fmt.Sprintf("⚠️ <b>No vehicle data for %s</b>\n"+
			"Newest telemetry or connectivity row: %s.\n"+
			"Check the fleet-telemetry container, its certificate, and the vehicle's telemetry config.",
			formatDuration(now.Sub(*newest).Truncate(time.Hour)), newest.UTC().Format("2006-01-02 15:04 UTC"))
		if err := sendMessage(cfg.TelegramToken, cfg.ChatID, msg); err != nil {
			return fmt.Errorf("send warning: %w", err)
		}
		return setWatchdogState(qctx, pool, cfg.VIN, &now)
	case watchdogRecover:
		msg := fmt.Sprintf("✅ Vehicle data is flowing again (newest row %s).",
			newest.UTC().Format("2006-01-02 15:04 UTC"))
		if err := sendMessage(cfg.TelegramToken, cfg.ChatID, msg); err != nil {
			return fmt.Errorf("send recovery: %w", err)
		}
		return setWatchdogState(qctx, pool, cfg.VIN, nil)
	}
	return nil
}

// latestOf returns the later of two optional timestamps.
func latestOf(a, b *time.Time) *time.Time {
	switch {
	case a == nil:
		return b
	case b == nil:
		return a
	case b.After(*a):
		return b
	}
	return a
}

func setWatchdogState(ctx context.Context, pool *pgxpool.Pool, vin string, sentAt *time.Time) error {
	_, err := pool.Exec(ctx, `
		INSERT INTO notify_watchdog (vin, stale_alert_sent_at, updated_at)
		VALUES ($1, $2, now())
		ON CONFLICT (vin) DO UPDATE
		  SET stale_alert_sent_at = EXCLUDED.stale_alert_sent_at,
		      updated_at          = now()`, vin, sentAt)
	if err != nil {
		return fmt.Errorf("save watchdog state: %w", err)
	}
	return nil
}
