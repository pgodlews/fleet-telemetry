package main

import (
	"context"
	"fmt"
	"log"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// handleUpdate dispatches a single incoming Telegram update to the right command handler.
// It ignores updates that are not from the configured chat and routes messages from
// an active service log session to the multi-turn handler before normal dispatch.
func handleUpdate(
	ctx context.Context,
	pool *pgxpool.Pool,
	cfg *Config,
	scCache *SuperchargerCache,
	sessions *SessionStore,
	update telegramUpdate,
) {
	msg := update.Message

	// Accept messages with text, photo, document, or location (various flow steps)
	if msg.Text == "" && len(msg.Photo) == 0 && msg.Document == nil && msg.Location == nil {
		return
	}

	// Security: only respond to the configured chat
	if fmt.Sprintf("%d", msg.Chat.ID) != cfg.ChatID {
		log.Printf("ignoring message from unknown chat %d", msg.Chat.ID)
		return
	}

	chatID := msg.Chat.ID

	// ── Per-chat serialization ───────────────────────────────────────────────
	// All updates for one chat must be handled in order — otherwise two photos
	// arriving back-to-back race on the shared ServiceLogSession.
	sessions.lockChat(chatID)
	defer sessions.unlockChat(chatID)

	// ── Active session check ─────────────────────────────────────────────────
	// If the user is mid-flow (service log), route all input there first.
	// /cancel is handled inside handleServiceLogStep as well; main-menu button
	// labels / known slash commands are treated as implicit cancel.
	if handleServiceLogStep(ctx, pool, cfg, sessions, chatID, msg) {
		return
	}

	// ── Command dispatch ─────────────────────────────────────────────────────
	// Normalise: strip @BotName suffix, lower-case, map keyboard button labels
	// to their equivalent command strings.
	parts := strings.Fields(msg.Text)
	if len(parts) == 0 {
		return
	}
	cmd := strings.ToLower(parts[0])
	if idx := strings.Index(cmd, "@"); idx != -1 {
		cmd = cmd[:idx]
	}
	args := parts[1:]

	// Map reply-keyboard button labels to canonical command strings.
	// Button labels are multi-word so we must match against the full message,
	// not just parts[0].
	fullText := strings.ToLower(strings.TrimSpace(msg.Text))
	switch fullText {
	case "📊 7d summary":
		cmd, args = "/summary7d", nil
	case "📊 30d summary":
		cmd, args = "/summary30d", nil
	case "🔧 log service":
		cmd, args = "/logservice", nil
	case "📍 last location":
		cmd, args = "/lastknownlocation", nil
	case "⚡ nearest charger":
		cmd, args = "/nearestcharger", nil
	case "⚙️ show config":
		cmd, args = "/showconfig", nil
	}

	var (
		reply   string
		err     error
		useMenu bool // when true, attach the main menu keyboard to the reply
	)

	switch cmd {
	case "/start", "/menu":
		reply = "👋 Welcome! Use the keyboard below or type a command."
		useMenu = true

	case "/hidekeyboard":
		if sendErr := sendMessageRemoveKeyboard(cfg.TelegramToken, cfg.ChatID,
			"Keyboard hidden. Send /menu to restore it."); sendErr != nil {
			log.Printf("send hidekeyboard: %v", sendErr)
		}
		return

	case "/help":
		reply = cmdHelp()

	case "/summary7d":
		reply, err = cmdSummary(ctx, pool, cfg, 7)

	case "/summary30d":
		reply, err = cmdSummary(ctx, pool, cfg, 30)

	case "/lastknownlocation":
		err = cmdLastLocation(ctx, pool, cfg)
		if err != nil {
			log.Printf("command %s error: %v", cmd, err)
			reply = "❌ Could not show the last location (details in the bot log)."
			useMenu = true
			err = nil
			break
		}
		return

	case "/nearestcharger":
		reply, err = cmdNearestCharger(ctx, pool, cfg, scCache)

	case "/logservice":
		startServiceLog(ctx, pool, cfg, sessions, chatID)
		return

	case "/setunits":
		reply, err = cmdSetUnits(ctx, pool, cfg, args)
	case "/settemp":
		reply, err = cmdSetTemp(ctx, pool, cfg, args)
	case "/setenergyprice":
		reply, err = cmdSetEnergyPrice(ctx, pool, cfg, args)
	case "/setcurrency":
		reply, err = cmdSetCurrency(ctx, pool, cfg, args)
	case "/addplace":
		reply, err = cmdAddPlace(ctx, pool, cfg, args)
	case "/listplaces":
		reply = cmdListPlaces(cfg)
	case "/showconfig":
		text := cmdShowConfig(cfg, scCache)
		kb := configInlineKeyboard(cfg)
		if err := sendMessageWithInlineKeyboard(cfg.TelegramToken, cfg.ChatID, text, kb); err != nil {
			log.Printf("send showconfig: %v", err)
		}
		return

	default:
		// Silently ignore unknown commands / plain messages
		return
	}

	if err != nil {
		// Detail stays in the log. Errors can carry driver or transport text
		// that has no business in the chat.
		log.Printf("command %s error: %v", cmd, err)
		reply = "❌ Something went wrong (details in the bot log)."
	}
	if reply == "" {
		return
	}

	var sendErr error
	if useMenu {
		sendErr = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID, reply, mainMenuKeyboard())
	} else {
		sendErr = sendMessage(cfg.TelegramToken, cfg.ChatID, reply)
	}
	if sendErr != nil {
		log.Printf("send reply for %s: %v", cmd, sendErr)
	}
}

// cmdHelp returns the help text listing all available commands.
func cmdHelp() string {
	return `🤖 <b>TeslikTripBot commands</b>

/summary7d — Last 7 days stats
/summary30d — Last 30 days stats
/lastknownlocation — Map of most recent GPS position
/nearestcharger — Nearest open Tesla Superchargers
/logservice — Log a service / maintenance entry

<b>Settings</b>
/showconfig — Show all current settings
/setunits km|miles — Distance units
/settemp c|f — Temperature units
/setcurrency &lt;symbol&gt; — Currency symbol (£ € $ etc)
/setenergyprice &lt;amount/kWh&gt; — Energy price in your currency per kWh (future trips only)
/addplace &lt;name&gt; &lt;lat&gt; &lt;lon&gt; [radius_m] — Add named place
/listplaces — List all named places

<b>Keyboard</b>
/menu — Show the main reply keyboard
/hidekeyboard — Hide the keyboard`
}

// cmdSummary builds and returns a period summary message.
func cmdSummary(ctx context.Context, pool *pgxpool.Pool, cfg *Config, days int) (string, error) {
	stats, err := fetchSummaryStats(ctx, pool, cfg.VIN, days)
	if err != nil {
		return "", err
	}

	if stats.TripCount == 0 {
		return fmt.Sprintf("📊 <b>Last %d days</b>\n\nNo trips recorded in this period.", days), nil
	}

	charge, chargeErr := fetchChargingEnergy(ctx, pool, cfg.VIN, days)
	if chargeErr != nil {
		log.Printf("warn: charging energy: %v", chargeErr)
	}

	snap := cfg.Snapshot()
	km := stats.TotalKM
	mi := km * 0.621371
	cur := htmlEscape(snap.Currency)

	tripWord := "trips"
	if stats.TripCount == 1 {
		tripWord = "trip"
	}

	var distStr, longestStr string
	if snap.Units == "miles" {
		distStr = fmt.Sprintf("%.1f mi  (%.1f km)", mi, km)
		longestStr = fmt.Sprintf("%.1f mi", stats.LongestKM*0.621371)
	} else {
		distStr = fmt.Sprintf("%.1f km  (%.1f mi)", km, mi)
		longestStr = fmt.Sprintf("%.1f km", stats.LongestKM)
	}

	var effStr string
	if stats.AvgWhPerKM > 0 {
		if snap.Units == "miles" {
			effStr = fmt.Sprintf(" · avg %.0f Wh/mi", stats.AvgWhPerKM*1.60934)
		} else {
			effStr = fmt.Sprintf(" · avg %.0f Wh/km", stats.AvgWhPerKM)
		}
	}

	var b strings.Builder
	fmt.Fprintf(&b, "📊 <b>Last %d days</b>\n\n", days)
	fmt.Fprintf(&b, "🚗 %d %s · %s\n", stats.TripCount, tripWord, distStr)
	fmt.Fprintf(&b, "⚡ %.2f kWh used%s\n", stats.TotalKWh, effStr)
	fmt.Fprintf(&b, "💰 Est. cost: %s%.2f\n", cur, stats.TotalKWh*snap.CostPerKWh)
	if chargeErr != nil {
		fmt.Fprintf(&b, "🔋 Charging data unavailable\n")
	} else {
		fmt.Fprintf(&b, "%s\n", formatChargingLine(charge))
	}
	if stats.LongestKM > 0 {
		fmt.Fprintf(&b, "🏆 Longest trip: %s\n", longestStr)
	}
	return strings.TrimRight(b.String(), "\n"), nil
}

// cmdLastLocation renders a static map PNG of the most recent GPS fix and sends
// it as a photo. If map rendering fails it falls back to a text message.
func cmdLastLocation(ctx context.Context, pool *pgxpool.Pool, cfg *Config) error {
	pt, err := fetchLastGPS(ctx, pool, cfg.VIN)
	if err != nil {
		return fmt.Errorf("fetch last GPS: %w", err)
	}

	caption := fmt.Sprintf("📍 Last known location\n%.5f, %.5f", pt.Lat, pt.Lon)

	mapPNG, err := renderSinglePointMap(pt)
	if err != nil {
		log.Printf("warn: last location map render failed: %v — sending text only", err)
		return sendMessage(cfg.TelegramToken, cfg.ChatID, caption)
	}
	return sendPhoto(cfg.TelegramToken, cfg.ChatID, mapPNG, caption)
}

// cmdNearestCharger finds and returns a message with the nearest open Superchargers.
func cmdNearestCharger(ctx context.Context, pool *pgxpool.Pool, cfg *Config, scCache *SuperchargerCache) (string, error) {
	if err := scCache.Ensure(); err != nil {
		return "", fmt.Errorf("load supercharger data: %w", err)
	}

	pt, err := fetchLastGPS(ctx, pool, cfg.VIN)
	if err != nil {
		return "", fmt.Errorf("fetch last GPS: %w", err)
	}

	results := scCache.FindNearest(pt.Lat, pt.Lon, 3)
	return formatNearestChargers(results, cfg.GetUnits()), nil
}

// cmdSetUnits updates the distance units preference.
func cmdSetUnits(ctx context.Context, pool *pgxpool.Pool, cfg *Config, args []string) (string, error) {
	if len(args) == 0 {
		return fmt.Sprintf("Current units: <b>%s</b>\nUsage: /setunits km|miles", cfg.GetUnits()), nil
	}
	val := strings.ToLower(args[0])
	if val != "km" && val != "miles" {
		return "Usage: /setunits km|miles", nil
	}
	cfg.SetUnits(val)
	if err := savePrefs(ctx, pool, cfg); err != nil {
		return "", err
	}
	return fmt.Sprintf("✅ Distance units set to <b>%s</b>", val), nil
}

// cmdSetTemp updates the temperature units preference.
func cmdSetTemp(ctx context.Context, pool *pgxpool.Pool, cfg *Config, args []string) (string, error) {
	if len(args) == 0 {
		return fmt.Sprintf("Current temperature units: <b>%s</b>\nUsage: /settemp c|f", cfg.GetTempUnits()), nil
	}
	val := strings.ToLower(args[0])
	if val != "c" && val != "f" {
		return "Usage: /settemp c|f", nil
	}
	cfg.SetTempUnits(val)
	if err := savePrefs(ctx, pool, cfg); err != nil {
		return "", err
	}
	label := map[string]string{"c": "Celsius (°C)", "f": "Fahrenheit (°F)"}[val]
	return fmt.Sprintf("✅ Temperature units set to <b>%s</b>", label), nil
}

// cmdSetCurrency updates the currency symbol used in all cost displays.
func cmdSetCurrency(ctx context.Context, pool *pgxpool.Pool, cfg *Config, args []string) (string, error) {
	if len(args) == 0 {
		return fmt.Sprintf("Current currency: <b>%s</b>\nUsage: /setcurrency &lt;symbol&gt;\nExamples: /setcurrency £   /setcurrency €   /setcurrency $", htmlEscape(cfg.GetCurrency())), nil
	}
	symbol := args[0]
	if len(symbol) > 4 {
		return "Currency symbol should be 1–4 characters (e.g. £ € $ kr zł)", nil
	}
	cfg.SetCurrency(symbol)
	if err := savePrefs(ctx, pool, cfg); err != nil {
		return "", err
	}
	return fmt.Sprintf("✅ Currency set to <b>%s</b>\nRemember to update your energy price with /setenergyprice if the rate has changed.", htmlEscape(symbol)), nil
}

// cmdSetEnergyPrice updates the cost per kWh.
// The user supplies the value in the configured currency's main unit
// (e.g. "0.2037" for £0.2037/kWh). Applies to future trips only.
func cmdSetEnergyPrice(ctx context.Context, pool *pgxpool.Pool, cfg *Config, args []string) (string, error) {
	snap := cfg.Snapshot()
	cur := snap.Currency
	if len(args) == 0 {
		return fmt.Sprintf(
			"Current energy price: <b>%s%.4f/kWh</b>\nUsage: /setenergyprice &lt;%s/kWh&gt;\nExample: /setenergyprice 0.2037",
			htmlEscape(cur), snap.CostPerKWh, htmlEscape(cur),
		), nil
	}
	price, err := strconv.ParseFloat(args[0], 64)
	if err != nil || price <= 0 || price > 5 {
		return fmt.Sprintf("Please provide a price in %s/kWh, e.g. /setenergyprice 0.2037", htmlEscape(cur)), nil
	}
	cfg.SetCostPerKWh(price)
	if err := savePrefs(ctx, pool, cfg); err != nil {
		return "", err
	}
	return fmt.Sprintf("✅ Energy price set to <b>%s%.4f/kWh</b>\nApplies to future trips only.", htmlEscape(cur), price), nil
}

// cmdAddPlace parses /addplace <name> <lat> <lon> [radius_m] and persists it.
// Name may contain spaces if quoted: /addplace "Corner Shop" 51.50 -0.12 150
func cmdAddPlace(ctx context.Context, pool *pgxpool.Pool, cfg *Config, args []string) (string, error) {
	if len(args) < 3 {
		return "Usage: /addplace &lt;name&gt; &lt;lat&gt; &lt;lon&gt; [radius_m]\nExample: /addplace Gym 51.503 -0.119 200", nil
	}

	// Last 2 (or 3) args are numeric; everything before is the name
	numArgs := 2
	radiusM := 100.0
	// Check if last arg is numeric radius
	if len(args) >= 4 {
		if r, err := strconv.ParseFloat(args[len(args)-1], 64); err == nil && r > 0 {
			radiusM = r
			numArgs = 3
		}
	}
	nameArgs := args[:len(args)-numArgs]
	numericArgs := args[len(args)-numArgs:]

	if len(nameArgs) == 0 {
		return "Usage: /addplace &lt;name&gt; &lt;lat&gt; &lt;lon&gt; [radius_m]", nil
	}

	lat, err := strconv.ParseFloat(numericArgs[0], 64)
	if err != nil || math.Abs(lat) > 90 {
		return fmt.Sprintf("Invalid latitude: %s", numericArgs[0]), nil
	}
	lon, err := strconv.ParseFloat(numericArgs[1], 64)
	if err != nil || math.Abs(lon) > 180 {
		return fmt.Sprintf("Invalid longitude: %s", numericArgs[1]), nil
	}

	name := strings.Join(nameArgs, " ")
	// Strip surrounding straight or smart double quotes (N6)
	name = trimSurroundingQuotes(name)

	if name == "" {
		return "Place name cannot be empty.", nil
	}

	p := Place{Name: name, Lat: lat, Lon: lon, RadiusM: radiusM}
	inserted, err := addDBPlace(ctx, pool, cfg, p)
	if err != nil {
		return "", err
	}
	verb := "added"
	if !inserted {
		verb = "updated"
	}
	return fmt.Sprintf("✅ Place <b>%s</b> %s (%.5f, %.5f · radius %.0f m)",
		htmlEscape(name), verb, lat, lon, radiusM), nil
}

// trimSurroundingQuotes strips a matched pair of straight or curly double
// quotes from the start and end of s.
func trimSurroundingQuotes(s string) string {
	if len(s) < 2 {
		return s
	}
	pairs := [][2]string{{`"`, `"`}, {"“", "”"}, {"„", "“"}}
	for _, pq := range pairs {
		if strings.HasPrefix(s, pq[0]) && strings.HasSuffix(s, pq[1]) {
			return strings.TrimSuffix(strings.TrimPrefix(s, pq[0]), pq[1])
		}
	}
	return s
}

// cmdListPlaces returns a formatted list of all configured named places.
func cmdListPlaces(cfg *Config) string {
	places := cfg.SnapshotPlaces()
	if len(places) == 0 {
		return "No named places configured.\nUse /addplace to add one."
	}
	var b strings.Builder
	b.WriteString("📍 <b>Named places</b>\n\n")
	for _, p := range places {
		fmt.Fprintf(&b, "• <b>%s</b> — %.5f, %.5f (radius %.0f m)\n",
			htmlEscape(p.Name), p.Lat, p.Lon, p.RadiusM)
	}
	return strings.TrimRight(b.String(), "\n")
}

// configInlineKeyboard builds the inline button grid shown below /showconfig.
// Toggle buttons (units, temp) show a ✓ on the current value and flip it on press.
// Input buttons (currency, energy price, add place) send a follow-up prompt.
func configInlineKeyboard(cfg *Config) InlineKeyboardMarkup {
	snap := cfg.Snapshot()
	km, miles := "📏 km", "📏 miles ✓"
	if snap.Units == "km" {
		km, miles = "📏 km ✓", "📏 miles"
	}
	celsius, fahrenheit := "🌡️ °C", "🌡️ °F ✓"
	if snap.TempUnits == "c" {
		celsius, fahrenheit = "🌡️ °C ✓", "🌡️ °F"
	}
	return InlineKeyboardMarkup{
		InlineKeyboard: [][]InlineKeyboardButton{
			{
				{Text: km, CallbackData: "set_units_km"},
				{Text: miles, CallbackData: "set_units_miles"},
			},
			{
				{Text: celsius, CallbackData: "set_temp_c"},
				{Text: fahrenheit, CallbackData: "set_temp_f"},
			},
			{
				{Text: "💰 Change currency", CallbackData: "prompt_currency"},
				{Text: "⚡ Change energy price", CallbackData: "prompt_energy_price"},
			},
			{
				{Text: "📍 Add place", CallbackData: "prompt_add_place"},
				{Text: "📋 List places", CallbackData: "list_places"},
			},
		},
	}
}

// handleCallbackQuery dispatches inline button presses from the /showconfig message.
// Toggle actions (units, temp) update cfg, save to DB, then edit the message in place.
// Prompt actions send a follow-up message with a ready-to-use command string.
func handleCallbackQuery(
	ctx context.Context,
	pool *pgxpool.Pool,
	cfg *Config,
	scCache *SuperchargerCache,
	sessions *SessionStore,
	cq telegramCallbackQuery,
) {
	// Always acknowledge the callback — clears the loading spinner on the button.
	// We'll send a meaningful toast for toggle actions below.
	toast := ""
	defer func() {
		if err := answerCallbackQuery(cfg.TelegramToken, cq.ID, toast); err != nil {
			log.Printf("answerCallbackQuery: %v", err)
		}
	}()

	// Serialise with handleUpdate for this chat so session / cfg writes can't race.
	sessions.lockChat(cq.Message.Chat.ID)
	defer sessions.unlockChat(cq.Message.Chat.ID)

	switch cq.Data {
	case "set_units_km", "set_units_miles":
		newVal := "km"
		if cq.Data == "set_units_miles" {
			newVal = "miles"
		}
		// Avoid a no-op edit (Telegram returns "message is not modified").
		if cfg.GetUnits() == newVal {
			toast = "Already set"
			return
		}
		cfg.SetUnits(newVal)
		toast = fmt.Sprintf("✓ Distance set to %s", newVal)
		if err := savePrefs(ctx, pool, cfg); err != nil {
			log.Printf("callback set_units savePrefs: %v", err)
			toast = "❌ Save failed"
			return
		}
		refreshConfigMessage(cfg, scCache, cq)

	case "set_temp_c", "set_temp_f":
		newVal := "c"
		if cq.Data == "set_temp_f" {
			newVal = "f"
		}
		if cfg.GetTempUnits() == newVal {
			toast = "Already set"
			return
		}
		cfg.SetTempUnits(newVal)
		if newVal == "c" {
			toast = "✓ Temperature set to °C"
		} else {
			toast = "✓ Temperature set to °F"
		}
		if err := savePrefs(ctx, pool, cfg); err != nil {
			log.Printf("callback set_temp savePrefs: %v", err)
			toast = "❌ Save failed"
			return
		}
		refreshConfigMessage(cfg, scCache, cq)

	case "prompt_currency":
		_ = sendMessage(cfg.TelegramToken, cfg.ChatID,
			fmt.Sprintf("Current currency: <b>%s</b>\n\nSend a new symbol, e.g.:\n<code>/setcurrency £</code>\n<code>/setcurrency €</code>\n<code>/setcurrency $</code>",
				htmlEscape(cfg.GetCurrency())))

	case "prompt_energy_price":
		snap := cfg.Snapshot()
		_ = sendMessage(cfg.TelegramToken, cfg.ChatID,
			fmt.Sprintf("Current price: <b>%s%.4f/kWh</b>\n\nSend a new rate, e.g.:\n<code>/setenergyprice 0.2037</code>",
				htmlEscape(snap.Currency), snap.CostPerKWh))

	case "prompt_add_place":
		// Refuse to clobber an in-progress flow (B4).
		if existing := sessions.get(cq.Message.Chat.ID); existing != nil {
			toast = "Finish or /cancel current flow first"
			_ = sendMessageWithKeyboard(cfg.TelegramToken, cfg.ChatID,
				"⚠️ You already have a flow in progress. Tap ❌ Cancel · main menu to abort it, then try again.",
				cancelOnlyKeyboard())
			return
		}
		startAddPlace(cfg, sessions, cq.Message.Chat.ID)

	case "list_places":
		_ = sendMessage(cfg.TelegramToken, cfg.ChatID, cmdListPlaces(cfg))
	}
}

// refreshConfigMessage edits the /showconfig message in place after a toggle.
func refreshConfigMessage(cfg *Config, scCache *SuperchargerCache, cq telegramCallbackQuery) {
	text := cmdShowConfig(cfg, scCache)
	kb := configInlineKeyboard(cfg)
	if err := editMessageText(cfg.TelegramToken, cfg.ChatID, cq.Message.MessageID, text, kb); err != nil {
		log.Printf("editMessageText after toggle: %v", err)
	}
}

// cmdShowConfig returns a summary of all active settings.
func cmdShowConfig(cfg *Config, scCache *SuperchargerCache) string {
	snap := cfg.Snapshot()
	places := cfg.SnapshotPlaces()

	var b strings.Builder
	b.WriteString("⚙️ <b>Active configuration</b>\n\n")

	tempLabel := "°C"
	if snap.TempUnits == "f" {
		tempLabel = "°F"
	}
	fmt.Fprintf(&b, "📏 Distance: <b>%s</b>\n", snap.Units)
	fmt.Fprintf(&b, "🌡️ Temperature: <b>%s</b>\n", tempLabel)
	fmt.Fprintf(&b, "💰 Currency: <b>%s</b>\n", htmlEscape(snap.Currency))
	fmt.Fprintf(&b, "⚡ Energy price: <b>%s%.4f/kWh</b>\n", htmlEscape(snap.Currency), snap.CostPerKWh)

	if cfg.SCAlertRadiusKM > 0 {
		fmt.Fprintf(&b, "🔍 SC alerts: <b>%.0f km radius</b>\n", cfg.SCAlertRadiusKM)
	} else {
		b.WriteString("🔍 SC alerts: <b>disabled</b>\n")
	}

	if len(places) == 0 {
		b.WriteString("📍 Named places: <b>none</b>\n")
	} else {
		names := make([]string, len(places))
		for i, p := range places {
			names[i] = htmlEscape(p.Name)
		}
		fmt.Fprintf(&b, "📍 Named places: <b>%d</b> (%s)\n",
			len(places), strings.Join(names, ", "))
	}

	if scCache != nil {
		count, loadedAt := scCache.Stats()
		if !loadedAt.IsZero() {
			fmt.Fprintf(&b, "🗺️ SC cache: <b>%d sites</b>, loaded %s ago\n",
				count, formatDuration(time.Since(loadedAt).Truncate(time.Minute)))
		} else {
			b.WriteString("🗺️ SC cache: <b>not loaded</b>\n")
		}
	}

	return strings.TrimRight(b.String(), "\n")
}
