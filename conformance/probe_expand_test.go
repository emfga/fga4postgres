package conformance

import (
	"context"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"

	"github.com/emfga/fga4postgres/internal/oracle"
)

// M19/M20 + the expand response shapes phase 7 encodes: the tree
// per operator, TTU computed-list ordering, wildcard/userset
// leaves, condition handling, and the error surface.
func TestProbeM19M20Expand(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()

	expand := func(store, model, object, relation string,
		ctxTuples []*openfgav1.TupleKey,
	) (string, int) {
		req := &openfgav1.ExpandRequest{
			StoreId:              store,
			AuthorizationModelId: model,
			TupleKey: &openfgav1.ExpandRequestTupleKey{
				Object: object, Relation: relation,
			},
		}
		if len(ctxTuples) > 0 {
			req.ContextualTuples = &openfgav1.ContextualTupleKeys{
				TupleKeys: ctxTuples,
			}
		}
		resp, err := client.Expand(ctx, req)
		if err != nil {
			s, _ := status.FromError(err)
			return s.Message(), int(s.Code())
		}
		j, _ := protojson.MarshalOptions{
			UseProtoNames: true,
		}.Marshal(resp)
		return string(j), 0
	}

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
    define either: owner or viewer
    define minus: owner but not viewer
    define inherited: viewer from parent
    define bound: [user with icond]

condition icond(x: int) {
  x > 999999
}
`
	store, model := setup(t, client, dsl,
		[]*openfgav1.TupleKey{
			tk("doc:1", "owner", "user:anne"),
			tk("doc:1", "owner", "user:*"),
			tk("doc:1", "owner", "doc:2#viewer"),
			tk("doc:1", "parent", "folder:z"),
			tk("doc:1", "parent", "folder:a"),
			tk("doc:1", "parent", "folder:m"),
		})

	for _, c := range [][2]string{
		{"doc:1", "owner"}, {"doc:1", "viewer"},
		{"doc:1", "both"}, {"doc:1", "either"},
		{"doc:1", "minus"}, {"doc:1", "inherited"},
		{"doc:1", "bound"},
	} {
		j, code := expand(store, model, c[0], c[1], nil)
		t.Logf("OBSERVED: expand %s#%s: code=%d %s",
			c[0], c[1], code, j)
	}

	// M20: a conditioned tuple whose condition cannot be met with
	// an empty context.
	one := 1
	_ = one
	condTK := tk("doc:1", "bound", "user:bob")
	condTK.Condition = &openfgav1.RelationshipCondition{
		Name: "icond"}
	_, err := client.Write(ctx, &openfgav1.WriteRequest{
		StoreId: store, AuthorizationModelId: model,
		Writes: &openfgav1.WriteRequestWrites{
			TupleKeys: []*openfgav1.TupleKey{condTK}},
	})
	if err != nil {
		t.Fatalf("write conditioned tuple: %v", err)
	}
	j, code := expand(store, model, "doc:1", "bound", nil)
	t.Logf("OBSERVED: M20 unmet-able condition: code=%d %s",
		code, j)

	// Contextual tuples in expand?
	j, code = expand(store, model, "doc:9", "owner",
		[]*openfgav1.TupleKey{tk("doc:9", "owner", "user:cara")})
	t.Logf("OBSERVED: expand with ctx tuples: code=%d %s",
		code, j)

	// Error surface.
	j, code = expand(store, model, "doc:1", "ghost", nil)
	t.Logf("OBSERVED: undefined relation: code=%d msg=%q",
		code, j)
	j, code = expand(store, model, "ghost:1", "owner", nil)
	t.Logf("OBSERVED: undefined type: code=%d msg=%q", code, j)
	j, code = expand(store, model, "doc:", "owner", nil)
	t.Logf("OBSERVED: malformed object: code=%d msg=%q", code, j)
}
