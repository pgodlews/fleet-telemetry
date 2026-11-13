package main

import (
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// formatMessage builds the Telegram caption / message text for a completed trip.
func formatMessage(
	trip TripRow,
	startLabel, endLabel string,
	avgWhPerKM *float64,
	charge ChargeInfo,
	weatherStr string,
	cfg *Config,
) string {
	snap := cfg.Snapshot()
	cur := htmlEscape(snap.Currency)

	var b strings.Builder

	// ── Header ───────────────────────────────────────────────────────────────
	b.WriteString(fmt.Sprintf("🚗 <b>Trip complete</b> · %s\n", formatDuration(trip.Duration)))
	b.WriteString("\n")

	// ── Route ────────────────────────────────────────────────────────────────
	b.WriteString(fmt.Sprintf("📍 %s → %s\n", htmlEscape(startLabel), htmlEscape(endLabel)))

	// ── Distance ─────────────────────────────────────────────────────────────
	// The preferred unit comes first; the other one follows in brackets.
	miles := snap.Units == "miles"
	km := trip.DistanceKM
	mi := km * kmToMi
	if miles {
		b.WriteString(fmt.Sprintf("📏 %.1f mi  (%.1f km)\n", mi, km))
	} else {
		b.WriteString(fmt.Sprintf("📏 %.1f km  (%.1f mi)\n", km, mi))
	}

	// ── Energy & cost ────────────────────────────────────────────────────────
	kwh := trip.KWhUsed
	cost := kwh * snap.CostPerKWh
	b.WriteString(fmt.Sprintf("⚡ %.2f kWh\n", kwh))
	b.WriteString(fmt.Sprintf("💰 Est. cost: %s%.2f  (@ %s%.4f/kWh)\n", cur, cost, cur, snap.CostPerKWh))

	// ── Efficiency ───────────────────────────────────────────────────────────
	if trip.WhPerKM != nil && *trip.WhPerKM > 0 {
		whkm := *trip.WhPerKM
		whmi := whkm / kmToMi
		if miles {
			b.WriteString(fmt.Sprintf("🌡️ %.0f Wh/mi  (%.0f Wh/km)\n", whmi, whkm))
		} else {
			b.WriteString(fmt.Sprintf("🌡️ %.0f Wh/km  (%.0f Wh/mi)\n", whkm, whmi))
		}

		// Comparison to 30-day average
		if avgWhPerKM != nil && *avgWhPerKM > 0 {
			diff := (*avgWhPerKM - whkm) / *avgWhPerKM * 100
			if math.Abs(diff) >= 5 {
				if diff > 0 {
					b.WriteString(fmt.Sprintf("📊 %.0f%% more efficient than 30-day avg\n", diff))
				} else {
					b.WriteString(fmt.Sprintf("📊 %.0f%% less efficient than 30-day avg\n", -diff))
				}
			}
		}
	}

	// ── Battery ──────────────────────────────────────────────────────────────
	b.WriteString(fmt.Sprintf("🔋 %.0f%% → %.0f%%\n", trip.SocStartPct, trip.SocEndPct))

	// ── Speed ────────────────────────────────────────────────────────────────
	// The trips view reports speeds in mph (VehicleSpeed is mph on the wire).
	if trip.AvgSpeedMPH > 0 || trip.MaxSpeedMPH > 0 {
		if miles {
			b.WriteString(fmt.Sprintf("🏎️  Avg %.0f mph · Max %.0f mph\n", trip.AvgSpeedMPH, trip.MaxSpeedMPH))
		} else {
			b.WriteString(fmt.Sprintf("🏎️  Avg %.0f km/h · Max %.0f km/h\n", trip.AvgSpeedMPH/kmToMi, trip.MaxSpeedMPH/kmToMi))
		}
	}

	// ── Weather ──────────────────────────────────────────────────────────────
	if weatherStr != "" {
		b.WriteString(convertWeatherTemp(weatherStr, snap.TempUnits) + "\n")
	}

	// ── Charge status ────────────────────────────────────────────────────────
	if line := chargeLine(charge, time.Now()); line != "" {
		b.WriteString(line + "\n")
	}

	return strings.TrimRight(b.String(), "\n")
}

// kmToMi converts kilometres to miles.
const kmToMi = 0.621371

// chargeLine renders the post-trip charging status. charge.State is the
// DetailedChargeState value with its proto prefix already stripped
// (see normalizeChargeState).
func chargeLine(charge ChargeInfo, now time.Time) string {
	switch charge.State {
	case "Charging", "Starting":
		if charge.TTFHours != nil && *charge.TTFHours > 0 {
			eta := now.Add(time.Duration(*charge.TTFHours * float64(time.Hour)))
			return fmt.Sprintf("🔌 Now charging · full by ~%s", eta.Format("15:04"))
		}
		return "🔌 Now charging"
	case "Complete":
		return "🔌 Charge complete"
	}
	return ""
}

// normalizeChargeState strips the proto enum prefix the ingester stores
// DetailedChargeState values with ("DetailedChargeStateCharging" →
// "Charging"). A NULL (never reported) becomes "".
func normalizeChargeState(raw *string) string {
	if raw == nil {
		return ""
	}
	return strings.TrimPrefix(*raw, "DetailedChargeState")
}

// weatherTempRe matches the Celsius token in a weather string.
var weatherTempRe = regexp.MustCompile(`(-?\d+)°C`)

// convertWeatherTemp rewrites the temperature token in a weather string (e.g.
// "🌤️ 8°C, partly cloudy") from Celsius to Fahrenheit when tempUnits == "f".
// If the string doesn't match the expected pattern it is returned unchanged.
func convertWeatherTemp(s, tempUnits string) string {
	if tempUnits != "f" {
		return s
	}
	return weatherTempRe.ReplaceAllStringFunc(s, func(match string) string {
		sub := weatherTempRe.FindStringSubmatch(match)
		if len(sub) < 2 {
			return match
		}
		c, err := strconv.Atoi(sub[1])
		if err != nil {
			return match
		}
		f := int(math.Round(float64(c)*9/5 + 32))
		return fmt.Sprintf("%d°F", f)
	})
}

// formatDuration returns a human-readable trip duration like "1h 23m" or "45m".
func formatDuration(d time.Duration) string {
	d = d.Round(time.Minute)
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	if h > 0 {
		return fmt.Sprintf("%dh %02dm", h, m)
	}
	return fmt.Sprintf("%dm", m)
}
