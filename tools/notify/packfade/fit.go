// Portions of this file are ported from Packfade's browser engine
// (web/index.html: choleskyDecompose, choleskySolve,
// solveWeightedLinearSystem, mulberry32 and the Huber-IRLS / date-clustered
// bootstrap loop of fitModelClient), https://github.com/pgodlews/packfade.
// Changes: Huber residuals are standardised by the base weight, IRLS runs to
// convergence, the bootstrap re-runs the same IRLS, and the dependent
// variable is ln(apparent capacity) instead of ln(%SOC per km).
//
// Packfade is distributed under the MIT License:
//
// Copyright (c) 2026 Piotr Godlewski
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

package packfade

import (
	"math"
	"sort"
	"strconv"
)

const (
	ridge        = 1e-6 // Packfade's diagonal regularisation (standardised columns)
	irlsMaxIter  = 50
	irlsTol      = 1e-10
	madFloor     = 1e-4
	madToSigma   = 1.4826
	minBootstrap = 10
)

// fitter holds a standardised design: column 0 of X is the intercept,
// column 1 time, then the covariates (Packfade standardises every
// non-intercept column by its mean and population standard deviation).
type fitter struct {
	X         [][]float64
	y         []float64
	wBase     []float64 // normalised to mean 1
	groups    []string
	means     []float64
	stds      []float64
	k         float64
	lastScale float64
}

func newFitter(cols [][]float64, y, wBase []float64, groups []string, k float64) *fitter {
	n := len(y)
	f := &fitter{y: y, groups: groups, k: k}
	f.means = make([]float64, len(cols))
	f.stds = make([]float64, len(cols))
	for j, c := range cols {
		m := 0.0
		for _, v := range c {
			m += v
		}
		m /= float64(n)
		v := 0.0
		for _, x := range c {
			v += (x - m) * (x - m)
		}
		sd := math.Sqrt(v / float64(n))
		if sd == 0 {
			sd = 1
		}
		f.means[j], f.stds[j] = m, sd
	}
	f.X = make([][]float64, n)
	for i := 0; i < n; i++ {
		row := make([]float64, len(cols)+1)
		row[0] = 1
		for j := range cols {
			row[j+1] = (cols[j][i] - f.means[j]) / f.stds[j]
		}
		f.X[i] = row
	}
	sum := 0.0
	for _, w := range wBase {
		sum += w
	}
	mean := sum / float64(n)
	f.wBase = make([]float64, n)
	for i, w := range wBase {
		f.wBase[i] = w / mean
	}
	return f
}

// fit runs Huber IRLS on the rows in idx (rows may repeat, as in a
// bootstrap sample). It returns the coefficients and the Huber weight of
// each row of idx.
func (f *fitter) fit(idx []int) ([]float64, []float64, bool) {
	n := len(idx)
	w := make([]float64, n)
	for r, i := range idx {
		w[r] = f.wBase[i]
	}
	coef := f.solve(idx, w)
	if coef == nil {
		return nil, nil, false
	}
	hub := make([]float64, n)
	for r := range hub {
		hub[r] = 1
	}
	std := make([]float64, n)
	for iter := 0; iter < irlsMaxIter; iter++ {
		for r, i := range idx {
			std[r] = (f.y[i] - dot(f.X[i], coef)) * math.Sqrt(f.wBase[i])
		}
		med := median(std)
		dev := make([]float64, n)
		for r, v := range std {
			dev[r] = math.Abs(v - med)
		}
		s := madToSigma * math.Max(median(dev), madFloor)
		f.lastScale = s
		for r, i := range idx {
			u := math.Abs(std[r]) / s
			h := 1.0
			if u > f.k {
				h = f.k / math.Max(madFloor, u)
			}
			hub[r] = h
			w[r] = f.wBase[i] * h
		}
		next := f.solve(idx, w)
		if next == nil {
			break
		}
		delta := 0.0
		for j := range coef {
			delta = math.Max(delta, math.Abs(next[j]-coef[j]))
		}
		coef = next
		if delta < irlsTol {
			break
		}
	}
	return coef, hub, true
}

// solve is Packfade's solveWeightedLinearSystem: normal equations with a
// small ridge, solved by Cholesky.
func (f *fitter) solve(idx []int, w []float64) []float64 {
	p := len(f.X[0])
	A := make([][]float64, p)
	for j := range A {
		A[j] = make([]float64, p)
	}
	b := make([]float64, p)
	for r, i := range idx {
		xi := f.X[i]
		for j := 0; j < p; j++ {
			wx := w[r] * xi[j]
			b[j] += wx * f.y[i]
			for k := j; k < p; k++ {
				A[j][k] += wx * xi[k]
			}
		}
	}
	for j := 0; j < p; j++ {
		for k := 0; k < j; k++ {
			A[j][k] = A[k][j]
		}
		A[j][j] += ridge
	}
	L := cholesky(A)
	if L == nil {
		return nil
	}
	return choleskySolve(L, b)
}

func (f *fitter) slope(coef []float64) float64 { return coef[1] / f.stds[0] }

func (f *fitter) covCoef(coef []float64, j int) float64 { return coef[j+2] / f.stds[j+1] }

// predictRef is ln C at time t (years from the first observation) with the
// covariates at their means.
func (f *fitter) predictRef(coef []float64, t float64) float64 {
	return coef[0] + coef[1]*(t-f.means[0])/f.stds[0]
}

// covEffect is the covariate part of row k's prediction.
func (f *fitter) covEffect(coef []float64, k int) float64 {
	e := 0.0
	for j := 2; j < len(coef); j++ {
		e += coef[j] * f.X[k][j]
	}
	return e
}

// bootstrap resamples whole days with replacement (seeded) and refits.
func (f *fitter) bootstrap(B int, seed uint32) [][]float64 {
	if B < 20 || len(f.y) < 10 {
		return nil
	}
	byDay := map[string][]int{}
	for i, g := range f.groups {
		byDay[g] = append(byDay[g], i)
	}
	keys := make([]string, 0, len(byDay))
	for k := range byDay {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	rng := newMulberry32(seed)
	var out [][]float64
	for b := 0; b < B; b++ {
		var idx []int
		for g := 0; g < len(keys); g++ {
			idx = append(idx, byDay[keys[int(rng.next()*float64(len(keys)))]]...)
		}
		if c, _, ok := f.fit(idx); ok {
			out = append(out, c)
		}
	}
	if len(out) < minBootstrap {
		return nil
	}
	return out
}

func cholesky(A [][]float64) [][]float64 {
	n := len(A)
	L := make([][]float64, n)
	for i := range L {
		L[i] = make([]float64, n)
	}
	for i := 0; i < n; i++ {
		for j := 0; j <= i; j++ {
			sum := 0.0
			for k := 0; k < j; k++ {
				sum += L[i][k] * L[j][k]
			}
			if i == j {
				v := A[i][i] - sum
				if v <= 1e-12 {
					return nil
				}
				L[i][j] = math.Sqrt(v)
			} else {
				L[i][j] = (A[i][j] - sum) / L[j][j]
			}
		}
	}
	return L
}

func choleskySolve(L [][]float64, b []float64) []float64 {
	n := len(b)
	y := make([]float64, n)
	for i := 0; i < n; i++ {
		sum := 0.0
		for k := 0; k < i; k++ {
			sum += L[i][k] * y[k]
		}
		y[i] = (b[i] - sum) / L[i][i]
	}
	x := make([]float64, n)
	for i := n - 1; i >= 0; i-- {
		sum := 0.0
		for k := i + 1; k < n; k++ {
			sum += L[k][i] * x[k]
		}
		x[i] = (y[i] - sum) / L[i][i]
	}
	return x
}

// mulberry32 is Packfade's seeded PRNG, so a seed gives the same resamples
// in both implementations.
type mulberry32 struct{ a uint32 }

func newMulberry32(seed uint32) *mulberry32 { return &mulberry32{a: seed} }

func (m *mulberry32) next() float64 {
	m.a += 0x6D2B79F5
	t := m.a
	t = (t ^ (t >> 15)) * (t | 1)
	t ^= t + (t^(t>>7))*(t|61)
	return float64(t^(t>>14)) / 4294967296.0
}

func dot(a, b []float64) float64 {
	s := 0.0
	for i := range a {
		s += a[i] * b[i]
	}
	return s
}

func median(v []float64) float64 {
	if len(v) == 0 {
		return 0
	}
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

func itoa(n int) string { return strconv.Itoa(n) }

func ftoa(v float64) string { return strconv.FormatFloat(v, 'f', 1, 64) }

func sortFloats(v []float64) { sort.Float64s(v) }
