package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/emfga/fga4postgres/internal/bench"
)

// smallN marks percentiles computed from fewer samples than this
// with a ~ prefix and a footnote (plan §5).
const smallN = 100

func load(path string) (*bench.Result, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r bench.Result
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if r.SchemaVersion != bench.ResultSchemaVersion {
		return nil, fmt.Errorf(
			"%s: result schema %d, this benchreport reads %d",
			path, r.SchemaVersion, bench.ResultSchemaVersion)
	}
	if len(r.Cases) == 0 {
		return nil, fmt.Errorf("%s: no cases", path)
	}
	return &r, nil
}

// loadBaseline reads a baseline file: either one result object
// or an array of them (one per scenario — a bench invocation
// writes one file per scenario, and a committed baseline bundles
// them).
func loadBaseline(path string) ([]*bench.Result, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var many []*bench.Result
	if err := json.Unmarshal(b, &many); err == nil {
		for _, r := range many {
			if r.SchemaVersion != bench.ResultSchemaVersion {
				return nil, fmt.Errorf(
					"%s: result schema %d, this benchreport "+
						"reads %d", path, r.SchemaVersion,
					bench.ResultSchemaVersion)
			}
		}
		return many, nil
	}
	one, err := load(path)
	if err != nil {
		return nil, err
	}
	return []*bench.Result{one}, nil
}

func render(paths []string, baselinePath string) (
	string, error,
) {
	var bases []*bench.Result
	if baselinePath != "" {
		var err error
		bases, err = loadBaseline(baselinePath)
		if err != nil {
			return "", err
		}
	}
	var b strings.Builder
	b.WriteString("# Benchmark report\n")
	for _, p := range paths {
		r, err := load(p)
		if err != nil {
			return "", err
		}
		var base *bench.Result
		if bases != nil {
			for _, cand := range bases {
				if cand.Scenario == r.Scenario {
					base = cand
					break
				}
			}
			if base == nil {
				return "", fmt.Errorf(
					"baseline has no entry for scenario %q",
					r.Scenario)
			}
			if base.Size != r.Size ||
				base.Seed != r.Seed ||
				base.GeneratorVersion !=
					r.GeneratorVersion {
				return "", fmt.Errorf(
					"baseline measured %s/%s seed %d gen %d; "+
						"candidate is %s/%s seed %d gen %d — "+
						"not comparable",
					base.Scenario, base.Size, base.Seed,
					base.GeneratorVersion, r.Scenario,
					r.Size, r.Seed, r.GeneratorVersion)
			}
		}
		section(&b, r, base)
	}
	return b.String(), nil
}

func section(
	b *strings.Builder, r *bench.Result, base *bench.Result,
) {
	fmt.Fprintf(b, "\n## %s @ %s (seed %d)\n\n",
		r.Scenario, r.Size, r.Seed)
	envBlock(b, r)
	if ws := envWarnings(r, base); len(ws) > 0 {
		b.WriteString("\n")
		for _, w := range ws {
			fmt.Fprintf(b, "> ⚠ %s\n", w)
		}
	}
	if base != nil {
		b.WriteString("\nDeltas are against the committed " +
			"baseline; informational only.\n")
	}

	small := false
	if base == nil {
		b.WriteString("\n| case | ops/s | p50 | p95 | p99 " +
			"| mean |\n|---|--:|--:|--:|--:|--:|\n")
	} else {
		b.WriteString("\n| case | ops/s | Δ ops/s | p50 " +
			"| p95 | Δ p95 | p99 |\n" +
			"|---|--:|--:|--:|--:|--:|--:|\n")
	}
	for _, c := range r.Cases {
		name := c.Feature + " " + c.Variant
		tilde := ""
		if c.Ops < smallN {
			tilde, small = "~", true
		}
		if base == nil {
			fmt.Fprintf(b,
				"| %s | %s | %s | %s%s | %s%s | %s |\n",
				name, opsPerSec(c),
				dur(c.Latency.P50), tilde,
				dur(c.Latency.P95), tilde,
				dur(c.Latency.P99), dur(c.Latency.Mean))
			continue
		}
		bc := findCase(base, c.Feature, c.Variant)
		dOps, dP95 := "n/a", "n/a"
		if bc != nil {
			dOps = delta(rate(c), rate(*bc))
			dP95 = delta(float64(c.Latency.P95),
				float64(bc.Latency.P95))
		}
		fmt.Fprintf(b,
			"| %s | %s | %s | %s | %s%s | %s | %s |\n",
			name, opsPerSec(c), dOps,
			dur(c.Latency.P50), tilde,
			dur(c.Latency.P95), dP95, dur(c.Latency.P99))
	}
	if small {
		b.WriteString("\n~ percentile computed from fewer " +
			"than 100 samples\n")
	}
}

func envBlock(b *strings.Builder, r *bench.Result) {
	e := r.Env
	dirty := ""
	if e.GitDirty {
		dirty = " (dirty)"
	}
	loaded := fmt.Sprintf("loaded %d rows in %.1fs",
		r.Load.Rows, r.Load.Seconds)
	if r.Load.Skipped {
		loaded = fmt.Sprintf(
			"reused a prior load of %d rows", r.Load.Rows)
	}
	fmt.Fprintf(b,
		"- engine %s, PostgreSQL %s, %s\n"+
			"- %s/%s, %d× %s, governor %s\n"+
			"- storage %s; %s\n"+
			"- commit %.12s%s\n"+
			"- closed-loop warm-cache service times, single "+
			"connection — not latency under load\n",
		e.EngineVersion, e.PGVersion, e.GoVersion,
		e.OS, e.Arch, e.CPUCount, e.CPUModel, e.Governor,
		e.Storage, loaded, e.GitCommit, dirty)
}

// envWarnings lists comparability hazards between candidate and
// baseline: load.skipped, storage and every captured env and
// pg_settings value except the git fields (a differing commit is
// the point of comparing) and the dead-tuple counters.
func envWarnings(r, base *bench.Result) []string {
	if base == nil {
		return nil
	}
	var w []string
	warn := func(field, bv, cv string) {
		if bv != cv {
			w = append(w, fmt.Sprintf(
				"baseline %s %q, candidate %q",
				field, bv, cv))
		}
	}
	warn("load.skipped",
		fmt.Sprint(base.Load.Skipped),
		fmt.Sprint(r.Load.Skipped))
	be, ce := base.Env, r.Env
	warn("storage", be.Storage, ce.Storage)
	warn("engine_version", be.EngineVersion, ce.EngineVersion)
	warn("pg_version", be.PGVersion, ce.PGVersion)
	warn("os", be.OS, ce.OS)
	warn("arch", be.Arch, ce.Arch)
	warn("cpu_model", be.CPUModel, ce.CPUModel)
	warn("cpu_count",
		fmt.Sprint(be.CPUCount), fmt.Sprint(ce.CPUCount))
	warn("governor", be.Governor, ce.Governor)
	warn("go_version", be.GoVersion, ce.GoVersion)
	keys := map[string]bool{}
	for k := range be.PGSettings {
		keys[k] = true
	}
	for k := range ce.PGSettings {
		keys[k] = true
	}
	sorted := make([]string, 0, len(keys))
	for k := range keys {
		sorted = append(sorted, k)
	}
	sort.Strings(sorted)
	for _, k := range sorted {
		warn("pg_settings."+k,
			be.PGSettings[k], ce.PGSettings[k])
	}
	return w
}

func findCase(
	r *bench.Result, feature, variant string,
) *bench.CaseResult {
	for i := range r.Cases {
		c := &r.Cases[i]
		if c.Feature == feature && c.Variant == variant {
			return c
		}
	}
	return nil
}

func rate(c bench.CaseResult) float64 {
	if c.Seconds == 0 {
		return 0
	}
	return float64(c.Ops) / c.Seconds
}

func opsPerSec(c bench.CaseResult) string {
	return fmt.Sprintf("%.0f", rate(c))
}

func delta(cand, base float64) string {
	if base == 0 {
		return "n/a"
	}
	return fmt.Sprintf("%+.1f%%", (cand-base)/base*100)
}

// dur renders a microsecond figure with a readable unit.
func dur(us int64) string {
	switch {
	case us >= 10_000_000:
		return fmt.Sprintf("%.1fs", float64(us)/1e6)
	case us >= 10_000:
		return fmt.Sprintf("%.1fms", float64(us)/1e3)
	default:
		return fmt.Sprintf("%dµs", us)
	}
}
