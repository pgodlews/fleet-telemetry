// Package packfade is an EXPERIMENTAL estimate of traction-battery capacity
// fade from drive telemetry.
//
// The statistical method is adapted from Packfade
// (https://github.com/pgodlews/packfade, MIT licence), an e-bike battery
// degradation tool by the same author: a log-linear degradation model fitted
// by quantization-weighted least squares with Huber IRLS (k = 1.345, MAD
// scale) and a seeded, date-clustered block bootstrap for a 95 % interval.
// The fitting routine in fit.go is a port of Packfade's browser engine; see
// the notice at the top of that file.
//
// What differs from Packfade, and why:
//
//   - Observable. Packfade has only %SOC per km. The car reports pack voltage
//     and current, so each drive gives an apparent capacity directly:
//     energy out of the pack / fraction of SOC used (deploy/sql/057). Route,
//     wind and load cancel. The model is
//     ln(C_i) = b0 - bt*t_i + gamma*x_i + e_i, with t in years.
//   - Weights. Soc arrives in steps of about 0.0392 percentage points
//     (measured), so quantization alone gives a variance of
//     2*q^2/12 / drop^2 on ln C (delta method), which is negligible. The
//     scatter actually measured on production data is dominated by the BMS
//     SOC estimate itself (LFP packs drift between full charges), so each
//     SOC reading also carries an estimation error SOCReadingSD (1.0 pp,
//     measured: robust scatter of 2-10 pp drives). Var(ln C_i) =
//     EnvSD^2 + 2*(q^2/12 + SOCReadingSD^2) / drop_i^2.
//   - Huber residuals are standardised by each observation's own base
//     weight before the MAD scale is taken, because the weights here span
//     two orders of magnitude.
//   - IRLS runs to convergence rather than a fixed four iterations.
//
// Limits: it relies on the BMS SOC; LFP SOC drifts between full charges;
// current and voltage are sampled every 30 s, so short peaks are missed.
// The result is an apparent capacity index, not a laboratory capacity test,
// and it is kept out of the predictive health score.
package packfade

import (
	"math"
	"sort"
	"time"
)

// Observation is one discharge segment (one drive) from packfade_segments.
type Observation struct {
	Start, End          time.Time
	SOCDrop             float64 // percentage points
	ApparentCapacityKWh float64 // energy out / (SOCDrop/100)
	Coverage            float64 // fraction of the segment covered by power samples
	TempC               float64
	HasTemp             bool
	MeanSOC             float64
	MeanPowerKW         float64
	HoursSinceFull      float64 // hours since SOC was last >= 99 %; NaN if unknown
	SOCRisePP           float64 // largest SOC rise above the running minimum
	ChargeCounterKWh    float64 // AC/DC charging counters' increase inside the segment
	BMSCapacityKWh      float64 // BMS EnergyRemaining drop / SOCDrop, comparison only; NaN if unknown
}

// Options controls eligibility and the fit. DefaultOptions documents the
// values used in production.
type Options struct {
	SOCStepPP       float64  // Soc quantization step, percentage points
	SOCReadingSD    float64  // BMS SOC estimation error per reading, pp
	EnvSD           float64  // environmental noise floor on ln C (Packfade: 0.05)
	MinSOCDrop      float64  // pp
	MinCoverage     float64  // fraction
	MaxSOCRise      float64  // pp; above this the segment contains charging
	MaxChargeKWh    float64  // charging-counter increase that marks charging
	CalibratedHours float64  // a segment is "calibrated" if it starts within this many hours of a full charge
	OnlyCalibrated  bool     // fit only calibrated-start segments
	Covariates      []string // any of "temp", "soc", "power"
	HuberK          float64
	Bootstrap       int
	Seed            uint32
	MinUsed         int     // insufficient data below this many observations
	MinDays         int     // ... or below this many distinct days
	MinSpanDays     float64 // ... or a shorter span than this
}

// DefaultOptions are the settings documented in deploy/README.md. They were
// fixed from the measured noise of the observations before any fade was
// fitted, not tuned on the result.
func DefaultOptions() Options {
	return Options{
		SOCStepPP:       0.0392,
		SOCReadingSD:    1.0,
		EnvSD:           0.05,
		MinSOCDrop:      5,
		MinCoverage:     0.9,
		MaxSOCRise:      1.0,
		MaxChargeKWh:    0.5,
		CalibratedHours: 24,
		Covariates:      []string{"temp"},
		HuberK:          1.345,
		Bootstrap:       500,
		Seed:            7,
		MinUsed:         15,
		MinDays:         8,
		MinSpanDays:     90,
	}
}

// Rejection reasons recorded per observation.
const (
	RejectNoDrop       = "no_soc_drop"
	RejectSmallDrop    = "soc_drop_below_min"
	RejectCoverage     = "power_coverage_low"
	RejectCharging     = "charging_in_segment"
	RejectNoTemp       = "no_temperature"
	RejectNotCalibrate = "not_calibrated_start"
	RejectImplausible  = "implausible_capacity"
)

// Eligibility returns "" when the observation can be used, otherwise the
// reason it is rejected.
func Eligibility(o Observation, opt Options) string {
	switch {
	case !(o.SOCDrop > 0):
		return RejectNoDrop
	case o.ChargeCounterKWh > opt.MaxChargeKWh || o.SOCRisePP > opt.MaxSOCRise:
		return RejectCharging
	case !(o.Coverage >= opt.MinCoverage):
		return RejectCoverage
	case o.SOCDrop < opt.MinSOCDrop:
		return RejectSmallDrop
	case !(o.ApparentCapacityKWh > 0) || o.ApparentCapacityKWh > 1000 || math.IsInf(o.ApparentCapacityKWh, 0):
		return RejectImplausible
	case needsTemp(opt) && !o.HasTemp:
		return RejectNoTemp
	case opt.OnlyCalibrated && !(o.HoursSinceFull <= opt.CalibratedHours):
		return RejectNotCalibrate
	}
	return ""
}

func needsTemp(opt Options) bool {
	for _, c := range opt.Covariates {
		if c == "temp" {
			return true
		}
	}
	return false
}

// BaseWeight is the inverse of Var(ln C) for one observation (delta method).
func BaseWeight(drop float64, opt Options) float64 {
	quant := opt.SOCStepPP * opt.SOCStepPP / 12
	perReading := quant + opt.SOCReadingSD*opt.SOCReadingSD
	return 1 / (opt.EnvSD*opt.EnvSD + 2*perReading/(drop*drop))
}

// Status values of Result.
const (
	StatusOK           = "OK"
	StatusInsufficient = "INSUFFICIENT_DATA"
)

// Point is one observation with its fit outcome.
type Point struct {
	Obs           Observation
	Used          bool
	Reason        string
	BaseWeight    float64 // normalised to mean 1 over the used points
	HuberWeight   float64
	NormalisedKWh float64 // covariate effects removed (reference conditions); NaN if not used
}

// CurvePoint is the fitted capacity at reference conditions with a
// pointwise 95 % bootstrap band.
type CurvePoint struct {
	T            time.Time
	FittedKWh    float64
	LoKWh, HiKWh float64
}

// Result is one fit.
type Result struct {
	Status                     string
	Message                    string
	NSegments, NUsed, NRejectd int
	NDays                      int
	FirstObs, LastObs          time.Time
	SpanDays                   float64
	BaselineKWh, NowKWh        float64
	IndexPct                   float64
	IndexLoPct, IndexHiPct     float64
	FadePctPerYear             float64
	FadeLoPct, FadeHiPct       float64
	TempEffectPctPer10C        float64
	ResidualScale              float64
	Slope                      float64 // d ln C / d year
	SlopeLo, SlopeHi           float64
	NBoot                      int
	Points                     []Point
	Curve                      []CurvePoint
}

// Estimate applies the eligibility rules and fits the model.
func Estimate(obs []Observation, opt Options) Result {
	res := Result{NSegments: len(obs), Status: StatusInsufficient, NBoot: opt.Bootstrap}
	sorted := append([]Observation(nil), obs...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Start.Before(sorted[j].Start) })

	var used []int
	res.Points = make([]Point, len(sorted))
	for i, o := range sorted {
		r := Eligibility(o, opt)
		res.Points[i] = Point{Obs: o, Used: r == "", Reason: r, NormalisedKWh: math.NaN(), HuberWeight: math.NaN(), BaseWeight: math.NaN()}
		if r == "" {
			used = append(used, i)
		}
	}
	res.NUsed = len(used)
	res.NRejectd = len(sorted) - len(used)
	if len(used) > 0 {
		res.FirstObs = sorted[used[0]].Start
		res.LastObs = sorted[used[len(used)-1]].Start
		res.SpanDays = res.LastObs.Sub(res.FirstObs).Hours() / 24
		days := map[string]bool{}
		for _, i := range used {
			days[dayKey(sorted[i].Start)] = true
		}
		res.NDays = len(days)
	}
	if res.NUsed < opt.MinUsed || res.NDays < opt.MinDays || res.SpanDays < opt.MinSpanDays {
		res.Message = "Insufficient data: needs at least " + itoa(opt.MinUsed) + " usable drives on " +
			itoa(opt.MinDays) + " different days over " + itoa(int(opt.MinSpanDays)) + " days (have " +
			itoa(res.NUsed) + " drives, " + itoa(res.NDays) + " days, " + itoa(int(res.SpanDays)) + " days)."
		return res
	}

	// Design: column 0 = time in years from the first used observation,
	// then covariates.
	n := len(used)
	cols := make([][]float64, 1+len(opt.Covariates))
	for j := range cols {
		cols[j] = make([]float64, n)
	}
	y := make([]float64, n)
	wBase := make([]float64, n)
	groups := make([]string, n)
	for k, i := range used {
		o := sorted[i]
		cols[0][k] = o.Start.Sub(res.FirstObs).Hours() / 24 / 365.25
		for j, c := range opt.Covariates {
			cols[j+1][k] = covariate(o, c)
		}
		y[k] = math.Log(o.ApparentCapacityKWh)
		wBase[k] = BaseWeight(o.SOCDrop, opt)
		groups[k] = dayKey(o.Start)
	}
	f := newFitter(cols, y, wBase, groups, opt.HuberK)
	coef, hub, ok := f.fit(allIndex(n))
	if !ok {
		res.Message = "Fit failed: the design matrix is singular."
		return res
	}
	slope := f.slope(coef)
	res.Slope = slope
	res.ResidualScale = f.lastScale

	// Reference conditions: covariates at their means (Packfade's choice).
	refLog := func(c []float64, t float64) float64 { return f.predictRef(c, t) }
	T := cols[0][n-1]
	res.BaselineKWh = math.Exp(refLog(coef, 0))
	res.NowKWh = math.Exp(refLog(coef, T))
	res.IndexPct = 100 * math.Exp(slope*T)
	res.FadePctPerYear = 100 * (1 - math.Exp(slope))
	for j, c := range opt.Covariates {
		if c == "temp" {
			res.TempEffectPctPer10C = 100 * (math.Exp(10*f.covCoef(coef, j)) - 1)
		}
	}

	for k, i := range used {
		p := &res.Points[i]
		p.BaseWeight = f.wBase[k]
		p.HuberWeight = hub[k]
		p.NormalisedKWh = math.Exp(y[k] - f.covEffect(coef, k))
	}

	// Seeded date-clustered bootstrap.
	boots := f.bootstrap(opt.Bootstrap, opt.Seed)
	res.NBoot = len(boots)
	nCurve := 60
	if len(boots) >= 10 {
		slopes := make([]float64, len(boots))
		for b, c := range boots {
			slopes[b] = f.slope(c)
		}
		sort.Float64s(slopes)
		lo, hi := quantilePair(slopes)
		res.SlopeLo, res.SlopeHi = lo, hi
		res.IndexLoPct = 100 * math.Exp(lo*T)
		res.IndexHiPct = 100 * math.Exp(hi*T)
		res.FadeLoPct = 100 * (1 - math.Exp(hi)) // a higher slope is less fade
		res.FadeHiPct = 100 * (1 - math.Exp(lo))
	} else {
		res.SlopeLo, res.SlopeHi = math.NaN(), math.NaN()
		res.IndexLoPct, res.IndexHiPct = math.NaN(), math.NaN()
		res.FadeLoPct, res.FadeHiPct = math.NaN(), math.NaN()
	}
	for s := 0; s < nCurve; s++ {
		t := T * float64(s) / float64(nCurve-1)
		cp := CurvePoint{
			T:         res.FirstObs.Add(time.Duration(t * 365.25 * 24 * float64(time.Hour))),
			FittedKWh: math.Exp(refLog(coef, t)),
			LoKWh:     math.NaN(), HiKWh: math.NaN(),
		}
		if len(boots) >= 10 {
			v := make([]float64, len(boots))
			for b, c := range boots {
				v[b] = refLog(c, t)
			}
			sort.Float64s(v)
			lo, hi := quantilePair(v)
			cp.LoKWh, cp.HiKWh = math.Exp(lo), math.Exp(hi)
		}
		res.Curve = append(res.Curve, cp)
	}
	res.Status = StatusOK
	res.Message = Describe(res)
	return res
}

// Describe gives the plain-words reading of a fit.
func Describe(r Result) string {
	if r.Status != StatusOK {
		return r.Message
	}
	if math.IsNaN(r.FadeLoPct) {
		return "Estimate without an interval (bootstrap failed); treat as not yet distinguishable from no fade."
	}
	switch {
	case r.FadeLoPct <= 0 && r.FadeHiPct >= 0:
		return "Not yet distinguishable from no fade: the 95 % interval of the fade rate (" +
			ftoa(r.FadeLoPct) + " to " + ftoa(r.FadeHiPct) + " %/year) includes zero."
	case r.FadeLoPct > 0:
		return "Apparent capacity is falling: 95 % interval " + ftoa(r.FadeLoPct) + " to " + ftoa(r.FadeHiPct) + " %/year."
	default:
		return "Apparent capacity is rising (an artefact of the method, not a gain): 95 % interval " +
			ftoa(r.FadeLoPct) + " to " + ftoa(r.FadeHiPct) + " %/year."
	}
}

func covariate(o Observation, c string) float64 {
	switch c {
	case "temp":
		return o.TempC
	case "soc":
		return o.MeanSOC
	case "power":
		return o.MeanPowerKW
	}
	return 0
}

func dayKey(t time.Time) string { return t.UTC().Format("2006-01-02") }

func allIndex(n int) []int {
	idx := make([]int, n)
	for i := range idx {
		idx[i] = i
	}
	return idx
}

// quantilePair returns the 2.5 % and 97.5 % order statistics as Packfade
// picks them (floor(n*q), clamped).
func quantilePair(sorted []float64) (float64, float64) {
	n := len(sorted)
	lo := sorted[int(math.Floor(float64(n)*0.025))]
	hiIdx := int(math.Floor(float64(n) * 0.975))
	if hiIdx > n-1 {
		hiIdx = n - 1
	}
	return lo, sorted[hiIdx]
}
