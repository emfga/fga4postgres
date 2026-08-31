package bench

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// The loader's integration test: load 100k fixtures into the
// compose database, then prove them end-to-end by running the
// scenario's own selection rules through fga.check — a generated
// hit must be allowed and a generated miss must not, which
// validates the COPY bypass, the uuid wiring and the model in
// one pass.

func loadFixture(
	t *testing.T, pool *pgxpool.Pool, s Scenario,
) LoadResult {
	t.Helper()
	ctx := context.Background()
	root, err := RepoRoot()
	if err != nil {
		t.Fatal(err)
	}
	if err := Install(ctx, pool, root); err != nil {
		t.Fatalf("reinstall: %v", err)
	}
	res, err := Load(ctx, pool, root, s, size100k, 1,
		t.Logf)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx,
			"SELECT fga.delete_store($1)", res.Store)
		_, _ = pool.Exec(ctx, `
			DELETE FROM fga_bench.manifest
			WHERE scenario = $1 AND size_name = $2`,
			s.Name(), size100k.Name)
	})
	return res
}

func checkAllowed(
	t *testing.T, pool *pgxpool.Pool,
	store, modelID string, q Query,
) bool {
	t.Helper()
	req, err := json.Marshal(map[string]any{
		"authorization_model_id": modelID,
		"tuple_key": map[string]string{
			"object":   q.Object,
			"relation": q.Relation,
			"user":     q.User,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	var allowed bool
	if err := pool.QueryRow(context.Background(),
		"SELECT (fga.check($1, $2) ->> 'allowed')::boolean",
		store, req).Scan(&allowed); err != nil {
		t.Fatalf("check %+v: %v", q, err)
	}
	return allowed
}

func TestLoadAndCheck(t *testing.T) {
	pool := testdb.Pool(t)
	ctx := context.Background()
	for _, s := range Scenarios {
		t.Run(s.Name(), func(t *testing.T) {
			res := loadFixture(t, pool, s)
			if res.Rows != int64(size100k.Tuples) {
				t.Fatalf("loaded %d rows", res.Rows)
			}

			var n int64
			if err := pool.QueryRow(ctx, `
				SELECT count(*) FROM fga.tuple
				WHERE store = $1`, res.Store,
			).Scan(&n); err != nil {
				t.Fatal(err)
			}
			if n != int64(size100k.Tuples) {
				t.Fatalf("store holds %d rows", n)
			}

			for i := 0; i < 5; i++ {
				for _, name := range []string{
					"hit-shallow", "hit-deep",
				} {
					q := s.Query(1, size100k,
						Variant{"check", name}, i)
					if !checkAllowed(t, pool, res.Store,
						res.ModelID, q) {
						t.Errorf("%s #%d denied: %+v",
							name, i, q)
					}
				}
				q := s.Query(1, size100k,
					Variant{"check", "miss"}, i)
				if checkAllowed(t, pool, res.Store,
					res.ModelID, q) {
					t.Errorf("miss #%d allowed: %+v", i, q)
				}
			}

			// The second load must be a manifest skip.
			root, err := RepoRoot()
			if err != nil {
				t.Fatal(err)
			}
			again, err := Load(ctx, pool, root, s,
				size100k, 1, t.Logf)
			if err != nil {
				t.Fatal(err)
			}
			if !again.Skipped || again.Store != res.Store {
				t.Errorf("expected a skip, got %+v", again)
			}

			// A changed seed must reload, not reuse.
			reload, err := Load(ctx, pool, root, s,
				size100k, 2, t.Logf)
			if err != nil {
				t.Fatal(err)
			}
			if reload.Skipped || reload.Store == res.Store {
				t.Errorf("expected a reload, got %+v", reload)
			}
			_, _ = pool.Exec(ctx,
				"SELECT fga.delete_store($1)", reload.Store)
		})
	}
}

// Storage classification: on the default compose stack this is
// tmpfs; on the bench stack (compose.bench.yaml, which names its
// cluster) it must say volume — the disk-backed assertion of
// plan milestone 2.
func TestStorageClassification(t *testing.T) {
	pool := testdb.Pool(t)
	got := Storage(context.Background(), pool)
	var cluster string
	if err := pool.QueryRow(context.Background(),
		"SHOW cluster_name").Scan(&cluster); err != nil {
		t.Fatal(err)
	}
	want := "tmpfs"
	if cluster == "fga4postgres-bench" {
		want = "volume"
	} else if cluster != "" {
		want = "external"
	}
	if got != want &&
		testdb.Env("FGA_BENCH_STORAGE", "") == "" {
		t.Fatalf("storage = %q, want %q (cluster %q)",
			got, want, cluster)
	}
}
