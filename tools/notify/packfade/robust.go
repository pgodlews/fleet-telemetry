package packfade

// RobustFit exposes the Packfade fitting engine (Huber-WLS with a seeded
// date-clustered bootstrap) for other experimental estimates, such as the
// route-efficiency monitor, so they share one implementation.

// RobustResult holds coefficients in the original units of the columns.
type RobustResult struct {
	Intercept    float64
	Coef         []float64 // one per column
	Means        []float64 // column means (reference conditions)
	Scale        float64   // MAD scale of the final weight-standardised residuals
	HuberWeights []float64
	// Boot holds one [intercept, coef...] vector per successful bootstrap
	// resample; nil when fewer than 10 succeeded or there are too few rows.
	Boot [][]float64
}

// RobustFit fits y = a + sum_j b_j*cols[j] by Huber IRLS (tuning constant
// k) with base weights w (nil = equal weights), then refits nboot
// resamples of whole groups (days) drawn with Packfade's mulberry32(seed).
func RobustFit(cols [][]float64, y, w []float64, groups []string, k float64, nboot int, seed uint32) (RobustResult, bool) {
	n := len(y)
	if n == 0 || len(cols) == 0 {
		return RobustResult{}, false
	}
	if w == nil {
		w = make([]float64, n)
		for i := range w {
			w[i] = 1
		}
	}
	f := newFitter(cols, y, w, groups, k)
	c, hub, ok := f.fit(allIndex(n))
	if !ok {
		return RobustResult{}, false
	}
	res := RobustResult{Means: append([]float64(nil), f.means...), Scale: f.lastScale, HuberWeights: hub}
	res.Intercept, res.Coef = f.unstandardise(c)
	for _, bc := range f.bootstrap(nboot, seed) {
		a, b := f.unstandardise(bc)
		res.Boot = append(res.Boot, append([]float64{a}, b...))
	}
	return res, true
}

// unstandardise converts standardised coefficients to original units.
func (f *fitter) unstandardise(c []float64) (float64, []float64) {
	b := make([]float64, len(f.stds))
	a := c[0]
	for j := range b {
		b[j] = c[j+1] / f.stds[j]
		a -= b[j] * f.means[j]
	}
	return a, b
}

// Quantiles95 returns the 2.5 % and 97.5 % order statistics (Packfade's
// choice of index) of v, which it sorts in place.
func Quantiles95(v []float64) (float64, float64) {
	sortFloats(v)
	return quantilePair(v)
}
