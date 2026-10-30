package conformance

import (
	"context"
	"sort"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
)

// Nested exclusion over a type-bound public wildcard in
// list_users (GHSA-h7w8-xr72-cv4r, fixed upstream in v1.20.0:
// before it, a user excluded under a wildcard reached through a
// userset leaked back into the result). The engine never leaked;
// these shapes pin the agreement with the fixed oracle, and
// PIN-LU-1 the one shape where the answers differ in form.
const nestedWildcardDSL = `model
  schema 1.1
type user
type group
  relations
    define member: [user, user:*]
type document
  relations
    define everyone: [user:*, group#member]
    define banned: [user, user:*, group#member]
    define suspended: [user]
    define active: [user]
    define n1: (everyone but not banned) but not suspended
    define n2: everyone but not (banned but not suspended)
    define n3: (everyone but not banned) and active
    define n4: ((everyone but not banned) but not suspended) or active
    define n5: everyone but not (everyone but not banned)
`

var nestedWildcardTuples = []*openfgav1.TupleKey{
	tk("document:1", "everyone", "user:*"),
	tk("document:1", "banned", "user:bob"),
	tk("document:1", "suspended", "user:carl"),
	tk("document:1", "suspended", "user:bob"),
	tk("document:1", "active", "user:bob"),
	tk("document:1", "active", "user:dan"),
	tk("document:2", "everyone", "group:g#member"),
	tk("group:g", "member", "user:*"),
	tk("document:2", "banned", "user:bob"),
	tk("document:2", "suspended", "user:carl"),
	tk("document:3", "everyone", "user:*"),
	tk("document:3", "banned", "group:h#member"),
	tk("group:h", "member", "user:*"),
}

func listUsersOn(t *testing.T, c listClient, store, model,
	object, relation string, filter *openfgav1.UserTypeFilter,
) string {
	t.Helper()
	typ, id, _ := strings.Cut(object, ":")
	resp, err := c.ListUsers(context.Background(),
		&openfgav1.ListUsersRequest{
			StoreId: store, AuthorizationModelId: model,
			Object:      &openfgav1.Object{Type: typ, Id: id},
			Relation:    relation,
			UserFilters: []*openfgav1.UserTypeFilter{filter}})
	if err != nil {
		t.Fatalf("list_users %s#%s: %v", object, relation, err)
	}
	var users []string
	for _, u := range resp.GetUsers() {
		users = append(users, userToString(u))
	}
	sort.Strings(users)
	return strings.Join(users, ",")
}

func TestListUsersNestedWildcardExclusion(t *testing.T) {
	users := &openfgav1.UserTypeFilter{Type: "user"}
	groups := &openfgav1.UserTypeFilter{
		Type: "group", Relation: "member"}
	cases := []struct {
		object, relation string
		filter           *openfgav1.UserTypeFilter
		want             string
	}{
		{"document:1", "n1", users, "user:*"},
		{"document:1", "n3", users, "user:dan"},
		{"document:1", "n4", users, "user:*,user:bob,user:dan"},
		{"document:1", "n5", users, "user:bob"},
		// The advisory's shape: the wildcard arrives through a
		// userset, and bob, banned, must not come back.
		{"document:2", "n1", users, "user:*"},
		{"document:2", "n1", groups, "group:g#member"},
		{"document:2", "n4", users, "user:*"},
		{"document:2", "n5", users, "user:bob"},
		{"document:3", "n1", users, ""},
		{"document:3", "n5", users, "user:*"},
	}
	for _, sd := range listSides(t, "lu-nested-wildcard") {
		t.Run(sd.name, func(t *testing.T) {
			store, model := setup(t, sd.client, nestedWildcardDSL,
				nestedWildcardTuples)
			for _, c := range cases {
				got := listUsersOn(t, sd.client, store, model,
					c.object, c.relation, c.filter)
				if got != c.want {
					t.Errorf("%s#%s %v: got [%s], want [%s]",
						c.object, c.relation, c.filter, got, c.want)
				}
			}
		})
	}
}

// PIN-LU-1. A wildcard minus a nested exclusion that removes
// nobody: everyone but not (banned but not suspended), with bob
// both banned and suspended. Upstream lists bob explicitly beside
// user:*; the engine answers user:* alone. Both grant bob (the
// check agrees), so the answers differ in form, not in who has
// access. Measured identically at v1.19.0.
func TestPinnedListUsersRedundantUser(t *testing.T) {
	users := &openfgav1.UserTypeFilter{Type: "user"}
	want := map[string]string{
		"engine": "user:*",
		"oracle": "user:*,user:bob",
	}
	for _, sd := range listSides(t, "pin-lu-redundant") {
		t.Run(sd.name, func(t *testing.T) {
			store, model := setup(t, sd.client, nestedWildcardDSL,
				nestedWildcardTuples)
			got := listUsersOn(t, sd.client, store, model,
				"document:1", "n2", users)
			if got != want[sd.name] {
				t.Errorf("%s side of PIN-LU-1 moved: got [%s], "+
					"want [%s] — update docs/CONFORMANCE.md",
					sd.name, got, want[sd.name])
			}
			r := doCheck(t, sd.client, store, model, "document:1",
				"n2", "user:bob", nil, nil)
			if got := outcome(r.allowed, r.err); got != "true" {
				t.Errorf("check bob: got %s, want true", got)
			}
		})
	}
}
