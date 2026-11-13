package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strings"
	"sync"
	"time"
)

// resolveLocation returns a human-readable label for a GPS coordinate.
// It first checks the configured named places (haversine distance); if none
// match it falls back to a Nominatim reverse-geocode request.
func resolveLocation(lat, lon float64, places []Place) string {
	// 1. Named places — exact match by radius
	for _, p := range places {
		if haversineM(lat, lon, p.Lat, p.Lon) <= p.RadiusM {
			return p.Name
		}
	}

	// 2. Nominatim reverse geocode
	label, err := nominatimReverse(lat, lon)
	if err != nil {
		// Fall back to bare coordinates rather than failing loudly
		return fmt.Sprintf("%.4f, %.4f", lat, lon)
	}
	return label
}

// ── Nominatim cache ──────────────────────────────────────────────────────────
//
// The public Nominatim service requires no more than 1 request/second and
// asks us to cache aggressively. We key by coordinates rounded to ~0.001°
// (≈100 m), with a 1h TTL so repeat trips around named places don't keep
// hitting the API.
const (
	nominatimCacheTTL  = 1 * time.Hour
	nominatimCacheGrid = 0.001
	nominatimCacheMax  = 512
)

type nominatimCacheEntry struct {
	label  string
	expiry time.Time
}

var (
	nominatimCacheMu sync.Mutex
	nominatimCache   = map[string]nominatimCacheEntry{}
)

func nominatimCacheKey(lat, lon float64) string {
	round := func(v float64) float64 {
		return math.Round(v/nominatimCacheGrid) * nominatimCacheGrid
	}
	return fmt.Sprintf("%.4f,%.4f", round(lat), round(lon))
}

func nominatimCacheGet(lat, lon float64) (string, bool) {
	key := nominatimCacheKey(lat, lon)
	nominatimCacheMu.Lock()
	defer nominatimCacheMu.Unlock()
	if e, ok := nominatimCache[key]; ok && time.Now().Before(e.expiry) {
		return e.label, true
	}
	return "", false
}

func nominatimCachePut(lat, lon float64, label string) {
	key := nominatimCacheKey(lat, lon)
	nominatimCacheMu.Lock()
	defer nominatimCacheMu.Unlock()
	if len(nominatimCache) >= nominatimCacheMax {
		// Lazy eviction: drop expired entries, then if still over cap, drop one
		// arbitrary entry (map iteration order is randomised).
		now := time.Now()
		for k, e := range nominatimCache {
			if now.After(e.expiry) {
				delete(nominatimCache, k)
			}
		}
		if len(nominatimCache) >= nominatimCacheMax {
			for k := range nominatimCache {
				delete(nominatimCache, k)
				break
			}
		}
	}
	nominatimCache[key] = nominatimCacheEntry{label: label, expiry: time.Now().Add(nominatimCacheTTL)}
}

// haversineM returns the great-circle distance in metres between two points.
func haversineM(lat1, lon1, lat2, lon2 float64) float64 {
	const R = 6_371_000 // Earth radius in metres
	φ1 := lat1 * math.Pi / 180
	φ2 := lat2 * math.Pi / 180
	Δφ := (lat2 - lat1) * math.Pi / 180
	Δλ := (lon2 - lon1) * math.Pi / 180
	a := math.Sin(Δφ/2)*math.Sin(Δφ/2) +
		math.Cos(φ1)*math.Cos(φ2)*math.Sin(Δλ/2)*math.Sin(Δλ/2)
	return R * 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

// nominatimResponse is the subset of the Nominatim JSON response we care about.
type nominatimResponse struct {
	Address struct {
		Road         string `json:"road"`
		Suburb       string `json:"suburb"`
		CityDistrict string `json:"city_district"`
		Town         string `json:"town"`
		City         string `json:"city"`
		Village      string `json:"village"`
	} `json:"address"`
}

var nominatimClient = &http.Client{Timeout: 5 * time.Second}

// nominatimMinInterval is the minimum spacing between outbound Nominatim
// requests, per that service's usage policy.
const nominatimMinInterval = 1 * time.Second

var (
	nominatimRateMu   sync.Mutex
	nominatimLastCall time.Time
)

// nominatimWait blocks until at least nominatimMinInterval has passed since
// the previous request. The cache alone did not enforce the stated one
// request per second: two different coordinates in one trip miss
// back-to-back, and concurrent workers miss concurrently.
func nominatimWait() {
	nominatimRateMu.Lock()
	defer nominatimRateMu.Unlock()
	if wait := nominatimMinInterval - time.Since(nominatimLastCall); wait > 0 {
		time.Sleep(wait)
	}
	nominatimLastCall = time.Now()
}

// nominatimReverse calls the public Nominatim API and returns a short
// human-readable address (road + area). Results are cached for ~1h per
// rounded (lat, lon) bucket.
func nominatimReverse(lat, lon float64) (string, error) {
	if hit, ok := nominatimCacheGet(lat, lon); ok {
		return hit, nil
	}
	nominatimWait()
	// Re-check: another caller may have populated this key while we waited.
	if hit, ok := nominatimCacheGet(lat, lon); ok {
		return hit, nil
	}
	url := fmt.Sprintf(
		"https://nominatim.openstreetmap.org/reverse?lat=%f&lon=%f&format=json&zoom=16",
		lat, lon,
	)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	// Nominatim policy requires a descriptive User-Agent
	req.Header.Set("User-Agent", "tesla-fleet-telemetry-notify/1.0")

	resp, err := nominatimClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("nominatim request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("nominatim HTTP %d", resp.StatusCode)
	}

	var nr nominatimResponse
	if err := json.NewDecoder(resp.Body).Decode(&nr); err != nil {
		return "", fmt.Errorf("nominatim decode: %w", err)
	}

	// Build a concise label: "Road, Area"
	parts := []string{}
	if nr.Address.Road != "" {
		parts = append(parts, nr.Address.Road)
	}
	area := firstNonEmpty(
		nr.Address.Suburb,
		nr.Address.CityDistrict,
		nr.Address.Town,
		nr.Address.City,
		nr.Address.Village,
	)
	if area != "" {
		parts = append(parts, area)
	}

	var label string
	if len(parts) == 0 {
		label = fmt.Sprintf("%.4f, %.4f", lat, lon)
	} else {
		label = strings.Join(parts, ", ")
	}
	nominatimCachePut(lat, lon, label)
	return label, nil
}

func firstNonEmpty(ss ...string) string {
	for _, s := range ss {
		if s != "" {
			return s
		}
	}
	return ""
}
