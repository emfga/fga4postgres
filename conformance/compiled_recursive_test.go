package conformance

import (
	"context"
	"fmt"
	"slices"
	"sort"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// Two types whose member relations name each other: the relation
// graph has the cycle team#member -> crew#member -> team#member, and
// the tuples below close it in the data too.
const crossCycleDSL = `model
  schema 1.1
type user
type team
  relations
    define member: [user, crew#member]
type crew
  relations
    define member: [user, team#member]
type doc
  relations
    define viewer: [team#member]
`

func crossCycleTuples() []*openfgav1.TupleKey {
	return []*openfgav1.TupleKey{
		tk("team:t1", "member", "crew:c1#member"),
		tk("crew:c1", "member", "team:t1#member"),
		tk("crew:c1", "member", "user:anne"),
		tk("team:t2", "member", "crew:c1#member"),
		tk("crew:c2", "member", "team:t2#member"),
		tk("doc:d1", "viewer", "team:t2#member"),
	}
}

// compiledFixture is a store opted in to compiled relations with a
// model and tuples written, plus the uuid map its DSL ids went
// through.
type compiledFixture struct {
	schema, storeID string
	ids             *uuidmap.Map
}

func newCompiledFixture(
	t *testing.T, dsl string, tuples []*openfgav1.TupleKey,
) compiledFixture {
	t.Helper()
	client := compiledEngine(t)
	schema := compiledSchema(t)
	store, err := client.CreateStore(context.Background(),
		&openfgav1.CreateStoreRequest{Name: t.Name()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = client.DeleteStore(context.Background(), store.GetId())
	})
	enableCompiled(t, store.GetId(), schema)
	storeID, modelID := setupModel(t, client, store.GetId(), dsl)
	for start := 0; start < len(tuples); start += 40 {
		end := min(start+40, len(tuples))
		_, err := client.Write(context.Background(),
			&openfgav1.WriteRequest{
				StoreId:              storeID,
				AuthorizationModelId: modelID,
				Writes: &openfgav1.WriteRequestWrites{
					TupleKeys: tuples[start:end],
				},
			})
		if err != nil {
			t.Fatal(err)
		}
	}
	return compiledFixture{schema: schema, storeID: storeID,
		ids: uuidmap.New("compiled/" + t.Name())}
}

// strategy reads the registered strategy of one relation.
func (f compiledFixture) strategy(t *testing.T, rel string) string {
	t.Helper()
	typ, name, _ := strings.Cut(rel, "#")
	var s string
	err := testdb.Pool(t).QueryRow(context.Background(), `
		SELECT strategy FROM fga.compiled_relation
		WHERE store = $1 AND type_name = $2 AND relation_name = $3`,
		f.storeID, typ, name).Scan(&s)
	if err != nil {
		t.Fatalf("strategy of %s: %v", rel, err)
	}
	return s
}

// outcome runs a query and renders what it answered: its rows,
// mapped back to DSL ids and sorted, or the SQLSTATE it raised.
// Every query runs under a five-second statement timeout, so a
// body that walks a cycle without end fails instead of hanging.
func (f compiledFixture) outcome(
	t *testing.T, query string, args ...any,
) string {
	t.Helper()
	ctx := context.Background()
	conn, err := testdb.Pool(t).Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx,
		"SET statement_timeout = '5s'"); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = conn.Exec(ctx, "RESET statement_timeout")
	}()
	rows, err := conn.Query(ctx, query, args...)
	if err != nil {
		return "error " + sqlState(err)
	}
	var got []string
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			t.Fatal(err)
		}
		got = append(got, f.ids.Back(v))
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return "error " + sqlState(err)
	}
	sort.Strings(got)
	return strings.Join(got, ",")
}

// Relations on a cycle of the relation graph compile to a
// recursive body instead of delegating, and cyclic data ends the
// walk: every kind answers, well inside the statement timeout,
// what the generic resolver answers.
func TestCompiledCycleTerminates(t *testing.T) {
	f := newCompiledFixture(t, crossCycleDSL, crossCycleTuples())
	for _, rel := range []string{
		"team#member", "crew#member", "doc#viewer",
	} {
		if s := f.strategy(t, rel); s != "recursive" {
			t.Errorf("%s: strategy %s, want recursive", rel, s)
		}
	}

	objects := func(rel, user string) string {
		typ, name, _ := strings.Cut(rel, "#")
		return f.outcome(t, fmt.Sprintf(
			"SELECT x::text FROM %s.%s__%s__objects('user', $1::uuid) x",
			f.schema, typ, name), f.ids.ID(user))
	}
	generic := func(rel, user string) string {
		typ, name, _ := strings.Cut(rel, "#")
		return f.outcome(t, `
			SELECT split_part(o ->> 'object', ':', 2)
			FROM fga.streamed_list_objects($1, jsonb_build_object(
			  'type', $2::text, 'relation', $3::text,
			  'user', 'user:' || $4)) o`,
			f.storeID, typ, name, f.ids.ID(user))
	}
	want := map[string]string{
		"team#member": "t1,t2",
		"crew#member": "c1,c2",
		"doc#viewer":  "d1",
	}
	for _, d := range []string{"t1", "t2", "c1", "c2", "d1"} {
		f.ids.ID(d)
	}
	for rel, w := range want {
		if got := objects(rel, "anne"); got != w {
			t.Errorf("%s objects anne = %q, want %q", rel, got, w)
		}
		if got, g := objects(rel, "anne"), generic(rel, "anne"); got != g {
			t.Errorf("%s objects anne = %q, generic %q", rel, got, g)
		}
		if got := objects(rel, "bob"); got != "" {
			t.Errorf("%s objects bob = %q, want none", rel, got)
		}
	}

	check := func(obj, rel, user string) string {
		typ, name, _ := strings.Cut(rel, "#")
		return f.outcome(t, fmt.Sprintf(
			"SELECT %s.%s__%s__check($1::uuid, 'user', $2::uuid)::text",
			f.schema, typ, name), f.ids.ID(obj), f.ids.ID(user))
	}
	for _, c := range []struct{ obj, rel, user, want string }{
		{"t1", "team#member", "anne", "true"},
		{"t1", "team#member", "bob", "false"},
		{"c2", "crew#member", "anne", "true"},
		{"c2", "crew#member", "bob", "false"},
		{"d1", "doc#viewer", "anne", "true"},
		{"d1", "doc#viewer", "bob", "false"},
	} {
		if got := check(c.obj, c.rel, c.user); got != c.want {
			t.Errorf("%s %s %s: check %q, want %q",
				c.obj, c.rel, c.user, got, c.want)
		}
	}

	subjects := f.outcome(t, fmt.Sprintf(
		"SELECT x::text FROM %s.team__member__subjects($1::uuid, "+
			"'user') x", f.schema), f.ids.ID("t1"))
	if subjects != "anne" {
		t.Errorf("team:t1 member subjects = %q, want anne", subjects)
	}
	usersets := f.outcome(t, fmt.Sprintf(
		"SELECT x::text FROM %s.team__member__subjects($1::uuid, "+
			"'crew', 'member') x", f.schema), f.ids.ID("t1"))
	if usersets != "c1" {
		t.Errorf("team:t1 member crew#member subjects = %q, want c1",
			usersets)
	}

	plan := explain(t, fmt.Sprintf(
		"SELECT x FROM %s.team__member__objects('user', '%s') x",
		f.schema, f.ids.ID("anne")))
	if strings.Contains(plan, "Function Scan") {
		t.Errorf("team#member objects not inlined:\n%s", plan)
	}
	if !slices.ContainsFunc(strings.Split(plan, "\n"),
		func(l string) bool {
			return strings.Contains(l, "Recursive Union")
		}) {
		t.Errorf("team#member objects has no recursive walk:\n%s",
			plan)
	}
}
