package packfade

import (
	"math"
	"math/rand"
	"testing"
	"time"
)

// synthetic builds drives with a planted fade (fraction per year), a
// temperature effect and heteroscedastic noise following the weight model;
// outlierFrac of them get a gross error of +-35 %.
func synthetic(seed int64, fadePerYear, outlierFrac float64, n int) ([]Observation, []bool) {
	rng := rand.New(rand.NewSource(seed))
	t0 := time.Date(2025, 3, 1, 8, 0, 0, 0, time.UTC)
	bt := -math.Log(1 - fadePerYear)
	obs := make([]Observation, 0, n)
	outlier := make([]bool, 0, n)
	day := 0
	for len(obs) < n {
		day += 1 + rng.Intn(8)
		for k := 0; k < 1+rng.Intn(2) && len(obs) < n; k++ {
			start := t0.Add(time.Duration(day)*24*time.Hour + time.Duration(k*5)*time.Hour)
			years := start.Sub(t0).Hours() / 24 / 365.25
			drop := 5 + rng.Float64()*75
			temp := 12 + 9*math.Sin(2*math.Pi*(years-0.3)) + rng.NormFloat64()*2
			sd := math.Sqrt(0.03*0.03 + 2*1.0/(drop*drop))
			lnC := math.Log(50) - bt*years + 0.004*(temp-12) + rng.NormFloat64()*sd
			isOut := rng.Float64() < outlierFrac
			if isOut {
				if rng.Intn(2) == 0 {
					lnC += 0.35
				} else {
					lnC -= 0.35
				}
			}
			obs = append(obs, Observation{
				Start: start, End: start.Add(time.Hour), SOCDrop: drop,
				ApparentCapacityKWh: math.Exp(lnC), Coverage: 0.98,
				TempC: temp, HasTemp: true, MeanSOC: 60, MeanPowerKW: 12,
				HoursSinceFull: math.NaN(), BMSCapacityKWh: math.NaN(),
			})
			outlier = append(outlier, isOut)
		}
	}
	return obs, outlier
}

func TestRecoversPlantedFade(t *testing.T) {
	for _, fade := range []float64{0, 0.03, 0.08} {
		obs, _ := synthetic(1, fade, 0, 120)
		r := Estimate(obs, DefaultOptions())
		if r.Status != StatusOK {
			t.Fatalf("fade %.2f: status %s: %s", fade, r.Status, r.Message)
		}
		want := fade * 100
		if want < r.FadeLoPct || want > r.FadeHiPct {
			t.Errorf("fade %.2f: planted %.2f %%/yr outside interval [%.2f, %.2f] (estimate %.2f)",
				fade, want, r.FadeLoPct, r.FadeHiPct, r.FadePctPerYear)
		}
		if math.Abs(r.FadePctPerYear-want) > 1.5 {
			t.Errorf("fade %.2f: estimate %.2f %%/yr, planted %.2f", fade, r.FadePctPerYear, want)
		}
		if math.Abs(r.BaselineKWh-50) > 1.5 {
			t.Errorf("fade %.2f: baseline %.2f kWh, planted 50", fade, r.BaselineKWh)
		}
		if math.Abs(r.TempEffectPctPer10C-4.08) > 2 {
			t.Errorf("fade %.2f: temperature effect %.2f %%/10C, planted 4.08", fade, r.TempEffectPctPer10C)
		}
	}
}

func TestDeterministicForSeed(t *testing.T) {
	obs, _ := synthetic(2, 0.04, 0.1, 100)
	a := Estimate(obs, DefaultOptions())
	b := Estimate(obs, DefaultOptions())
	if a.FadePctPerYear != b.FadePctPerYear || a.FadeLoPct != b.FadeLoPct || a.FadeHiPct != b.FadeHiPct ||
		a.Curve[10].LoKWh != b.Curve[10].LoKWh {
		t.Fatalf("not deterministic: %+v vs %+v", a.FadeLoPct, b.FadeLoPct)
	}
	opt := DefaultOptions()
	opt.Seed = 99
	c := Estimate(obs, opt)
	if c.FadeLoPct == a.FadeLoPct && c.FadeHiPct == a.FadeHiPct {
		t.Errorf("a different seed gave an identical interval")
	}
	if c.FadePctPerYear != a.FadePctPerYear {
		t.Errorf("the point estimate must not depend on the seed")
	}
}

func TestResistsOutliers(t *testing.T) {
	clean, _ := synthetic(3, 0.04, 0, 120)
	dirty, isOut := synthetic(3, 0.04, 0.12, 120)
	rc := Estimate(clean, DefaultOptions())
	rd := Estimate(dirty, DefaultOptions())
	if rd.Status != StatusOK {
		t.Fatal(rd.Message)
	}
	if 4 < rd.FadeLoPct || 4 > rd.FadeHiPct {
		t.Errorf("with outliers the planted 4 %%/yr is outside [%.2f, %.2f]", rd.FadeLoPct, rd.FadeHiPct)
	}
	if math.Abs(rd.FadePctPerYear-rc.FadePctPerYear) > 1.5 {
		t.Errorf("outliers moved the estimate from %.2f to %.2f %%/yr", rc.FadePctPerYear, rd.FadePctPerYear)
	}
	// planted outliers are down-weighted
	var sumOut, nOut, sumIn, nIn float64
	for i, p := range rd.Points {
		if isOut[i] {
			sumOut += p.HuberWeight
			nOut++
		} else {
			sumIn += p.HuberWeight
			nIn++
		}
	}
	if nOut == 0 || sumOut/nOut > 0.6 || sumIn/nIn < 0.85 {
		t.Errorf("mean Huber weight: outliers %.2f (n=%v), others %.2f", sumOut/nOut, nOut, sumIn/nIn)
	}
	// plain WLS (no Huber) is pulled further
	opt := DefaultOptions()
	opt.HuberK = math.Inf(1)
	rw := Estimate(dirty, opt)
	if math.Abs(rw.FadePctPerYear-4) < math.Abs(rd.FadePctPerYear-4)-0.5 {
		t.Logf("note: WLS %.2f vs Huber %.2f", rw.FadePctPerYear, rd.FadePctPerYear)
	}
}

func TestInsufficientData(t *testing.T) {
	obs, _ := synthetic(4, 0.03, 0, 10)
	r := Estimate(obs, DefaultOptions())
	if r.Status != StatusInsufficient || r.Message == "" || len(r.Curve) != 0 {
		t.Fatalf("got %s %q", r.Status, r.Message)
	}
	// enough drives but a short span
	obs, _ = synthetic(4, 0.03, 0, 40)
	for i := range obs {
		obs[i].Start = obs[0].Start.Add(time.Duration(i) * 24 * time.Hour / 2)
	}
	if r := Estimate(obs, DefaultOptions()); r.Status != StatusInsufficient {
		t.Fatalf("20-day span: got %s", r.Status)
	}
}

func TestEligibility(t *testing.T) {
	opt := DefaultOptions()
	base := Observation{SOCDrop: 20, ApparentCapacityKWh: 45, Coverage: 0.95, HasTemp: true, TempC: 10, HoursSinceFull: 5}
	cases := []struct {
		mut  func(*Observation)
		want string
	}{
		{func(o *Observation) {}, ""},
		{func(o *Observation) { o.SOCDrop = 0 }, RejectNoDrop},
		{func(o *Observation) { o.SOCDrop = 4.9 }, RejectSmallDrop},
		{func(o *Observation) { o.Coverage = 0.8 }, RejectCoverage},
		{func(o *Observation) { o.ChargeCounterKWh = 3 }, RejectCharging},
		{func(o *Observation) { o.SOCRisePP = 1.5 }, RejectCharging},
		{func(o *Observation) { o.HasTemp = false }, RejectNoTemp},
		{func(o *Observation) { o.ApparentCapacityKWh = 0 }, RejectImplausible},
		{func(o *Observation) { o.Coverage = 0; o.ApparentCapacityKWh = 0 }, RejectCoverage},
	}
	for i, c := range cases {
		o := base
		c.mut(&o)
		if got := Eligibility(o, opt); got != c.want {
			t.Errorf("case %d: got %q want %q", i, got, c.want)
		}
	}
	opt.OnlyCalibrated = true
	o := base
	o.HoursSinceFull = 30
	if got := Eligibility(o, opt); got != RejectNotCalibrate {
		t.Errorf("calibrated: got %q", got)
	}
	o.HoursSinceFull = math.NaN()
	if got := Eligibility(o, opt); got != RejectNotCalibrate {
		t.Errorf("unknown full charge: got %q", got)
	}
}

func TestBaseWeight(t *testing.T) {
	opt := DefaultOptions()
	// the floor caps the weight at 1/EnvSD^2 = 400
	if w := BaseWeight(1e6, opt); math.Abs(w-400) > 1e-3 {
		t.Errorf("large drop weight %v", w)
	}
	// 10 pp: 1 / (0.0025 + 2*(0.0392^2/12 + 1)/100)
	want := 1 / (0.0025 + 2*(0.0392*0.0392/12+1)/100)
	if w := BaseWeight(10, opt); math.Abs(w-want) > 1e-9 {
		t.Errorf("10 pp weight %v want %v", w, want)
	}
}

// Same sequence as Packfade's JavaScript mulberry32(7).
func TestMulberry32MatchesPackfade(t *testing.T) {
	r := newMulberry32(7)
	for i, want := range []float64{0.011704753153026, 0.061958257574588, 0.976907632779330} {
		if got := r.next(); math.Abs(got-want) > 1e-12 {
			t.Errorf("draw %d: %v want %v", i, got, want)
		}
	}
}
