package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

const reverseIndexDef = "CREATE INDEX tuple_reverse_cond_idx " +
	"ON fga.tuple USING btree (store, subject_type, subject_id, " +
	"subject_relation, relation, object_type, object_id) " +
	"INCLUDE (condition_name)"

// Re-running the installer converges on one reverse index whatever
// the database had: the index of an earlier install, the current
// one, both, or neither. Each case runs sql/050_tuple.sql inside a
// transaction it rolls back, the way a migration tool would.
func TestTupleReverseIndexReinstall(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "sql", "050_tuple.sql"))
	if err != nil {
		t.Fatal(err)
	}
	const (
		dropNew   = "DROP INDEX IF EXISTS fga.tuple_reverse_cond_idx"
		dropOld   = "DROP INDEX IF EXISTS fga.tuple_reverse_idx"
		createOld = "CREATE INDEX IF NOT EXISTS tuple_reverse_idx " +
			"ON fga.tuple " +
			"(store, subject_type, subject_id, subject_relation, " +
			"relation, object_type, object_id)"
	)
	cases := map[string][]string{
		"previous release": {dropNew, createOld},
		"current":          nil,
		"both":             {createOld},
		"neither":          {dropNew, dropOld},
	}
	ctx := context.Background()
	pool := testdb.Pool(t)
	for name, before := range cases {
		t.Run(name, func(t *testing.T) {
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(ctx) }()
			for _, stmt := range before {
				if _, err := tx.Exec(ctx, stmt); err != nil {
					t.Fatalf("%s: %v", stmt, err)
				}
			}
			if _, err := tx.Exec(ctx, string(src)); err != nil {
				t.Fatalf("050_tuple.sql: %v", err)
			}
			rows, err := tx.Query(ctx, `
				SELECT c.relname, pg_get_indexdef(i.indexrelid)
				FROM pg_index i
				JOIN pg_class c ON c.oid = i.indexrelid
				WHERE i.indrelid = 'fga.tuple'::regclass
				ORDER BY c.relname`)
			if err != nil {
				t.Fatal(err)
			}
			defs := map[string]string{}
			var names []string
			for rows.Next() {
				var n, d string
				if err := rows.Scan(&n, &d); err != nil {
					t.Fatal(err)
				}
				names = append(names, n)
				defs[n] = d
			}
			if err := rows.Err(); err != nil {
				t.Fatal(err)
			}
			want := []string{"tuple_pkey", "tuple_reverse_cond_idx",
				"tuple_ulid_idx"}
			if !slices.Equal(names, want) {
				t.Errorf("indexes %v, want %v", names, want)
			}
			if got := defs["tuple_reverse_cond_idx"]; got !=
				reverseIndexDef {
				t.Errorf("reverse index:\n got %s\nwant %s", got,
					reverseIndexDef)
			}
		})
	}
}

// The reason the reverse index carries condition_name: an exact
// parent edge must be an unconditioned row, and a page over a broad
// ladder walks one parent edge per leaf. With condition_name in the
// index every edge is answered from the index alone; without it,
// each is a heap fetch. After a VACUUM the visibility map is set,
// so an index-only scan reports zero heap fetches.
func TestTupleReverseIndexCoversParentEdges(t *testing.T) {
	ctx := context.Background()
	pool := testdb.Pool(t)
	client := compiledEngine(t)
	ids := uuidmap.New("compiled/" + t.Name())
	storeID, _ := setup(t, client, ladderDSL, nil)
	t.Cleanup(func() { _ = client.DeleteStore(ctx, storeID) })
	schema := compiledSchema(t)
	enableCompiled(t, storeID, schema)

	// 1 platform, 4 accounts, 20 projects, 2,000 environments, and a
	// background reader on every environment.
	_, err := pool.Exec(ctx, `
		WITH acc AS (
		  SELECT a, md5($1 || 'a' || a)::uuid AS id
		  FROM generate_series(1, 4) a),
		prj AS (
		  SELECT acc.id AS parent, md5($1 || 'j' || a || '.' || j)::uuid
		    AS id
		  FROM acc, generate_series(1, 5) j),
		env AS (
		  SELECT prj.id AS parent,
		    md5($1 || 'e' || prj.id || '.' || e)::uuid AS id
		  FROM prj, generate_series(1, 100) e),
		rows (ot, oid, rel, st, sid) AS (
		  SELECT 'platform', $2::uuid, 'admin', 'user', $3::uuid
		  UNION ALL
		  SELECT 'account', id, 'parent', 'platform', $2::uuid
		  FROM acc
		  UNION ALL
		  SELECT 'project', id, 'parent', 'account', parent FROM prj
		  UNION ALL
		  SELECT 'environment', id, 'parent', 'project', parent
		  FROM env
		  UNION ALL
		  SELECT 'environment', id, 'reader', 'user',
		    md5($1 || 'u' || id)::uuid
		  FROM env)
		INSERT INTO fga.tuple (store, object_type, object_id,
		  relation, subject_type, subject_id, ulid)
		SELECT $4::uuid, ot, oid, rel, st, sid, fga._ulid()
		FROM rows`,
		t.Name(), ids.ID("p"), ids.ID("padmin"), storeID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "VACUUM (ANALYZE) fga.tuple"); err != nil {
		t.Fatal(err)
	}

	query := fmt.Sprintf("SELECT count(*) FROM "+
		"%s.environment__can_view__objects('user', '%s')",
		schema, ids.ID("padmin"))
	if n := queryInt(t, query); n != 2000 {
		t.Fatalf("padmin sees %d environments, want 2000", n)
	}
	var raw []byte
	if err := pool.QueryRow(ctx,
		"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) "+query,
	).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	var plans []struct {
		Plan planNode `json:"Plan"`
	}
	if err := json.Unmarshal(raw, &plans); err != nil {
		t.Fatal(err)
	}

	// Every scan of fga.tuple keyed by subject is a parent edge or
	// a grant; each must come from the reverse index alone.
	var edges int
	var walk func(n planNode)
	walk = func(n planNode) {
		if n.Relation == "tuple" && n.IndexName != "tuple_pkey" &&
			n.IndexName != "tuple_ulid_idx" {
			if n.NodeType != "Index Only Scan" ||
				n.IndexName != "tuple_reverse_cond_idx" {
				t.Errorf("%s on %q reads fga.tuple by subject "+
					"outside the covering index", n.NodeType,
					n.IndexName)
			} else if n.HeapFetches != 0 {
				t.Errorf("index-only scan made %d heap fetches",
					n.HeapFetches)
			}
			edges += int(n.ActualRows * n.ActualLoops)
		}
		for _, c := range n.Plans {
			walk(c)
		}
	}
	walk(plans[0].Plan)
	// The 2,000 environment edges alone are read through the index.
	if edges < 2000 {
		t.Errorf("%d rows read by subject, want at least 2000",
			edges)
	}
	if t.Failed() {
		t.Logf("plan:\n%s", raw)
	}
}

type planNode struct {
	NodeType    string     `json:"Node Type"`
	Relation    string     `json:"Relation Name"`
	IndexName   string     `json:"Index Name"`
	HeapFetches int64      `json:"Heap Fetches"`
	ActualRows  float64    `json:"Actual Rows"`
	ActualLoops float64    `json:"Actual Loops"`
	Plans       []planNode `json:"Plans"`
}
