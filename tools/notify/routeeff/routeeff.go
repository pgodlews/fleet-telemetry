// Package routeeff is an EXPERIMENTAL efficiency monitor on routes the car
// drives often.
//
// On the same route at matched conditions, energy per km should be stable,
// so a sustained drift points at the vehicle (tyres and pressures,
// alignment, a dragging brake, added load), not at the battery; pack
// capacity is the packfade estimate's job. The repeated-route idea comes
// from Packfade's approach (https://github.com/pgodlews/packfade, MIT
// licence, by the same author), and the fitting reuses the packfade
// package's Huber-WLS and seeded date-clustered bootstrap.
//
// Routes are found in the data, not configured:
//
//  1. Trip start and end points are clustered (leader clustering, densest
//     point first, ClusterRadiusM).
//  2. Each ordered pair of different clusters is a candidate; the two
//     directions are separate routes (the gradient differs).
//  3. Trips whose distance is more than DistanceTol from the pair's median
//     are detours and are left out.
//  4. The remaining trips are grouped by the road actually driven: the
//     largest group within PathDeviationM (symmetric maximum distance
//     between GPS tracks) of its medoid is one route, and the rest are
//     grouped again, so two roads between the same endpoints become two
//     routes.
//  5. A route qualifies with at least MinTrips trips, a median distance of
//     at least MinMedianKm and a distance CV of at most MaxDistanceCV.
//
// Route ids are opaque hashes; coordinates never leave the database.
//
// Model, per route: ln(Wh/km) = a + d*t + gamma*x (t in years), and pooled
// across routes with a route fixed effect so short histories borrow
// strength. Drift is reported as (exp(d) - 1) * 100 % per year with a 95 %
// interval.
package routeeff

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/teslamotors/fleet-telemetry/tools/notify/packfade"
)

// LatLon is a WGS84 position in degrees.
type LatLon struct{ Lat, Lon float64 }

// Trip is one drive from route_trip_observations. Missing numbers are NaN.
type Trip struct {
	ID             int64
	Started, Ended time.Time
	DistanceKm     float64
	Start, End     LatLon
	HasEndpoints   bool
	Track          []LatLon
	WhPerKm        float64
	OutsideC       float64
	CabinMinusOutC float64
	MeanFan        float64
	HvacOn         bool
	HasHvac        bool
	Defrost        bool
	TyreBar        float64
	HoursSincePrev float64
	SpeedKmh       float64
	DurationMin    float64
}

// Options holds the rules; DefaultOptions documents the production values.
type Options struct {
	ClusterRadiusM float64
	DistanceTol    float64
	PathDeviationM float64
	MinTrips       int
	MinMedianKm    float64
	MaxDistanceCV  float64
	MinFitTrips    int
	MinFitDays     int
	MinSpanDays    float64
	// Covariates of the pooled model; RouteCovariates of the per-route
	// fits, which have too few trips for more than one.
	Covariates      []string
	RouteCovariates []string
	HuberK          float64
	Bootstrap       int
	Seed            uint32
}

// DefaultOptions: rules fixed before the drift was fitted (see
// deploy/README.md for the real-data reasoning).
func DefaultOptions() Options {
	return Options{
		ClusterRadiusM:  300,
		DistanceTol:     0.10,
		PathDeviationM:  300,
		MinTrips:        8,
		MinMedianKm:     1.0,
		MaxDistanceCV:   0.05,
		MinFitTrips:     8,
		MinFitDays:      5,
		MinSpanDays:     60,
		Covariates:      []string{"temp", "duration", "fan"},
		RouteCovariates: []string{"temp"},
		HuberK:          1.345,
		Bootstrap:       500,
		Seed:            7,
	}
}

// Covariate names accepted in Options.Covariates.
var covariateNames = []string{"temp", "cabin_delta", "fan", "hvac_on", "defrost", "tyre", "cold_soak", "speed", "duration"}

// CovariateValue returns the covariate value of a trip, or NaN if missing.
func CovariateValue(t Trip, name string) float64 {
	switch name {
	case "temp":
		return t.OutsideC
	case "cabin_delta":
		return t.CabinMinusOutC
	case "fan":
		return t.MeanFan
	case "hvac_on":
		if !t.HasHvac {
			return math.NaN()
		}
		return b2f(t.HvacOn)
	case "defrost":
		return b2f(t.Defrost)
	case "tyre":
		return t.TyreBar
	case "cold_soak":
		if math.IsNaN(t.HoursSincePrev) || t.HoursSincePrev < 0 {
			return math.NaN()
		}
		return math.Log1p(t.HoursSincePrev)
	case "speed":
		return t.SpeedKmh
	case "duration":
		return t.DurationMin
	}
	return math.NaN()
}

func b2f(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

// Route is one qualifying route.
type Route struct {
	ID         string
	Label      string // "Route A", "Route B", ... by trip count
	Start, End LatLon // cluster centres
	PathIndex  int    // 0 for the main road between the endpoints, 1, 2 ... for others
	Trips      []int  // indexes into the trips slice, by start time
	MedianKm   float64
	DistanceCV float64
}

// Trip-level reasons.
const (
	ReasonNoRoute       = "not_on_a_frequent_route"
	ReasonDetour        = "distance_off_route_median"
	ReasonOtherPath     = "different_road"
	ReasonNoEnergy      = "no_positive_energy"
	ReasonNoCovariate   = "missing_covariate"
	ReasonRouteTooSmall = "route_not_qualifying"
)

// Identify finds the qualifying routes. reasons gives, for each trip that
// is not on a qualifying route, why not.
func Identify(trips []Trip, opt Options) ([]Route, map[int]string) {
	reasons := map[int]string{}
	var pts []LatLon
	for _, t := range trips {
		if t.HasEndpoints {
			pts = append(pts, t.Start, t.End)
		}
	}
	centres := leaderCluster(pts, opt.ClusterRadiusM)
	assign := func(p LatLon) int {
		best, bd := -1, math.Inf(1)
		for i, c := range centres {
			if d := Haversine(p, c); d < bd {
				best, bd = i, d
			}
		}
		if bd <= opt.ClusterRadiusM {
			return best
		}
		return -1
	}
	pairs := map[[2]int][]int{}
	for i, t := range trips {
		reasons[i] = ReasonNoRoute
		if !t.HasEndpoints || !(t.DistanceKm > 0) {
			continue
		}
		a, b := assign(t.Start), assign(t.End)
		if a < 0 || b < 0 || a == b {
			continue
		}
		pairs[[2]int{a, b}] = append(pairs[[2]int{a, b}], i)
	}
	keys := make([][2]int, 0, len(pairs))
	for k := range pairs {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i][0] != keys[j][0] {
			return keys[i][0] < keys[j][0]
		}
		return keys[i][1] < keys[j][1]
	})

	var routes []Route
	for _, k := range keys {
		idx := pairs[k]
		if len(idx) < opt.MinTrips {
			continue
		}
		d := make([]float64, len(idx))
		for j, i := range idx {
			d[j] = trips[i].DistanceKm
		}
		med := median(d)
		var kept []int
		for _, i := range idx {
			if math.Abs(trips[i].DistanceKm-med) <= opt.DistanceTol*med {
				kept = append(kept, i)
			} else {
				reasons[i] = ReasonDetour
			}
		}
		for p, group := range pathGroups(trips, kept, opt) {
			if len(group) < opt.MinTrips {
				for _, i := range group {
					reasons[i] = ReasonOtherPath
				}
				continue
			}
			gd := make([]float64, len(group))
			for j, i := range group {
				gd[j] = trips[i].DistanceKm
			}
			r := Route{Start: centres[k[0]], End: centres[k[1]], PathIndex: p, Trips: group,
				MedianKm: median(gd), DistanceCV: cv(gd)}
			if r.MedianKm < opt.MinMedianKm || r.DistanceCV > opt.MaxDistanceCV {
				for _, i := range group {
					reasons[i] = ReasonRouteTooSmall
				}
				continue
			}
			sort.Slice(r.Trips, func(a, b int) bool { return trips[r.Trips[a]].Started.Before(trips[r.Trips[b]].Started) })
			r.ID = routeID(r)
			for _, i := range group {
				delete(reasons, i)
			}
			routes = append(routes, r)
		}
	}
	sort.SliceStable(routes, func(i, j int) bool {
		if len(routes[i].Trips) != len(routes[j].Trips) {
			return len(routes[i].Trips) > len(routes[j].Trips)
		}
		return routes[i].ID < routes[j].ID
	})
	for i := range routes {
		routes[i].Label = "Route " + letters(i)
	}
	return routes, reasons
}

// pathGroups splits trips between the same endpoints by the road driven.
// Trips without a usable track join the first (main) group.
func pathGroups(trips []Trip, idx []int, opt Options) [][]int {
	var withTrack, without []int
	for _, i := range idx {
		if len(trips[i].Track) >= 3 {
			withTrack = append(withTrack, i)
		} else {
			without = append(without, i)
		}
	}
	var groups [][]int
	rest := withTrack
	for len(rest) > 0 {
		dev := func(a, b int) float64 { return pathDeviation(trips[a].Track, trips[b].Track) }
		// medoid: smallest median deviation to the others
		medoid, best := rest[0], math.Inf(1)
		for _, a := range rest {
			var ds []float64
			for _, b := range rest {
				if a != b {
					ds = append(ds, dev(a, b))
				}
			}
			m := 0.0
			if len(ds) > 0 {
				m = median(ds)
			}
			if m < best {
				medoid, best = a, m
			}
		}
		var in, out []int
		for _, a := range rest {
			if a == medoid || dev(a, medoid) <= opt.PathDeviationM {
				in = append(in, a)
			} else {
				out = append(out, a)
			}
		}
		groups = append(groups, in)
		rest = out
	}
	if len(groups) == 0 {
		groups = [][]int{nil}
	}
	groups[0] = append(groups[0], without...)
	return groups
}

// pathDeviation is the symmetric maximum distance (m) from any point of one
// track to the nearest point of the other.
func pathDeviation(a, b []LatLon) float64 {
	return math.Max(directed(a, b), directed(b, a))
}

func directed(a, b []LatLon) float64 {
	worst := 0.0
	for _, p := range a {
		near := math.Inf(1)
		for _, q := range b {
			if d := Haversine(p, q); d < near {
				near = d
			}
		}
		if near > worst {
			worst = near
		}
	}
	return worst
}

// leaderCluster returns cluster centres: points are taken densest first
// (ties by input order) and start a new cluster when no centre is within r.
func leaderCluster(pts []LatLon, r float64) []LatLon {
	n := len(pts)
	nb := make([]int, n)
	for i := range pts {
		for j := range pts {
			if Haversine(pts[i], pts[j]) < r {
				nb[i]++
			}
		}
	}
	order := make([]int, n)
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool { return nb[order[a]] > nb[order[b]] })
	var centres []LatLon
	for _, i := range order {
		near := false
		for _, c := range centres {
			if Haversine(pts[i], c) < r {
				near = true
				break
			}
		}
		if !near {
			centres = append(centres, pts[i])
		}
	}
	return centres
}

// Haversine distance in metres.
func Haversine(a, b LatLon) float64 {
	const rad = math.Pi / 180
	dLat := (b.Lat - a.Lat) * rad
	dLon := (b.Lon - a.Lon) * rad
	x := math.Sin(dLat/2)*math.Sin(dLat/2) + math.Cos(a.Lat*rad)*math.Cos(b.Lat*rad)*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * 6371000 * math.Asin(math.Min(1, math.Sqrt(x)))
}

// routeID is an opaque, reasonably stable id: a hash of the endpoints
// (rounded to about 100 m) and the path index.
func routeID(r Route) string {
	s := fmt.Sprintf("%.3f,%.3f>%.3f,%.3f#%d", r.Start.Lat, r.Start.Lon, r.End.Lat, r.End.Lon, r.PathIndex)
	h := sha256.Sum256([]byte(s))
	return "r" + hex.EncodeToString(h[:])[:10]
}

func letters(i int) string {
	s := ""
	for {
		s = string(rune('A'+i%26)) + s
		i = i/26 - 1
		if i < 0 {
			return s
		}
	}
}

func median(v []float64) float64 {
	if len(v) == 0 {
		return math.NaN()
	}
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

func cv(v []float64) float64 {
	if len(v) < 2 {
		return 0
	}
	m := 0.0
	for _, x := range v {
		m += x
	}
	m /= float64(len(v))
	s := 0.0
	for _, x := range v {
		s += (x - m) * (x - m)
	}
	return math.Sqrt(s/float64(len(v))) / m
}

// robustScale is 1.4826 * MAD.
func robustScale(v []float64) float64 {
	if len(v) == 0 {
		return math.NaN()
	}
	m := median(v)
	d := make([]float64, len(v))
	for i, x := range v {
		d[i] = math.Abs(x - m)
	}
	return 1.4826 * median(d)
}

// ── fitting ─────────────────────────────────────────────────────────────

// minRouteScale floors a route's scatter when it sets the pooled weights
// (as Packfade's environmental floor caps the weight of one ride).
const minRouteScale = 0.05

// Status values.
const (
	StatusOK           = "OK"
	StatusInsufficient = "INSUFFICIENT_DATA"
)

// Estimate is a drift fit for one route or for the pooled model.
type Estimate struct {
	Status          string
	Message         string
	NUsed, NDays    int
	NRoutes         int
	First, Last     time.Time
	SpanDays        float64
	DriftPctPerYear float64
	DriftLo         float64
	DriftHi         float64
	TempPctPer10C   float64 // NaN if temperature is not in the model
	CovEffects      map[string]float64
	CovLo, CovHi    map[string]float64
	RawScale        float64 // robust scale of ln(Wh/km) around the route level(s)
	ResidualScale   float64 // robust scale of the model residuals
	MedianWhPerKm   float64
}

// Point is one trip with its fit outcome.
type Point struct {
	Trip       int
	RouteID    string
	Used       bool
	Reason     string
	Normalised float64 // Wh/km with the pooled covariate effects removed (route level kept); NaN if not used
	Huber      float64
}

// CurvePoint is the pooled model's fitted Wh/km on one route at reference
// conditions, with a pointwise 95 % band.
type CurvePoint struct {
	RouteID        string
	T              time.Time
	Fitted, Lo, Hi float64
}

// Result of one run.
type Result struct {
	Routes   []Route
	PerRoute map[string]Estimate
	Pooled   Estimate
	Points   []Point
	Curve    []CurvePoint
}

// Run identifies routes and fits per route and pooled.
func Run(trips []Trip, opt Options) Result {
	routes, reasons := Identify(trips, opt)
	res := Result{Routes: routes, PerRoute: map[string]Estimate{}}
	routeOf := map[int]string{}
	for _, r := range routes {
		for _, i := range r.Trips {
			routeOf[i] = r.ID
		}
	}
	usable := func(i int) string {
		t := trips[i]
		if !(t.WhPerKm > 0) || math.IsInf(t.WhPerKm, 0) {
			return ReasonNoEnergy
		}
		for _, c := range opt.Covariates {
			if v := CovariateValue(t, c); math.IsNaN(v) {
				return ReasonNoCovariate
			}
		}
		return ""
	}
	pts := make([]Point, len(trips))
	for i := range trips {
		pts[i] = Point{Trip: i, Normalised: math.NaN(), Huber: math.NaN()}
		if r, ok := routeOf[i]; ok {
			pts[i].RouteID = r
			pts[i].Reason = usable(i)
			pts[i].Used = pts[i].Reason == ""
		} else {
			pts[i].Reason = reasons[i]
		}
	}

	// per route
	for _, r := range routes {
		var rows []int
		for _, i := range r.Trips {
			if pts[i].Used {
				rows = append(rows, i)
			}
		}
		ropt := opt
		ropt.Covariates = opt.RouteCovariates
		e, _ := fit(trips, rows, nil, ropt)
		res.PerRoute[r.ID] = e
	}

	// pooled with route fixed effects
	// (routes with fewer than 3 usable trips cannot carry a fixed effect)
	var rows []int
	var routeIdx []int
	var pooledRoutes []Route
	for _, r := range routes {
		var mine []int
		for _, i := range r.Trips {
			if pts[i].Used {
				mine = append(mine, i)
			}
		}
		if len(mine) < 3 {
			continue
		}
		for _, i := range mine {
			rows = append(rows, i)
			routeIdx = append(routeIdx, len(pooledRoutes))
		}
		pooledRoutes = append(pooledRoutes, r)
	}
	pe, pf := fit(trips, rows, routeIdx, opt)
	pe.NRoutes = len(pooledRoutes)
	res.Pooled = pe
	if pf != nil {
		for j, i := range rows {
			pts[i].Huber = pf.HuberWeights[j]
			pts[i].Normalised = math.Exp(math.Log(trips[i].WhPerKm) - pf.covEffect(trips[i]))
		}
		res.Curve = pf.curves(pooledRoutes, trips)
	}
	res.Points = pts
	return res
}

// pooledFit keeps what the curve and normalisation need.
type pooledFit struct {
	r       packfade.RobustResult
	opt     Options
	t0      time.Time
	nRoutes int
	covs    []string
	means   []float64
	// HuberWeights per row
	HuberWeights []float64
}

func (p *pooledFit) covEffect(t Trip) float64 {
	e := 0.0
	for j, c := range p.covs {
		e += p.r.Coef[1+j] * (CovariateValue(t, c) - p.means[1+j])
	}
	return e
}

// curves: fitted ln(Wh/km) on route k at time t with covariates at their
// means: a + route_k + d*t + sum gamma_j*mean_j.
func (p *pooledFit) curves(routes []Route, trips []Trip) []CurvePoint {
	var out []CurvePoint
	nc := len(p.covs)
	for k, r := range routes {
		var first, last time.Time
		n := 0
		for _, i := range r.Trips {
			if !(trips[i].WhPerKm > 0) || math.IsNaN(p.covEffect(trips[i])) {
				continue
			}
			if n == 0 {
				first = trips[i].Started
			}
			last = trips[i].Started
			n++
		}
		if n < 2 {
			continue
		}
		lnAt := func(c []float64, intercept float64, t time.Time) float64 {
			v := intercept + c[0]*years(t, p.t0)
			for j := 0; j < nc; j++ {
				v += c[1+j] * p.means[1+j]
			}
			if k > 0 {
				v += c[1+nc+k-1]
			}
			return v
		}
		const steps = 30
		for s := 0; s < steps; s++ {
			t := first.Add(time.Duration(float64(last.Sub(first)) * float64(s) / float64(steps-1)))
			cp := CurvePoint{RouteID: r.ID, T: t, Fitted: math.Exp(lnAt(p.r.Coef, p.r.Intercept, t)), Lo: math.NaN(), Hi: math.NaN()}
			if len(p.r.Boot) >= 10 {
				v := make([]float64, len(p.r.Boot))
				for b, bc := range p.r.Boot {
					v[b] = lnAt(bc[1:], bc[0], t)
				}
				lo, hi := packfade.Quantiles95(v)
				cp.Lo, cp.Hi = math.Exp(lo), math.Exp(hi)
			}
			out = append(out, cp)
		}
	}
	return out
}

func years(t, t0 time.Time) float64 { return t.Sub(t0).Hours() / 24 / 365.25 }

// fit fits ln(Wh/km) on time and the covariates for the given trips; with
// routeIdx it adds route dummies (the first route is the reference).
func fit(trips []Trip, rows []int, routeIdx []int, opt Options) (Estimate, *pooledFit) {
	e := Estimate{Status: StatusInsufficient, NUsed: len(rows), DriftPctPerYear: math.NaN(), DriftLo: math.NaN(),
		DriftHi: math.NaN(), TempPctPer10C: math.NaN(), RawScale: math.NaN(), ResidualScale: math.NaN(), MedianWhPerKm: math.NaN(),
		CovEffects: map[string]float64{}, CovLo: map[string]float64{}, CovHi: map[string]float64{}}
	if len(rows) == 0 {
		e.Message = "Insufficient data: no usable trips."
		return e, nil
	}
	days := map[string]bool{}
	groups := make([]string, len(rows))
	wh := make([]float64, len(rows))
	first, last := trips[rows[0]].Started, trips[rows[0]].Started
	for j, i := range rows {
		t := trips[i].Started
		if t.Before(first) {
			first = t
		}
		if t.After(last) {
			last = t
		}
		groups[j] = t.UTC().Format("2006-01-02")
		days[groups[j]] = true
		wh[j] = trips[i].WhPerKm
	}
	e.NDays, e.First, e.Last = len(days), first, last
	e.SpanDays = last.Sub(first).Hours() / 24
	e.MedianWhPerKm = median(wh)

	// raw scatter: ln(Wh/km) around each route's median
	byRoute := map[int][]float64{}
	for j, i := range rows {
		k := 0
		if routeIdx != nil {
			k = routeIdx[j]
		}
		byRoute[k] = append(byRoute[k], math.Log(trips[i].WhPerKm))
	}
	var centred []float64
	routeScale := map[int]float64{}
	for k, v := range byRoute {
		m := median(v)
		var c []float64
		for _, x := range v {
			c = append(c, x-m)
		}
		centred = append(centred, c...)
		routeScale[k] = math.Max(robustScale(c), minRouteScale)
	}
	e.RawScale = robustScale(centred)
	// Pooled: each route's trips are weighted by the inverse of that
	// route's own raw scatter, so a noisy route (for example a mostly
	// downhill one, whose small net energy makes Wh/km jumpy) does not set
	// the scale for the others.
	var w []float64
	if routeIdx != nil {
		w = make([]float64, len(rows))
		for j := range rows {
			s := routeScale[routeIdx[j]]
			w[j] = 1 / (s * s)
		}
	}

	minTrips := opt.MinFitTrips
	if routeIdx != nil {
		minTrips = opt.MinFitTrips * 2
	}
	if len(rows) < minTrips || e.NDays < opt.MinFitDays || e.SpanDays < opt.MinSpanDays {
		e.Message = fmt.Sprintf("Insufficient data: needs at least %d usable trips on %d days over %.0f days (have %d trips, %d days, %.0f days).",
			minTrips, opt.MinFitDays, opt.MinSpanDays, len(rows), e.NDays, e.SpanDays)
		return e, nil
	}

	nc := len(opt.Covariates)
	nRoutes := 0
	if routeIdx != nil {
		for _, k := range routeIdx {
			if k+1 > nRoutes {
				nRoutes = k + 1
			}
		}
	}
	nCols := 1 + nc
	if nRoutes > 1 {
		nCols += nRoutes - 1
	}
	cols := make([][]float64, nCols)
	for c := range cols {
		cols[c] = make([]float64, len(rows))
	}
	y := make([]float64, len(rows))
	for j, i := range rows {
		cols[0][j] = years(trips[i].Started, first)
		for c, name := range opt.Covariates {
			cols[1+c][j] = CovariateValue(trips[i], name)
		}
		if nRoutes > 1 && routeIdx[j] > 0 {
			cols[1+nc+routeIdx[j]-1][j] = 1
		}
		y[j] = math.Log(trips[i].WhPerKm)
	}
	r, ok := packfade.RobustFit(cols, y, w, groups, opt.HuberK, opt.Bootstrap, opt.Seed)
	if !ok {
		e.Message = "Fit failed (singular design: a covariate does not vary)."
		return e, nil
	}
	resid := make([]float64, len(rows))
	for j := range rows {
		p := r.Intercept
		for c := range cols {
			p += r.Coef[c] * cols[c][j]
		}
		resid[j] = y[j] - p
	}
	e.ResidualScale = robustScale(resid)
	e.DriftPctPerYear = 100 * (math.Exp(r.Coef[0]) - 1)
	for c, name := range opt.Covariates {
		e.CovEffects[name] = r.Coef[1+c]
	}
	if len(r.Boot) >= 10 {
		d := make([]float64, len(r.Boot))
		for b, bc := range r.Boot {
			d[b] = bc[1]
		}
		lo, hi := packfade.Quantiles95(d)
		e.DriftLo, e.DriftHi = 100*(math.Exp(lo)-1), 100*(math.Exp(hi)-1)
		for c, name := range opt.Covariates {
			v := make([]float64, len(r.Boot))
			for b, bc := range r.Boot {
				v[b] = bc[2+c]
			}
			e.CovLo[name], e.CovHi[name] = packfade.Quantiles95(v)
		}
	}
	if g, ok := e.CovEffects["temp"]; ok {
		e.TempPctPer10C = 100 * (math.Exp(10*g) - 1)
	}
	e.Status = StatusOK
	e.Message = Describe(e)
	pf := &pooledFit{r: r, opt: opt, t0: first, nRoutes: nRoutes, covs: opt.Covariates,
		means: r.Means, HuberWeights: r.HuberWeights}
	return e, pf
}

// Describe gives the plain-words reading.
func Describe(e Estimate) string {
	if e.Status != StatusOK {
		return e.Message
	}
	if math.IsNaN(e.DriftLo) {
		return "Fitted without an interval (bootstrap failed); not distinguishable from no drift."
	}
	iv := fmt.Sprintf("%.1f to %.1f %%/year", e.DriftLo, e.DriftHi)
	switch {
	case e.DriftLo <= 0 && e.DriftHi >= 0:
		return "Not distinguishable from no drift: the 95 % interval (" + iv + ") includes zero."
	case e.DriftLo > 0:
		return "Energy per km is rising on this route (" + iv + "). Usual causes: tyre pressure, temperature, load."
	default:
		return "Energy per km is falling on this route (" + iv + ")."
	}
}

// CovariateNames lists the accepted covariates, for flags and docs.
func CovariateNames() string { return strings.Join(covariateNames, ", ") }
