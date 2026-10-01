package bench

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// tenant's selection rules, replayed against its generated
// dataset: environment#can_view flattened to its four grant
// places, which is what the model's ladders reduce to for
// [user] grants.

var tenantPlaces = map[string]map[string]bool{
	"environment": {"admin": true, "maintainer": true,
		"writer": true, "reader": true},
	"project": {"admin": true, "maintainer": true,
		"writer": true, "reader": true},
	"account": {"owner": true, "admin": true,
		"maintainer": true, "writer": true, "reader": true},
	"platform": {"admin": true, "support": true,
		"auditor": true},
}

type tenantGraph struct {
	// grants: "type:id" -> "user:id" -> relations held.
	grants map[string]map[string][]string
	// parent: "type:id" -> its parent "type:id".
	parent map[string]string
	leaves []string
}

func buildTenantGraph(t *testing.T) *tenantGraph {
	t.Helper()
	g := &tenantGraph{
		grants: map[string]map[string][]string{},
		parent: map[string]string{},
	}
	for _, r := range generate(t, tenantScenario{}, 1) {
		obj := r.ObjectType + ":" + r.ObjectID.String()
		subj := r.SubjectType + ":" + r.SubjectID.String()
		if r.Relation == "parent" {
			g.parent[obj] = subj
			if r.ObjectType == "environment" {
				g.leaves = append(g.leaves, obj)
			}
			continue
		}
		if g.grants[obj] == nil {
			g.grants[obj] = map[string][]string{}
		}
		g.grants[obj][subj] = append(g.grants[obj][subj],
			r.Relation)
	}
	return g
}

// canView walks leaf → project → account → platform, granting on
// any relation of the place's set.
func (g *tenantGraph) canView(leaf, user string) bool {
	for obj := leaf; obj != ""; obj = g.parent[obj] {
		typ := obj[:len(obj)-37]
		for _, rel := range g.grants[obj][user] {
			if tenantPlaces[typ][rel] {
				return true
			}
		}
	}
	return false
}

func (g *tenantGraph) reach(user string) int {
	n := 0
	for _, l := range g.leaves {
		if g.canView(l, user) {
			n++
		}
	}
	return n
}

func TestTenantSizes(t *testing.T) {
	for k, off := range tReaderOffsets {
		if off >= tLeaves || (k > 0 &&
			off <= tReaderOffsets[k-1]) {
			t.Fatalf("reader offsets must be distinct, "+
				"ascending and below %d", tLeaves)
		}
	}
	for _, size := range Sizes {
		accounts := tAccounts(size)
		leaves := accounts * tLeaves
		// The miss rule draws from accounts outside a reader's
		// three.
		if accounts < 4 {
			t.Errorf("%s: %d accounts", size.Name, accounts)
		}
		fill := tFill(size)
		if fill < 0 {
			t.Errorf("%s: fixed tuples exceed the size",
				size.Name)
		}
		// Two background grants of one (leaf, relation) are
		// m rounds apart and their users m·(7·leaves+1) apart;
		// a multiple of U would duplicate a primary key.
		stride := len(tLeafRelations) * leaves
		rounds := (fill + stride - 1) / stride
		for m := 1; m < rounds; m++ {
			if m*(stride+1)%tUsers(size) == 0 {
				t.Errorf("%s: rounds 0 and %d collide",
					size.Name, m)
			}
		}
	}
}

func TestTenantSelectionRules(t *testing.T) {
	s := tenantScenario{}
	g := buildTenantGraph(t)
	if len(g.leaves) != 5_000 {
		t.Fatalf("%d leaves at 100k, want 5000", len(g.leaves))
	}
	for i := 0; i < querySamples; i++ {
		for _, f := range []string{
			"check", "compiled_check", "check_opted_in",
		} {
			hs := s.Query(1, size100k,
				Variant{f, "hit-shallow"}, i)
			if !g.canView(hs.Object, hs.User) {
				t.Errorf("%s hit-shallow #%d denied: %+v",
					f, i, hs)
			}
			hd := s.Query(1, size100k,
				Variant{f, "hit-deep"}, i)
			if !g.canView(hd.Object, hd.User) {
				t.Errorf("%s hit-deep #%d denied: %+v",
					f, i, hd)
			}
			if len(g.grants[hd.Object][hd.User]) != 0 {
				t.Errorf("%s hit-deep #%d is direct: %+v",
					f, i, hd)
			}
			m := s.Query(1, size100k, Variant{f, "miss"}, i)
			if g.canView(m.Object, m.User) {
				t.Errorf("%s miss #%d allowed: %+v", f, i, m)
			}
		}
	}
	want := map[string]int{"few": 3, "many": tLeaves,
		"all": 5_000}
	for _, f := range []string{
		"list_objects", "compiled_objects", "compiled_page",
	} {
		for name, n := range want {
			for i := 0; i < 3; i++ {
				q := s.Query(1, size100k, Variant{f, name}, i)
				if got := g.reach(q.User); got != n {
					t.Errorf(
						"%s:%s #%d reaches %d, want %d",
						f, name, i, got, n)
				}
			}
		}
	}
}

// End to end against the compose database: every tenant case
// runs, the generated functions agree with the selection rules
// on the loaded store, and the store is left opted out.
func TestTenantRun(t *testing.T) {
	pool := testdb.Pool(t)
	ctx := context.Background()
	s := tenantScenario{}
	schema := AppSchema(s, size100k)
	load := loadFixture(t, pool, s)
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "DROP SCHEMA IF EXISTS "+
			pgx.Identifier{schema}.Sanitize()+" CASCADE")
	})

	res, err := Run(ctx, pool, s, size100k, load, RunConfig{
		Seed:     1,
		Warmup:   20 * time.Millisecond,
		Duration: 20 * time.Millisecond,
		MinOps:   3,
	}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Cases) != len(s.Variants()) {
		t.Errorf("%d cases, want %d",
			len(res.Cases), len(s.Variants()))
	}

	var opted bool
	if err := pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT FROM fga.compiled_store
		               WHERE store = $1)`, load.Store,
	).Scan(&opted); err != nil {
		t.Fatal(err)
	}
	if opted {
		t.Error("store left opted in after the run")
	}

	// The generated set must match the rule each list variant
	// promises — on the engine, not just the replay above.
	cleanup, err := optIn(ctx, pool, schema, load.Store)
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	fn, err := compiledFn(ctx, pool, load.Store,
		"environment", "can_view", "objects")
	if err != nil {
		t.Fatal(err)
	}
	table := pgx.Identifier{schema, "environment"}.Sanitize()
	for name, n := range map[string]int{
		"few": 3, "many": tLeaves, "all": 5_000,
	} {
		q := s.Query(1, size100k,
			Variant{"compiled_objects", name}, 0)
		var got, page int
		if err := pool.QueryRow(ctx, `
			SELECT (SELECT count(*) FROM `+fn+`('user',
			          split_part($1, ':', 2)::uuid)),
			       (SELECT count(*) FROM (SELECT FROM `+
			table+` e WHERE e.id IN (SELECT x FROM `+fn+
			`('user', split_part($1, ':', 2)::uuid) x)
			        LIMIT 50) p)`, q.User,
		).Scan(&got, &page); err != nil {
			t.Fatal(err)
		}
		if got != n || page != min(n, 50) {
			t.Errorf("%s: __objects %d, page %d; want %d, %d",
				name, got, page, n, min(n, 50))
		}
	}
}
