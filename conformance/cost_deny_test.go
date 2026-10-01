package conformance

import (
	"encoding/json"
	"fmt"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// denyHierarchyDSL is a folder tree where viewer is granted
// directly or inherited from the parent. Its restriction for viewer
// is the only thing the subtests vary: plain users only, plus a
// group userset, or plus a user wildcard.
func denyHierarchyDSL(viewerTypes string) string {
	return `model
  schema 1.1
type user
type group
  relations
    define member: [user]
type folder
  relations
    define parent: [folder]
    define viewer: [` + viewerTypes + `] or viewer from parent
`
}

// denyCounts writes a parent chain folder:f0..f<depth>, grants
// user:bob on the root, and returns the per-function call counts
// of user:anne's denied check on the deepest folder.
func denyCounts(
	t *testing.T, viewerTypes string, depth int,
) map[string]int64 {
	t.Helper()
	ids := uuidmap.New("cost/" + t.Name())
	client := sqlclient.New(testdb.Pool(t), ids)
	tuples := []*openfgav1.TupleKey{
		tk("folder:f0", "viewer", "user:bob"),
	}
	for i := 1; i <= depth; i++ {
		tuples = append(tuples, tk(
			fmt.Sprintf("folder:f%d", i), "parent",
			fmt.Sprintf("folder:f%d", i-1),
		))
	}
	store, model := setup(t, client, denyHierarchyDSL(viewerTypes),
		tuples)

	req, err := json.Marshal(map[string]any{
		"authorization_model_id": model,
		"tuple_key": map[string]string{
			"object":   "folder:" + ids.ID(fmt.Sprintf("f%d", depth)),
			"relation": "viewer",
			"user":     "user:" + ids.ID("anne"),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	var allowed bool
	err = testdb.Pool(t).QueryRow(t.Context(),
		"SELECT (fga.check($1, $2) ->> 'allowed')::boolean",
		store, req).Scan(&allowed)
	if err != nil {
		t.Fatal(err)
	}
	if allowed {
		t.Fatal("anne is allowed; the fixture must deny")
	}
	return callCounts(t, "SELECT fga.check($1, $2)", store, req)
}

// A deny walks every node of the hierarchy, so a read that the
// model can never answer is paid once per node. The model's type
// restrictions say up front which reads can return rows: no
// userset restriction means no userset row exists to read (stored
// rows are filtered by the restrictions, contextual ones are
// refused by them), and no wildcard restriction for the subject's
// type means no wildcard row does.
func TestDenySkipsImpossibleReads(t *testing.T) {
	const depth = 5
	t.Run("plain users only", func(t *testing.T) {
		got := denyCounts(t, "user", depth)
		direct := got["fga._check_direct"]
		if direct != depth+1 {
			t.Fatalf("_check_direct calls = %d, want %d (all: %v)",
				direct, depth+1, got)
		}
		if n := got["fga._read_usersets"]; n != 0 {
			t.Errorf("_read_usersets calls = %d, want 0", n)
		}
		if n := got["fga._read_exact"]; n != direct {
			t.Errorf("_read_exact calls = %d, want %d: the "+
				"wildcard probe ran", n, direct)
		}
	})
	t.Run("userset restriction still reads", func(t *testing.T) {
		got := denyCounts(t, "user, group#member", depth)
		direct := got["fga._check_direct"]
		if n := got["fga._read_usersets"]; n != direct {
			t.Errorf("_read_usersets calls = %d, want %d (all: %v)",
				n, direct, got)
		}
		if n := got["fga._read_exact"]; n != direct {
			t.Errorf("_read_exact calls = %d, want %d", n, direct)
		}
	})
	t.Run("wildcard restriction still probes", func(t *testing.T) {
		got := denyCounts(t, "user, user:*", depth)
		direct := got["fga._check_direct"]
		if n := got["fga._read_exact"]; n != 2*direct {
			t.Errorf("_read_exact calls = %d, want %d (all: %v)",
				n, 2*direct, got)
		}
		if n := got["fga._read_usersets"]; n != 0 {
			t.Errorf("_read_usersets calls = %d, want 0", n)
		}
	})
}

// deepDenyDSL is a four-level tenancy hierarchy where every
// relation is a union of a direct grant, a sibling relation and an
// inherited one, so a deny visits every path to the root.
const deepDenyDSL = `model
  schema 1.1
type user
type platform
  relations
    define admin: [user]
    define support: [user] or admin
type account
  relations
    define platform: [platform]
    define owner: [user] or admin from platform
    define admin: [user] or owner or support from platform
    define member: [user] or admin
type project
  relations
    define account: [account]
    define owner: [user] or admin from account
    define editor: [user] or owner or member from account
    define viewer: [user] or editor
type environment
  relations
    define project: [project]
    define deployer: [user] or editor from project
    define can_read: [user] or deployer or viewer from project
`

// deepDenyTuples links environment:e0 to three projects, each to
// two accounts, each to two platforms, with user:bob granted at
// every level so no read is trivially empty.
func deepDenyTuples() []*openfgav1.TupleKey {
	tuples := []*openfgav1.TupleKey{
		tk("environment:e0", "can_read", "user:bob"),
	}
	for p := range 3 {
		project := fmt.Sprintf("project:p%d", p)
		tuples = append(tuples,
			tk("environment:e0", "project", project),
			tk(project, "viewer", "user:bob"))
		for a := range 2 {
			account := fmt.Sprintf("account:a%d%d", p, a)
			tuples = append(tuples,
				tk(project, "account", account),
				tk(account, "member", "user:bob"))
			for f := range 2 {
				platform := fmt.Sprintf("platform:f%d%d%d", p, a, f)
				tuples = append(tuples,
					tk(account, "platform", platform),
					tk(platform, "admin", "user:bob"))
			}
		}
	}
	return tuples
}

func BenchmarkCheckDeepDeny(b *testing.B) {
	client, store, model := benchSetup(b, deepDenyDSL,
		deepDenyTuples())
	benchCheck(b, client, store, model,
		"environment:e0", "can_read", "user:anne", false, false)
}
