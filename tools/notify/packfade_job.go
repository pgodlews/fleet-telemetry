package main

// EXPERIMENTAL capacity-fade estimate (Packfade method, see the packfade
// package): reads packfade_segments, fits, and writes packfade_estimate,
// packfade_points and packfade_curve (deploy/sql/057). It runs once a day
// inside the daemon and on demand with --packfade-once. It sends nothing to
// Telegram and is not part of the predictive health score.

import (
	"context"
	"fmt"
	"log"
	"math"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/teslamotors/fleet-telemetry/tools/notify/packfade"
)

const (
	packfadeCheckInterval = time.Hour
	packfadeMaxAge        = 23 * time.Hour // recompute when the newest estimate is older than this
	packfadeTimeout       = 5 * time.Minute
	packfadeMethod        = "packfade-v1: ln C = b0 - bt*t + temp; Huber-WLS (k=1.345, MAD); date-clustered bootstrap"
)

// packfadeWatcher recomputes the estimate when the stored one is older than
// packfadeMaxAge, checking every packfadeCheckInterval (so a restart does
// not trigger a recomputation, and a missed day is caught up within an hour).
func packfadeWatcher(ctx context.Context, pool *pgxpool.Pool, cfg *Config) {
	log.Println("packfade watcher started (experimental capacity fade, daily)")
	ticker := time.NewTicker(packfadeCheckInterval)
	defer ticker.Stop()
	for {
		if due, err := packfadeDue(ctx, pool, cfg.VIN); err != nil {
			log.Printf("packfade: %v", err)
		} else if due {
			jctx, cancel := context.WithTimeout(ctx, packfadeTimeout)
			summary, err := runPackfade(jctx, pool, cfg.VIN, false)
			cancel()
			if err != nil {
				log.Printf("packfade: %v", err)
			} else {
				log.Printf("packfade: %s", summary)
			}
		}
		select {
		case <-ctx.Done():
			log.Println("packfade watcher stopped")
			return
		case <-ticker.C:
		}
	}
}

func packfadeDue(ctx context.Context, pool *pgxpool.Pool, vin string) (bool, error) {
	qctx, cancel := context.WithTimeout(ctx, dbQueryTimeout)
	defer cancel()
	var last *time.Time
	if err := pool.QueryRow(qctx,
		`SELECT max(computed_at) FROM packfade_estimate WHERE vin = $1`, vin).Scan(&last); err != nil {
		return false, fmt.Errorf("last estimate: %w", err)
	}
	return last == nil || time.Since(*last) > packfadeMaxAge, nil
}

// fetchPackfadeSegments reads the observations for one vehicle.
func fetchPackfadeSegments(ctx context.Context, pool *pgxpool.Pool, vin string) ([]packfade.Observation, error) {
	rows, err := pool.Query(ctx, `
		SELECT seg_start, seg_end, soc_drop::float8, apparent_capacity_kwh::float8, coverage::float8,
		       outside_temp_c::float8, mean_soc::float8, mean_power_kw::float8,
		       hours_since_full_charge::float8, soc_rise_pp::float8, charge_counter_kwh::float8,
		       bms_energy_drop_kwh::float8
		FROM packfade_segments WHERE vin = $1 ORDER BY seg_start`, vin)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []packfade.Observation
	for rows.Next() {
		var o packfade.Observation
		var drop, capKWh, cov, temp, msoc, mpow, hfull, rise, chg, bms *float64
		if err := rows.Scan(&o.Start, &o.End, &drop, &capKWh, &cov, &temp, &msoc, &mpow, &hfull, &rise, &chg, &bms); err != nil {
			return nil, err
		}
		o.SOCDrop = orNaN(drop)
		o.ApparentCapacityKWh = orNaN(capKWh)
		o.Coverage = orZero(cov)
		o.HasTemp = temp != nil
		o.TempC = orNaN(temp)
		o.MeanSOC = orNaN(msoc)
		o.MeanPowerKW = orNaN(mpow)
		o.HoursSinceFull = orNaN(hfull)
		o.SOCRisePP = orZero(rise)
		o.ChargeCounterKWh = orZero(chg)
		o.BMSCapacityKWh = math.NaN()
		if bms != nil && o.SOCDrop > 0 {
			o.BMSCapacityKWh = *bms / (o.SOCDrop / 100)
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

// runPackfade computes both variants and, unless dryRun, stores them. The
// returned summary is one line per variant.
func runPackfade(ctx context.Context, pool *pgxpool.Pool, vin string, dryRun bool) (string, error) {
	obs, err := fetchPackfadeSegments(ctx, pool, vin)
	if err != nil {
		return "", fmt.Errorf("read packfade_segments: %w", err)
	}
	opt := packfade.DefaultOptions()
	all := packfade.Estimate(obs, opt)
	calOpt := opt
	calOpt.OnlyCalibrated = true
	cal := packfade.Estimate(obs, calOpt)
	summary := packfadeSummary("all", all) + "\n" + packfadeSummary("calibrated_start", cal)
	if dryRun {
		return summary, nil
	}
	if err := storePackfade(ctx, pool, vin, time.Now().UTC(), opt, all, cal); err != nil {
		return "", fmt.Errorf("store: %w", err)
	}
	return summary, nil
}

func packfadeSummary(variant string, r packfade.Result) string {
	if r.Status != packfade.StatusOK {
		return fmt.Sprintf("%s: %s (%d segments, %d used)", variant, r.Status, r.NSegments, r.NUsed)
	}
	return fmt.Sprintf("%s: index %.1f %% [%.1f, %.1f], fade %.1f %%/yr [%.1f, %.1f], now %.2f kWh, %d used / %d rejected on %d days — %s",
		variant, r.IndexPct, r.IndexLoPct, r.IndexHiPct, r.FadePctPerYear, r.FadeLoPct, r.FadeHiPct,
		r.NowKWh, r.NUsed, r.NRejectd, r.NDays, r.Message)
}

func storePackfade(ctx context.Context, pool *pgxpool.Pool, vin string, at time.Time, opt packfade.Options, all, cal packfade.Result) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	// Serialise writers (the daemon's daily run and a --packfade-once run) so
	// one's DELETE always sees the other's committed rows.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('packfade:' || $1))`, vin); err != nil {
		return fmt.Errorf("lock: %w", err)
	}

	method := packfadeMethod + "; covariates " + strings.Join(opt.Covariates, ",")
	for _, v := range []struct {
		name string
		r    packfade.Result
	}{{"all", all}, {"calibrated_start", cal}} {
		r := v.r
		_, err := tx.Exec(ctx, `
			INSERT INTO packfade_estimate (vin, computed_at, variant, status, message, n_segments, n_used, n_rejected,
			  n_days, first_obs, last_obs, span_days, baseline_capacity_kwh, capacity_now_kwh, index_pct,
			  index_lo_pct, index_hi_pct, fade_pct_per_year, fade_lo_pct_per_year, fade_hi_pct_per_year,
			  temp_effect_pct_per_10c, residual_scale, n_boot, seed, method)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25)`,
			vin, at, v.name, r.Status, r.Message, r.NSegments, r.NUsed, r.NRejectd, r.NDays,
			nullTime(r.FirstObs), nullTime(r.LastObs), num(r.SpanDays),
			okNum(r, r.BaselineKWh), okNum(r, r.NowKWh), okNum(r, r.IndexPct),
			okNum(r, r.IndexLoPct), okNum(r, r.IndexHiPct), okNum(r, r.FadePctPerYear),
			okNum(r, r.FadeLoPct), okNum(r, r.FadeHiPct), okNum(r, r.TempEffectPctPer10C),
			okNum(r, r.ResidualScale), r.NBoot, int64(opt.Seed), method)
		if err != nil {
			return fmt.Errorf("insert estimate %s: %w", v.name, err)
		}
	}

	// points and curve: latest computation only, variant "all"
	if _, err := tx.Exec(ctx, `DELETE FROM packfade_points WHERE vin = $1`, vin); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM packfade_curve WHERE vin = $1`, vin); err != nil {
		return err
	}
	pts := make([][]any, 0, len(all.Points))
	seen := map[time.Time]bool{}
	for _, p := range all.Points {
		if seen[p.Obs.Start] {
			continue
		}
		seen[p.Obs.Start] = true
		var reason any
		if p.Reason != "" {
			reason = p.Reason
		}
		temp := any(nil)
		if p.Obs.HasTemp {
			temp = p.Obs.TempC
		}
		pts = append(pts, []any{vin, p.Obs.Start, p.Obs.End, at, num(p.Obs.SOCDrop), num(p.Obs.ApparentCapacityKWh),
			num(p.NormalisedKWh), num(p.Obs.BMSCapacityKWh), temp, num(p.Obs.MeanSOC), num(p.Obs.MeanPowerKW),
			num(p.Obs.HoursSinceFull), num(p.BaseWeight), num(p.HuberWeight), p.Used, reason})
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"packfade_points"},
		[]string{"vin", "seg_start", "seg_end", "computed_at", "soc_drop", "apparent_capacity_kwh",
			"normalised_capacity_kwh", "bms_capacity_kwh", "outside_temp_c", "mean_soc", "mean_power_kw",
			"hours_since_full_charge", "base_weight", "huber_weight", "used", "reject_reason"},
		pgx.CopyFromRows(pts)); err != nil {
		return fmt.Errorf("copy points: %w", err)
	}
	curve := make([][]any, 0, len(all.Curve))
	for _, c := range all.Curve {
		curve = append(curve, []any{vin, c.T, at, c.FittedKWh, num(c.LoKWh), num(c.HiKWh)})
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"packfade_curve"},
		[]string{"vin", "ts", "computed_at", "fitted_kwh", "lo_kwh", "hi_kwh"},
		pgx.CopyFromRows(curve)); err != nil {
		return fmt.Errorf("copy curve: %w", err)
	}
	return tx.Commit(ctx)
}

// num maps NaN and Inf to NULL.
func num(v float64) any {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return nil
	}
	return v
}

// okNum is NULL unless the fit succeeded.
func okNum(r packfade.Result, v float64) any {
	if r.Status != packfade.StatusOK {
		return nil
	}
	return num(v)
}

func nullTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t
}

func orNaN(p *float64) float64 {
	if p == nil {
		return math.NaN()
	}
	return *p
}

func orZero(p *float64) float64 {
	if p == nil {
		return 0
	}
	return *p
}
