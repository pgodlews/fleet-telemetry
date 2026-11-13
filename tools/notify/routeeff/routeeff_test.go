package routeeff

import (
	"math"
	"math/rand"
	"testing"
	"time"
)

// Invented positions (open ocean), about 2-3 km apart.
var (
	pA = LatLon{10.000, -30.000}
	pB = LatLon{10.020, -30.000}
	pC = LatLon{10.000, -30.025}
)

// line returns a straight track from a to b, optionally bowed sideways by
// bow degrees at the middle (a different road).
func line(a, b LatLon, bow float64) []LatLon {
	var out []LatLon
	dl, dn := b.Lat-a.Lat, b.Lon-a.Lon
	norm := math.Hypot(dl, dn)
	pl, pn := -dn/norm, dl/norm // perpendicular unit vector
	for s := 0; s <= 20; s++ {
		f := float64(s) / 20
		off := bow * math.Sin(math.Pi*f)
		out = append(out, LatLon{a.Lat + dl*f + pl*off, a.Lon + dn*f + pn*off})
	}
	return out
}

type spec struct {
	from, to LatLon
	km, base float64
	bow      float64
	n        int
}

// synthetic plants drift (fraction per year), a temperature effect of
// -1 % per degC, lognormal noise, outliers (x1.8 or /1.8) and detours.
func synthetic(seed int64, drift, outlierFrac float64, specs []spec) ([]Trip, map[int64]bool) {
	rng := rand.New(rand.NewSource(seed))
	t0 := time.Date(2025, 1, 6, 8, 0, 0, 0, time.UTC)
	var trips []Trip
	out := map[int64]bool{}
	id := int64(0)
	for _, sp := range specs {
		for k := 0; k < sp.n; k++ {
			id++
			start := t0.Add(time.Duration(rng.Intn(420))*24*time.Hour + time.Duration(rng.Intn(10))*time.Hour)
			y := years(start, t0)
			temp := 10 + 8*math.Sin(2*math.Pi*(y-0.3)) + rng.NormFloat64()*2
			km := sp.km * (1 + rng.NormFloat64()*0.01)
			ln := math.Log(sp.base) + math.Log(1+drift)*y - 0.01*temp + rng.NormFloat64()*0.12
			if rng.Float64() < outlierFrac {
				out[id] = true
				if rng.Intn(2) == 0 {
					ln += math.Log(1.8)
				} else {
					ln -= math.Log(1.8)
				}
			}
			trips = append(trips, Trip{
				ID: id, Started: start, Ended: start.Add(8 * time.Minute), DistanceKm: km,
				Start: sp.from, End: sp.to, HasEndpoints: true, Track: line(sp.from, sp.to, sp.bow),
				WhPerKm: math.Exp(ln), OutsideC: temp, CabinMinusOutC: 2, MeanFan: float64(rng.Intn(6)), HasHvac: true,
				TyreBar: 2.9, HoursSincePrev: 5, SpeedKmh: 30, DurationMin: 6 + 4*rng.Float64(),
			})
		}
	}
	return trips, out
}

func standard() []spec {
	return []spec{
		{pA, pB, 2.2, 200, 0, 40},
		{pB, pA, 2.2, 230, 0, 35},
		{pA, pC, 2.7, 180, 0, 30},
		{pA, pC, 2.8, 180, 0.01, 12}, // another road between the same endpoints, similar length
		{pC, pA, 2.7, 210, 0, 4},     // too few to qualify
	}
}

func TestIdentify(t *testing.T) {
	trips, _ := synthetic(1, 0, 0, standard())
	// two detours on A->B
	for i := 0; i < 2; i++ {
		d := trips[i]
		d.ID = int64(1000 + i)
		d.DistanceKm = 3.5
		trips = append(trips, d)
	}
	routes, reasons := Identify(trips, DefaultOptions())
	if len(routes) != 4 {
		t.Fatalf("got %d routes, want 4 (A>B, B>A, A>C main road, A>C other road)", len(routes))
	}
	want := []int{40, 35, 30, 12}
	for i, r := range routes {
		if len(r.Trips) != want[i] {
			t.Errorf("route %s (%s): %d trips, want %d", r.Label, r.ID, len(r.Trips), want[i])
		}
	}
	if routes[0].Label != "Route A" || routes[3].Label != "Route D" {
		t.Errorf("labels %q %q", routes[0].Label, routes[3].Label)
	}
	if routes[2].PathIndex == routes[3].PathIndex {
		t.Errorf("the two roads between the same endpoints share a path index")
	}
	n := map[string]int{}
	for _, r := range reasons {
		n[r]++
	}
	if n[ReasonDetour] != 2 || n[ReasonNoRoute]+n[ReasonOtherPath] != 4 {
		t.Errorf("reasons %v", n)
	}
	// ids are stable across runs and opaque
	again, _ := Identify(trips, DefaultOptions())
	for i := range routes {
		if routes[i].ID != again[i].ID || len(routes[i].ID) != 11 {
			t.Errorf("id %q vs %q", routes[i].ID, again[i].ID)
		}
	}
}

func TestRecoversPlantedDrift(t *testing.T) {
	for _, drift := range []float64{0, 0.05, 0.15} {
		trips, _ := synthetic(2, drift, 0, standard())
		r := Run(trips, DefaultOptions())
		p := r.Pooled
		if p.Status != StatusOK {
			t.Fatalf("drift %.2f: %s", drift, p.Message)
		}
		want := drift * 100
		if want < p.DriftLo || want > p.DriftHi {
			t.Errorf("drift %.2f: planted %.1f %%/yr outside [%.1f, %.1f] (estimate %.1f)", drift, want, p.DriftLo, p.DriftHi, p.DriftPctPerYear)
		}
		if lo, hi := p.CovLo["temp"], p.CovHi["temp"]; -0.01 < lo || -0.01 > hi {
			t.Errorf("drift %.2f: planted temperature coefficient -0.01 outside [%.4f, %.4f]", drift, lo, hi)
		}
		if p.NRoutes != 4 {
			t.Errorf("pooled over %d routes, want 4", p.NRoutes)
		}
		if !(p.ResidualScale < p.RawScale) {
			t.Errorf("covariates did not reduce the scatter: raw %.3f residual %.3f", p.RawScale, p.ResidualScale)
		}
		if len(r.Curve) == 0 {
			t.Errorf("no curve")
		}
	}
}

func TestDeterministicAndRobust(t *testing.T) {
	clean, _ := synthetic(3, 0.08, 0, standard())
	dirty, isOut := synthetic(3, 0.08, 0.12, standard())
	a := Run(dirty, DefaultOptions())
	b := Run(dirty, DefaultOptions())
	if a.Pooled.DriftLo != b.Pooled.DriftLo || a.Pooled.DriftPctPerYear != b.Pooled.DriftPctPerYear {
		t.Fatalf("not deterministic")
	}
	c := Run(clean, DefaultOptions())
	if math.Abs(a.Pooled.DriftPctPerYear-c.Pooled.DriftPctPerYear) > 4 {
		t.Errorf("outliers moved the pooled drift from %.1f [%.1f, %.1f] to %.1f [%.1f, %.1f]", c.Pooled.DriftPctPerYear, c.Pooled.DriftLo, c.Pooled.DriftHi, a.Pooled.DriftPctPerYear, a.Pooled.DriftLo, a.Pooled.DriftHi)
	}
	if 8 < a.Pooled.DriftLo || 8 > a.Pooled.DriftHi {
		t.Errorf("with outliers the planted 8 %%/yr is outside [%.1f, %.1f]", a.Pooled.DriftLo, a.Pooled.DriftHi)
	}
	var hOut, nOut, hIn, nIn float64
	for _, p := range a.Points {
		if !p.Used || math.IsNaN(p.Huber) {
			continue
		}
		if isOut[dirty[p.Trip].ID] {
			hOut += p.Huber
			nOut++
		} else {
			hIn += p.Huber
			nIn++
		}
	}
	if nOut == 0 || hOut/nOut > 0.5 || hIn/nIn < 0.85 {
		t.Errorf("mean Huber weight outliers %.2f (n %v), others %.2f", hOut/nOut, nOut, hIn/nIn)
	}
}

func TestInsufficientAndMissing(t *testing.T) {
	trips, _ := synthetic(4, 0, 0, []spec{{pA, pB, 2.2, 200, 0, 9}})
	for i := range trips {
		trips[i].Started = trips[0].Started.Add(time.Duration(i) * 24 * time.Hour)
	}
	r := Run(trips, DefaultOptions())
	if len(r.Routes) != 1 {
		t.Fatalf("routes %d", len(r.Routes))
	}
	if e := r.PerRoute[r.Routes[0].ID]; e.Status != StatusInsufficient || e.Message == "" {
		t.Errorf("9-day span: %s %q", e.Status, e.Message)
	}
	if r.Pooled.Status != StatusInsufficient {
		t.Errorf("pooled %s", r.Pooled.Status)
	}
	trips[0].OutsideC = math.NaN()
	trips[1].WhPerKm = -5
	r = Run(trips, DefaultOptions())
	if r.Points[0].Reason != ReasonNoCovariate || r.Points[1].Reason != ReasonNoEnergy {
		t.Errorf("reasons %q %q", r.Points[0].Reason, r.Points[1].Reason)
	}
}

func TestHaversineAndLetters(t *testing.T) {
	if d := Haversine(LatLon{0, 0}, LatLon{0, 1}); math.Abs(d-111195) > 100 {
		t.Errorf("1 degree of longitude at the equator: %.0f m", d)
	}
	if letters(0) != "A" || letters(25) != "Z" || letters(26) != "AA" {
		t.Errorf("letters %s %s %s", letters(0), letters(25), letters(26))
	}
}
