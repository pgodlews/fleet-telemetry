package main

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const superchargerURL = "https://supercharge.info/service/supercharge/allSites"
const superchargerFeedURL = "https://supercharge.info/service/supercharge/feed/atom.xml"
const superchargerCacheTTL = 7 * 24 * time.Hour
const feedPollInterval = 6 * time.Hour

// scSite mirrors the relevant fields from the supercharge.info allSites JSON.
type scSite struct {
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Status string `json:"status"`
	GPS    struct {
		Lat float64 `json:"latitude"`
		Lon float64 `json:"longitude"`
	} `json:"gps"`
	Address struct {
		City    string `json:"city"`
		Country string `json:"country"`
	} `json:"address"`
	StallCount    int `json:"stallCount"`
	PowerKilowatt int `json:"powerKilowatt"`
}

// SuperchargerCache holds an in-memory snapshot of all supercharger sites.
type SuperchargerCache struct {
	mu       sync.RWMutex
	sites    []scSite
	loadedAt time.Time
}

// Ensure loads (or refreshes) the cache if it is empty or older than the TTL.
func (sc *SuperchargerCache) Ensure() error {
	sc.mu.RLock()
	fresh := len(sc.sites) > 0 && time.Since(sc.loadedAt) < superchargerCacheTTL
	sc.mu.RUnlock()
	if fresh {
		return nil
	}
	sites, err := fetchAllSuperchargers()
	if err != nil {
		return err
	}
	sc.mu.Lock()
	sc.sites = sites
	sc.loadedAt = time.Now()
	sc.mu.Unlock()
	return nil
}

// invalidate forces the next Ensure() call to refetch the site list.
func (sc *SuperchargerCache) invalidate() {
	sc.mu.Lock()
	sc.loadedAt = time.Time{}
	sc.mu.Unlock()
}

// Stats returns the current cache size and load time (for /showconfig).
func (sc *SuperchargerCache) Stats() (int, time.Time) {
	sc.mu.RLock()
	defer sc.mu.RUnlock()
	return len(sc.sites), sc.loadedAt
}

// fetchAllSuperchargers downloads the full supercharger list from supercharge.info.
func fetchAllSuperchargers() ([]scSite, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(superchargerURL)
	if err != nil {
		return nil, fmt.Errorf("supercharge.info request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("supercharge.info HTTP %d", resp.StatusCode)
	}

	var sites []scSite
	if err := json.NewDecoder(resp.Body).Decode(&sites); err != nil {
		return nil, fmt.Errorf("supercharge.info decode: %w", err)
	}
	return sites, nil
}

// nearResult is a supercharger with its computed distance.
type nearResult struct {
	site   scSite
	distKM float64
}

// FindNearest returns up to n open superchargers closest to (lat, lon).
func (sc *SuperchargerCache) FindNearest(lat, lon float64, n int) []nearResult {
	sc.mu.RLock()
	defer sc.mu.RUnlock()
	var candidates []nearResult
	for _, s := range sc.sites {
		if s.Status != "OPEN" {
			continue
		}
		d := haversineM(lat, lon, s.GPS.Lat, s.GPS.Lon) / 1000.0
		candidates = append(candidates, nearResult{site: s, distKM: d})
	}
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].distKM < candidates[j].distKM
	})
	if n < len(candidates) {
		return candidates[:n]
	}
	return candidates
}

// siteByID looks up a supercharger site by its numeric ID.
// Returns the zero value and false if not found.
func (sc *SuperchargerCache) siteByID(id int) (scSite, bool) {
	sc.mu.RLock()
	defer sc.mu.RUnlock()
	for _, s := range sc.sites {
		if s.ID == id {
			return s, true
		}
	}
	return scSite{}, false
}

// formatNearestChargers builds the Telegram message text for /nearestcharger.
func formatNearestChargers(results []nearResult, units string) string {
	if len(results) == 0 {
		return "⚡ No open Tesla Superchargers found nearby."
	}

	msg := "⚡ <b>Nearest Tesla Superchargers</b>\n\n"
	for i, r := range results {
		var distStr string
		if units == "miles" {
			distStr = fmt.Sprintf("%.1f mi", r.distKM*0.621371)
		} else {
			distStr = fmt.Sprintf("%.1f km", r.distKM)
		}
		stallStr := "stall"
		if r.site.StallCount != 1 {
			stallStr = "stalls"
		}
		msg += fmt.Sprintf("%d. %s · %s · %d %s · %d kW\n",
			i+1, r.site.Name, distStr, r.site.StallCount, stallStr, r.site.PowerKilowatt)
	}
	msg += "\n📍 Based on last known location"
	return msg
}

// ── Atom feed watcher ─────────────────────────────────────────────────────────

// atomFeed is the minimal structure needed to parse the supercharge.info Atom feed.
type atomFeed struct {
	Entries []atomEntry `xml:"entry"`
}

type atomEntry struct {
	Title string `xml:"title"`
	Link  struct {
		Href string `xml:"href,attr"`
	} `xml:"link"`
	ID      string `xml:"id"`
	Updated string `xml:"updated"`
}

// reChangeID extracts the numeric change ID from the Atom entry ID string:
// "tag:supercharge.info,2018-03-19:all-changes-25276" → 25276
var reChangeID = regexp.MustCompile(`all-changes-(\d+)$`)

// reSiteID extracts the siteId query param from the entry link href.
var reSiteID = regexp.MustCompile(`siteId=(\d+)`)

// fetchFeedEntries downloads and parses the Atom feed.
func fetchFeedEntries() ([]atomEntry, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(superchargerFeedURL)
	if err != nil {
		return nil, fmt.Errorf("feed request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("feed HTTP %d", resp.StatusCode)
	}

	var feed atomFeed
	if err := xml.NewDecoder(resp.Body).Decode(&feed); err != nil {
		return nil, fmt.Errorf("feed decode: %w", err)
	}
	return feed.Entries, nil
}

// parseChangeID returns the integer change ID from an entry, or 0 on failure.
func parseChangeID(entry atomEntry) int {
	m := reChangeID.FindStringSubmatch(entry.ID)
	if len(m) < 2 {
		return 0
	}
	n, _ := strconv.Atoi(m[1])
	return n
}

// parseSiteID returns the siteId from the entry's link href, or 0 on failure.
func parseSiteID(entry atomEntry) int {
	m := reSiteID.FindStringSubmatch(entry.Link.Href)
	if len(m) < 2 {
		return 0
	}
	n, _ := strconv.Atoi(m[1])
	return n
}

// isOpenEvent returns true if the entry title indicates a site is now OPEN
// (covers both ADD→OPEN and UPDATE→OPEN transitions).
func isOpenEvent(title string) bool {
	upper := strings.ToUpper(title)
	return strings.Contains(upper, "- OPEN -") || strings.HasSuffix(upper, "- OPEN")
}

// feedWatcher polls the Atom feed every feedPollInterval and sends Telegram
// notifications when a Supercharger within cfg.SCAlertRadiusKM of any named
// place transitions to OPEN status.
func feedWatcher(ctx context.Context, pool *pgxpool.Pool, cfg *Config, scCache *SuperchargerCache) {
	if cfg.SCAlertRadiusKM <= 0 {
		log.Println("feed watcher disabled (sc_alert_radius_km = 0)")
		return
	}
	log.Printf("feed watcher started (radius %.0f km, poll every %s)", cfg.SCAlertRadiusKM, feedPollInterval)

	ticker := time.NewTicker(feedPollInterval)
	defer ticker.Stop()

	for {
		checkFeed(ctx, pool, cfg, scCache)

		select {
		case <-ctx.Done():
			log.Println("feed watcher stopped")
			return
		case <-ticker.C:
		}
	}
}

// checkFeed fetches the Atom feed and processes any entries newer than the
// last stored change ID.
func checkFeed(ctx context.Context, pool *pgxpool.Pool, cfg *Config, scCache *SuperchargerCache) {
	lastID, found, err := loadLastSCChangeID(ctx, pool, cfg.VIN)
	if err != nil {
		// Unknown checkpoint: treating it as 0 replayed the whole feed as new
		// alerts. Skip this pass and try again on the next tick.
		log.Printf("feed watcher: load checkpoint: %v (skipping this pass)", err)
		return
	}

	entries, err := fetchFeedEntries()
	if err != nil {
		log.Printf("feed watcher: fetch: %v", err)
		return
	}
	if len(entries) == 0 {
		return
	}

	if !found {
		// First run for this VIN: everything in the feed is history. Record
		// the newest change as the starting point and alert on nothing.
		if maxID := maxChangeID(entries); maxID > 0 {
			saveLastSCChangeID(ctx, pool, cfg.VIN, maxID)
			log.Printf("feed watcher: first run, checkpoint initialised at change %d", maxID)
		}
		return
	}

	// Entries are processed oldest-first and the checkpoint only advances past
	// an entry that has been fully handled — enriched and, if it produced an
	// alert, delivered. Previously the checkpoint moved as soon as an entry was
	// *seen*, and was persisted before any send, so a transient cache miss or a
	// Telegram outage skipped those alerts permanently.
	pending := make([]atomEntry, 0, len(entries))
	for _, entry := range entries {
		if id := parseChangeID(entry); id != 0 && id > lastID {
			pending = append(pending, entry)
		}
	}
	sort.Slice(pending, func(i, j int) bool {
		return parseChangeID(pending[i]) < parseChangeID(pending[j])
	})

	checkpoint := lastID
	defer func() {
		if checkpoint > lastID {
			saveLastSCChangeID(ctx, pool, cfg.VIN, checkpoint)
		}
	}()

	for _, entry := range pending {
		changeID := parseChangeID(entry)

		if !isOpenEvent(entry.Title) {
			checkpoint = changeID
			continue
		}

		siteID := parseSiteID(entry)
		if siteID == 0 {
			checkpoint = changeID
			continue
		}

		// Refresh cache if needed so newly-added sites are present
		if err := scCache.Ensure(); err != nil {
			// Transient: stop here so this entry is reconsidered next poll.
			log.Printf("feed watcher: refresh cache: %v (stopping at change %d)", err, changeID)
			return
		}

		site, ok := scCache.siteByID(siteID)
		if !ok {
			// Site not in cache yet — force a full refresh and retry
			scCache.invalidate()
			if err := scCache.Ensure(); err != nil {
				log.Printf("feed watcher: force refresh cache: %v (stopping at change %d)", err, changeID)
				return
			}
			site, ok = scCache.siteByID(siteID)
			if !ok {
				// Not transient: the feed references a site the dataset does
				// not have. Skip it rather than blocking the checkpoint.
				log.Printf("feed watcher: site %d not in dataset, skipping change %d", siteID, changeID)
				checkpoint = changeID
				continue
			}
		}

		// Check distance to each configured place
		msg := ""
		snap := cfg.Snapshot()
		for _, place := range cfg.SnapshotPlaces() {
			distKM := haversineM(place.Lat, place.Lon, site.GPS.Lat, site.GPS.Lon) / 1000.0
			if distKM <= cfg.SCAlertRadiusKM {
				var distStr string
				if snap.Units == "miles" {
					distStr = fmt.Sprintf("%.1f mi", distKM*0.621371)
				} else {
					distStr = fmt.Sprintf("%.1f km", distKM)
				}
				msg = fmt.Sprintf(
					"⚡ <b>New Supercharger near %s</b> (%s)\n%s\n%d stalls · %d kW\n%s",
					htmlEscape(place.Name), distStr,
					htmlEscape(site.Name),
					site.StallCount, site.PowerKilowatt,
					entry.Link.Href,
				)
				break // only one alert per site (nearest place is enough)
			}
		}

		if msg != "" {
			log.Printf("feed watcher: sending alert: %s", msg[:min(60, len(msg))])
			if err := sendMessage(cfg.TelegramToken, cfg.ChatID, msg); err != nil {
				log.Printf("feed watcher: send alert: %v (stopping at change %d)", err, changeID)
				return
			}
		}

		checkpoint = changeID
	}
}

// maxChangeID returns the highest change ID among entries (0 if none parse).
func maxChangeID(entries []atomEntry) int {
	maxID := 0
	for _, e := range entries {
		if id := parseChangeID(e); id > maxID {
			maxID = id
		}
	}
	return maxID
}

// loadLastSCChangeID reads the persisted last-seen change ID from the DB.
// found is false when no checkpoint has been stored yet (no prefs row, or the
// column still holds its default 0); err is set only for a real query failure.
func loadLastSCChangeID(ctx context.Context, pool *pgxpool.Pool, vin string) (id int, found bool, err error) {
	qctx, cancel := context.WithTimeout(ctx, dbQueryTimeout)
	defer cancel()
	err = pool.QueryRow(qctx, `
		SELECT last_sc_change_id FROM notify_user_prefs WHERE vin = $1`, vin).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return id, id > 0, nil
}

// saveLastSCChangeID upserts the last-seen change ID.
func saveLastSCChangeID(ctx context.Context, pool *pgxpool.Pool, vin string, changeID int) {
	qctx, cancel := context.WithTimeout(ctx, dbQueryTimeout)
	defer cancel()
	_, err := pool.Exec(qctx, `
		INSERT INTO notify_user_prefs (vin, last_sc_change_id)
		VALUES ($1, $2)
		ON CONFLICT (vin) DO UPDATE SET last_sc_change_id = EXCLUDED.last_sc_change_id`,
		vin, changeID)
	if err != nil {
		log.Printf("feed watcher: save change ID: %v", err)
	}
}
