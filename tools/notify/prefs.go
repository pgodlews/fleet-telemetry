package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// loadPrefs reads notify_user_prefs from the DB and applies any stored values
// to cfg, overriding the defaults/config-file values.
// cost_per_kwh of 0 in the DB means "not set via bot — use config file value".
func loadPrefs(ctx context.Context, pool *pgxpool.Pool, cfg *Config) error {
	const q = `
		SELECT units, temp_units, cost_per_kwh, currency
		FROM notify_user_prefs
		WHERE vin = $1`

	var units, tempUnits, currency string
	var costPerKWh float64
	err := pool.QueryRow(ctx, q, cfg.VIN).Scan(&units, &tempUnits, &costPerKWh, &currency)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// No row yet is fine — just use config-file defaults
			return nil
		}
		// Real error (column missing, permission denied, conn lost) — surface
		// it so the caller can log loudly and the user can investigate
		// instead of silently falling back to defaults forever.
		return fmt.Errorf("query prefs: %w", err)
	}
	if units != "" {
		cfg.SetUnits(units)
	}
	if tempUnits != "" {
		cfg.SetTempUnits(tempUnits)
	}
	if costPerKWh > 0 {
		cfg.SetCostPerKWh(costPerKWh)
	}
	if currency != "" {
		cfg.SetCurrency(currency)
	}
	return nil
}

// savePrefs upserts all user-configurable preferences for the VIN.
func savePrefs(ctx context.Context, pool *pgxpool.Pool, cfg *Config) error {
	snap := cfg.Snapshot()
	_, err := pool.Exec(ctx, `
		INSERT INTO notify_user_prefs (vin, units, temp_units, cost_per_kwh, currency, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (vin) DO UPDATE
		  SET units        = EXCLUDED.units,
		      temp_units   = EXCLUDED.temp_units,
		      cost_per_kwh = EXCLUDED.cost_per_kwh,
		      currency     = EXCLUDED.currency,
		      updated_at   = EXCLUDED.updated_at`,
		cfg.VIN, snap.Units, snap.TempUnits, snap.CostPerKWh, snap.Currency, time.Now(),
	)
	if err != nil {
		return fmt.Errorf("save prefs: %w", err)
	}
	return nil
}

// loadDBPlaces appends places stored in notify_places (added via /addplace) to
// cfg.Places. If a name already exists in cfg.Places (from config file) the DB
// version takes precedence — the config-file entry is replaced.
func loadDBPlaces(ctx context.Context, pool *pgxpool.Pool, cfg *Config) error {
	const q = `
		SELECT name, lat, lon, radius_m
		FROM notify_places
		WHERE vin = $1
		ORDER BY created_at`

	rows, err := pool.Query(ctx, q, cfg.VIN)
	if err != nil {
		return fmt.Errorf("load DB places: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var p Place
		if err := rows.Scan(&p.Name, &p.Lat, &p.Lon, &p.RadiusM); err != nil {
			return fmt.Errorf("scan place: %w", err)
		}
		cfg.UpsertPlace(p)
	}
	return rows.Err()
}

// addDBPlace inserts a new place into notify_places and updates cfg.Places.
// Returns inserted=true when the place did not already exist, false when an
// existing place with the same name was updated.
func addDBPlace(ctx context.Context, pool *pgxpool.Pool, cfg *Config, p Place) (bool, error) {
	// Use xmax to detect whether the row was inserted (xmax=0) or updated.
	const q = `
		INSERT INTO notify_places (vin, name, lat, lon, radius_m)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (vin, name) DO UPDATE
		  SET lat = EXCLUDED.lat,
		      lon = EXCLUDED.lon,
		      radius_m = EXCLUDED.radius_m
		RETURNING (xmax = 0) AS inserted`

	var inserted bool
	if err := pool.QueryRow(ctx, q, cfg.VIN, p.Name, p.Lat, p.Lon, p.RadiusM).Scan(&inserted); err != nil {
		return false, fmt.Errorf("insert place: %w", err)
	}

	cfg.UpsertPlace(p)
	return inserted, nil
}
