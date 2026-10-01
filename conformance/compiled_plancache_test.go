package conformance

import (
	"context"
	"fmt"
	"slices"
	"sort"
	"testing"

	"github.com/jackc/pgx/v5"
	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// An application prepares its page query once per connection, and
// PostgreSQL inlines the generated function into that plan. A model
// write must reach the cached plan: the generator replaces each
// function in place, which invalidates every plan that inlined it,
// so the next execution re-plans against the new body. A generic
// plan is forced so the statement is never re-planned for any other
// reason. The model moves doc#viewer through two rewrites and two
// strategies (flattened, then delegated).
//
// The application's view over the same function is what replacing
// in place protects most: a view holds the function by oid, so a
// generator that dropped and re-created functions would fail every
// model write with "other objects depend on it" (a prepared
// statement alone re-resolves the name when re-analysed, and
// survives either way).
func TestCompiledPlanInvalidation(t *testing.T) {
	ctx := context.Background()
	models := []struct {
		rewrite string
		want    []string
	}{
		{"[user]", []string{"d1"}},
		{"[user] or editor", []string{"d1", "d2", "d3"}},
		{"[user] but not editor", []string{"d1"}},
	}
	dsl := func(rewrite string) string {
		return `model
  schema 1.1
type user
type doc
  relations
    define editor: [user]
    define viewer: ` + rewrite
	}
	schema := compiledSchema(t)
	storeID, ids := compiledStore(t, schema, dsl(models[0].rewrite),
		[]*openfgav1.TupleKey{
			tk("doc:d1", "viewer", "user:anne"),
			tk("doc:d2", "editor", "user:anne"),
			tk("doc:d3", "editor", "user:anne"),
		})
	for _, d := range []string{"d1", "d2", "d3"} {
		ids.ID(d)
	}

	conn, err := testdb.Pool(t).Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	_, err = conn.Exec(ctx, "SET plan_cache_mode = force_generic_plan")
	if err != nil {
		t.Fatal(err)
	}
	_, err = conn.Exec(ctx, fmt.Sprintf(`PREPARE page(uuid) AS
		SELECT x::text FROM %s.doc__viewer__objects('user', $1) x`,
		schema))
	if err != nil {
		t.Fatal(err)
	}
	// Runs before Release: the connection goes back to the pool.
	defer func() {
		_, _ = conn.Exec(context.Background(),
			"DEALLOCATE page; RESET plan_cache_mode")
	}()

	anne := ids.ID("anne")
	_, err = conn.Exec(ctx, fmt.Sprintf(`CREATE VIEW %s.anne_docs AS
		SELECT x::text AS doc FROM %s.doc__viewer__objects('user',
		  '%s'::uuid) x`, schema, schema, anne))
	if err != nil {
		t.Fatal(err)
	}
	for i, m := range models {
		if i > 0 {
			setupModel(t, compiledEngine(t), storeID, dsl(m.rewrite))
		}
		// EXECUTE takes no protocol parameters; anne is a uuid.
		rows, err := conn.Query(ctx,
			fmt.Sprintf("EXECUTE page('%s')", anne))
		if err != nil {
			t.Fatalf("viewer: %s: %v", m.rewrite, err)
		}
		got, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			t.Fatalf("viewer: %s: %v", m.rewrite, err)
		}
		for j, v := range got {
			got[j] = ids.Back(v)
		}
		sort.Strings(got)
		if !slices.Equal(got, m.want) {
			t.Errorf("viewer: %s: prepared page = %v, want %v",
				m.rewrite, got, m.want)
		}
		rows, err = conn.Query(ctx, fmt.Sprintf(
			"SELECT doc FROM %s.anne_docs", schema))
		if err != nil {
			t.Fatalf("viewer: %s: view: %v", m.rewrite, err)
		}
		got, err = pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			t.Fatalf("viewer: %s: view: %v", m.rewrite, err)
		}
		for j, v := range got {
			got[j] = ids.Back(v)
		}
		sort.Strings(got)
		if !slices.Equal(got, m.want) {
			t.Errorf("viewer: %s: view = %v, want %v",
				m.rewrite, got, m.want)
		}
	}
}

// Dispatch from list_objects reaches a generated __objects function
// through a dynamic statement, which PostgreSQL plans on every
// execution. Inlined into that statement, the function's body was
// planned with it on every call: on a wide model that planning cost
// ten times the execution. Called as a function, its own plan is
// cached for the session and only the call is planned.
//
// Whether a SQL function was inlined is visible in its call count:
// an inlined body never runs as a function, so track_functions
// counts nothing. Both entry points dispatch, and both must count
// one call each.
func TestCompiledDispatchCallsTheFunction(t *testing.T) {
	schema := compiledSchema(t)
	storeID, ids := compiledStore(t, schema, `model
  schema 1.1
type user
type doc
  relations
    define editor: [user]
    define viewer: [user] or editor`,
		[]*openfgav1.TupleKey{
			tk("doc:d1", "viewer", "user:anne"),
			tk("doc:d2", "editor", "user:anne"),
		})
	request := fmt.Sprintf(
		`{"type": "doc", "relation": "viewer", "user": "user:%s"}`,
		ids.ID("anne"))
	generated := schema + ".doc__viewer__objects"
	for _, call := range []string{
		"SELECT fga.list_objects($1, $2::jsonb)",
		"SELECT fga.streamed_list_objects($1, $2::jsonb)",
	} {
		calls := callCounts(t, call, storeID, request)
		if got := calls[generated]; got != 1 {
			t.Errorf("%s: %s ran as a function %d times, want 1 "+
				"(0 means dispatch inlined it; all: %v)",
				call, generated, got, calls)
		}
	}
}
