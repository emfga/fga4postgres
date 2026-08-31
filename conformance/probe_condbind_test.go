package conformance

import (
	"context"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc/status"

	"github.com/emfga/fga4postgres/internal/oracle"
)

const condBindDSL = `model
  schema 1.1
type user
type document
  relations
    define b0: [user, user:* with isOk]
condition isOk(ok: bool) {
  ok
}`

// The error code for a contextual tuple whose only fault is
// the condition binding (facet exists unconditioned, tuple carries
// a condition — and the reverse).
func TestProbeConditionBindingCode(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()
	store, model := setup(t, client, condBindDSL, nil)

	mk := func(user, cond string) *openfgav1.TupleKey {
		tp := tk("document:1", "b0", user)
		if cond != "" {
			tp.Condition = &openfgav1.RelationshipCondition{
				Name: cond}
		}
		return tp
	}

	cases := []struct {
		label string
		tuple *openfgav1.TupleKey
	}{
		{"plain-user tuple WITH condition (binding mismatch)",
			mk("user:alice", "isOk")},
		{"wildcard tuple WITHOUT condition (binding mismatch)",
			mk("user:*", "")},
		{"undefined condition name",
			mk("user:alice", "ghost")},
	}
	for _, c := range cases {
		_, err := client.Check(ctx, &openfgav1.CheckRequest{
			StoreId:              store,
			AuthorizationModelId: model,
			TupleKey: &openfgav1.CheckRequestTupleKey{
				Object: "document:1", Relation: "b0",
				User: "user:alice",
			},
			ContextualTuples: &openfgav1.ContextualTupleKeys{
				TupleKeys: []*openfgav1.TupleKey{c.tuple},
			},
		})
		s1, _ := status.FromError(err)
		_, err2 := client.ListObjects(ctx,
			&openfgav1.ListObjectsRequest{
				StoreId:              store,
				AuthorizationModelId: model,
				Type:                 "document",
				Relation:             "b0",
				User:                 "user:alice",
				ContextualTuples: &openfgav1.ContextualTupleKeys{
					TupleKeys: []*openfgav1.TupleKey{c.tuple},
				},
			})
		s2, _ := status.FromError(err2)
		t.Logf("OBSERVED: %s: check=%d list_objects=%d (%v / %v)",
			c.label, int(s1.Code()), int(s2.Code()), err, err2)
	}
}
