package bench

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Fixture loading (plan §3): reinstall the engine, write the
// scenario model through the public API, then COPY the generated
// rows straight into fga.tuple — a deliberate bypass of the
// 100-op fga.write gate for fixture setup only (decision 6;
// fga.write throughput is its own benchmark). A manifest in the
// fga_bench schema records what was loaded so re-runs against a
// persistent database skip the load; fga_bench is tooling state,
// never product surface — sql/ and the release never mention it.

// indexDropSize is the scale at which the loader drops the two
// secondary indexes before COPY and recreates them afterwards by
// re-running sql/050_tuple.sql (the single DDL source).
const indexDropSize = 10_000_000

// RepoRoot walks up from the working directory to the checkout
// root, identified by the engine's first install script — the
// loader needs sql/ and vendor/ to reinstall.
func RepoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		marker := filepath.Join(dir, "sql", "010_install.sql")
		if _, err := os.Stat(marker); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New(
				"repo root not found (no sql/010_install.sql " +
					"above the working directory)")
		}
		dir = parent
	}
}

// installFiles lists the engine's install scripts in install
// order: the vendored cel4postgres bundle, then sql/*.sql.
func installFiles(root string) ([]string, error) {
	cel, err := filepath.Glob(
		filepath.Join(root, "vendor", "cel4postgres--*.sql"))
	if err != nil || len(cel) != 1 {
		return nil, fmt.Errorf(
			"expected one vendored cel4postgres bundle, "+
				"found %d", len(cel))
	}
	engine, err := filepath.Glob(
		filepath.Join(root, "sql", "*.sql"))
	if err != nil || len(engine) == 0 {
		return nil, errors.New("no sql/*.sql install scripts")
	}
	sort.Strings(engine)
	return append(cel, engine...), nil
}

// execFile runs one install script. The scripts hold their own
// BEGIN/COMMIT and multiple statements, so this goes through the
// simple protocol.
func execFile(
	ctx context.Context, pool *pgxpool.Pool, path string,
) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	_, err = conn.Conn().PgConn().
		Exec(ctx, string(b)).ReadAll()
	if err != nil {
		return fmt.Errorf("%s: %w", filepath.Base(path), err)
	}
	return nil
}

// Install re-runs the documented idempotent install loop. It is
// unconditional before every measured run (plan §3): a
// persistent bench volume must never silently measure a stale
// engine.
func Install(
	ctx context.Context, pool *pgxpool.Pool, root string,
) error {
	files, err := installFiles(root)
	if err != nil {
		return err
	}
	for _, f := range files {
		if err := execFile(ctx, pool, f); err != nil {
			return err
		}
	}
	return nil
}

// LoadResult reports one scenario × size fixture load.
type LoadResult struct {
	Store   string
	ModelID string
	Rows    int64
	Seconds float64
	Skipped bool
}

const manifestDDL = `
CREATE SCHEMA IF NOT EXISTS fga_bench;
CREATE TABLE IF NOT EXISTS fga_bench.manifest (
  scenario text NOT NULL,
  size_name text NOT NULL,
  seed bigint NOT NULL,
  generator_version integer NOT NULL,
  store uuid NOT NULL,
  model_id uuid NOT NULL,
  tuples bigint NOT NULL,
  load_seconds double precision NOT NULL,
  loaded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (scenario, size_name)
);`

// copySource adapts the push-style generator to pgx's pull-style
// CopyFromSource through a channel.
type copySource struct {
	rows <-chan []any
	err  <-chan error
	cur  []any
	done error
}

func (s *copySource) Next() bool {
	r, ok := <-s.rows
	if !ok {
		s.done = <-s.err
		return false
	}
	s.cur = r
	return true
}

func (s *copySource) Values() ([]any, error) { return s.cur, nil }
func (s *copySource) Err() error             { return s.done }

// Load ensures the fixture for one scenario × size exists,
// loading it when the manifest does not already record an
// identical one. progress receives human-oriented status lines
// (a nil progress discards them).
func Load(
	ctx context.Context, pool *pgxpool.Pool, root string,
	s Scenario, size Size, seed uint64,
	progress func(format string, args ...any),
) (LoadResult, error) {
	if progress == nil {
		progress = func(string, ...any) {}
	}
	// Multi-statement DDL goes through the simple protocol.
	if _, err := pool.Exec(ctx, manifestDDL,
		pgx.QueryExecModeSimpleProtocol); err != nil {
		return LoadResult{}, err
	}

	// A matching manifest row whose store still exists means the
	// fixture is already there.
	var (
		prevSeed  int64
		prevGen   int
		prevStore string
		prevModel string
		prevRows  int64
		prevSecs  float64
	)
	err := pool.QueryRow(ctx, `
		SELECT m.seed, m.generator_version, m.store::text,
		       m.model_id::text, m.tuples, m.load_seconds
		FROM fga_bench.manifest m
		WHERE m.scenario = $1 AND m.size_name = $2`,
		s.Name(), size.Name,
	).Scan(&prevSeed, &prevGen, &prevStore, &prevModel,
		&prevRows, &prevSecs)
	switch {
	case err == nil:
		var live bool
		if err := pool.QueryRow(ctx, `
			SELECT EXISTS (
			  SELECT FROM fga.store WHERE id = $1)`,
			prevStore).Scan(&live); err != nil {
			return LoadResult{}, err
		}
		if live && uint64(prevSeed) == seed &&
			prevGen == GeneratorVersion &&
			prevRows == int64(size.Tuples) {
			progress("fixture %s/%s already loaded, skipping",
				s.Name(), size.Name)
			return LoadResult{Store: prevStore,
				ModelID: prevModel, Rows: prevRows,
				Seconds: prevSecs, Skipped: true}, nil
		}
		progress("fixture %s/%s is stale, reloading",
			s.Name(), size.Name)
		if _, err := pool.Exec(ctx,
			"SELECT fga.delete_store($1)", prevStore,
		); err != nil {
			return LoadResult{}, err
		}
		if _, err := pool.Exec(ctx, `
			DELETE FROM fga_bench.manifest
			WHERE scenario = $1 AND size_name = $2`,
			s.Name(), size.Name); err != nil {
			return LoadResult{}, err
		}
	case errors.Is(err, pgx.ErrNoRows):
		// Nothing loaded yet.
	default:
		return LoadResult{}, err
	}

	var store string
	if err := pool.QueryRow(ctx,
		"SELECT id::text FROM fga.create_store($1)",
		fmt.Sprintf("bench-%s-%s", s.Name(), size.Name),
	).Scan(&store); err != nil {
		return LoadResult{}, err
	}
	var modelResp []byte
	if err := pool.QueryRow(ctx,
		"SELECT fga.write_authorization_model($1, $2)",
		store, s.Model()).Scan(&modelResp); err != nil {
		return LoadResult{}, err
	}
	var modelID string
	if err := pool.QueryRow(ctx,
		"SELECT $1::jsonb ->> 'authorization_model_id'",
		modelResp).Scan(&modelID); err != nil {
		return LoadResult{}, err
	}

	dropped := size.Tuples >= indexDropSize
	if dropped {
		progress("dropping secondary indexes for the %s load",
			size.Name)
		for _, idx := range []string{
			"tuple_ulid_idx", "tuple_reverse_idx",
		} {
			if _, err := pool.Exec(ctx,
				"DROP INDEX IF EXISTS fga."+idx,
			); err != nil {
				return LoadResult{}, err
			}
		}
	}

	progress("loading %s/%s: %d tuples",
		s.Name(), size.Name, size.Tuples)
	start := time.Now()
	rows := make(chan []any, 4096)
	genErr := make(chan error, 1)
	gen := NewULIDGen(seed)
	go func() {
		defer close(rows)
		var n int64
		genErr <- s.Generate(seed, size, func(t Tuple) error {
			n++
			if n%1_000_000 == 0 {
				progress("  %dM rows generated", n/1_000_000)
			}
			select {
			case rows <- []any{
				store, t.ObjectType, t.ObjectID.String(),
				t.Relation, t.SubjectType,
				t.SubjectID.String(), t.SubjectRelation,
				gen.Next(),
			}:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		})
	}()
	copied, err := pool.CopyFrom(ctx,
		pgx.Identifier{"fga", "tuple"},
		[]string{"store", "object_type", "object_id",
			"relation", "subject_type", "subject_id",
			"subject_relation", "ulid"},
		&copySource{rows: rows, err: genErr})
	if err != nil {
		return LoadResult{}, err
	}
	if copied != int64(size.Tuples) {
		return LoadResult{}, fmt.Errorf(
			"copied %d rows, want %d", copied, size.Tuples)
	}

	if dropped {
		progress("recreating secondary indexes")
		if err := execFile(ctx, pool, filepath.Join(
			root, "sql", "050_tuple.sql")); err != nil {
			return LoadResult{}, err
		}
	}
	if _, err := pool.Exec(ctx,
		"ANALYZE fga.tuple"); err != nil {
		return LoadResult{}, err
	}
	// CHECKPOINT keeps the load's WAL flush out of the first
	// measured case; a managed database may refuse it, which
	// only means the first case absorbs some background I/O.
	if _, err := pool.Exec(ctx, "CHECKPOINT"); err != nil {
		progress("CHECKPOINT refused (%v), continuing", err)
	}

	secs := time.Since(start).Seconds()
	if _, err := pool.Exec(ctx, `
		INSERT INTO fga_bench.manifest (scenario, size_name,
		  seed, generator_version, store, model_id, tuples,
		  load_seconds)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		s.Name(), size.Name, int64(seed), GeneratorVersion,
		store, modelID, int64(size.Tuples), secs,
	); err != nil {
		return LoadResult{}, err
	}
	progress("loaded %s/%s in %.1fs",
		s.Name(), size.Name, secs)
	return LoadResult{Store: store, ModelID: modelID,
		Rows: copied, Seconds: secs}, nil
}

// Storage classifies where the database keeps its data, for the
// result file's env block. The bench compose stack names itself
// via cluster_name; the default compose stack is tmpfs-backed;
// anything else is external. FGA_BENCH_STORAGE overrides when
// the heuristic cannot know (an external volume, say).
func Storage(
	ctx context.Context, pool *pgxpool.Pool,
) string {
	if v := os.Getenv("FGA_BENCH_STORAGE"); v != "" {
		return v
	}
	var cluster string
	if err := pool.QueryRow(ctx,
		"SHOW cluster_name").Scan(&cluster); err != nil {
		return "unknown"
	}
	switch cluster {
	case "fga4postgres-bench":
		return "volume"
	case "":
		// The repo's default compose stack sets no cluster
		// name and is tmpfs-backed; a bare external server is
		// indistinguishable from here, hence the override.
		return "tmpfs"
	default:
		return "external"
	}
}
