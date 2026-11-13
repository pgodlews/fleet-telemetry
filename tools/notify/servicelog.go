package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// ── Session state machine ─────────────────────────────────────────────────────

type sessionState int

const (
	// Service log states
	stateAwaitingDescription sessionState = iota
	stateAwaitingServiceItem              // optional: which service_intervals item this was
	stateAwaitingPhoto
	stateAwaitingServiceLocation // optional GPS of where the service was done
	stateAwaitingConfirm
	// Add-place states
	stateAwaitingPlaceLocation // waiting for user to share a Telegram location
	stateAwaitingPlaceName     // got location, waiting for place name
	stateAwaitingPlaceRadius   // got name, waiting for radius (or /skip)
)

// sessionTimeout is how long an inactive session is kept before being discarded.
const sessionTimeout = 10 * time.Minute

// ServiceLogSession holds in-progress state for one multi-turn conversation.
// It covers both the service-log flow and the add-place flow (keyed by State).
type ServiceLogSession struct {
	State sessionState
	// Service log fields
	OdometerKM  *float64 // fetched at session start; nil if unavailable
	Description string
	ServiceItem string            // service_intervals.item, "" if none chosen
	ItemChoices map[string]string // lowercased button label -> item, for this session
	PhotoPaths  []string
	ServiceLat  *float64 // optional GPS of service location
	ServiceLon  *float64
	// Add-place fields
	PlaceLat  float64
	PlaceLon  float64
	PlaceName string
	// Common
	CreatedAt    time.Time
	LastActivity time.Time
}

// ── SessionStore ──────────────────────────────────────────────────────────────

// SessionStore is a thread-safe map of active service log sessions keyed by
// chat ID. It also vends per-chat mutexes that callers must hold for the entire
// duration of handling one update — this serialises concurrent goroutines
// processing updates from the same chat so the session fields can be mutated
// without further locking.
type SessionStore struct {
	mu        sync.Mutex
	sessions  map[int64]*ServiceLogSession
	chatLocks map[int64]*sync.Mutex
}

func newSessionStore() *SessionStore {
	return &SessionStore{
		sessions:  make(map[int64]*ServiceLogSession),
		chatLocks: make(map[int64]*sync.Mutex),
	}
}

// chatLock returns (creating if needed) the per-chat mutex for chatID.
func (s *SessionStore) chatLock(chatID int64) *sync.Mutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.chatLocks[chatID]
	if !ok {
		m = &sync.Mutex{}
		s.chatLocks[chatID] = m
	}
	return m
}

// lockChat and unlockChat serialise update handling per chat.
func (s *SessionStore) lockChat(chatID int64)   { s.chatLock(chatID).Lock() }
func (s *SessionStore) unlockChat(chatID int64) { s.chatLock(chatID).Unlock() }

func (s *SessionStore) get(chatID int64) *ServiceLogSession {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sessions[chatID]
}

func (s *SessionStore) set(chatID int64, sess *ServiceLogSession) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sessions[chatID] = sess
}

func (s *SessionStore) clear(chatID int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.sessions, chatID)
}

func (s *SessionStore) touch(chatID int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if sess, ok := s.sessions[chatID]; ok {
		sess.LastActivity = time.Now()
	}
}

// purgeStale removes sessions that have been inactive for longer than
// sessionTimeout and deletes any on-disk photos attached to them. Returns the
// number of sessions removed.
func (s *SessionStore) purgeStale() int {
	// Two passes. The first only nominates candidates under s.mu; the actual
	// removal happens under the same per-chat lock a handler holds for the
	// whole duration of an update. Deleting under s.mu alone let cleanup pull
	// a session (and its photos) out from under a handler that had already
	// fetched it, and raced on PhotoPaths, which handlers mutate under the
	// per-chat lock rather than s.mu.
	s.mu.Lock()
	cutoff := time.Now().Add(-sessionTimeout)
	var candidates []int64
	for chatID, sess := range s.sessions {
		if sess.LastActivity.Before(cutoff) {
			candidates = append(candidates, chatID)
		}
	}
	s.mu.Unlock()

	type doomed struct {
		chatID int64
		paths  []string
		idle   time.Time
	}
	var purged []doomed

	for _, chatID := range candidates {
		lock := s.chatLock(chatID)
		if !lock.TryLock() {
			// A handler owns this chat right now. Leave it for the next sweep
			// rather than deleting state it is using.
			continue
		}
		s.mu.Lock()
		// Re-check expiry: the session may have been touched or cleared
		// between the two passes.
		if sess, ok := s.sessions[chatID]; ok && sess.LastActivity.Before(time.Now().Add(-sessionTimeout)) {
			purged = append(purged, doomed{
				chatID: chatID,
				paths:  append([]string(nil), sess.PhotoPaths...),
				idle:   sess.LastActivity,
			})
			delete(s.sessions, chatID)
		}
		s.mu.Unlock()
		lock.Unlock()
	}

	for _, d := range purged {
		removePhotos(d.paths)
		log.Printf("session store: purged stale session for chat %d (idle since %s, %d photo(s) deleted)",
			d.chatID, d.idle.Format(time.RFC3339), len(d.paths))
	}
	return len(purged)
}

// removePhotos best-effort deletes the on-disk photos for an abandoned session.
func removePhotos(paths []string) {
	for _, p := range paths {
		if p == "" {
			continue
		}
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			log.Printf("session store: remove orphan photo %s: %v", p, err)
		}
	}
}

// ── Keyboards ─────────────────────────────────────────────────────────────────

// mainMenuKeyboard returns the persistent reply keyboard shown outside log flows.
func mainMenuKeyboard() replyKeyboardMarkup {
	return replyKeyboardMarkup{
		Keyboard: [][]keyboardButton{
			{{Text: "📊 7d summary"}, {Text: "📊 30d summary"}},
			{{Text: "🔧 Log Service"}, {Text: "📍 Last location"}},
			{{Text: "⚡ Nearest charger"}, {Text: "⚙️ Show config"}},
		},
		ResizeKeyboard: true,
	}
}

// cancelRow is the bottom row present on every flow keyboard so the user can
// always bail out back to the main menu with one tap.
var cancelRow = []keyboardButton{{Text: "❌ Cancel · main menu"}}

// cancelOnlyKeyboard offers a single Cancel · main menu button. Used when the
// bot prompts the user to bail out of an in-progress flow.
func cancelOnlyKeyboard() replyKeyboardMarkup {
	return replyKeyboardMarkup{
		Keyboard:       [][]keyboardButton{cancelRow},
		ResizeKeyboard: true,
	}
}

// mainMenuLabels are the persistent reply-keyboard labels. Typing one of these
// mid-flow is treated as an implicit cancel + dispatch (handled by the caller).
var mainMenuLabels = map[string]bool{
	"📊 7d summary":      true,
	"📊 30d summary":     true,
	"🔧 log service":     true,
	"📍 last location":   true,
	"⚡ nearest charger": true,
	"⚙️ show config":    true,
}

// cancelLabel is the text the cancel button sends, lowercased.
var cancelLabel = strings.ToLower(cancelRow[0].Text)

// isCancelInput reports whether s (already lowercased+trimmed) is a cancel
// request: exactly /cancel (optionally addressed to the bot) or the cancel
// button's label. A substring match aborted the flow — and deleted the
// photos — for a description such as "cancelled appointment, rebooked".
func isCancelInput(s string) bool {
	if s == "/cancel" || strings.HasPrefix(s, "/cancel@") {
		return true
	}
	return s == cancelLabel
}

// isControlLabel reports whether s (lowercased+trimmed) is one of the flow
// buttons' labels or their slash forms. These must never be stored as a
// description or place name.
func isControlLabel(s string) bool {
	switch s {
	case "⏭ skip", "/skip", "✅ done", "/done", "✅ confirm", "/confirm":
		return true
	}
	return false
}

// isImplicitCancel reports whether the user typed a main-menu label or a known
// slash command that should abort the current flow before being dispatched.
func isImplicitCancel(s string) bool {
	if mainMenuLabels[s] {
		return true
	}
	// Known top-level commands that should not be swallowed as flow input.
	switch strings.SplitN(s, " ", 2)[0] {
	case "/start", "/menu", "/help", "/hidekeyboard",
		"/summary7d", "/summary30d", "/lastknownlocation",
		"/nearestcharger", "/logservice", "/showconfig",
		"/setunits", "/settemp", "/setenergyprice", "/setcurrency",
		"/addplace", "/listplaces":
		return true
	}
	return false
}

// logFlowSkipKeyboard is shown when waiting for a first photo (no photos yet).
func logFlowSkipKeyboard() replyKeyboardMarkup {
	return replyKeyboardMarkup{
		Keyboard:       [][]keyboardButton{{{Text: "⏭ Skip"}}, cancelRow},
		ResizeKeyboard: true,
	}
}

// logFlowDoneKeyboard is shown when at least one photo has been attached.
func logFlowDoneKeyboard() replyKeyboardMarkup {
	return replyKeyboardMarkup{
		Keyboard:       [][]keyboardButton{{{Text: "✅ Done"}}, cancelRow},
		ResizeKeyboard: true,
	}
}

// logLocationKeyboard is shown at the service location step.
// The request_location button sends GPS automatically when pressed.
func logLocationKeyboard() replyKeyboardMarkup {
	return replyKeyboardMarkup{
		Keyboard: [][]keyboardButton{
			{{Text: "📍 Share my location", RequestLocation: true}, {Text: "⏭ Skip"}},
			cancelRow,
		},
		ResizeKeyboard: true,
	}
}

// confirmKeyboard is shown at the confirmation step.
func confirmKeyboard() replyKeyboardMarkup {
	return replyKeyboardMarkup{
		Keyboard:       [][]keyboardButton{{{Text: "✅ Confirm"}}, cancelRow},
		ResizeKeyboard: true,
	}
}

// formatOdometer returns an HTML-formatted odometer string in the user's
// preferred unit.  km is the input value in kilometres (the unit used in
// session state and the service_log DB column).
func formatOdometer(cfg *Config, km float64, prefix string) string {
	if cfg.GetUnits() == "miles" {
		return fmt.Sprintf("%s<b>%.0f mi</b>", prefix, km*0.621371)
	}
	return fmt.Sprintf("%s<b>%.0f km</b>", prefix, km)
}

// ── Entry point ───────────────────────────────────────────────────────────────

// startServiceLog begins a new service log session for the given chat.
// Called when the user sends /logservice or taps "🔧 Log Service".
func startServiceLog(
	ctx context.Context,
	pool *pgxpool.Pool,
	cfg *Config,
	sessions *SessionStore,
	chatID int64,
) {
	odo, err := fetchCurrentOdometer(ctx, pool, cfg.VIN)
	if err != nil {
		log.Printf("service log: odometer: %v", err)
	}

	items, err := fetchServiceItems(ctx, pool)
	if err != nil {
		log.Printf("service log: service items: %v", err)
	}

	now := time.Now()
	sessions.set(chatID, &ServiceLogSession{
		State:        stateAwaitingDescription,
		OdometerKM:   odo,
		ItemChoices:  serviceItemChoices(items),
		CreatedAt:    now,
		LastActivity: now,
	})

	var sb strings.Builder
	sb.WriteString("🔧 <b>Log Service Entry</b>\n\n")
	if odo != nil {
		sb.WriteString(formatOdometer(cfg, *odo, "📏 Current odometer: ") + "\n\n")
	} else {
		sb.WriteString("📏 Odometer: <i>not available</i>\n\n")
	}
	sb.WriteString("Please describe the service performed:")

	// Cancel only: the description is required, so a Skip button here was
	// stored verbatim as the description.
	if err := sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID, sb.String(),
		cancelOnlyKeyboard()); err != nil {
		log.Printf("service log: send start: %v", err)
	}
}

// ── Step dispatcher ───────────────────────────────────────────────────────────

// handleServiceLogStep routes an incoming message to the right handler based on
// the current session state. Returns true if the message was consumed by the
// service log flow so the caller can skip normal command processing.
func handleServiceLogStep(
	ctx context.Context,
	pool *pgxpool.Pool,
	cfg *Config,
	sessions *SessionStore,
	chatID int64,
	msg telegramMessage,
) bool {
	sess := sessions.get(chatID)
	if sess == nil {
		return false
	}

	lower := strings.ToLower(strings.TrimSpace(msg.Text))

	// Cancel is valid at any step.
	if isCancelInput(lower) {
		removePhotos(sess.PhotoPaths)
		sessions.clear(chatID)
		if err := sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
			"❌ Cancelled.", mainMenuKeyboard()); err != nil {
			log.Printf("service log: send cancel: %v", err)
		}
		return true
	}

	// If the user typed a main-menu label or a known slash command mid-flow,
	// abort the flow and let the normal dispatcher handle the new request.
	if isImplicitCancel(lower) {
		removePhotos(sess.PhotoPaths)
		sessions.clear(chatID)
		_ = sendMessage(cfg.TelegramToken, cfg.ChatID,
			"ℹ️ Previous flow cancelled.")
		return false // fall through to command dispatch
	}

	sessions.touch(chatID)

	switch sess.State {
	case stateAwaitingDescription:
		return handleLogDescription(cfg, sessions, chatID, sess, strings.TrimSpace(msg.Text))

	case stateAwaitingServiceItem:
		return handleLogServiceItem(cfg, sess, lower)

	case stateAwaitingPhoto:
		return handleLogPhoto(ctx, cfg, sessions, chatID, sess, msg, lower)

	case stateAwaitingServiceLocation:
		return handleServiceLocation(cfg, sessions, chatID, sess, msg, lower)

	case stateAwaitingConfirm:
		return handleLogConfirm(ctx, pool, cfg, sessions, chatID, sess, lower)

	case stateAwaitingPlaceLocation:
		return handlePlaceLocation(cfg, sessions, chatID, sess, msg)

	case stateAwaitingPlaceName:
		return handlePlaceName(cfg, sessions, chatID, sess, strings.TrimSpace(msg.Text))

	case stateAwaitingPlaceRadius:
		return handlePlaceRadius(ctx, pool, cfg, sessions, chatID, sess, strings.TrimSpace(msg.Text), lower)
	}

	return false
}

// ── Step handlers ─────────────────────────────────────────────────────────────

func handleLogDescription(
	cfg *Config,
	sessions *SessionStore,
	chatID int64,
	sess *ServiceLogSession,
	text string,
) bool {
	if text == "" || isControlLabel(strings.ToLower(text)) {
		_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
			"Please enter a description of the service performed.", cancelOnlyKeyboard())
		return true
	}

	sess.Description = text

	// Offer the scheduled service items so a logged service also resets that
	// item in service_interval_status. Without a list (query failed, table
	// empty) go straight to photos.
	if len(sess.ItemChoices) > 0 {
		sess.State = stateAwaitingServiceItem
		_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
			"✅ Description saved.\n\nWas this one of the scheduled service items? "+
				"Pick it to reset its interval, or tap <b>"+htmlEscape(noServiceItemLabel)+"</b>.",
			serviceItemKeyboard(sess.ItemChoices))
		return true
	}
	promptForPhotos(cfg, sess)
	return true
}

// noServiceItemLabel is the "not a scheduled item" button.
const noServiceItemLabel = "➖ Other / none of these"

// serviceItemLabel turns a service_intervals.item key into a button label.
func serviceItemLabel(item string) string {
	words := strings.ReplaceAll(item, "_", " ")
	if words == "" {
		return "🔧"
	}
	return "🔧 " + strings.ToUpper(words[:1]) + words[1:]
}

// serviceItemChoices maps lowercased button labels to item keys.
func serviceItemChoices(items []string) map[string]string {
	out := make(map[string]string, len(items))
	for _, it := range items {
		out[strings.ToLower(serviceItemLabel(it))] = it
	}
	return out
}

// serviceItemKeyboard shows one button per item (sorted, two per row), then
// the "none" button and cancel.
func serviceItemKeyboard(choices map[string]string) replyKeyboardMarkup {
	items := make([]string, 0, len(choices))
	for _, it := range choices {
		items = append(items, it)
	}
	sort.Strings(items)
	var rows [][]keyboardButton
	for i := 0; i < len(items); i += 2 {
		row := []keyboardButton{{Text: serviceItemLabel(items[i])}}
		if i+1 < len(items) {
			row = append(row, keyboardButton{Text: serviceItemLabel(items[i+1])})
		}
		rows = append(rows, row)
	}
	rows = append(rows, []keyboardButton{{Text: noServiceItemLabel}}, cancelRow)
	return replyKeyboardMarkup{Keyboard: rows, ResizeKeyboard: true}
}

// handleLogServiceItem records the optional scheduled item and moves on to
// the photo step.
func handleLogServiceItem(cfg *Config, sess *ServiceLogSession, lower string) bool {
	switch {
	case lower == strings.ToLower(noServiceItemLabel) || lower == "/skip":
		sess.ServiceItem = ""
	case sess.ItemChoices[lower] != "":
		sess.ServiceItem = sess.ItemChoices[lower]
	default:
		_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
			"Please pick one of the buttons, or tap <b>"+htmlEscape(noServiceItemLabel)+"</b>.",
			serviceItemKeyboard(sess.ItemChoices))
		return true
	}
	promptForPhotos(cfg, sess)
	return true
}

// promptForPhotos moves the session to the photo step.
func promptForPhotos(cfg *Config, sess *ServiceLogSession) {
	sess.State = stateAwaitingPhoto
	_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
		"Send photo(s) to attach, or tap /skip to continue without photos.",
		logFlowSkipKeyboard())
}

func handleLogPhoto(
	ctx context.Context,
	cfg *Config,
	sessions *SessionStore,
	chatID int64,
	sess *ServiceLogSession,
	msg telegramMessage,
	lower string,
) bool {
	// /skip or /done — advance to location step
	if lower == "/skip" || lower == "⏭ skip" || lower == "/done" || lower == "✅ done" {
		sess.State = stateAwaitingServiceLocation
		_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
			"📍 Would you like to record where the service was done?\n\n"+
				"Tap <b>Share my location</b> or /skip to continue.",
			logLocationKeyboard())
		return true
	}

	// Expecting a photo or document
	if len(msg.Photo) == 0 && msg.Document == nil {
		kb := logFlowSkipKeyboard()
		if len(sess.PhotoPaths) > 0 {
			kb = logFlowDoneKeyboard()
		}
		_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
			"Please send a photo, tap /done when finished, or /skip to attach no photos.", kb)
		return true
	}

	if len(sess.PhotoPaths) >= maxPhotosPerEntry {
		_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
			fmt.Sprintf("⚠️ An entry can hold at most %d photos. Tap /done to continue.", maxPhotosPerEntry),
			logFlowDoneKeyboard())
		return true
	}

	path, err := downloadTelegramPhoto(cfg, msg, len(sess.PhotoPaths))
	if err != nil {
		// Detail goes to the log only; the chat gets a short reason.
		log.Printf("service log: download photo: %v", err)
		kb := logFlowSkipKeyboard()
		if len(sess.PhotoPaths) > 0 {
			kb = logFlowDoneKeyboard()
		}
		reason := "could not download it"
		if errors.Is(err, errPhotoTooLarge) {
			reason = "it is larger than 20 MB"
		}
		_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
			fmt.Sprintf("❌ Photo not saved: %s.\n\nTry again or tap /done to continue.", reason), kb)
		return true
	}

	sess.PhotoPaths = append(sess.PhotoPaths, path)
	n := len(sess.PhotoPaths)
	word := "photo"
	if n != 1 {
		word = "photos"
	}
	_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
		fmt.Sprintf("📎 %d %s attached. Send another or tap /done to continue.", n, word),
		logFlowDoneKeyboard())
	return true
}

func sendLogConfirmPrompt(cfg *Config, sess *ServiceLogSession) {
	var sb strings.Builder
	sb.WriteString("📋 <b>Review service entry</b>\n\n")
	if sess.OdometerKM != nil {
		sb.WriteString(formatOdometer(cfg, *sess.OdometerKM, "📏 Odometer: ") + "\n")
	}
	sb.WriteString(fmt.Sprintf("📝 %s\n", htmlEscape(sess.Description)))
	if sess.ServiceItem != "" {
		sb.WriteString(fmt.Sprintf("🗓 Marks done: %s\n", htmlEscape(serviceItemLabel(sess.ServiceItem))))
	}
	n := len(sess.PhotoPaths)
	if n == 0 {
		sb.WriteString("📎 No photos\n")
	} else {
		word := "photo"
		if n != 1 {
			word = "photos"
		}
		sb.WriteString(fmt.Sprintf("📎 %d %s\n", n, word))
	}
	if sess.ServiceLat != nil {
		sb.WriteString(fmt.Sprintf("📍 %.5f, %.5f\n", *sess.ServiceLat, *sess.ServiceLon))
	}
	sb.WriteString("\nConfirm to save this entry:")

	_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID, sb.String(), confirmKeyboard())
}

func handleLogConfirm(
	ctx context.Context,
	pool *pgxpool.Pool,
	cfg *Config,
	sessions *SessionStore,
	chatID int64,
	sess *ServiceLogSession,
	lower string,
) bool {
	if lower != "/confirm" && lower != "✅ confirm" {
		// Anything other than confirm/cancel (cancel handled above) — re-prompt
		_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
			"Tap ✅ Confirm to save or ❌ Cancel to discard.", confirmKeyboard())
		return true
	}

	id, err := insertServiceLog(ctx, pool, cfg.VIN, sess)
	if err != nil {
		log.Printf("service log: insert: %v", err)
		// Keep the draft. Clearing it here discarded a description and photos
		// the user had already assembled, with no way to retry and with the
		// downloaded files no longer reachable by session cleanup.
		sess.LastActivity = time.Now()
		// Plain-text error — never lose the user's content to an HTML-parse
		// failure on the failure path.
		_ = sendMessageWithKeyboardPlain(cfg.TelegramToken, cfg.ChatID,
			"❌ Failed to save the service log (database error, details in the bot log).\n\nYour entry is still here — tap ✅ Confirm to try again, or ❌ Cancel to discard it.",
			confirmKeyboard())
		return true
	}

	// Persisted: only now is it safe to drop the draft.
	sessions.clear(chatID)

	// Send a guaranteed-deliverable confirmation FIRST so the user always sees
	// that the row was saved, even if the rich recap below fails HTML parsing
	// for some bizarre reason (R2).
	if err := sendMessageWithKeyboardPlain(cfg.TelegramToken, cfg.ChatID,
		fmt.Sprintf("✅ Service entry #%d saved.", id), mainMenuKeyboard()); err != nil {
		log.Printf("service log: send confirm: %v", err)
	}

	// Rich recap as a follow-up. All user/external strings are escaped.
	var sb strings.Builder
	fmt.Fprintf(&sb, "✅ <b>Service entry #%d saved</b>\n\n", id)
	if sess.OdometerKM != nil {
		fmt.Fprintf(&sb, "%s\n", formatOdometer(cfg, *sess.OdometerKM, "📏 "))
	}
	fmt.Fprintf(&sb, "📝 %s\n", htmlEscape(sess.Description))
	if sess.ServiceItem != "" {
		fmt.Fprintf(&sb, "🗓 %s marked done\n", htmlEscape(serviceItemLabel(sess.ServiceItem)))
	}
	n := len(sess.PhotoPaths)
	if n > 0 {
		word := "photo"
		if n != 1 {
			word = "photos"
		}
		fmt.Fprintf(&sb, "📎 %d %s\n", n, word)
	}
	if sess.ServiceLat != nil {
		fmt.Fprintf(&sb, "📍 %.5f, %.5f\n", *sess.ServiceLat, *sess.ServiceLon)
	}
	if err := sendMessage(cfg.TelegramToken, cfg.ChatID, sb.String()); err != nil {
		log.Printf("service log: send recap: %v", err)
	}
	return true
}

func handleServiceLocation(
	cfg *Config,
	sessions *SessionStore,
	chatID int64,
	sess *ServiceLogSession,
	msg telegramMessage,
	lower string,
) bool {
	if lower == "/skip" || lower == "⏭ skip" {
		// No location — go straight to confirm
		sess.State = stateAwaitingConfirm
		sendLogConfirmPrompt(cfg, sess)
		return true
	}

	if msg.Location != nil {
		lat, lon := msg.Location.Latitude, msg.Location.Longitude
		sess.ServiceLat = &lat
		sess.ServiceLon = &lon
		sess.State = stateAwaitingConfirm
		sendLogConfirmPrompt(cfg, sess)
		return true
	}

	// User sent something else — re-prompt
	_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
		"Tap <b>Share my location</b> to record the service location, or /skip to continue.",
		logLocationKeyboard())
	return true
}

// ── Add-place flow ────────────────────────────────────────────────────────────

// startAddPlace begins the guided add-place session.
// Called from the "📍 Add place" inline button callback.
func startAddPlace(cfg *Config, sessions *SessionStore, chatID int64) {
	now := time.Now()
	sessions.set(chatID, &ServiceLogSession{
		State:        stateAwaitingPlaceLocation,
		CreatedAt:    now,
		LastActivity: now,
	})
	_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
		"📍 <b>Add named place</b>\n\n"+
			"Share your current location using Telegram's 📎 attachment menu → <b>Location</b>.\n\n"+
			"The bot will use it as the GPS pin for the new place.",
		cancelOnlyKeyboard())
}

func handlePlaceLocation(
	cfg *Config,
	sessions *SessionStore,
	chatID int64,
	sess *ServiceLogSession,
	msg telegramMessage,
) bool {
	if msg.Location == nil {
		_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
			"Please share a location using the 📎 attachment menu → <b>Location</b>.",
			cancelOnlyKeyboard())
		return true
	}

	sess.PlaceLat = msg.Location.Latitude
	sess.PlaceLon = msg.Location.Longitude
	sess.State = stateAwaitingPlaceName

	_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
		fmt.Sprintf("📍 Got it — <b>%.5f, %.5f</b>\n\nWhat would you like to name this place?",
			sess.PlaceLat, sess.PlaceLon),
		cancelOnlyKeyboard())
	return true
}

func handlePlaceName(
	cfg *Config,
	sessions *SessionStore,
	chatID int64,
	sess *ServiceLogSession,
	text string,
) bool {
	if text == "" || strings.HasPrefix(text, "/") || isControlLabel(strings.ToLower(text)) {
		_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
			"Please enter a name for this place (e.g. Home, Work, Gym):",
			cancelOnlyKeyboard())
		return true
	}

	sess.PlaceName = text
	sess.State = stateAwaitingPlaceRadius

	_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
		fmt.Sprintf("Got it — <b>%s</b>.\n\nWhat match radius in metres?\n\n"+
			"• 150 m — home / driveway\n"+
			"• 300 m — large car park / workplace\n\n"+
			"Send a number or /skip for the default (100 m).", htmlEscape(text)),
		logFlowDoneKeyboard())
	return true
}

func handlePlaceRadius(
	ctx context.Context,
	pool *pgxpool.Pool,
	cfg *Config,
	sessions *SessionStore,
	chatID int64,
	sess *ServiceLogSession,
	text, lower string,
) bool {
	radiusM := 100.0
	if lower != "/skip" && lower != "⏭ skip" && lower != "/done" && lower != "✅ done" {
		r, err := strconv.ParseFloat(text, 64)
		if err != nil || r <= 0 || r > 10000 {
			_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
				"Please enter a radius in metres (e.g. 150), or /skip for the default.",
				logFlowDoneKeyboard())
			return true
		}
		radiusM = r
	}

	p := Place{Name: sess.PlaceName, Lat: sess.PlaceLat, Lon: sess.PlaceLon, RadiusM: radiusM}
	sessions.clear(chatID)

	inserted, err := addDBPlace(ctx, pool, cfg, p)
	if err != nil {
		log.Printf("add place: %v", err)
		_ = sendMessageWithKeyboardPlain(cfg.TelegramToken, cfg.ChatID,
			"❌ Failed to save the place (details in the bot log).", mainMenuKeyboard())
		return true
	}

	verb := "saved"
	if !inserted {
		verb = "updated"
	}
	_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
		fmt.Sprintf("✅ <b>%s</b> %s\n📍 %.5f, %.5f · radius %.0f m",
			htmlEscape(p.Name), verb, p.Lat, p.Lon, p.RadiusM),
		mainMenuKeyboard())
	return true
}

// ── Photo download ────────────────────────────────────────────────────────────

// maxPhotoBytes caps one downloaded attachment. Telegram's own bot download
// limit is 20 MB; anything larger is refused rather than streamed to disk.
const maxPhotoBytes = 20 << 20

// maxPhotosPerEntry caps the attachments on one service-log entry.
const maxPhotosPerEntry = 10

var errPhotoTooLarge = errors.New("attachment larger than 20 MB")

// writeLimited copies at most limit bytes from r into a new file at path. A
// body longer than limit, or any write error, removes the partial file.
func writeLimited(path string, r io.Reader, limit int64) (err error) {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("create %s: %w", path, err)
	}
	defer func() {
		if cerr := f.Close(); err == nil && cerr != nil {
			err = fmt.Errorf("close %s: %w", path, cerr)
		}
		if err != nil {
			_ = os.Remove(path)
		}
	}()
	// Read one byte past the limit so an oversized body is detected rather
	// than silently truncated.
	n, err := io.Copy(f, io.LimitReader(r, limit+1))
	if err != nil {
		return fmt.Errorf("write file: %w", err)
	}
	if n > limit {
		return errPhotoTooLarge
	}
	return nil
}

// downloadTelegramPhoto downloads a photo from a Telegram message and saves it
// under cfg.AttachmentsDir/{vin}/{date}/{timestamp}_{idx}{ext}.
// Returns the saved file path (absolute on the host filesystem).
func downloadTelegramPhoto(cfg *Config, msg telegramMessage, idx int) (string, error) {
	// Prefer highest-resolution photo (last element); fall back to document.
	var fileID string
	if len(msg.Photo) > 0 {
		fileID = msg.Photo[len(msg.Photo)-1].FileID
	} else if msg.Document != nil {
		fileID = msg.Document.FileID
	} else {
		return "", fmt.Errorf("no photo or document in message")
	}

	serverPath, err := telegramGetFilePath(cfg.TelegramToken, fileID)
	if err != nil {
		return "", fmt.Errorf("getFile: %w", err)
	}

	// Build local directory: {attachments_dir}/{vin}/{YYYY-MM-DD}/
	dir := filepath.Join(cfg.AttachmentsDir, cfg.VIN, time.Now().Format("2006-01-02"))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("mkdir %s: %w", dir, err)
	}

	ext := filepath.Ext(serverPath)
	if ext == "" {
		ext = ".jpg"
	}
	filename := fmt.Sprintf("%d_%d%s", time.Now().UnixNano(), idx, ext)
	localPath := filepath.Join(dir, filename)

	// Download from Telegram file server. telegramDo keeps the token out of
	// any error it returns.
	resp, err := telegramDo(telegramClient, cfg.TelegramToken, http.MethodGet, serverPath, "", nil, true)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download HTTP %d", resp.StatusCode)
	}
	if resp.ContentLength > maxPhotoBytes {
		return "", fmt.Errorf("%w (%d bytes)", errPhotoTooLarge, resp.ContentLength)
	}

	if err := writeLimited(localPath, resp.Body, maxPhotoBytes); err != nil {
		return "", err
	}

	log.Printf("service log: saved photo → %s", localPath)
	return localPath, nil
}
