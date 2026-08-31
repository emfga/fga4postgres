package conformance

import (
	"context"
	"fmt"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc"

	"github.com/emfga/fga4postgres/internal/oracle"
)

// M21: the deep-chain envelope for list_objects. tsfga measured
// (at v1.18.2) that upstream reverse expansion returns all 41
// objects of a 40-hop chain where forward-checking returns 25;
// re-measured here at the pin, for both the userset-chain and
// TTU-chain shapes.
func TestProbeM21DeepChainEnvelope(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()

	// Userset chain, 100 links.
	store, model := setup(t, client, chainGroupsDSL,
		groupChain(100))
	resp, err := client.ListObjects(ctx,
		&openfgav1.ListObjectsRequest{
			StoreId:              store,
			AuthorizationModelId: model,
			Type:                 "group",
			Relation:             "member",
			User:                 "user:anne",
		})
	if err != nil {
		t.Logf("OBSERVED: userset chain 40: error %v", err)
	} else {
		t.Logf("OBSERVED: userset chain 40: %d objects",
			len(resp.GetObjects()))
	}

	// TTU chain, 40 links.
	tuples := []*openfgav1.TupleKey{
		tk("folder:f0", "viewer", "user:anne"),
	}
	for i := 1; i <= 40; i++ {
		tuples = append(tuples, tk(
			fmt.Sprintf("folder:f%d", i), "parent",
			fmt.Sprintf("folder:f%d", i-1)))
	}
	store2, model2 := setup(t, client, ttuChainDSL, tuples)
	resp2, err := client.ListObjects(ctx,
		&openfgav1.ListObjectsRequest{
			StoreId:              store2,
			AuthorizationModelId: model2,
			Type:                 "folder",
			Relation:             "viewer",
			User:                 "user:anne",
		})
	if err != nil {
		t.Logf("OBSERVED: ttu chain 40: error %v", err)
	} else {
		t.Logf("OBSERVED: ttu chain 40: %d objects",
			len(resp2.GetObjects()))
	}

	// Computed chain beyond 25.
	store3, model3 := setup(t, client, computedChainDSL(30),
		[]*openfgav1.TupleKey{tk("doc:1", "r0", "user:anne")})
	resp3, err := client.ListObjects(ctx,
		&openfgav1.ListObjectsRequest{
			StoreId:              store3,
			AuthorizationModelId: model3,
			Type:                 "doc",
			Relation:             "r30",
			User:                 "user:anne",
		})
	if err != nil {
		t.Logf("OBSERVED: computed chain 30: error %v", err)
	} else {
		t.Logf("OBSERVED: computed chain 30: %d objects",
			len(resp3.GetObjects()))
	}
}

// M10b: list_objects request validation order.
func TestProbeM10bListObjectsValidationOrder(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()
	store, model := setup(t, client, plainDSL, nil)

	cases := []struct {
		label, typ, relation, user string
		ctx                        []*openfgav1.TupleKey
	}{
		{"bad ctx tuple + undefined relation + malformed user",
			"doc", "nonexistent", "junk",
			[]*openfgav1.TupleKey{tk("doc:1", "ghost", "user:a")}},
		{"undefined relation + malformed user",
			"doc", "nonexistent", "junk", nil},
		{"undefined type + undefined relation",
			"ghost", "nonexistent", "user:anne", nil},
		{"malformed user only",
			"doc", "viewer", "junk", nil},
		{"undefined subject relation",
			"doc", "viewer", "user:anne#norel", nil},
	}
	for _, c := range cases {
		req := &openfgav1.ListObjectsRequest{
			StoreId:              store,
			AuthorizationModelId: model,
			Type:                 c.typ,
			Relation:             c.relation,
			User:                 c.user,
		}
		if len(c.ctx) > 0 {
			req.ContextualTuples =
				&openfgav1.ContextualTupleKeys{TupleKeys: c.ctx}
		}
		_, err := client.ListObjects(ctx, req)
		t.Logf("OBSERVED: %s: %v", c.label, err)
	}
}

// Alternating-relation chain: not self-recursive, so no recursive
// fast path applies — does the default reverse expansion charge
// depth?
const altChainDSL = `model
  schema 1.1
type user
type node
  relations
    define x: [user, node#y]
    define y: [user, node#x]
`

func TestProbeM21AlternatingChain(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()
	tuples := []*openfgav1.TupleKey{
		tk("node:n0", "x", "user:anne"),
	}
	rels := []string{"x", "y"}
	for i := 1; i <= 40; i++ {
		tuples = append(tuples, tk(
			fmt.Sprintf("node:n%d", i), rels[i%2],
			fmt.Sprintf("node:n%d#%s", i-1, rels[(i+1)%2])))
	}
	store, model := setup(t, client, altChainDSL, tuples)
	for _, rel := range rels {
		resp, err := client.ListObjects(ctx,
			&openfgav1.ListObjectsRequest{
				StoreId:              store,
				AuthorizationModelId: model,
				Type:                 "node",
				Relation:             rel,
				User:                 "user:anne",
			})
		if err != nil {
			t.Logf("OBSERVED: alt chain 40 rel=%s: error %v",
				rel, err)
		} else {
			t.Logf("OBSERVED: alt chain 40 rel=%s: %d objects",
				rel, len(resp.GetObjects()))
		}
	}
	// And check parity on the deep end of the alternating chain.
	r := doCheck(t, client, store, model,
		"node:n40", "x", "user:anne", nil, nil)
	t.Logf("OBSERVED: alt chain check n40: %v", r)
}

// Group F: the 1000-result cap, both engines.
func TestProbeListObjectsResultCap(t *testing.T) {
	ctx := context.Background()
	for _, sd := range bothSides(t, "lo-cap") {
		var tuples []*openfgav1.TupleKey
		for i := 0; i < 1005; i++ {
			tuples = append(tuples, tk(
				fmt.Sprintf("doc:d%d", i), "viewer", "user:anne"))
		}
		store, model := setup(t, sd.client, plainDSL, tuples)
		resp, err := sd.client.(interface {
			ListObjects(context.Context,
				*openfgav1.ListObjectsRequest,
				...grpc.CallOption,
			) (*openfgav1.ListObjectsResponse, error)
		}).ListObjects(ctx, &openfgav1.ListObjectsRequest{
			StoreId:              store,
			AuthorizationModelId: model,
			Type:                 "doc",
			Relation:             "viewer",
			User:                 "user:anne",
		})
		if err != nil {
			t.Fatalf("%s: %v", sd.name, err)
		}
		t.Logf("OBSERVED(%s): 1005 accessible -> %d objects",
			sd.name, len(resp.GetObjects()))
		if len(resp.GetObjects()) != 1000 {
			t.Errorf("%s: want the 1000 cap", sd.name)
		}
	}
}
