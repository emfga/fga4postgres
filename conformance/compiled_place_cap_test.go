package conformance

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// placeChainDSL is a chain of levels l0 .. l<levels-1> in which
// every level's viewer is granted directly or through any of
// `branches` parents at the next level, and l0's also through
// `extra` parents at the last level. Flattening l0#viewer enumerates
// every path down the chain: branches^0 + branches^1 + ... +
// branches^(levels-1) places, plus one per extra parent.
func placeChainDSL(levels, branches, extra int) string {
	var b strings.Builder
	b.WriteString("model\n  schema 1.1\ntype user\n")
	for i := range levels {
		fmt.Fprintf(&b, "type l%d\n  relations\n", i)
		if i == levels-1 {
			b.WriteString("    define viewer: [user]\n")
			continue
		}
		rewrite := []string{"[user]"}
		for p := 1; p <= branches; p++ {
			fmt.Fprintf(&b, "    define p%d: [l%d]\n", p, i+1)
			rewrite = append(rewrite, fmt.Sprintf("viewer from p%d", p))
		}
		for q := 1; i == 0 && q <= extra; q++ {
			fmt.Fprintf(&b, "    define q%d: [l%d]\n", q, levels-1)
			rewrite = append(rewrite, fmt.Sprintf("viewer from q%d", q))
		}
		fmt.Fprintf(&b, "    define viewer: %s\n",
			strings.Join(rewrite, " or "))
	}
	return b.String()
}

// placeChainTuples links o0 .. o<levels-1> down the chain through
// the last parent relation and grants anne at the bottom, so anne
// views every o<i>. Bob views the bottom level's x, which o0 reaches
// through its last extra parent when it has one.
func placeChainTuples(levels, branches, extra int) []*openfgav1.TupleKey {
	last := levels - 1
	var ts []*openfgav1.TupleKey
	for i := range last {
		ts = append(ts, tk(fmt.Sprintf("l%d:o%d", i, i),
			fmt.Sprintf("p%d", branches),
			fmt.Sprintf("l%d:o%d", i+1, i+1)))
	}
	if extra > 0 {
		ts = append(ts, tk("l0:o0", fmt.Sprintf("q%d", extra),
			fmt.Sprintf("l%d:x", last)))
	}
	return append(ts,
		tk(fmt.Sprintf("l%d:o%d", last, last), "viewer", "user:anne"),
		tk(fmt.Sprintf("l%d:x", last), "viewer", "user:bob"))
}

// newTimedCompiledFixture is newCompiledFixture with the model write
// run under a ten-second statement timeout, so a generator that
// enumerates paths without a bound fails the test instead of
// stalling it.
func newTimedCompiledFixture(
	t *testing.T, dsl string, tuples []*openfgav1.TupleKey,
) compiledFixture {
	t.Helper()
	ctx := context.Background()
	client := compiledEngine(t)
	schema := compiledSchema(t)
	store, err := client.CreateStore(ctx,
		&openfgav1.CreateStoreRequest{Name: t.Name()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = client.DeleteStore(context.Background(), store.GetId())
	})
	enableCompiled(t, store.GetId(), schema)

	conn, err := testdb.Pool(t).Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx,
		"SET statement_timeout = '10s'"); err != nil {
		t.Fatal(err)
	}
	var modelID string
	err = conn.QueryRow(ctx, `
		SELECT fga.write_authorization_model($1, $2::jsonb)
		  ->> 'authorization_model_id'`,
		store.GetId(), modelJSON(t, dsl)).Scan(&modelID)
	_, _ = conn.Exec(ctx, "RESET statement_timeout")
	if err != nil {
		t.Fatalf("model write: %v", err)
	}

	_, err = client.Write(ctx, &openfgav1.WriteRequest{
		StoreId:              store.GetId(),
		AuthorizationModelId: modelID,
		Writes: &openfgav1.WriteRequestWrites{
			TupleKeys: tuples,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return compiledFixture{schema: schema, storeID: store.GetId(),
		ids: uuidmap.New("compiled/" + t.Name())}
}

// registry reads one relation's strategy and reason.
func (f compiledFixture) registry(
	t *testing.T, rel string,
) (string, string) {
	t.Helper()
	typ, name, _ := strings.Cut(rel, "#")
	var s, r string
	err := testdb.Pool(t).QueryRow(context.Background(), `
		SELECT strategy, coalesce(reason, '')
		FROM fga.compiled_relation
		WHERE store = $1 AND type_name = $2 AND relation_name = $3`,
		f.storeID, typ, name).Scan(&s, &r)
	if err != nil {
		t.Fatalf("registry of %s: %v", rel, err)
	}
	return s, r
}

// generic runs a query with dispatch to generated functions off, so
// fga.check and fga.streamed_list_objects answer through the generic
// resolver, and renders its rows like outcome.
func (f compiledFixture) generic(
	t *testing.T, query string, args ...any,
) string {
	t.Helper()
	ctx := context.Background()
	conn, err := testdb.Pool(t).Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "SET fga._dispatching = 'on'; "+
		"SET statement_timeout = '5s'"); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = conn.Exec(ctx,
			"RESET fga._dispatching; RESET statement_timeout")
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

// agreesWithGeneric asserts an l0 relation's generated __check and
// __objects answer what the generic fga.check and
// fga.streamed_list_objects answer on the chain's tuples, and that
// anne's objects are not trivially empty.
func agreesWithGeneric(t *testing.T, f compiledFixture, rel string) {
	t.Helper()
	for _, o := range []string{"o0", "x"} {
		f.ids.ID(o)
	}
	for _, user := range []string{"anne", "bob", "carl"} {
		got := f.outcome(t, fmt.Sprintf(
			"SELECT x::text FROM %s.l0__%s__objects('user', $1::uuid) x",
			f.schema, rel), f.ids.ID(user))
		want := f.generic(t, `
			SELECT split_part(o ->> 'object', ':', 2)
			FROM fga.streamed_list_objects($1, jsonb_build_object(
			  'type', 'l0', 'relation', $3::text,
			  'user', 'user:' || $2)) o`,
			f.storeID, f.ids.ID(user), rel)
		if got != want {
			t.Errorf("%s objects %s = %q, generic %q",
				rel, user, got, want)
		}
		got = f.outcome(t, fmt.Sprintf(
			"SELECT %s.l0__%s__check($1::uuid, 'user', $2::uuid)::text",
			f.schema, rel), f.ids.ID("o0"), f.ids.ID(user))
		want = f.generic(t, `
			SELECT (fga.check($1, jsonb_build_object('tuple_key',
			  jsonb_build_object('object', 'l0:' || $2,
			    'relation', $4::text, 'user', 'user:' || $3)))
			  ->> 'allowed')`,
			f.storeID, f.ids.ID("o0"), f.ids.ID(user), rel)
		if got != want {
			t.Errorf("%s check o0 %s = %q, generic %q",
				rel, user, got, want)
		}
	}
	if got := f.outcome(t, fmt.Sprintf(
		"SELECT x::text FROM %s.l0__%s__objects('user', $1::uuid) x",
		f.schema, rel), f.ids.ID("anne")); got != "o0" {
		t.Errorf("%s objects anne = %q, want o0", rel, got)
	}
}

// A relation whose flattening would enumerate more places than the
// cap compiles to the recursive walk instead, which reaches the same
// grants without listing every path: 4 branches over 9 levels is
// 87,381 places for l0#viewer. The model write stays well inside the
// timeout and the answers equal the generic resolver's.
func TestCompiledPlaceCapGoesRecursive(t *testing.T) {
	const levels, branches = 9, 4
	f := newTimedCompiledFixture(t, placeChainDSL(levels, branches, 0),
		placeChainTuples(levels, branches, 0))
	if s, r := f.registry(t, "l0#viewer"); s != "recursive" {
		t.Errorf("l0#viewer: strategy %s (%s), want recursive", s, r)
	}
	agreesWithGeneric(t, f, "viewer")
}

// The cap is inclusive and exact: 7 branches over 3 levels plus 7
// extra parents is 1 + 7 + 49 + 7 = 64 places, which flattens; one
// more extra parent is 65, which does not.
func TestCompiledPlaceCapBoundary(t *testing.T) {
	for _, c := range []struct {
		extra int
		want  string
	}{
		{7, "flattened"},
		{8, "recursive"},
	} {
		t.Run(fmt.Sprintf("places_%d", 57+c.extra), func(t *testing.T) {
			f := newTimedCompiledFixture(t, placeChainDSL(3, 7, c.extra),
				placeChainTuples(3, 7, c.extra))
			if s, r := f.registry(t, "l0#viewer"); s != c.want {
				t.Errorf("l0#viewer: strategy %s (%s), want %s",
					s, r, c.want)
			}
			agreesWithGeneric(t, f, "viewer")
		})
	}
}

// Above the cap, a relation the recursive walk cannot answer (it
// reaches a set operation) is delegated, and the registry says why.
func TestCompiledPlaceCapDelegates(t *testing.T) {
	const levels, branches = 9, 4
	dsl := strings.Replace(placeChainDSL(levels, branches, 0),
		"type l0\n  relations\n",
		"type l0\n  relations\n"+
			"    define banned: [user]\n"+
			"    define allowed: viewer but not banned\n"+
			"    define top: [user] or viewer or allowed\n", 1)
	f := newTimedCompiledFixture(t, dsl,
		placeChainTuples(levels, branches, 0))
	if s, r := f.registry(t, "l0#viewer"); s != "recursive" {
		t.Errorf("l0#viewer: strategy %s (%s), want recursive", s, r)
	}
	s, r := f.registry(t, "l0#top")
	if s != "delegated" ||
		r != "flattening would need more than 64 places" {
		t.Errorf("l0#top: strategy %s (%s), want delegated over the cap",
			s, r)
	}
	for _, rel := range []string{"viewer", "allowed", "top"} {
		agreesWithGeneric(t, f, rel)
	}
}
