package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Invented fixture token; shaped like a BotFather token.
const testToken = "123456789:AAFakeTokenForTestsOnly_abcdefghijk"

func TestUTF16Len(t *testing.T) {
	cases := map[string]int{"": 0, "abc": 3, "ł": 1, "🚗": 2, "a🚗b": 4}
	for s, want := range cases {
		if got := utf16Len(s); got != want {
			t.Errorf("utf16Len(%q) = %d, want %d", s, got, want)
		}
	}
}

func TestTruncateCaption(t *testing.T) {
	short := "🚗 <b>Trip</b>"
	if got := truncateCaption(short); got != short {
		t.Errorf("short caption changed: %q", got)
	}
	long := strings.Repeat("🚗", 600) // 1200 UTF-16 units
	got := truncateCaption(long)
	if utf16Len(got) > captionLimit {
		t.Fatalf("truncated caption is %d units, limit %d", utf16Len(got), captionLimit)
	}
	if !strings.HasSuffix(got, "…") {
		t.Errorf("missing ellipsis")
	}
	// A cut inside a tag must not leave a dangling "<b".
	tagged := strings.Repeat("x", captionLimit-5) + "<b>bold</b>"
	got = truncateCaption(tagged)
	body := strings.TrimSuffix(got, "\n…")
	if i := strings.LastIndexByte(body, '<'); i >= 0 && !strings.Contains(body[i:], ">") {
		t.Errorf("dangling tag in %q", body[len(body)-10:])
	}
}

func TestNormalizeBotToken(t *testing.T) {
	if got := normalizeBotToken("bot" + testToken); got != testToken {
		t.Errorf("prefix not stripped: %q", got)
	}
	if got := normalizeBotToken(testToken); got != testToken {
		t.Errorf("plain token changed: %q", got)
	}
	if got := normalizeBotToken(""); got != "" {
		t.Errorf("empty token changed: %q", got)
	}
}

func TestIsCancelInput(t *testing.T) {
	yes := []string{"/cancel", "/cancel@mybot", strings.ToLower(cancelRow[0].Text)}
	no := []string{"", "cancel", "cancelled appointment, rebooked", "please cancel the booking", "/cancelled"}
	for _, s := range yes {
		if !isCancelInput(s) {
			t.Errorf("isCancelInput(%q) = false, want true", s)
		}
	}
	for _, s := range no {
		if isCancelInput(s) {
			t.Errorf("isCancelInput(%q) = true, want false", s)
		}
	}
}

func TestIsImplicitCancel(t *testing.T) {
	yes := []string{"📊 7d summary", "/help", "/summary7d", "/setunits km"}
	no := []string{"replaced cabin filter", "/skip", "/done", "/cancel"}
	for _, s := range yes {
		if !isImplicitCancel(s) {
			t.Errorf("isImplicitCancel(%q) = false", s)
		}
	}
	for _, s := range no {
		if isImplicitCancel(s) {
			t.Errorf("isImplicitCancel(%q) = true", s)
		}
	}
}

func TestIsControlLabel(t *testing.T) {
	for _, s := range []string{"⏭ skip", "/skip", "✅ done", "/done", "✅ confirm"} {
		if !isControlLabel(s) {
			t.Errorf("isControlLabel(%q) = false", s)
		}
	}
	if isControlLabel("skipped the wash") {
		t.Error("free text treated as control label")
	}
}

func TestServiceItemChoices(t *testing.T) {
	ch := serviceItemChoices([]string{"cabin_air_filter", "tire_rotation"})
	if ch[strings.ToLower(serviceItemLabel("cabin_air_filter"))] != "cabin_air_filter" {
		t.Errorf("label lookup failed: %v", ch)
	}
	if got := serviceItemLabel("tire_rotation"); got != "🔧 Tire rotation" {
		t.Errorf("label = %q", got)
	}
	kb := serviceItemKeyboard(ch)
	last := kb.Keyboard[len(kb.Keyboard)-1]
	if last[0].Text != cancelRow[0].Text {
		t.Errorf("cancel row missing")
	}
}

func TestConvertWeatherTemp(t *testing.T) {
	cases := []struct{ in, units, want string }{
		{"🌤️ 8°C, partly cloudy", "c", "🌤️ 8°C, partly cloudy"},
		{"🌤️ 8°C, partly cloudy", "f", "🌤️ 46°F, partly cloudy"},
		{"❄️ -1°C, snow", "f", "❄️ 30°F, snow"},
		{"no temperature", "f", "no temperature"},
	}
	for _, tc := range cases {
		if got := convertWeatherTemp(tc.in, tc.units); got != tc.want {
			t.Errorf("convertWeatherTemp(%q, %q) = %q, want %q", tc.in, tc.units, got, tc.want)
		}
	}
}

func TestFormatDuration(t *testing.T) {
	cases := map[time.Duration]string{
		45 * time.Minute:                "45m",
		83 * time.Minute:                "1h 23m",
		2*time.Hour + 30*time.Second:    "2h 01m",
		29 * time.Second:                "0m",
		10*time.Hour + 5*time.Minute:    "10h 05m",
		59*time.Minute + 31*time.Second: "1h 00m",
	}
	for d, want := range cases {
		if got := formatDuration(d); got != want {
			t.Errorf("formatDuration(%s) = %q, want %q", d, got, want)
		}
	}
}

func TestFeedParsing(t *testing.T) {
	var e atomEntry
	e.ID = "tag:supercharge.info,2018-03-19:all-changes-25276"
	e.Link.Href = "https://supercharge.info/map?siteId=1234"
	if got := parseChangeID(e); got != 25276 {
		t.Errorf("parseChangeID = %d", got)
	}
	if got := parseSiteID(e); got != 1234 {
		t.Errorf("parseSiteID = %d", got)
	}
	var bad atomEntry
	bad.ID = "something-else"
	if parseChangeID(bad) != 0 || parseSiteID(bad) != 0 {
		t.Error("unparseable entry should give 0")
	}
	if !isOpenEvent("Somewhere, UK - OPEN - 12 stalls") || !isOpenEvent("Somewhere - open") {
		t.Error("open event not detected")
	}
	if isOpenEvent("Somewhere - CONSTRUCTION - 12 stalls") {
		t.Error("construction treated as open")
	}
	if got := maxChangeID([]atomEntry{e, bad}); got != 25276 {
		t.Errorf("maxChangeID = %d", got)
	}
}

func TestTrimSurroundingQuotes(t *testing.T) {
	cases := map[string]string{
		`"Tesco Extra"`: "Tesco Extra",
		"“Gym”":         "Gym",
		"„Dom“":         "Dom",
		`"unbalanced`:   `"unbalanced`,
		"x":             "x",
	}
	for in, want := range cases {
		if got := trimSurroundingQuotes(in); got != want {
			t.Errorf("trimSurroundingQuotes(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHaversineM(t *testing.T) {
	if d := haversineM(51.5, -0.1, 51.5, -0.1); d != 0 {
		t.Errorf("same point = %f", d)
	}
	// One degree of latitude is about 111.2 km.
	d := haversineM(50, 0, 51, 0)
	if d < 111000 || d > 111400 {
		t.Errorf("1 deg latitude = %f m", d)
	}
}

func TestNominatimCacheKey(t *testing.T) {
	a := nominatimCacheKey(51.50001, -0.12001)
	b := nominatimCacheKey(51.50002, -0.12002)
	if a != b {
		t.Errorf("nearby points should share a key: %s vs %s", a, b)
	}
	if nominatimCacheKey(51.5, -0.12) == nominatimCacheKey(51.6, -0.12) {
		t.Error("distant points share a key")
	}
}

// ── P2: charge state ─────────────────────────────────────────────────────────

func TestNormalizeChargeState(t *testing.T) {
	s := func(v string) *string { return &v }
	cases := []struct {
		in   *string
		want string
	}{
		{nil, ""},
		{s("DetailedChargeStateCharging"), "Charging"},
		{s("DetailedChargeStateComplete"), "Complete"},
		{s("DetailedChargeStateDisconnected"), "Disconnected"},
		{s("Charging"), "Charging"},
	}
	for _, tc := range cases {
		if got := normalizeChargeState(tc.in); got != tc.want {
			t.Errorf("normalizeChargeState(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestChargeLine(t *testing.T) {
	now := time.Date(2026, 11, 1, 18, 0, 0, 0, time.UTC)
	ttf := 2.5
	if got := chargeLine(ChargeInfo{State: "Charging", TTFHours: &ttf}, now); got != "🔌 Now charging · full by ~20:30" {
		t.Errorf("charging line = %q", got)
	}
	if got := chargeLine(ChargeInfo{State: "Starting"}, now); got != "🔌 Now charging" {
		t.Errorf("starting line = %q", got)
	}
	if got := chargeLine(ChargeInfo{State: "Complete"}, now); got != "🔌 Charge complete" {
		t.Errorf("complete line = %q", got)
	}
	for _, st := range []string{"", "Disconnected", "Stopped"} {
		if got := chargeLine(ChargeInfo{State: st}, now); got != "" {
			t.Errorf("state %q produced %q", st, got)
		}
	}
}

// ── N5: unit preference in trip messages ─────────────────────────────────────

func testTrip() TripRow {
	wh := 150.0
	return TripRow{
		Duration: 30 * time.Minute, DistanceKM: 16.0934, KWhUsed: 2.4, WhPerKM: &wh,
		SocStartPct: 80, SocEndPct: 76, AvgSpeedMPH: 30, MaxSpeedMPH: 60,
	}
}

func testConfig(units string) *Config {
	return &Config{Units: units, TempUnits: "c", Currency: "£", CostPerKWh: 0.25}
}

func TestFormatMessage_Metric(t *testing.T) {
	msg := formatMessage(testTrip(), "Home", "Work", nil, ChargeInfo{State: "Complete"}, "", testConfig("km"))
	for _, want := range []string{"📏 16.1 km  (10.0 mi)", "150 Wh/km  (241 Wh/mi)", "Avg 48 km/h · Max 97 km/h", "🔌 Charge complete"} {
		if !strings.Contains(msg, want) {
			t.Errorf("metric message missing %q:\n%s", want, msg)
		}
	}
	if strings.Contains(msg, "mph") {
		t.Errorf("metric message mentions mph:\n%s", msg)
	}
}

func TestFormatMessage_Imperial(t *testing.T) {
	msg := formatMessage(testTrip(), "Home", "Work", nil, ChargeInfo{}, "", testConfig("miles"))
	for _, want := range []string{"📏 10.0 mi  (16.1 km)", "241 Wh/mi  (150 Wh/km)", "Avg 30 mph · Max 60 mph"} {
		if !strings.Contains(msg, want) {
			t.Errorf("imperial message missing %q:\n%s", want, msg)
		}
	}
	if strings.Contains(msg, "🔌") {
		t.Errorf("no charge line expected:\n%s", msg)
	}
}

func TestFormatMessage_EscapesLabels(t *testing.T) {
	msg := formatMessage(testTrip(), "<Home>", "A&B", nil, ChargeInfo{}, "", testConfig("km"))
	if !strings.Contains(msg, "&lt;Home&gt; → A&amp;B") {
		t.Errorf("labels not escaped:\n%s", msg)
	}
}

// ── P5: the bot token never appears in an error ──────────────────────────────

func TestTelegramErrors_DoNotLeakToken(t *testing.T) {
	saved := telegramAPI
	// Nothing listens on port 1: every call fails in the transport, which is
	// where *url.Error (and with it the full URL) comes from.
	telegramAPI = "http://127.0.0.1:1"
	defer func() { telegramAPI = saved }()

	calls := map[string]func() error{
		"sendMessage": func() error { return sendMessage(testToken, "1", "hi") },
		"sendPhoto":   func() error { return sendPhoto(testToken, "1", []byte{1, 2, 3}, "cap") },
		"keyboard": func() error {
			return sendMessageWithKeyboard(testToken, "1", "hi", mainMenuKeyboard())
		},
		"removeKeyboard": func() error { return sendMessageRemoveKeyboard(testToken, "1", "hi") },
		"inline": func() error {
			return sendMessageWithInlineKeyboard(testToken, "1", "hi", InlineKeyboardMarkup{})
		},
		"edit":   func() error { return editMessageText(testToken, "1", 1, "hi", InlineKeyboardMarkup{}) },
		"answer": func() error { return answerCallbackQuery(testToken, "q", "") },
		"getFile": func() error {
			_, err := telegramGetFilePath(testToken, "file-id")
			return err
		},
		"getUpdates": func() error {
			_, err := telegramGetUpdates(testToken, 0, 0)
			return err
		},
		"download": func() error {
			resp, err := telegramDo(telegramClient, testToken, "GET", "photos/file_1.jpg", "", nil, true)
			if resp != nil {
				resp.Body.Close()
			}
			return err
		},
	}
	for name, call := range calls {
		err := call()
		if err == nil {
			t.Errorf("%s: expected a transport error", name)
			continue
		}
		if strings.Contains(err.Error(), testToken) || strings.Contains(err.Error(), "bot123456789") {
			t.Errorf("%s: token leaked: %v", name, err)
		}
		if strings.Contains(err.Error(), "127.0.0.1:1/bot") {
			t.Errorf("%s: URL leaked: %v", name, err)
		}
	}
}

func TestTelegramError_RedactsResidualToken(t *testing.T) {
	err := telegramError("getUpdates", errors.New("weird failure mentioning "+testToken), testToken)
	if strings.Contains(err.Error(), testToken) {
		t.Fatalf("token not redacted: %v", err)
	}
	if !strings.Contains(err.Error(), "<redacted>") {
		t.Errorf("expected redaction marker: %v", err)
	}
	if redactToken("abc", "") != "abc" {
		t.Error("empty token must not alter the string")
	}
}

// ── N6: photo size cap ───────────────────────────────────────────────────────

func TestWriteLimited(t *testing.T) {
	dir := t.TempDir()
	ok := filepath.Join(dir, "ok.jpg")
	if err := writeLimited(ok, bytes.NewReader(make([]byte, 10)), 10); err != nil {
		t.Fatalf("at-limit write failed: %v", err)
	}
	if fi, err := os.Stat(ok); err != nil || fi.Size() != 10 {
		t.Fatalf("written file wrong: %v %v", fi, err)
	}
	big := filepath.Join(dir, "big.jpg")
	err := writeLimited(big, bytes.NewReader(make([]byte, 11)), 10)
	if !errors.Is(err, errPhotoTooLarge) {
		t.Fatalf("over-limit write: err = %v", err)
	}
	if _, err := os.Stat(big); !os.IsNotExist(err) {
		t.Errorf("partial file left behind: %v", err)
	}
}

// ── N3: update routing ───────────────────────────────────────────────────────

func TestUpdateChatID(t *testing.T) {
	var empty telegramUpdate
	if _, ok := updateChatID(empty); ok {
		t.Error("update with no message accepted")
	}
	var msg telegramUpdate
	msg.Message.MessageID = 5
	msg.Message.Chat.ID = 42
	if id, ok := updateChatID(msg); !ok || id != 42 {
		t.Errorf("message update: %d %v", id, ok)
	}
	cb := telegramUpdate{CallbackQuery: &telegramCallbackQuery{ID: "x"}}
	cb.CallbackQuery.Message.Chat.ID = 43
	if id, ok := updateChatID(cb); !ok || id != 43 {
		t.Errorf("callback update: %d %v", id, ok)
	}
	cfg := &Config{ChatID: "42"}
	if !isConfiguredChat(cfg, 42) || isConfiguredChat(cfg, 43) {
		t.Error("isConfiguredChat wrong")
	}
}

// ── N8: staleness watchdog ───────────────────────────────────────────────────

func TestWatchdogDecide(t *testing.T) {
	now := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	fresh := now.Add(-time.Hour)
	old := now.Add(-72 * time.Hour)
	th := 48 * time.Hour
	cases := []struct {
		name    string
		newest  *time.Time
		th      time.Duration
		alerted bool
		want    watchdogAction
	}{
		{"fresh, quiet", &fresh, th, false, watchdogNone},
		{"stale, not yet alerted", &old, th, false, watchdogWarn},
		{"stale, already alerted", &old, th, true, watchdogNone},
		{"recovered", &fresh, th, true, watchdogRecover},
		{"no data ever", nil, th, false, watchdogNone},
		{"disabled", &old, 0, false, watchdogNone},
	}
	for _, tc := range cases {
		if got := watchdogDecide(tc.newest, now, tc.th, tc.alerted); got != tc.want {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
	if got := latestOf(&old, &fresh); !got.Equal(fresh) {
		t.Errorf("latestOf = %v", got)
	}
	if latestOf(nil, nil) != nil {
		t.Error("latestOf(nil, nil) != nil")
	}
}

func TestStaleThreshold(t *testing.T) {
	if (&Config{StaleAfterHours: 0}).StaleThreshold() != 0 {
		t.Error("0 must disable")
	}
	if got := (&Config{StaleAfterHours: 48}).StaleThreshold(); got != 48*time.Hour {
		t.Errorf("48h = %s", got)
	}
}

// ── Charging energy presentation ─────────────────────────────────────────────

func TestChargingEnergy_ACOnly(t *testing.T) {
	e := ChargingEnergy{FromACSupply: 32.2, IntoBattery: 31.8}
	if got := e.IntoBatteryFromAC(); got < 31.79 || got > 31.81 {
		t.Errorf("IntoBatteryFromAC = %v", got)
	}
	loss, ok := e.ACLossPct()
	if !ok || loss < 1.2 || loss > 1.3 {
		t.Errorf("ACLossPct = %v %v", loss, ok)
	}
	line := formatChargingLine(e)
	for _, want := range []string{"31.8 kWh into the battery", "31.8 kWh from AC (32.2 kWh drawn from the supply, 1% charger loss)"} {
		if !strings.Contains(line, want) {
			t.Errorf("missing %q in %q", want, line)
		}
	}
	if strings.Contains(line, "DC fast") {
		t.Errorf("no DC fast charging expected: %q", line)
	}
}

func TestChargingEnergy_DCFastOnly(t *testing.T) {
	e := ChargingEnergy{IntoBattery: 30.7, DCFast: 30.7}
	line := formatChargingLine(e)
	if !strings.Contains(line, "30.7 kWh DC fast charging") || strings.Contains(line, "from AC") {
		t.Errorf("unexpected %q", line)
	}
	if _, ok := e.ACLossPct(); ok {
		t.Error("no AC loss without AC energy")
	}
}

func TestChargingEnergy_None(t *testing.T) {
	if got := formatChargingLine(ChargingEnergy{}); got != "🔋 No charging in this period" {
		t.Errorf("got %q", got)
	}
}

func TestChargingEnergySQL_ResetRule(t *testing.T) {
	// The reset rule must stay "a fall to under half the previous value".
	if !strings.Contains(chargingEnergySQL, "num_value < prev * 0.5 THEN num_value") ||
		!strings.Contains(chargingEnergySQL, "WHEN num_value < prev       THEN 0") {
		t.Error("reset rule changed")
	}
}
