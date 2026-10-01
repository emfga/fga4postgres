package conformance

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// ladderDSL is a four-level tenant hierarchy whose permissions are
// ladders of computed usersets and `x from parent`: the shape where
// a relation composed from other relations' generated functions
// re-plans the same callee once per path to it, and dedups once per
// composed UNION.
const ladderDSL = `model
  schema 1.1
type user
type team
  relations
    define member: [user]
type platform
  relations
    define admin: [user]
    define support: [user] or admin
    define auditor: [user, user:*] or support
type account
  relations
    define parent: [platform]
    define owner: [user] or admin from parent
    define admin: [user, team#member] or owner
    define maintainer: [user] or admin or support from parent
    define writer: [user] or maintainer
    define reader: [user] or writer or auditor from parent
type project
  relations
    define parent: [account]
    define admin: [user] or admin from parent
    define maintainer: [user] or admin or maintainer from parent
    define writer: [user] or maintainer or writer from parent
    define reader: [user] or writer or reader from parent
type environment
  relations
    define parent: [project]
    define admin: [user] or admin from parent
    define maintainer: [user] or admin or maintainer from parent
    define writer: [user] or maintainer or writer from parent
    define reader: [user] or writer or reader from parent
    define can_view: reader
    define can_edit: writer
`

func ladderTuples() []*openfgav1.TupleKey {
	return []*openfgav1.TupleKey{
		tk("account:a1", "parent", "platform:p"),
		tk("account:a2", "parent", "platform:p"),
		tk("project:j1", "parent", "account:a1"),
		tk("project:j2", "parent", "account:a1"),
		tk("project:j3", "parent", "account:a2"),
		tk("environment:e1", "parent", "project:j1"),
		tk("environment:e2", "parent", "project:j1"),
		tk("environment:e3", "parent", "project:j2"),
		tk("environment:e4", "parent", "project:j3"),
		tk("platform:p", "admin", "user:padmin"),
		tk("platform:p", "support", "user:sup"),
		tk("account:a1", "admin", "user:aadmin"),
		tk("account:a2", "admin", "team:t1#member"),
		tk("team:t1", "member", "user:tm"),
		tk("project:j1", "writer", "user:pw"),
		tk("environment:e4", "reader", "user:er"),
		tk("environment:e1", "maintainer", "user:er"),
	}
}

// dedupNode matches a plan node that removes duplicates.
var dedupNode = regexp.MustCompile(
	`^\s*(->\s+)?(Unique|HashAggregate|MixedAggregate|` +
		`GroupAggregate|HashSetOp|SetOp)\b`)

// A flattened relation inlines the whole ladder it reaches into its
// own body: no call to another relation's generated function, so the
// planner parses one body instead of one per path through the
// ladder, and the set passes a single dedup instead of one per
// composed UNION.
func TestCompiledPlanShape(t *testing.T) {
	ctx := context.Background()
	pool := testdb.Pool(t)
	client := compiledEngine(t)
	ids := uuidmap.New("compiled/" + t.Name())
	storeID, _ := setup(t, client, ladderDSL, ladderTuples())
	t.Cleanup(func() { _ = client.DeleteStore(ctx, storeID) })
	schema := compiledSchema(t)
	enableCompiled(t, storeID, schema)

	for _, f := range registeredFns(t, storeID) {
		key := f.typeName + "#" + f.relation + "/" + f.kind
		if f.strategy != "flattened" {
			t.Errorf("%s: strategy %s, want flattened", key,
				f.strategy)
			continue
		}
		var src string
		err := pool.QueryRow(ctx,
			"SELECT prosrc FROM pg_proc WHERE oid = $1",
			f.oid).Scan(&src)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(src, schema+".") {
			t.Errorf("%s: body calls another generated function",
				key)
		}
		// A check never inlines; a second statement makes the
		// planner give up before analysing the body.
		if f.kind == "check" && !strings.HasPrefix(src, "SELECT;\n") {
			t.Errorf("%s: check body is a single statement", key)
		}
	}

	for _, q := range []string{
		fmt.Sprintf("SELECT x FROM %s.environment__can_view__objects("+
			"'user', '%s') x", schema, ids.ID("padmin")),
		fmt.Sprintf("SELECT x FROM %s.environment__can_view__subjects("+
			"'%s', 'user') x", schema, ids.ID("e1")),
	} {
		plan := explain(t, q)
		dedups := 0
		for _, line := range strings.Split(plan, "\n") {
			if dedupNode.MatchString(line) {
				dedups++
			}
		}
		if dedups > 1 || strings.Contains(plan, "Function Scan") {
			t.Errorf("%s: %d dedup nodes (want at most 1), "+
				"function scan %v:\n%s", q, dedups,
				strings.Contains(plan, "Function Scan"), plan)
		}
	}
}

// Every generated function of the ladder answers like the generic
// resolver, for every subject and object of the fixture.
func TestCompiledLadderAgreement(t *testing.T) {
	ctx := context.Background()
	client := compiledEngine(t)
	ids := uuidmap.New("compiled/" + t.Name())
	storeID, modelID := setup(t, client, ladderDSL, ladderTuples())
	t.Cleanup(func() { _ = client.DeleteStore(ctx, storeID) })
	schema := compiledSchema(t)
	enableCompiled(t, storeID, schema)

	objects := map[string][]string{
		"platform":    {"p"},
		"account":     {"a1", "a2"},
		"project":     {"j1", "j2", "j3"},
		"environment": {"e1", "e2", "e3", "e4"},
		"team":        {"t1"},
	}
	users := []string{"padmin", "sup", "aadmin", "tm", "pw", "er",
		"nobody"}
	// agree runs the compiled query with args, and the generic one
	// with args followed by the store, model, type and relation.
	agree := func(f compiledFn, label, got, want string, args ...any) {
		t.Helper()
		var g, w string
		pool := testdb.Pool(t)
		if err := pool.QueryRow(ctx, got, args...).Scan(&g); err != nil {
			t.Fatalf("%s: %v", label, err)
		}
		gen := append(args, storeID, modelID, f.typeName, f.relation)
		if err := pool.QueryRow(ctx, want, gen...).Scan(&w); err != nil {
			t.Fatalf("%s (generic): %v", label, err)
		}
		if g != w {
			t.Errorf("%s: compiled %s, generic %s", label, g, w)
		}
	}
	const set = "SELECT coalesce(string_agg(x::text, ',' ORDER BY x), '') "
	for _, f := range registeredFns(t, storeID) {
		rel := f.typeName + "#" + f.relation
		switch f.kind {
		case "objects":
			for _, u := range users {
				agree(f, rel+" objects "+u,
					set+"FROM "+f.call+"('user', $1::uuid) x",
					set+"FROM fga._compiled_objects($2::uuid, "+
						"$3::uuid, $4, $5, 'user', $1::uuid, '', "+
						"false, '{}', '[]') x",
					ids.ID(u))
			}
			agree(f, rel+" objects any",
				set+"FROM "+f.call+"('user', NULL, "+
					"p_any_subject => true) x",
				set+"FROM fga._compiled_objects($1::uuid, $2::uuid, "+
					"$3, $4, 'user', NULL, '', true, '{}', '[]') x")
		case "subjects":
			for _, o := range objects[f.typeName] {
				agree(f, rel+" subjects "+o,
					set+"FROM "+f.call+"($1::uuid, 'user') x",
					set+"FROM fga._compiled_subjects($2::uuid, "+
						"$3::uuid, $4, $5, $1::uuid, 'user', '', "+
						"'{}', '[]') x",
					ids.ID(o))
			}
		case "check":
			for _, o := range objects[f.typeName] {
				for _, u := range users {
					agree(f, rel+" check "+o+" "+u,
						"SELECT "+f.call+"($1::uuid, 'user', "+
							"$2::uuid)::text",
						"SELECT fga._compiled_check($3::uuid, $4::uuid, "+
							"$5, $6, $1::uuid, 'user', $2::uuid, '', "+
							"false, '{}', '[]')::text",
						ids.ID(o), ids.ID(u))
				}
			}
		}
	}
}
