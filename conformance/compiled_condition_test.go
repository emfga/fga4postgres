package conformance

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/protobuf/types/known/structpb"

	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// compiledCondDSL has conditioned grants of every direct kind — plain,
// wildcard, and a relation with no unconditioned grant at all —
// beside unconditioned ones, so errors meet granting siblings.
const compiledCondDSL = `model
  schema 1.1
type user
type doc
  relations
    define owner: [user]
    define viewer: [user, user with small, user:* with small] or owner
    define editor: [user with small]
condition small(x: int, limit: int) {
  x < limit
}
`

// tkc is tk with a condition and its tuple context.
func tkc(
	object, relation, user, cond string, ctx map[string]any,
) *openfgav1.TupleKey {
	s, err := structpb.NewStruct(ctx)
	if err != nil {
		panic(err)
	}
	t := tk(object, relation, user)
	t.Condition = &openfgav1.RelationshipCondition{
		Name: cond, Context: s,
	}
	return t
}

func compiledCondTuples() []*openfgav1.TupleKey {
	return []*openfgav1.TupleKey{
		tkc("doc:d1", "viewer", "user:anne", "small",
			map[string]any{"limit": 10}),
		tk("doc:d1", "viewer", "user:bob"),
		tkc("doc:d2", "viewer", "user:*", "small",
			map[string]any{"limit": 5}),
		tk("doc:d3", "owner", "user:carl"),
		tkc("doc:d3", "viewer", "user:carl", "small",
			map[string]any{"limit": 1}),
		tkc("doc:d1", "editor", "user:anne", "small",
			map[string]any{"limit": 10}),
		tkc("doc:d2", "editor", "user:anne", "small",
			map[string]any{"limit": 1}),
		tkc("doc:d4", "editor", "user:dave", "small",
			map[string]any{}),
	}
}

// ctxTuplesJSON renders contextual tuples the way the generated
// functions take them, ids mapped to the engine's uuids.
func ctxTuplesJSON(ids *uuidmap.Map, keys ...map[string]any) string {
	mapID := func(s string) string {
		typ, rest, _ := strings.Cut(s, ":")
		id, rel, hasRel := strings.Cut(rest, "#")
		if id != "*" {
			id = ids.ID(id)
		}
		if hasRel {
			return typ + ":" + id + "#" + rel
		}
		return typ + ":" + id
	}
	for _, k := range keys {
		k["object"] = mapID(k["object"].(string))
		k["user"] = mapID(k["user"].(string))
	}
	b, err := json.Marshal(keys)
	if err != nil {
		panic(err)
	}
	return string(b)
}

// compiledCondCtxTuples are the contextual-tuple lists every relation is
// compared under: none; a plain grant; a conditioned wildcard; a
// conditioned row with the key of a stored unconditioned one (check
// lets it replace the stored row, the list APIs read both); a tuple
// naming an unknown relation; and one missing the condition its
// restriction requires (check refuses it as an invalid tuple, the
// list APIs as a validation error).
func compiledCondCtxTuples(ids *uuidmap.Map) []string {
	small := func(limit int) map[string]any {
		return map[string]any{"name": "small",
			"context": map[string]any{"limit": limit}}
	}
	return []string{
		"[]",
		ctxTuplesJSON(ids, map[string]any{"object": "doc:d4",
			"relation": "viewer", "user": "user:erin"}),
		ctxTuplesJSON(ids, map[string]any{"object": "doc:d4",
			"relation": "viewer", "user": "user:*",
			"condition": small(100)}),
		ctxTuplesJSON(ids, map[string]any{"object": "doc:d1",
			"relation": "viewer", "user": "user:bob",
			"condition": small(0)}),
		ctxTuplesJSON(ids, map[string]any{"object": "doc:d1",
			"relation": "nope", "user": "user:anne"}),
		ctxTuplesJSON(ids, map[string]any{"object": "doc:d1",
			"relation": "editor", "user": "user:anne"}),
	}
}

// Conditioned grants compile: every answer and every refusal of the
// generated functions equals the generic resolver's — with the
// condition met, unmet, missing a parameter (an error check holds
// back while a sibling grants, and the list APIs raise), and the
// tuple context overriding the request's — and no answer calls the
// generic resolver.
func TestCompiledConditionStrategy(t *testing.T) {
	storeID, modelID, schema, ids :=
		sourcedStore(t, compiledCondDSL, compiledCondTuples())
	for rel, want := range map[string]string{
		"owner": "flattened", "viewer": "conditioned",
		"editor": "conditioned",
	} {
		if got := strategyOf(t, storeID, "doc", rel); got != want {
			t.Errorf("doc#%s strategy %q, want %q", rel, got, want)
		}
	}
	contexts := []string{`{}`, `{"x": 3}`, `{"x": 7}`, `{"x": 20}`,
		`{"x": 3, "limit": 0}`}
	for _, rel := range []string{"viewer", "editor"} {
		diffRelation(t, storeID, modelID, schema, ids, rel,
			contexts, []string{"[]"})
	}

	// Not vacuous: the missing parameter is an error here, and a
	// sibling grant swallows it for check.
	if got := answer(t, fmt.Sprintf("SELECT %s.doc__editor__check("+
		"$1::uuid, 'user', $2::uuid)::text", schema),
		ids.ID("d4"), ids.ID("dave")); got != "error YF100" {
		t.Errorf("doc:d4 editor dave, no context: %s, want YF100",
			got)
	}
	if got := answer(t, fmt.Sprintf("SELECT %s.doc__viewer__check("+
		"$1::uuid, 'user', $2::uuid)::text", schema),
		ids.ID("d3"), ids.ID("carl")); got != "true" {
		t.Errorf("doc:d3 viewer carl, no context: %s, want true", got)
	}

	for _, q := range []string{
		"SELECT count(*) FROM %s.doc__viewer__objects('user', $1::uuid, " +
			"p_context => '{\"x\": 3}')",
		"SELECT count(*) FROM %s.doc__viewer__subjects($1::uuid, " +
			"'user', p_context => '{\"x\": 3}')",
		"SELECT %s.doc__viewer__check($1::uuid, 'user', $1::uuid, " +
			"p_context => '{\"x\": 3}')",
	} {
		stmt := fmt.Sprintf(q, schema)
		if c := genericCalls(t, stmt, ids.ID("d1")); c != 0 {
			t.Errorf("%s: %d generic resolver calls, want 0", stmt, c)
		}
	}
}

// Conditioned bodies keep the inlinable shape: the condition is a
// filter, not a set-returning call.
func TestCompiledConditionInlinable(t *testing.T) {
	_, _, schema, _ := sourcedStore(t, compiledCondDSL,
		compiledCondTuples())
	const anyID = "'0199a0a0-0000-7000-8000-000000000001'"
	for _, call := range []string{
		"SELECT x FROM %s.doc__viewer__objects('user', " + anyID +
			", p_context => '{\"x\": 1}') x",
		"SELECT x FROM %s.doc__viewer__subjects(" + anyID +
			", 'user', p_context => '{\"x\": 1}') x",
	} {
		call = fmt.Sprintf(call, schema)
		if plan := explain(t, call); strings.Contains(plan,
			"Function Scan") {
			t.Errorf("%s: not inlined:\n%s", call, plan)
		}
	}
}

// Contextual tuples are read by the generated functions themselves,
// for every strategy, with the generic resolver's semantics and
// refusals. Mutation: drop the contextual source from the generated
// reads and the grants they carry go missing.
func TestCompiledContextualTuples(t *testing.T) {
	t.Run("conditioned", func(t *testing.T) {
		storeID, modelID, schema, ids :=
			sourcedStore(t, compiledCondDSL, compiledCondTuples())
		ctuples := compiledCondCtxTuples(ids)
		for _, rel := range []string{"owner", "viewer", "editor"} {
			diffRelation(t, storeID, modelID, schema, ids, rel,
				[]string{`{"x": 3}`, `{}`}, ctuples)
		}

		// Not vacuous: the contextual grant is seen.
		got := answer(t, fmt.Sprintf("SELECT %s.doc__viewer__check("+
			"$1::uuid, 'user', $2::uuid, "+
			"p_contextual_tuples => $3)::text", schema),
			ids.ID("d4"), ids.ID("erin"), ctuples[1])
		if got != "true" {
			t.Errorf("doc:d4 viewer erin, contextual grant: %s", got)
		}

		for _, q := range []string{
			"SELECT count(*) FROM %s.doc__viewer__objects('user', " +
				"$1::uuid, p_context => '{\"x\": 3}', " +
				"p_contextual_tuples => $2)",
			"SELECT count(*) FROM %s.doc__viewer__subjects($1::uuid, " +
				"'user', p_context => '{\"x\": 3}', " +
				"p_contextual_tuples => $2)",
			"SELECT %s.doc__viewer__check($1::uuid, 'user', $1::uuid, " +
				"p_context => '{\"x\": 3}', " +
				"p_contextual_tuples => $2)",
		} {
			stmt := fmt.Sprintf(q, schema)
			if c := genericCalls(t, stmt, ids.ID("d4"),
				ctuples[2]); c != 0 {
				t.Errorf("%s: %d generic resolver calls, want 0",
					stmt, c)
			}
		}
	})

	t.Run("setop", func(t *testing.T) {
		storeID, modelID, schema, ids :=
			sourcedStore(t, setopDSL, setopTuples())
		grant := ctxTuplesJSON(ids, map[string]any{"object": "doc:d3",
			"relation": "viewer", "user": "user:carl"})
		block := ctxTuplesJSON(ids, map[string]any{"object": "doc:d2",
			"relation": "blocked", "user": "user:anne"})
		for _, rel := range []string{"viewer", "reader", "nested"} {
			diffRelation(t, storeID, modelID, schema, ids, rel,
				[]string{"{}"}, []string{grant, block})
		}
	})
}
