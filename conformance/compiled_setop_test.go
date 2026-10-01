package conformance

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// setopDSL exercises the set-operation strategy: exclusion with a
// wildcard on both sides and a userset on the subtract side,
// intersection over a tuple-to-userset, and both nested inside
// each other.
const setopDSL = `model
  schema 1.1
type user
type group
  relations
    define member: [user]
type folder
  relations
    define viewer: [user]
type doc
  relations
    define parent: [folder]
    define allowed: [user]
    define blocked: [user, user:*, group#member]
    define viewer: [user, user:*] but not blocked
    define reader: ([user] or viewer from parent) and allowed
    define nested: (viewer or reader) but not (allowed and blocked)
    define either: viewer or reader
`

func setopTuples() []*openfgav1.TupleKey {
	return []*openfgav1.TupleKey{
		tk("group:g1", "member", "user:bob"),
		tk("doc:d1", "viewer", "user:anne"),
		tk("doc:d1", "viewer", "user:bob"),
		tk("doc:d1", "blocked", "group:g1#member"),
		tk("doc:d2", "viewer", "user:*"),
		tk("doc:d2", "blocked", "user:carl"),
		tk("doc:d3", "viewer", "user:anne"),
		tk("doc:d3", "blocked", "user:*"),
		tk("folder:f1", "viewer", "user:dave"),
		tk("folder:f1", "viewer", "user:erin"),
		tk("doc:d1", "parent", "folder:f1"),
		tk("doc:d4", "parent", "folder:f1"),
		tk("doc:d4", "allowed", "user:dave"),
		tk("doc:d4", "reader", "user:erin"),
		tk("doc:d1", "allowed", "user:anne"),
		tk("doc:d1", "allowed", "user:erin"),
		tk("doc:d2", "allowed", "user:bob"),
		tk("doc:d2", "blocked", "user:bob"),
	}
}

var (
	diffUsers = []string{"anne", "bob", "carl", "dave", "erin"}
	diffDocs  = []string{"d1", "d2", "d3", "d4"}
)

// sourcedStore writes a model and tuples into a fresh store, opts
// it in with a subject source for user (so a wildcard expands into
// a final list) and returns the store, model, schema and id map.
func sourcedStore(
	t *testing.T, dsl string, tuples []*openfgav1.TupleKey,
) (storeID, modelID, schema string, ids *uuidmap.Map) {
	t.Helper()
	ctx := context.Background()
	client := compiledEngine(t)
	ids = uuidmap.New("compiled/" + t.Name())
	storeID, modelID = setup(t, client, dsl, tuples)
	t.Cleanup(func() { _ = client.DeleteStore(ctx, storeID) })
	schema = compiledSchema(t)
	pool := testdb.Pool(t)
	_, err := pool.Exec(ctx, fmt.Sprintf(
		"CREATE TABLE %s.people (id uuid)", schema))
	if err != nil {
		t.Fatal(err)
	}
	for _, u := range diffUsers {
		_, err := pool.Exec(ctx, fmt.Sprintf(
			"INSERT INTO %s.people VALUES ($1)", schema), ids.ID(u))
		if err != nil {
			t.Fatal(err)
		}
	}
	_, err = pool.Exec(ctx,
		"SELECT fga.enable_compiled_relations($1, $2, $3)",
		storeID, schema,
		fmt.Sprintf(`{"user": "%s.people(id)"}`, schema))
	if err != nil {
		t.Fatalf("enable_compiled_relations: %v", err)
	}
	return storeID, modelID, schema, ids
}

// strategyOf reads the registry's strategy for one relation.
func strategyOf(t *testing.T, storeID, typ, rel string) string {
	t.Helper()
	var s string
	err := testdb.Pool(t).QueryRow(context.Background(), `
		SELECT strategy || coalesce(' (' || reason || ')', '')
		FROM fga.compiled_relation
		WHERE store = $1 AND type_name = $2 AND relation_name = $3`,
		storeID, typ, rel).Scan(&s)
	if err != nil {
		t.Fatalf("%s#%s: %v", typ, rel, err)
	}
	return s
}

// rowQuerier is a pool or one connection.
type rowQuerier interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

// answer runs one query and renders its single text value, or the
// SQLSTATE it failed with, so answers and refusals compare alike.
func answer(t *testing.T, q string, args ...any) string {
	t.Helper()
	return answerOn(t, testdb.Pool(t), q, args...)
}

func answerOn(
	t *testing.T, db rowQuerier, q string, args ...any,
) string {
	t.Helper()
	var v *string
	err := db.QueryRow(context.Background(), q, args...).Scan(&v)
	if err != nil {
		if s := sqlState(err); s != "" {
			return "error " + s
		}
		t.Fatalf("%s: %v", q, err)
	}
	if v == nil {
		return "null"
	}
	return *v
}

// diffRelation compares the generated functions of one doc
// relation with the generic resolver that a delegated relation
// calls (fga._compiled_check / _objects / _subjects), for every
// doc, every user, the "any user" question, and each given request
// context and contextual-tuple list: the same answer or the same
// SQLSTATE. Returns the number of comparisons made.
func diffRelation(
	t *testing.T, storeID, modelID, schema string, ids *uuidmap.Map,
	rel string, contexts, ctuples []string,
) int {
	t.Helper()
	return diffRelationOn(t, testdb.Pool(t), storeID, modelID, schema,
		ids, rel, contexts, ctuples)
}

// diffRelationOn is diffRelation on a given pool or connection.
func diffRelationOn(
	t *testing.T, db rowQuerier, storeID, modelID, schema string,
	ids *uuidmap.Map, rel string, contexts, ctuples []string,
) int {
	t.Helper()
	answer := func(t *testing.T, q string, args ...any) string {
		t.Helper()
		return answerOn(t, db, q, args...)
	}
	fn := func(kind string) string {
		return schema + "." + answer(t,
			"SELECT fga._compiled_name('doc', $1, $2)", rel, kind)
	}
	checkFn, objectsFn, subjectsFn :=
		fn("check"), fn("objects"), fn("subjects")
	const agg = "SELECT coalesce(string_agg(x::text, ',' " +
		"ORDER BY x::text), '') FROM "
	n := 0
	compare := func(label, got, want string) {
		n++
		if got != want {
			t.Errorf("doc#%s %s: compiled %q, generic %q",
				rel, label, got, want)
		}
	}
	for _, c := range contexts {
		for _, ct := range ctuples {
			at := fmt.Sprintf("[ctx %s, tuples %s]", c, ct)
			for _, u := range append(diffUsers, "*") {
				var sid any
				anyUser := u == "*"
				if !anyUser {
					sid = ids.ID(u)
				}
				compare("objects "+u+" "+at,
					answer(t, agg+objectsFn+"('user', $1::uuid, '', "+
						"$2, $3::jsonb, $4::jsonb) x",
						sid, anyUser, c, ct),
					answer(t, agg+"fga._compiled_objects($1::uuid, "+
						"$2::uuid, 'doc', $3, 'user', $4::uuid, '', $5, "+
						"$6::jsonb, $7::jsonb) x",
						storeID, modelID, rel, sid, anyUser, c, ct))
				for _, d := range diffDocs {
					compare("check "+d+" "+u+" "+at,
						answer(t, "SELECT "+checkFn+"($1::uuid, 'user', "+
							"$2::uuid, '', $3, $4::jsonb, $5::jsonb)::text",
							ids.ID(d), sid, anyUser, c, ct),
						answer(t, "SELECT fga._compiled_check($1::uuid, "+
							"$2::uuid, 'doc', $3, $4::uuid, 'user', "+
							"$5::uuid, '', $6, $7::jsonb, $8::jsonb)::text",
							storeID, modelID, rel, ids.ID(d), sid, anyUser,
							c, ct))
				}
			}
			for _, d := range diffDocs {
				compare("subjects "+d+" "+at,
					answer(t, agg+subjectsFn+"($1::uuid, 'user', '', "+
						"$2::jsonb, $3::jsonb) x", ids.ID(d), c, ct),
					answer(t, agg+"fga._compiled_subjects($1::uuid, "+
						"$2::uuid, 'doc', $3, $4::uuid, 'user', '', "+
						"$5::jsonb, $6::jsonb) x",
						storeID, modelID, rel, ids.ID(d), c, ct))
			}
		}
	}
	return n
}

// genericCalls counts calls into the generic resolvers while stmt
// runs: a strategy that answers by itself makes none.
func genericCalls(t *testing.T, stmt string, args ...any) int64 {
	t.Helper()
	counts := callCounts(t, stmt, args...)
	var n int64
	for _, f := range []string{"fga._check_node", "fga._list_objects",
		"fga._lu_node", "fga.list_users"} {
		n += counts[f]
	}
	return n
}

// Intersection and exclusion compile to set operations whose
// answers equal the generic resolver's for every question, without
// calling it. Mutation: compile "but not" as a plain union and the
// blocked subjects reappear (bob on d1, carl on d2, anne on d3).
func TestCompiledSetOpStrategy(t *testing.T) {
	storeID, modelID, schema, ids :=
		sourcedStore(t, setopDSL, setopTuples())
	for _, rel := range []string{"viewer", "reader", "nested",
		"either"} {
		want := "setop"
		if rel == "either" {
			want = "flattened"
		}
		if got := strategyOf(t, storeID, "doc", rel); got != want {
			t.Errorf("doc#%s strategy %q, want %q", rel, got, want)
		}
	}
	n := 0
	for _, rel := range []string{"viewer", "reader", "nested",
		"either"} {
		n += diffRelation(t, storeID, modelID, schema, ids, rel,
			[]string{"{}"}, []string{"[]"})
	}
	if n == 0 {
		t.Fatal("no comparisons made")
	}

	// The answers are not vacuous: exclusion removed someone.
	got := answer(t, fmt.Sprintf("SELECT coalesce(string_agg(x::text, "+
		"','), '') FROM %s.doc__viewer__subjects($1::uuid, 'user') x",
		schema), ids.ID("d1"))
	if got != ids.ID("anne") {
		t.Errorf("doc:d1 viewers = %q, want only anne", got)
	}

	for _, q := range []string{
		"SELECT count(*) FROM %s.doc__nested__objects('user', $1::uuid)",
		"SELECT count(*) FROM %s.doc__nested__subjects($1::uuid, 'user')",
		"SELECT %s.doc__nested__check($1::uuid, 'user', $1::uuid)",
	} {
		stmt := fmt.Sprintf(q, schema)
		if c := genericCalls(t, stmt, ids.ID("d1")); c != 0 {
			t.Errorf("%s: %d generic resolver calls, want 0", stmt, c)
		}
	}

	const anyID = "'0199a0a0-0000-7000-8000-000000000001'"
	for _, call := range []string{
		"SELECT x FROM %s.doc__nested__objects('user', " + anyID + ") x",
		"SELECT x FROM %s.doc__nested__subjects(" + anyID + ", 'user') x",
	} {
		call = fmt.Sprintf(call, schema)
		if plan := explain(t, call); strings.Contains(plan,
			"Function Scan") {
			t.Errorf("%s: not inlined:\n%s", call, plan)
		}
	}
}

// A set operation is exact only over operands that never raise and
// never cycle: a cycled false on the subtract side must not turn
// into "not excluded", and an operand that may raise must not raise
// where a sibling's answer swallows the error. Such relations stay
// delegated, whatever strategy their operands get.
func TestCompiledSetOpOperandGuards(t *testing.T) {
	const dsl = `model
  schema 1.1
type user
type team
  relations
    define member: [user, team#member]
type doc
  relations
    define banned: [user, team#member]
    define cond_banned: [user with ok]
    define viewer: [user] but not banned
    define cviewer: [user] but not cond_banned
    define both: [user] and cond_banned
condition ok(x: int) {
  x < 10
}
`
	storeID, _, _, _ := sourcedStore(t, dsl, nil)
	for _, rel := range []string{"viewer", "cviewer", "both"} {
		got := strategyOf(t, storeID, "doc", rel)
		if !strings.HasPrefix(got, "delegated") {
			t.Errorf("doc#%s strategy %q, want delegated", rel, got)
		}
	}
}

// Generated bodies run under the caller's search_path (decision
// 21): a schema ahead of pg_catalog holding a table named tuple
// with extra grants and always-true / never-true uuid operators
// must not change one answer of the set-operation and conditioned
// strategies, contextual tuples included.
func TestCompiledStrategiesSearchPathIndependent(t *testing.T) {
	for _, c := range []struct {
		name     string
		dsl      string
		tuples   []*openfgav1.TupleKey
		rels     []string
		contexts []string
	}{
		{"setop", setopDSL, setopTuples(),
			[]string{"viewer", "reader", "nested"}, []string{"{}"}},
		{"conditioned", compiledCondDSL, compiledCondTuples(),
			[]string{"viewer", "editor"}, []string{`{"x": 3}`}},
	} {
		t.Run(c.name, func(t *testing.T) {
			ctx := context.Background()
			storeID, modelID, schema, ids :=
				sourcedStore(t, c.dsl, c.tuples)
			pool := testdb.Pool(t)
			decoy := schema + "_decoy"
			_, err := pool.Exec(ctx, fmt.Sprintf(`
				DROP SCHEMA IF EXISTS %[1]s CASCADE;
				CREATE SCHEMA %[1]s;
				CREATE TABLE %[1]s.tuple (LIKE fga.tuple);
				INSERT INTO %[1]s.tuple SELECT * FROM fga.tuple
				  WHERE store = '%[2]s';
				INSERT INTO %[1]s.tuple
				  SELECT store, 'doc', object_id, relation, 'user',
				         '%[3]s', '', NULL, NULL, ulid || 'x', now()
				  FROM fga.tuple WHERE store = '%[2]s'
				    AND object_type = 'doc';
				CREATE FUNCTION %[1]s.always(uuid, uuid)
				  RETURNS boolean LANGUAGE sql IMMUTABLE
				  AS 'SELECT true';
				CREATE OPERATOR %[1]s.= (
				  LEFTARG = uuid, RIGHTARG = uuid,
				  FUNCTION = %[1]s.always);
				CREATE FUNCTION %[1]s.never(uuid, uuid)
				  RETURNS boolean LANGUAGE sql IMMUTABLE
				  AS 'SELECT false';
				CREATE OPERATOR %[1]s.<> (
				  LEFTARG = uuid, RIGHTARG = uuid,
				  FUNCTION = %[1]s.never)`,
				decoy, storeID, ids.ID("erin")))
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				_, _ = pool.Exec(context.Background(),
					"DROP SCHEMA IF EXISTS "+decoy+" CASCADE")
			})
			conn, err := pool.Acquire(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Release()
			_, err = conn.Exec(ctx, fmt.Sprintf(
				"SET search_path = %s, pg_catalog, fga, public", decoy))
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _, _ = conn.Exec(ctx, "RESET search_path") }()

			ctuples := []string{"[]", ctxTuplesJSON(ids,
				map[string]any{"object": "doc:d4", "relation": "viewer",
					"user": "user:anne"})}
			for _, rel := range c.rels {
				diffRelationOn(t, conn, storeID, modelID, schema, ids,
					rel, c.contexts, ctuples)
			}
		})
	}
}
