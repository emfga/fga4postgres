package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// Cost tests assert how much work a request does, counted in
// function calls (callCounts), so a performance regression fails
// deterministically instead of drifting a benchmark. Each one sets
// up its own store on the engine only: the oracle has no
// equivalent of a call count.

// costStore is an engine store holding dsl and tuples, deleted when
// the test ends, plus the uuid map its corpus-style ids went through.
type costStore struct {
	id  string
	ids *uuidmap.Map
}

func newCostStore(
	t *testing.T, dsl string, tuples []*openfgav1.TupleKey,
) costStore {
	t.Helper()
	ids := uuidmap.New("cost/" + t.Name())
	client := sqlclient.New(testdb.Pool(t), ids)
	store, _ := setup(t, client, dsl, tuples)
	t.Cleanup(func() {
		_ = client.DeleteStore(context.Background(), store)
	})
	return costStore{id: store, ids: ids}
}

// user maps a corpus-style "type:id" to the engine's id domain.
func (s costStore) user(typ, id string) string {
	return typ + ":" + s.ids.ID(id)
}

func jsonArg(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// listObjectsCount runs fga.list_objects and returns how many
// objects it answered, with the call counts of that run.
func listObjectsCount(
	t *testing.T, s costStore, typ, rel, user string,
) (int, map[string]int64) {
	t.Helper()
	req := jsonArg(t, map[string]any{
		"type": typ, "relation": rel, "user": user,
	})
	stmt := `SELECT jsonb_array_length(
	           fga.list_objects($1, $2) -> 'objects')`
	var n int
	err := testdb.Pool(t).QueryRow(context.Background(), stmt,
		s.id, req).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n, callCounts(t, stmt, s.id, req)
}

// A tuple without a condition has nothing to evaluate: list_objects
// must not call the condition evaluator for it at all. Evaluating
// unconditionally cost ~1.3 s of a 7.9 s request on a 5,000-object
// hierarchy.
func TestListObjectsSkipsUnconditionedEval(t *testing.T) {
	var tuples []*openfgav1.TupleKey
	for i := 0; i < 1000; i++ {
		tuples = append(tuples, tk(
			fmt.Sprintf("doc:d%d", i), "viewer", "user:anne"))
	}
	s := newCostStore(t, plainDSL, tuples)

	n, calls := listObjectsCount(t, s, "doc", "viewer",
		s.user("user", "anne"))
	if n != 1000 {
		t.Fatalf("objects = %d, want 1000", n)
	}
	if got := calls["fga._eval_condition"]; got != 0 {
		t.Errorf("fga._eval_condition calls = %d, want 0", got)
	}
}
