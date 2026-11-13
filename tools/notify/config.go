package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Place is a named location with a GPS coordinate and a match radius.
// When a trip start or end point falls within radius_m metres of a Place,
// the Place name is used instead of the reverse-geocoded address.
type Place struct {
	Name    string  `json:"name"`
	Lat     float64 `json:"lat"`
	Lon     float64 `json:"lon"`
	RadiusM float64 `json:"radius_m"`
}

// Config holds all runtime configuration for the notify binary.
//
// Fields below the `mu` line are mutated at runtime from goroutines (callback
// handlers, watchers). They must be accessed via the helper methods so the
// race detector stays clean and `Places` iteration never overlaps with append.
// Fields above `mu` are written once at startup and then read-only.
type Config struct {
	Conn            string  `json:"conn"`
	TelegramToken   string  `json:"telegram_token"`
	ChatID          string  `json:"telegram_chat_id"`
	VIN             string  `json:"vin"`
	SCAlertRadiusKM float64 `json:"sc_alert_radius_km"` // alert when new charger opens within this distance of a named place (0 = disabled)
	AttachmentsDir  string  `json:"attachments_dir"`    // directory for service-log photos (default: /attachments)
	// StaleAfterHours: warn once when neither telemetry nor connectivity has
	// produced a row for this many hours (default 48; 0 disables).
	StaleAfterHours float64 `json:"stale_after_hours"`

	mu         sync.RWMutex
	CostPerKWh float64 `json:"cost_per_kwh"`
	Units      string  `json:"units"`      // "km" or "miles"
	TempUnits  string  `json:"temp_units"` // "c" or "f"
	Currency   string  `json:"currency"`   // currency symbol, e.g. "£", "€", "$"
	Places     []Place `json:"places"`
}

// StaleThreshold is StaleAfterHours as a duration (0 = watchdog disabled).
func (c *Config) StaleThreshold() time.Duration {
	if c.StaleAfterHours <= 0 {
		return 0
	}
	return time.Duration(c.StaleAfterHours * float64(time.Hour))
}

// PrefsSnapshot is an immutable copy of the user-tunable preferences.
type PrefsSnapshot struct {
	Units      string
	TempUnits  string
	Currency   string
	CostPerKWh float64
}

// Snapshot returns a consistent copy of the mutable preferences.
func (c *Config) Snapshot() PrefsSnapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return PrefsSnapshot{
		Units: c.Units, TempUnits: c.TempUnits,
		Currency: c.Currency, CostPerKWh: c.CostPerKWh,
	}
}

// SnapshotPlaces returns a copy of the named places list, safe to iterate
// without holding the lock.
func (c *Config) SnapshotPlaces() []Place {
	c.mu.RLock()
	defer c.mu.RUnlock()
	out := make([]Place, len(c.Places))
	copy(out, c.Places)
	return out
}

func (c *Config) GetUnits() string     { c.mu.RLock(); defer c.mu.RUnlock(); return c.Units }
func (c *Config) GetTempUnits() string { c.mu.RLock(); defer c.mu.RUnlock(); return c.TempUnits }
func (c *Config) GetCurrency() string  { c.mu.RLock(); defer c.mu.RUnlock(); return c.Currency }
func (c *Config) GetCostPerKWh() float64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.CostPerKWh
}

func (c *Config) SetUnits(v string)       { c.mu.Lock(); c.Units = v; c.mu.Unlock() }
func (c *Config) SetTempUnits(v string)   { c.mu.Lock(); c.TempUnits = v; c.mu.Unlock() }
func (c *Config) SetCurrency(v string)    { c.mu.Lock(); c.Currency = v; c.mu.Unlock() }
func (c *Config) SetCostPerKWh(v float64) { c.mu.Lock(); c.CostPerKWh = v; c.mu.Unlock() }

// upsertPlaceLocked replaces an existing place with the same name, or appends.
// Returns true if it was a new insert. Caller must hold c.mu (write).
func (c *Config) upsertPlaceLocked(p Place) bool {
	for i, existing := range c.Places {
		if existing.Name == p.Name {
			c.Places[i] = p
			return false
		}
	}
	c.Places = append(c.Places, p)
	return true
}

// UpsertPlace is the locked entry point used by callers outside this package's
// own writers (loadDBPlaces, addDBPlace).
func (c *Config) UpsertPlace(p Place) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.upsertPlaceLocked(p)
}

// HasPlace reports whether a place with the given name already exists.
func (c *Config) HasPlace(name string) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	for _, p := range c.Places {
		if p.Name == name {
			return true
		}
	}
	return false
}

// loadConfig reads the JSON config file at path (if it exists) and then
// applies environment variable overrides. The returned Config has defaults
// applied for CostPerKWh (0.23) and Units ("km").
func loadConfig(path string) (*Config, error) {
	cfg := &Config{
		CostPerKWh:      0.23,
		Units:           "km",
		TempUnits:       "c",
		Currency:        "£",
		SCAlertRadiusKM: 50,
		AttachmentsDir:  "/attachments",
		StaleAfterHours: 48,
	}

	if path != "" {
		f, err := os.Open(path)
		if err != nil && !os.IsNotExist(err) {
			return nil, fmt.Errorf("open config %q: %w", path, err)
		}
		if err == nil {
			defer f.Close()
			if err := json.NewDecoder(f).Decode(cfg); err != nil {
				return nil, fmt.Errorf("parse config %q: %w", path, err)
			}
		}
	}

	// Environment variable overrides (useful for Docker/cron without editing the file)
	if v := os.Getenv("NOTIFY_CONN"); v != "" {
		cfg.Conn = v
	}
	if v := os.Getenv("NOTIFY_TOKEN"); v != "" {
		cfg.TelegramToken = v
	}
	if v := os.Getenv("NOTIFY_CHAT_ID"); v != "" {
		cfg.ChatID = v
	}
	if v := os.Getenv("NOTIFY_VIN"); v != "" {
		cfg.VIN = v
	}
	if v := os.Getenv("NOTIFY_STALE_AFTER_HOURS"); v != "" {
		h, err := strconv.ParseFloat(v, 64)
		if err != nil || h < 0 {
			return nil, fmt.Errorf("NOTIFY_STALE_AFTER_HOURS: want a number of hours >= 0, got %q", v)
		}
		cfg.StaleAfterHours = h
	}

	cfg.TelegramToken = normalizeBotToken(cfg.TelegramToken)

	return cfg, nil
}

// normalizeBotToken strips a leading "bot" from a Telegram token.
//
// Every URL builder writes "/bot%s" itself, so a token copied from a sample
// that already carried the prefix produced "/botbot<token>" and failed
// authentication with nothing to explain why. A real BotFather token is
// "<digits>:<base64ish>" and never begins with "bot", so trimming it is safe.
func normalizeBotToken(token string) string {
	if strings.HasPrefix(token, "bot") {
		trimmed := strings.TrimPrefix(token, "bot")
		log.Printf("warn: telegram token starts with %q — the API prefix is added automatically, using %q...", "bot", trimmed[:min(6, len(trimmed))])
		return trimmed
	}
	return token
}
