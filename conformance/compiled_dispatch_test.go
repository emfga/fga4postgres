package conformance

import (
	"context"
	"fmt"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// The first model of the dispatch store; the second adds "or
// editor" to doc#viewer, so a viewer question about an editor
// answers differently on the two models.
const dispatchDSLv1 = `model
  schema 1.1
type user
type team
  relations
    define member: [user]
type group
  relations
    define member: [user, group#member]
type doc
  relations
    define editor: [user]
    define viewer: [user, team#member]
    define gated: [group#member with ok]
condition ok(flag: bool) {
  flag
}`

var dispatchDSLv2 = strings.Replace(dispatchDSLv1,
	"define viewer: [user, team#member]",
	"define viewer: [user, team#member] or editor", 1)

var dispatchTuples = []*openfgav1.TupleKey{
	tk("doc:d1", "editor", "user:anne"),
	tk("doc:d2", "viewer", "user:bob"),
	tk("doc:d3", "viewer", "team:t1#member"),
	tk("team:t1", "member", "user:carl"),
	tk("group:g1", "member", "group:g2#member"),
	tk("group:g2", "member", "user:carl"),
	{
		Object: "doc:d4", Relation: "gated", User: "group:g1#member",
		Condition: &openfgav1.RelationshipCondition{Name: "ok"},
	},
}

// dispatchStore is a store holding both dispatch models and the
// tuples, opted in (or not) after the second model is written.
type dispatchStore struct {
	id, m1, m2, schema string
	ids                *uuidmap.Map
}

func newDispatchStore(t *testing.T, optIn bool) dispatchStore {
	t.Helper()
	client := compiledEngine(t)
	storeID, m1 := setup(t, client, dispatchDSLv1, dispatchTuples)
	t.Cleanup(func() {
		_ = client.DeleteStore(context.Background(), storeID)
	})
	_, m2 := setupModel(t, client, storeID, dispatchDSLv2)
	s := dispatchStore{id: storeID, m1: m1, m2: m2,
		ids: uuidmap.New("compiled/" + t.Name())}
	if optIn {
		s.schema = optInCountable(t, storeID)
	}
	return s
}

// optInCountable opts a store in to a fresh schema whose functions
// callCounts can see (countable), and opts it out again when the
// test ends so no opted-in store outlives it.
func optInCountable(t *testing.T, storeID string) string {
	t.Helper()
	schema := compiledSchema(t)
	enableCompiled(t, storeID, schema)
	t.Cleanup(func() {
		_, _ = testdb.Pool(t).Exec(context.Background(),
			"SELECT fga.disable_compiled_relations($1)", storeID)
	})
	countable(t, schema)
	return schema
}

// countable gives every function in schema a SET clause. A
// generated function the planner inlines into the calling query
// never shows up in the call counters, and an inlined __objects is
// what dispatch runs; with the clause it is called as itself, so
// callCounts sees exactly the registered functions dispatch chose.
func countable(t *testing.T, schema string) {
	t.Helper()
	_, err := testdb.Pool(t).Exec(context.Background(), `
		DO $$
		DECLARE f regprocedure;
		BEGIN
		  FOR f IN SELECT p.oid FROM pg_proc p
		    JOIN pg_namespace n ON n.oid = p.pronamespace
		    WHERE n.nspname = '`+schema+`'
		  LOOP
		    EXECUTE format('ALTER FUNCTION %s SET work_mem = %L',
		      f, current_setting('work_mem'));
		  END LOOP;
		END $$`)
	if err != nil {
		t.Fatal(err)
	}
}

func (s dispatchStore) ref(typ, id string) string {
	typ, rel, _ := strings.Cut(typ, "#")
	out := typ + ":" + s.ids.ID(id)
	if rel != "" {
		out += "#" + rel
	}
	return out
}

// generated sums the calls into functions of the store's schema.
func (s dispatchStore) generated(counts map[string]int64) int64 {
	var n int64
	for name, c := range counts {
		if s.schema != "" && strings.HasPrefix(name, s.schema+".") {
			n += c
		}
		if s.schema == "" && strings.HasPrefix(name, "fgac_") {
			n += c
		}
	}
	return n
}

// check runs fga.check with call counting and returns the answer.
func (s dispatchStore) check(
	t *testing.T, req map[string]any,
) (bool, map[string]int64) {
	t.Helper()
	b := jsonArg(t, req)
	var allowed bool
	err := testdb.Pool(t).QueryRow(context.Background(),
		`SELECT (fga.check($1, $2) ->> 'allowed')::boolean`,
		s.id, b).Scan(&allowed)
	if err != nil {
		t.Fatalf("check %s: %v", b, err)
	}
	return allowed, callCounts(t,
		`SELECT fga.check($1, $2)`, s.id, b)
}

func checkReq(object, relation, user string) map[string]any {
	return map[string]any{"tuple_key": map[string]string{
		"object": object, "relation": relation, "user": user,
	}}
}

// fga.check, batch_check, list_objects and streamed_list_objects
// answer an opted-in store's latest model through its generated
// functions, and only those: a pinned older model, a store not
// opted in, a delegated relation (whose generated function calls
// fga.check) and list_users stay on the generic resolver.
//
// Mutations: drop model_id from the registry lookup and the pinned
// request is answered by the latest model's function (true where
// the first model says false); dispatch delegated rows, or drop
// the guard that keeps a generated function's hand-off to the
// generic resolver generic, and the delegated or contextual
// recursive case recurses until the stack limit.
func TestCompiledDispatch(t *testing.T) {
	s := newDispatchStore(t, true)
	plain := newDispatchStore(t, false)
	for rel, want := range map[string]string{
		"doc#viewer": "flattened", "group#member": "recursive",
		"doc#gated": "delegated",
	} {
		typ, r, _ := strings.Cut(rel, "#")
		got, _, _ := strings.Cut(strategyOf(t, s.id, typ, r), " ")
		if got != want {
			t.Fatalf("%s strategy %q, want %q (the cases below "+
				"rely on it)", rel, got, want)
		}
	}

	t.Run("check", func(t *testing.T) {
		cases := []struct {
			name      string
			store     dispatchStore
			model     string // "", "m1" or "m2"
			object    string
			rel, user string
			ctxTuples []*openfgav1.TupleKey
			context   map[string]any
			want      bool
			compiled  bool
		}{
			{name: "allow", store: s, object: "d1", rel: "viewer",
				user: "user:anne", want: true, compiled: true},
			{name: "deny", store: s, object: "d1", rel: "viewer",
				user: "user:bob", want: false, compiled: true},
			{name: "userset", store: s, object: "d3", rel: "viewer",
				user: "user:carl", want: true, compiled: true},
			{name: "explicit latest", store: s, model: "m2",
				object: "d1", rel: "viewer", user: "user:anne",
				want: true, compiled: true},
			{name: "pinned older", store: s, model: "m1",
				object: "d1", rel: "viewer", user: "user:anne",
				want: false},
			{name: "not opted in", store: plain, object: "d1",
				rel: "viewer", user: "user:anne", want: true},
			{name: "delegated", store: s, object: "d4",
				rel: "gated", user: "user:carl",
				context: map[string]any{"flag": true}, want: true},
			{name: "recursive with contextual tuples", store: s,
				object: "g2", rel: "member", user: "user:dan",
				ctxTuples: []*openfgav1.TupleKey{
					tk("group:g2", "member", "user:dan")},
				want: true, compiled: true},
		}
		for _, c := range cases {
			t.Run(c.name, func(t *testing.T) {
				st := c.store
				typ := "doc"
				if c.rel == "member" {
					typ = "group"
				}
				ut, uid, _ := strings.Cut(c.user, ":")
				req := checkReq(st.ref(typ, c.object), c.rel,
					st.ref(ut, uid))
				switch c.model {
				case "m1":
					req["authorization_model_id"] = st.m1
				case "m2":
					req["authorization_model_id"] = st.m2
				}
				if c.context != nil {
					req["context"] = c.context
				}
				if c.ctxTuples != nil {
					var keys []map[string]string
					for _, k := range c.ctxTuples {
						ot, oid, _ := strings.Cut(k.GetObject(), ":")
						kt, kid, _ := strings.Cut(k.GetUser(), ":")
						keys = append(keys, map[string]string{
							"object":   st.ref(ot, oid),
							"relation": k.GetRelation(),
							"user":     st.ref(kt, kid),
						})
					}
					req["contextual_tuples"] =
						map[string]any{"tuple_keys": keys}
				}
				got, counts := st.check(t, req)
				if got != c.want {
					t.Errorf("allowed = %v, want %v", got, c.want)
				}
				gen := st.generated(counts)
				if c.compiled && gen < 1 {
					t.Errorf("no generated function called: %v",
						counts)
				}
				if !c.compiled && gen != 0 {
					t.Errorf("%d generated calls, want 0: %v",
						gen, counts)
				}
				if c.compiled && c.ctxTuples == nil &&
					counts["fga._check_node"] != 0 {
					t.Errorf("generic resolver called %d times: %v",
						counts["fga._check_node"], counts)
				}
			})
		}
	})

	t.Run("batch_check", func(t *testing.T) {
		b := jsonArg(t, map[string]any{"checks": []map[string]any{{
			"correlation_id": "a",
			"tuple_key": map[string]string{
				"object": s.ref("doc", "d1"), "relation": "viewer",
				"user": s.ref("user", "anne"),
			},
		}}})
		var allowed bool
		err := testdb.Pool(t).QueryRow(context.Background(), `
			SELECT (fga.batch_check($1, $2)
			        -> 'result' -> 'a' ->> 'allowed')::boolean`,
			s.id, b).Scan(&allowed)
		if err != nil {
			t.Fatal(err)
		}
		if !allowed {
			t.Error("batch_check denied anne viewer on d1")
		}
		counts := callCounts(t,
			"SELECT fga.batch_check($1, $2)", s.id, b)
		if s.generated(counts) < 1 ||
			counts["fga._check_node"] != 0 {
			t.Errorf("batch_check not dispatched: %v", counts)
		}
	})

	lists := []struct {
		name     string
		store    dispatchStore
		model    string
		user     string
		want     string // the one object, or "" for none
		compiled bool
	}{
		{"opted in", s, "", "carl", "d3", true},
		{"explicit latest", s, s.m2, "anne", "d1", true},
		{"pinned older", s, s.m1, "anne", "", false},
		{"not opted in", plain, "", "carl", "d3", false},
	}
	for _, l := range []struct{ name, stmt string }{
		{"list_objects", `SELECT jsonb_array_elements_text(
		   fga.list_objects($1, $2) -> 'objects')`},
		{"streamed_list_objects", `SELECT o ->> 'object'
		   FROM fga.streamed_list_objects($1, $2) AS o`},
	} {
		for _, c := range lists {
			t.Run(l.name+"/"+c.name, func(t *testing.T) {
				st := c.store
				req := map[string]any{
					"type": "doc", "relation": "viewer",
					"user": st.ref("user", c.user),
				}
				if c.model != "" {
					req["authorization_model_id"] = c.model
				}
				b := jsonArg(t, req)
				var got []string
				rows, err := testdb.Pool(t).Query(
					context.Background(), l.stmt, st.id, b)
				if err != nil {
					t.Fatal(err)
				}
				for rows.Next() {
					var o string
					if err := rows.Scan(&o); err != nil {
						t.Fatal(err)
					}
					got = append(got, o)
				}
				rows.Close()
				var want []string
				if c.want != "" {
					want = []string{st.ref("doc", c.want)}
				}
				if strings.Join(got, ",") != strings.Join(want, ",") {
					t.Errorf("objects %v, want %v", got, want)
				}
				gen := st.generated(callCounts(t, l.stmt, st.id, b))
				if c.compiled && gen < 1 {
					t.Error("no generated function called")
				}
				if !c.compiled && gen != 0 {
					t.Errorf("%d generated calls, want 0", gen)
				}
			})
		}
	}

	t.Run("list_users", func(t *testing.T) {
		b := jsonArg(t, map[string]any{
			"object": map[string]string{
				"type": "doc", "id": s.ids.ID("d3"),
			},
			"relation":     "viewer",
			"user_filters": []map[string]string{{"type": "user"}},
		})
		counts := callCounts(t,
			"SELECT fga.list_users($1, $2)", s.id, b)
		if gen := s.generated(counts); gen != 0 {
			t.Errorf("list_users made %d generated calls: %v",
				gen, counts)
		}
	})
}

// The dispatched list_objects keeps the unary function's cap, and
// the streamed one stays uncapped. Mutation: skip the cap on the
// dispatched path and the unary call answers 1,005.
func TestCompiledDispatchListCap(t *testing.T) {
	const dsl = `model
  schema 1.1
type user
type doc
  relations
    define viewer: [user]`
	const n = 1005
	tuples := make([]*openfgav1.TupleKey, 0, n)
	for i := range n {
		tuples = append(tuples,
			tk(fmt.Sprintf("doc:d%d", i), "viewer", "user:anne"))
	}
	client := compiledEngine(t)
	storeID, _ := setup(t, client, dsl, tuples)
	t.Cleanup(func() {
		_ = client.DeleteStore(context.Background(), storeID)
	})
	schema := optInCountable(t, storeID)
	ids := uuidmap.New("compiled/" + t.Name())
	req := jsonArg(t, map[string]any{
		"type": "doc", "relation": "viewer",
		"user": "user:" + ids.ID("anne"),
	})

	for _, c := range []struct {
		name, stmt string
		want       int
	}{
		{"list_objects", `SELECT jsonb_array_length(
		   fga.list_objects($1, $2) -> 'objects')`, 1000},
		{"streamed_list_objects", `SELECT count(*)::int
		   FROM fga.streamed_list_objects($1, $2)`, n},
	} {
		if got := queryInt(t, c.stmt, storeID, req); got != c.want {
			t.Errorf("%s: %d objects, want %d", c.name, got, c.want)
		}
		counts := callCounts(t, c.stmt, storeID, req)
		if counts[schema+".doc__viewer__objects"] < 1 {
			t.Errorf("%s not dispatched: %v", c.name, counts)
		}
	}
}

// Past the cap, list_objects tolerates condition errors (the
// generic search's contract): the dispatched call answers the
// capped list where the generated function, which fails on any
// condition error it meets, would refuse. The streamed call has no
// cap, so it refuses on both paths.
func TestCompiledDispatchCapToleratesErrors(t *testing.T) {
	const dsl = `model
  schema 1.1
type user
type doc
  relations
    define viewer: [user, user with ok]
condition ok(flag: bool) {
  flag
}`
	const n = 1005
	var tuples []*openfgav1.TupleKey
	for i := range n {
		tuples = append(tuples,
			tk(fmt.Sprintf("doc:d%d", i), "viewer", "user:anne"),
			&openfgav1.TupleKey{
				Object:   fmt.Sprintf("doc:e%d", i),
				Relation: "viewer", User: "user:anne",
				Condition: &openfgav1.RelationshipCondition{
					Name: "ok"},
			})
	}
	client := compiledEngine(t)
	storeID, _ := setup(t, client, dsl, tuples)
	t.Cleanup(func() {
		_ = client.DeleteStore(context.Background(), storeID)
	})
	ids := uuidmap.New("compiled/" + t.Name())
	req := jsonArg(t, map[string]any{
		"type": "doc", "relation": "viewer",
		"user": "user:" + ids.ID("anne"),
	})
	const unary = `SELECT jsonb_array_length(
	  fga.list_objects($1, $2) -> 'objects')`
	const streamed = `SELECT count(*)::int
	  FROM fga.streamed_list_objects($1, $2)`

	answers := func() (int, string) {
		got := queryInt(t, unary, storeID, req)
		var n int
		err := testdb.Pool(t).QueryRow(context.Background(),
			streamed, storeID, req).Scan(&n)
		return got, sqlState(err)
	}
	genericN, genericState := answers()
	optInCountable(t, storeID)
	if got := strategyOf(t, storeID, "doc", "viewer"); got !=
		"conditioned" {
		t.Fatalf("doc#viewer strategy %q, want conditioned", got)
	}
	gotN, gotState := answers()
	if genericN != 1000 || gotN != genericN {
		t.Errorf("list_objects: generic %d, dispatched %d; "+
			"want 1000 both", genericN, gotN)
	}
	if genericState == "" || gotState != genericState {
		t.Errorf("streamed: generic %q, dispatched %q; want the "+
			"same refusal", genericState, gotState)
	}
}
