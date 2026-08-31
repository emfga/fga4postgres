package conformance

import (
	"context"
	"fmt"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// Phase-2 resolver benchmarks (plan §3). Run with:
//
//	go test -bench BenchmarkCheck -benchtime 2s ./conformance/
//
// Numbers are recorded in workspace measurements.md; rerun after
// resolver changes that touch the hot path.

func benchClient(b *testing.B) *sqlclient.Client {
	return sqlclient.New(testdb.Pool(b), uuidmap.New("bench"))
}

func benchSetup(
	b *testing.B, dsl string, tuples []*openfgav1.TupleKey,
) (*sqlclient.Client, string, string) {
	b.Helper()
	client := benchClient(b)
	st, model := setup(b, client, dsl, tuples)
	b.Cleanup(func() {
		_ = client.DeleteStore(context.Background(), st)
	})
	return client, st, model
}

func benchCheck(
	b *testing.B, client *sqlclient.Client,
	store, model, object, relation, user string,
	wantAllowed bool, wantErr bool,
) {
	b.Helper()
	ctx := context.Background()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		resp, err := client.Check(ctx, &openfgav1.CheckRequest{
			StoreId:              store,
			AuthorizationModelId: model,
			TupleKey: &openfgav1.CheckRequestTupleKey{
				Object: object, Relation: relation, User: user,
			},
		})
		if wantErr {
			if err == nil {
				b.Fatal("expected error")
			}
			continue
		}
		if err != nil {
			b.Fatal(err)
		}
		if resp.GetAllowed() != wantAllowed {
			b.Fatalf("allowed=%v", resp.GetAllowed())
		}
	}
}

func BenchmarkCheckDirect(b *testing.B) {
	client, store, model := benchSetup(b, plainDSL,
		[]*openfgav1.TupleKey{tk("doc:1", "viewer", "user:anne")})
	benchCheck(b, client, store, model,
		"doc:1", "viewer", "user:anne", true, false)
}

func BenchmarkCheckDeepTTUChain(b *testing.B) {
	tuples := []*openfgav1.TupleKey{
		tk("folder:f0", "viewer", "user:anne"),
	}
	for i := 1; i <= 25; i++ {
		tuples = append(tuples, tk(
			fmt.Sprintf("folder:f%d", i), "parent",
			fmt.Sprintf("folder:f%d", i-1)))
	}
	client, store, model := benchSetup(b, ttuChainDSL, tuples)
	benchCheck(b, client, store, model,
		"folder:f25", "viewer", "user:anne", true, false)
}

func BenchmarkCheckWideFanout(b *testing.B) {
	var tuples []*openfgav1.TupleKey
	for i := 0; i < 200; i++ {
		g := fmt.Sprintf("group:g%d", i)
		tuples = append(tuples,
			tk("doc:1", "deep", g+"#member"),
			tk(g, "member", "user:other"))
	}
	tuples = append(tuples,
		tk("group:g199", "member", "user:anne"))
	client, store, model := benchSetup(b, depthDSL, tuples)
	benchCheck(b, client, store, model,
		"doc:1", "deep", "user:anne", true, false)
}

// The exception path: depth exhaustion raised and re-raised
// through the deferral layers — the cost the errors-as-values
// alternative would remove.
func BenchmarkCheckDepthExceeded(b *testing.B) {
	tuples := []*openfgav1.TupleKey{
		tk("folder:f0", "viewer", "user:anne"),
	}
	for i := 1; i <= 30; i++ {
		tuples = append(tuples, tk(
			fmt.Sprintf("folder:f%d", i), "parent",
			fmt.Sprintf("folder:f%d", i-1)))
	}
	client, store, model := benchSetup(b, ttuChainDSL, tuples)
	benchCheck(b, client, store, model,
		"folder:f30", "viewer", "user:anne", false, true)
}
