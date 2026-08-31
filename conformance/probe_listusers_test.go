package conformance

import (
	"context"
	"fmt"
	"sort"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/types/known/structpb"

	"github.com/emfga/fga4postgres/internal/oracle"
)

func userToString(u *openfgav1.User) string {
	switch x := u.GetUser().(type) {
	case *openfgav1.User_Object:
		return x.Object.GetType() + ":" + x.Object.GetId()
	case *openfgav1.User_Userset:
		return x.Userset.GetType() + ":" + x.Userset.GetId() +
			"#" + x.Userset.GetRelation()
	case *openfgav1.User_Wildcard:
		return x.Wildcard.GetType() + ":*"
	}
	return "?"
}

// M17/M18/M23/M24 + the list_users depth boundary: the measured
// contract phase 5 is built to (plan §1.6).
func TestProbeM17To24ListUsers(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()

	run := func(store, model, objType, objID, rel string,
		filters []string, reqCtx *structpb.Struct,
	) ([]string, int) {
		var ufs []*openfgav1.UserTypeFilter
		for _, f := range filters {
			uf := &openfgav1.UserTypeFilter{}
			if i := indexHash(f); i >= 0 {
				uf.Type, uf.Relation = f[:i], f[i+1:]
			} else {
				uf.Type = f
			}
			ufs = append(ufs, uf)
		}
		resp, err := client.ListUsers(ctx,
			&openfgav1.ListUsersRequest{
				StoreId:              store,
				AuthorizationModelId: model,
				Object: &openfgav1.Object{
					Type: objType, Id: objID,
				},
				Relation:    rel,
				UserFilters: ufs,
				Context:     reqCtx,
			})
		if err != nil {
			s, _ := status.FromError(err)
			return nil, int(s.Code())
		}
		var out []string
		for _, u := range resp.GetUsers() {
			out = append(out, userToString(u))
		}
		sort.Strings(out)
		// Also record the raw JSON of the first wildcard user.
		for _, u := range resp.GetUsers() {
			if u.GetWildcard() != nil {
				j, _ := protojson.Marshal(u)
				t.Logf("OBSERVED: wildcard user JSON: %s", j)
				break
			}
		}
		return out, 0
	}

	// Arity (M17) + reflexive + wildcard shape (M18).
	store, model := setup(t, client, depthDSL, []*openfgav1.TupleKey{
		tk("doc:1", "direct", "user:anne"),
		tk("doc:1", "deep", "group:g1#member"),
		tk("group:g1", "member", "user:bob"),
	})
	users, code := run(store, model, "doc", "1", "direct",
		nil, nil)
	t.Logf("OBSERVED: zero filters: users=%v code=%d",
		users, code)
	users, code = run(store, model, "doc", "1", "direct",
		[]string{"user", "group#member"}, nil)
	t.Logf("OBSERVED: two filters: users=%v code=%d", users, code)
	users, code = run(store, model, "doc", "1", "deep",
		[]string{"group#member"}, nil)
	t.Logf("OBSERVED: userset filter on deep: users=%v code=%d",
		users, code)
	users, code = run(store, model, "group", "g1", "member",
		[]string{"group#member"}, nil)
	t.Logf("OBSERVED: reflexive self userset: users=%v code=%d",
		users, code)

	// Wildcards (M18) and the exclusion dance (M23).
	wDSL := `model
  schema 1.1
type user
type doc
  relations
    define granted: [user, user:*]
    define blocked: [user, user:*]
    define viewer: granted but not blocked
`
	s2, m2 := setup(t, client, wDSL, []*openfgav1.TupleKey{
		tk("doc:a", "granted", "user:*"),
		tk("doc:a", "blocked", "user:bob"),
		tk("doc:b", "granted", "user:anne"),
		tk("doc:b", "blocked", "user:*"),
		tk("doc:c", "granted", "user:*"),
		tk("doc:c", "blocked", "user:*"),
	})
	for _, oid := range []string{"a", "b", "c"} {
		users, code = run(s2, m2, "doc", oid, "viewer",
			[]string{"user"}, nil)
		t.Logf("OBSERVED: exclusion doc:%s: users=%v code=%d",
			oid, users, code)
	}

	// Depth boundary: the group ladder.
	s3, m3 := setup(t, client, chainGroupsDSL, groupChain(30))
	for _, n := range []int{24, 25, 26, 30} {
		users, code = run(s3, m3, "group",
			fmt.Sprintf("g%d", n), "member",
			[]string{"user"}, nil)
		t.Logf("OBSERVED: chain g%d: %d users code=%d",
			n, len(users), code)
	}

	// Condition-error scoping (M24): a conditioned tuple with a
	// missing referenced param.
	s4, m4 := setup(t, client, condDSL, []*openfgav1.TupleKey{
		condTuple(nil),
	})
	users, code = run(s4, m4, "doc", "1", "viewer",
		[]string{"user"}, nil)
	t.Logf("OBSERVED: cond missing param: users=%v code=%d",
		users, code)
	one := 1
	bob := condTuple(&one)
	bob.User = "user:bob"
	s5, m5 := setup(t, client, condDSL, []*openfgav1.TupleKey{
		condTuple(nil),
		bob,
	})
	users, code = run(s5, m5, "doc", "1", "viewer",
		[]string{"user"}, nil)
	t.Logf("OBSERVED: cond err + valid sibling: users=%v code=%d",
		users, code)
}

func indexHash(s string) int {
	for i := range s {
		if s[i] == '#' {
			return i
		}
	}
	return -1
}
