package main

import (
	"bytes"
	"fmt"
	"image/color"
	"image/png"

	sm "github.com/flopp/go-staticmaps"
	"github.com/golang/geo/s2"
)

// renderRouteMap renders a PNG map image showing the GPS route.
// Returns the raw PNG bytes suitable for sending via Telegram sendPhoto.
// Returns an error if there are fewer than 2 GPS points, or if tile
// fetching / rendering fails.
func renderRouteMap(points []GPSPoint) ([]byte, error) {
	if len(points) < 2 {
		return nil, fmt.Errorf("need at least 2 GPS points, got %d", len(points))
	}

	ctx := sm.NewContext()
	ctx.SetSize(800, 450)
	ctx.SetTileProvider(sm.NewTileProviderOpenStreetMaps())

	// Convert GPS points to s2.LatLng slice for the path
	coords := make([]s2.LatLng, len(points))
	for i, p := range points {
		coords[i] = s2.LatLngFromDegrees(p.Lat, p.Lon)
	}

	// Blue route polyline
	ctx.AddObject(sm.NewPath(
		coords,
		color.RGBA{R: 66, G: 133, B: 244, A: 255},
		3.0,
	))

	// Green start marker
	ctx.AddObject(sm.NewMarker(
		coords[0],
		color.RGBA{R: 0, G: 180, B: 0, A: 255},
		16.0,
	))

	// Red end marker
	ctx.AddObject(sm.NewMarker(
		coords[len(coords)-1],
		color.RGBA{R: 220, G: 50, B: 50, A: 255},
		16.0,
	))

	img, err := ctx.Render()
	if err != nil {
		return nil, fmt.Errorf("render map: %w", err)
	}

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, fmt.Errorf("encode PNG: %w", err)
	}

	return buf.Bytes(), nil
}

// renderSinglePointMap renders a PNG map centred on a single GPS point with a
// red pin marker — used for /lastknownlocation.
func renderSinglePointMap(pt GPSPoint) ([]byte, error) {
	ctx := sm.NewContext()
	ctx.SetSize(600, 400)
	ctx.SetTileProvider(sm.NewTileProviderOpenStreetMaps())
	ctx.SetZoom(15)

	coord := s2.LatLngFromDegrees(pt.Lat, pt.Lon)
	ctx.AddObject(sm.NewMarker(
		coord,
		color.RGBA{R: 220, G: 50, B: 50, A: 255},
		16.0,
	))

	img, err := ctx.Render()
	if err != nil {
		return nil, fmt.Errorf("render single-point map: %w", err)
	}

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, fmt.Errorf("encode PNG: %w", err)
	}
	return buf.Bytes(), nil
}
