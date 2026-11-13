package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"time"
)

var weatherClient = &http.Client{Timeout: 5 * time.Second}

// openMeteoResponse is the subset of the open-meteo JSON we decode.
type openMeteoResponse struct {
	Hourly struct {
		Time        []string  `json:"time"`
		Temperature []float64 `json:"temperature_2m"`
		WeatherCode []int     `json:"weathercode"`
	} `json:"hourly"`
}

// fetchWeather returns a short weather string like "8°C, light rain" for
// the hour closest to t at the given coordinates.
// Uses the open-meteo API (free, no API key required).
// Returns an empty string on error so the caller can simply omit it.
func fetchWeather(lat, lon float64, t time.Time) (string, error) {
	// timezone=UTC, not auto. With auto, open-meteo returns local wall-clock
	// strings with no offset, which time.Parse below then reads as UTC — so
	// the "closest hour" was off by the location's offset, including one hour
	// during British summer time. Asking for UTC makes the request and the
	// parse agree.
	utc := t.UTC()
	// Span the neighbouring days so a trip near midnight UTC can still match
	// the genuinely closest hour rather than the nearest edge of one day.
	start := utc.AddDate(0, 0, -1).Format("2006-01-02")
	end := utc.AddDate(0, 0, 1).Format("2006-01-02")
	url := fmt.Sprintf(
		"https://api.open-meteo.com/v1/forecast?latitude=%f&longitude=%f"+
			"&hourly=temperature_2m,weathercode&timezone=UTC"+
			"&start_date=%s&end_date=%s",
		lat, lon, start, end,
	)

	resp, err := weatherClient.Get(url)
	if err != nil {
		return "", fmt.Errorf("open-meteo request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("open-meteo HTTP %d", resp.StatusCode)
	}

	var om openMeteoResponse
	if err := json.NewDecoder(resp.Body).Decode(&om); err != nil {
		return "", fmt.Errorf("open-meteo decode: %w", err)
	}

	if len(om.Hourly.Time) == 0 {
		return "", fmt.Errorf("open-meteo: no hourly data")
	}

	// Find the hourly slot closest to trip start time
	bestIdx := 0
	bestDiff := math.MaxFloat64
	for i, ts := range om.Hourly.Time {
		slot, err := time.ParseInLocation("2006-01-02T15:04", ts, time.UTC)
		if err != nil {
			continue
		}
		diff := math.Abs(utc.Sub(slot).Seconds())
		if diff < bestDiff {
			bestDiff = diff
			bestIdx = i
		}
	}

	if bestIdx >= len(om.Hourly.Temperature) || bestIdx >= len(om.Hourly.WeatherCode) {
		return "", fmt.Errorf("open-meteo: index out of range")
	}

	temp := om.Hourly.Temperature[bestIdx]
	code := om.Hourly.WeatherCode[bestIdx]

	return fmt.Sprintf("%s %d°C, %s", weatherEmoji(code), int(math.Round(temp)), weatherDesc(code)), nil
}

// weatherEmoji maps a WMO weather interpretation code to an emoji.
func weatherEmoji(code int) string {
	switch {
	case code == 0:
		return "☀️"
	case code <= 3:
		return "🌤️"
	case code <= 48:
		return "🌫️"
	case code <= 57:
		return "🌦️"
	case code <= 67:
		return "🌧️"
	case code <= 77:
		return "🌨️"
	case code <= 82:
		return "🌦️"
	case code <= 86:
		return "🌨️"
	case code <= 99:
		return "⛈️"
	default:
		return "🌡️"
	}
}

// weatherDesc maps a WMO code to a short description.
func weatherDesc(code int) string {
	switch {
	case code == 0:
		return "clear sky"
	case code == 1:
		return "mainly clear"
	case code == 2:
		return "partly cloudy"
	case code == 3:
		return "overcast"
	case code <= 48:
		return "foggy"
	case code <= 55:
		return "drizzle"
	case code <= 57:
		return "freezing drizzle"
	case code <= 65:
		return "rain"
	case code <= 67:
		return "freezing rain"
	case code <= 75:
		return "snow"
	case code <= 77:
		return "snow grains"
	case code <= 82:
		return "rain showers"
	case code <= 86:
		return "snow showers"
	case code == 95:
		return "thunderstorm"
	case code <= 99:
		return "thunderstorm with hail"
	default:
		return "unknown"
	}
}
