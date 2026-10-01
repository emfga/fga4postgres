package conformance

import (
	"context"
	"fmt"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// __objects mirrors list_objects without its cap whatever strategy
// answers it: the caller pages the set in its own query, so a
// silently truncated set would drop rows from the middle of a page.
// The exclusion below is the shape most likely to fall back to the
// generic resolver, which is where a cap could leak in.
func TestCompiledObjectsUncapped(t *testing.T) {
	const dsl = `model
  schema 1.1
type user
type doc
  relations
    define blocked: [user]
    define viewer: [user] but not blocked`
	const n = 1005
	tuples := make([]*openfgav1.TupleKey, 0, n+1)
	for i := range n {
		tuples = append(tuples,
			tk(fmt.Sprintf("doc:d%d", i), "viewer", "user:anne"))
	}
	tuples = append(tuples, tk("doc:d0", "blocked", "user:anne"))

	schema := compiledSchema(t)
	client := compiledEngine(t)
	store, err := client.CreateStore(context.Background(),
		&openfgav1.CreateStoreRequest{Name: t.Name()})
	if err != nil {
		t.Fatal(err)
	}
	enableCompiled(t, store.GetId(), schema)
	storeID, modelID := setupModel(t, client, store.GetId(), dsl)
	for start := 0; start < len(tuples); start += 40 {
		end := min(start+40, len(tuples))
		_, err := client.Write(context.Background(),
			&openfgav1.WriteRequest{
				StoreId:              storeID,
				AuthorizationModelId: modelID,
				Writes: &openfgav1.WriteRequestWrites{
					TupleKeys: tuples[start:end],
				},
			})
		if err != nil {
			t.Fatal(err)
		}
	}

	anne := uuidmap.New("compiled/" + t.Name()).ID("anne")
	got := queryInt(t, fmt.Sprintf(
		`SELECT count(*)::int
		 FROM %s.doc__viewer__objects('user', $1::uuid) x`,
		schema), anne)
	if got != n-1 {
		t.Fatalf("doc#viewer objects = %d, want %d", got, n-1)
	}
}
