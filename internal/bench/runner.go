package bench

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// The measurement loop (plan §4): single connection, sequential,
// closed-loop warm-cache service times — not latency under load.
// Per case: a duration-based warmup on the same loop as the
// measured phase (ops recorded), then timed ops for the
// configured duration, extended until at least MinOps samples
// exist. Wall-clock wraps each call, round-trip included.

type RunConfig struct {
	Seed     uint64
	Warmup   time.Duration
	Duration time.Duration
	MinOps   int
	// Features limits the run; nil or empty means every
	// implemented feature.
	Features map[string]bool
}

// caseCall is one case's per-op closure; i indexes the variant's
// deterministic query stream, shared across warmup and measure.
type caseCall func(ctx context.Context, i int) error

// Run measures every selected case against one loaded fixture
// and returns the invocation's result. Mutating cases run last
// (plan §4): write churns dead tuples and model writes
// accumulate immutable rows, so nothing may read after them.
func Run(
	ctx context.Context, pool *pgxpool.Pool,
	s Scenario, size Size, load LoadResult, cfg RunConfig,
	progress func(format string, args ...any),
) (*Result, error) {
	if progress == nil {
		progress = func(string, ...any) {}
	}
	res := &Result{
		SchemaVersion:    ResultSchemaVersion,
		StartedAt:        time.Now().UTC().Format(time.RFC3339),
		Scenario:         s.Name(),
		Size:             size.Name,
		Seed:             cfg.Seed,
		GeneratorVersion: GeneratorVersion,
		Load: LoadInfo{Rows: load.Rows,
			Seconds: load.Seconds, Skipped: load.Skipped},
	}
	env, err := CaptureEnv(ctx, pool)
	if err != nil {
		return nil, err
	}
	env.NDeadTupStart = DeadTuples(ctx, pool)

	// Cache-state policy: prime with a seq scan over the
	// scenario store before any case, then each case's own
	// warmup runs. Numbers are warm-cache by declaration.
	if _, err := pool.Exec(ctx,
		"SELECT count(*) FROM fga.tuple WHERE store = $1",
		load.Store); err != nil {
		return nil, err
	}

	for _, v := range orderedVariants(cfg.Features) {
		call, cleanup, err := newCase(
			ctx, pool, s, size, load, cfg.Seed, v)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", v.Key(), err)
		}
		progress("  case %s", v.Key())
		cr, err := measureCase(ctx, cfg, v, call)
		if cleanup != nil {
			cleanup()
		}
		if err != nil {
			return nil, fmt.Errorf("%s: %w", v.Key(), err)
		}
		res.Cases = append(res.Cases, cr)
		progress("    %d ops, p50 %dµs, p95 %dµs",
			cr.Ops, cr.Latency.P50, cr.Latency.P95)
	}

	env.NDeadTupEnd = DeadTuples(ctx, pool)
	res.Env = env
	res.FinishedAt = time.Now().UTC().Format(time.RFC3339)
	return res, nil
}

// orderedVariants selects and orders the cases: everything
// read-only in Variants order, then write, then
// write_authorization_model — the two mutating cases always
// last.
func orderedVariants(features map[string]bool) []Variant {
	selected := func(v Variant) bool {
		if !implemented[v.Feature] {
			return false
		}
		if len(features) == 0 {
			return true
		}
		return features[v.Feature]
	}
	var reads, mutating []Variant
	for _, v := range Variants {
		if !selected(v) {
			continue
		}
		if v.Feature == "write" ||
			v.Feature == "write_authorization_model" {
			mutating = append(mutating, v)
			continue
		}
		reads = append(reads, v)
	}
	return append(reads, mutating...)
}

func measureCase(
	ctx context.Context, cfg RunConfig, v Variant,
	call caseCall,
) (CaseResult, error) {
	cr := CaseResult{Feature: v.Feature, Variant: v.Name}
	i := 0
	wEnd := time.Now().Add(cfg.Warmup)
	for time.Now().Before(wEnd) {
		if err := call(ctx, i); err != nil {
			return cr, err
		}
		i++
		if err := ctx.Err(); err != nil {
			return cr, err
		}
	}
	cr.WarmupOps = uint64(i)

	h := NewHist()
	start := time.Now()
	for {
		t0 := time.Now()
		if err := call(ctx, i); err != nil {
			return cr, err
		}
		h.Record(time.Since(t0))
		i++
		if err := ctx.Err(); err != nil {
			return cr, err
		}
		if time.Since(start) >= cfg.Duration &&
			h.N() >= uint64(max(cfg.MinOps, 1)) {
			break
		}
	}
	cr.Ops = h.N()
	cr.Seconds = time.Since(start).Seconds()
	cr.Latency = summarize(h)
	return cr, nil
}
