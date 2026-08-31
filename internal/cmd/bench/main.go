// bench runs the benchmark suite against the database that
// DATABASE_URL (or the POSTGRES_* parts, or the compose
// defaults) resolves to, and writes one JSON result file per
// scenario. See docs/BENCHMARKS.md for methodology.
//
//	go run ./internal/cmd/bench -size 100k
//	go run ./internal/cmd/bench -size 1m \
//	  -scenario hierarchy -feature check,list_objects
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/emfga/fga4postgres/internal/bench"
	"github.com/emfga/fga4postgres/internal/testdb"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "bench:", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		scenarios = flag.String("scenario", "",
			"comma-separated scenarios (default: all)")
		sizeName = flag.String("size", "",
			"dataset size (required; see -list-sizes)")
		features = flag.String("feature", "",
			"comma-separated features (default: all)")
		results = flag.String("results", "",
			"results directory (default: $FGA_BENCH_RESULTS "+
				"or <repo>/bench-results)")
		seed = flag.Uint64("seed", 1,
			"generator and query-stream seed")
		warmup = flag.Duration("warmup", 5*time.Second,
			"per-case warmup duration")
		duration = flag.Duration("duration", 30*time.Second,
			"per-case measured duration")
		minOps = flag.Int("min-ops", 100,
			"extend past -duration until this many samples")
		loadOnly = flag.Bool("load-only", false,
			"load fixtures and exit without measuring")
		skipLoad = flag.Bool("skip-load", false,
			"measure existing fixtures; fail if absent")
		listSizes = flag.Bool("list-sizes", false,
			"print the supported sizes and exit")
	)
	flag.Parse()

	if *listSizes {
		for _, s := range bench.Sizes {
			fmt.Println(s.Name)
		}
		return nil
	}
	if *sizeName == "" {
		return fmt.Errorf("-size is required (one of: %s)",
			sizeNames())
	}
	size, err := bench.ParseSize(*sizeName)
	if err != nil {
		return err
	}
	if *loadOnly && *skipLoad {
		return fmt.Errorf(
			"-load-only and -skip-load exclude each other")
	}

	selected, err := selectScenarios(*scenarios)
	if err != nil {
		return err
	}
	feats, err := selectFeatures(*features)
	if err != nil {
		return err
	}

	root, err := bench.RepoRoot()
	if err != nil {
		return err
	}
	dir := *results
	if dir == "" {
		dir = os.Getenv("FGA_BENCH_RESULTS")
	}
	if dir == "" {
		dir = filepath.Join(root, "bench-results")
	}
	if !*loadOnly {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, testdb.DSN())
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		return fmt.Errorf(
			"cannot reach the database (%s): %w\nis a stack "+
				"up? docker compose -f compose.bench.yaml "+
				"up -d --wait", testdb.DSN(), err)
	}

	progress := func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, format+"\n", args...)
	}

	// Reinstall unconditionally: a persistent bench volume must
	// never measure a stale engine.
	progress("reinstalling the engine")
	if err := bench.Install(ctx, pool, root); err != nil {
		return err
	}

	for _, s := range selected {
		var load bench.LoadResult
		if *skipLoad {
			load, err = bench.LookupManifest(
				ctx, pool, s, size, *seed)
		} else {
			load, err = bench.Load(
				ctx, pool, root, s, size, *seed, progress)
		}
		if err != nil {
			return err
		}
		if *loadOnly {
			continue
		}

		progress("measuring %s/%s", s.Name(), size.Name)
		res, err := bench.Run(ctx, pool, s, size, load,
			bench.RunConfig{
				Seed:     *seed,
				Warmup:   *warmup,
				Duration: *duration,
				MinOps:   *minOps,
				Features: feats,
			}, progress)
		if err != nil {
			return err
		}
		path := filepath.Join(dir, fmt.Sprintf(
			"%s-%s-%s.json",
			time.Now().UTC().Format("20060102T150405Z"),
			s.Name(), size.Name))
		if err := writeResult(path, res); err != nil {
			return err
		}
		progress("wrote %s", path)
	}
	return nil
}

func sizeNames() string {
	names := make([]string, len(bench.Sizes))
	for i, s := range bench.Sizes {
		names[i] = s.Name
	}
	return strings.Join(names, ", ")
}

func selectScenarios(csv string) ([]bench.Scenario, error) {
	if csv == "" {
		return bench.Scenarios, nil
	}
	var out []bench.Scenario
	for _, name := range strings.Split(csv, ",") {
		s, err := bench.ScenarioByName(
			strings.TrimSpace(name))
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, nil
}

func selectFeatures(csv string) (map[string]bool, error) {
	if csv == "" {
		return nil, nil // all implemented
	}
	valid := map[string]bool{}
	for _, f := range bench.ImplementedFeatures() {
		valid[f] = true
	}
	out := map[string]bool{}
	for _, f := range strings.Split(csv, ",") {
		f = strings.TrimSpace(f)
		if !valid[f] {
			return nil, fmt.Errorf(
				"unknown or unimplemented feature %q "+
					"(implemented: %s)", f,
				strings.Join(
					bench.ImplementedFeatures(), ", "))
		}
		out[f] = true
	}
	return out, nil
}

func writeResult(path string, res *bench.Result) error {
	b, err := json.MarshalIndent(res, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}
