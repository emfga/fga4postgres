package conformance

import (
	"context"
	"fmt"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"

	"github.com/emfga/fga4postgres/internal/oracle"
)

// batch_check semantics as served — caps, duplicate
// correlation ids, per-item error isolation.
func TestProbeBatchCheck(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()
	store, model := setup(t, client, plainDSL,
		[]*openfgav1.TupleKey{tk("doc:1", "viewer", "user:anne")})

	item := func(id, obj, rel, user string,
	) *openfgav1.BatchCheckItem {
		return &openfgav1.BatchCheckItem{
			TupleKey: &openfgav1.CheckRequestTupleKey{
				Object: obj, Relation: rel, User: user,
			},
			CorrelationId: id,
		}
	}

	run := func(label string, items []*openfgav1.BatchCheckItem) {
		resp, err := client.BatchCheck(ctx,
			&openfgav1.BatchCheckRequest{
				StoreId:              store,
				AuthorizationModelId: model,
				Checks:               items,
			})
		if err != nil {
			s, _ := status.FromError(err)
			t.Logf("OBSERVED: %s: error code=%d: %v",
				label, int(s.Code()), err)
			return
		}
		out, _ := protojson.Marshal(resp)
		t.Logf("OBSERVED: %s: %s", label, out)
	}

	run("two items, one bad relation",
		[]*openfgav1.BatchCheckItem{
			item("a", "doc:1", "viewer", "user:anne"),
			item("b", "doc:1", "ghost", "user:anne"),
		})
	run("duplicate correlation ids",
		[]*openfgav1.BatchCheckItem{
			item("dup", "doc:1", "viewer", "user:anne"),
			item("dup", "doc:1", "viewer", "user:bob"),
		})

	var over []*openfgav1.BatchCheckItem
	for i := 0; i < 51; i++ {
		over = append(over, item(fmt.Sprintf("c%d", i),
			"doc:1", "viewer", "user:anne"))
	}
	run("51 items", over)
}
