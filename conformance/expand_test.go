package conformance

import (
	"context"
	"sort"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/status"

	"github.com/emfga/fga4postgres/internal/oracle"
	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

type expandClient interface {
	probeClient
	Expand(ctx context.Context, in *openfgav1.ExpandRequest,
		opts ...grpc.CallOption,
	) (*openfgav1.ExpandResponse, error)
}

// normTree canonicalizes an expand tree for comparison: users
// lists and TTU computed lists sort (upstream's ordering is
// tuple order, ours is ulid order — order-insensitivity is the
// measured contract, M19); operator children sort by their
// serialized form since both sides preserve rewrite order but
// the guard costs nothing.
func normTree(n *openfgav1.UsersetTree_Node) string {
	if n == nil {
		return "<nil>"
	}
	switch v := n.GetValue().(type) {
	case *openfgav1.UsersetTree_Node_Leaf:
		switch l := v.Leaf.GetValue().(type) {
		case *openfgav1.UsersetTree_Leaf_Users:
			users := append([]string(nil),
				l.Users.GetUsers()...)
			sort.Strings(users)
			return n.GetName() + "|users:" +
				joinStrings(users)
		case *openfgav1.UsersetTree_Leaf_Computed:
			return n.GetName() + "|computed:" +
				l.Computed.GetUserset()
		case *openfgav1.UsersetTree_Leaf_TupleToUserset:
			var cu []string
			for _, c := range l.TupleToUserset.GetComputed() {
				cu = append(cu, c.GetUserset())
			}
			sort.Strings(cu)
			return n.GetName() + "|ttu:" +
				l.TupleToUserset.GetTupleset() + "->" +
				joinStrings(cu)
		}
		return n.GetName() + "|leaf:?"
	case *openfgav1.UsersetTree_Node_Union:
		return n.GetName() + "|union(" +
			normNodes(v.Union.GetNodes()) + ")"
	case *openfgav1.UsersetTree_Node_Intersection:
		return n.GetName() + "|intersection(" +
			normNodes(v.Intersection.GetNodes()) + ")"
	case *openfgav1.UsersetTree_Node_Difference:
		return n.GetName() + "|difference(base=" +
			normTree(v.Difference.GetBase()) + ",subtract=" +
			normTree(v.Difference.GetSubtract()) + ")"
	}
	return n.GetName() + "|?"
}

func normNodes(ns []*openfgav1.UsersetTree_Node) string {
	var out []string
	for _, n := range ns {
		out = append(out, normTree(n))
	}
	sort.Strings(out)
	return joinStrings(out)
}

func joinStrings(ss []string) string {
	out := ""
	for i, s := range ss {
		if i > 0 {
			out += ","
		}
		out += s
	}
	return out
}

// Expand has no upstream corpus (plan phase 7): this suite is
// the differential contract — every operator shape, wildcard and
// userset leaves, TTU fan-out, contextual tuples, the measured
// no-condition-evaluation property (M20), and the all-2000 error
// surface (M19).
func TestExpandDifferential(t *testing.T) {
	ctx := context.Background()

	dsl := `model
  schema 1.1
type user
type folder
  relations
    define viewer: [user]
type doc
  relations
    define parent: [folder]
    define owner: [user, user:*, doc#viewer]
    define viewer: owner
    define both: owner and viewer
    define either: [user] or viewer
    define minus: owner but not viewer
    define inherited: viewer from parent
    define bound: [user with icond]
    define mixed: ([user] but not owner) or viewer from parent

condition icond(x: int) {
  x > 999999
}
`
	condTK := tk("doc:1", "bound", "user:bob")
	condTK.Condition = &openfgav1.RelationshipCondition{
		Name: "icond"}
	tuples := []*openfgav1.TupleKey{
		tk("doc:1", "owner", "user:anne"),
		tk("doc:1", "owner", "user:*"),
		tk("doc:1", "owner", "doc:2#viewer"),
		tk("doc:1", "parent", "folder:z"),
		tk("doc:1", "parent", "folder:a"),
		tk("doc:1", "parent", "folder:m"),
		tk("doc:1", "either", "user:cara"),
		tk("doc:1", "mixed", "user:dan"),
		condTK,
	}

	relations := []string{"owner", "viewer", "both", "either",
		"minus", "inherited", "bound", "mixed", "parent"}
	refusals := []struct {
		name, object, relation string
		wantCode               int
	}{
		{"undefined relation", "doc:1", "ghost", 2000},
		{"undefined type", "ghost:1", "owner", 2000},
		{"malformed object", "doc:", "owner", 2000},
	}

	trees := map[string]map[string]string{}
	for name, client := range map[string]expandClient{
		"engine": sqlclient.New(
			testdb.Pool(t), uuidmap.New("expand")),
		"oracle": oracle.Client(t),
	} {
		t.Run(name, func(t *testing.T) {
			store, model := setup(t, client, dsl, tuples)
			trees[name] = map[string]string{}
			for _, rel := range relations {
				resp, err := client.Expand(ctx,
					&openfgav1.ExpandRequest{
						StoreId:              store,
						AuthorizationModelId: model,
						TupleKey: &openfgav1.
							ExpandRequestTupleKey{
							Object: "doc:1", Relation: rel},
					})
				if err != nil {
					t.Errorf("expand %s: %v", rel, err)
					continue
				}
				trees[name][rel] = normTree(
					resp.GetTree().GetRoot())
			}
			// Contextual tuples participate.
			resp, err := client.Expand(ctx,
				&openfgav1.ExpandRequest{
					StoreId:              store,
					AuthorizationModelId: model,
					TupleKey: &openfgav1.ExpandRequestTupleKey{
						Object: "doc:9", Relation: "owner"},
					ContextualTuples: &openfgav1.
						ContextualTupleKeys{
						TupleKeys: []*openfgav1.TupleKey{
							tk("doc:9", "owner", "user:cara")}},
				})
			if err != nil {
				t.Errorf("expand with ctx tuples: %v", err)
			} else {
				trees[name]["ctx"] = normTree(
					resp.GetTree().GetRoot())
			}
			for _, r := range refusals {
				_, err := client.Expand(ctx,
					&openfgav1.ExpandRequest{
						StoreId:              store,
						AuthorizationModelId: model,
						TupleKey: &openfgav1.
							ExpandRequestTupleKey{
							Object:   r.object,
							Relation: r.relation},
					})
				s, _ := status.FromError(err)
				if int(s.Code()) != r.wantCode {
					t.Errorf("%s: got code %d, want %d",
						r.name, int(s.Code()), r.wantCode)
				}
			}
		})
	}

	if len(trees["engine"]) > 0 && len(trees["oracle"]) > 0 {
		for key, eng := range trees["engine"] {
			if ora := trees["oracle"][key]; eng != ora {
				t.Errorf("expand %s:\nengine %s\noracle %s",
					key, eng, ora)
			}
		}
	}
}
