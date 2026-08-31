package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	parser "github.com/openfga/language/pkg/go/transformer"

	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
)

// The engine's batch_check against the M34-measured oracle
// contract: per-item error capture, request-level refusal of
// duplicate correlation ids and of more than 50 items.
func TestEngineBatchCheck(t *testing.T) {
	ctx := context.Background()
	pool := testdb.Pool(t)
	client := sqlclient.New(pool, nil)

	store, err := client.CreateStore(ctx,
		&openfgav1.CreateStoreRequest{Name: t.Name()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = client.DeleteStore(ctx, store.GetId())
	})

	model, err := parser.TransformDSLToProto(plainDSL)
	if err != nil {
		t.Fatal(err)
	}
	wm, err := client.WriteAuthorizationModel(ctx,
		&openfgav1.WriteAuthorizationModelRequest{
			StoreId:         store.GetId(),
			SchemaVersion:   model.GetSchemaVersion(),
			TypeDefinitions: model.GetTypeDefinitions(),
		})
	if err != nil {
		t.Fatal(err)
	}

	const anne = "user:11111111-1111-7111-8111-111111111111"
	const doc = "doc:22222222-2222-7222-8222-222222222222"
	_, err = client.Write(ctx, &openfgav1.WriteRequest{
		StoreId:              store.GetId(),
		AuthorizationModelId: wm.GetAuthorizationModelId(),
		Writes: &openfgav1.WriteRequestWrites{
			TupleKeys: []*openfgav1.TupleKey{
				tk(doc, "viewer", anne),
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	batch := func(req string) (map[string]any, error) {
		var out []byte
		err := pool.QueryRow(ctx,
			"SELECT fga.batch_check($1, $2)",
			store.GetId(), []byte(req)).Scan(&out)
		if err != nil {
			return nil, err
		}
		var m map[string]any
		if err := json.Unmarshal(out, &m); err != nil {
			return nil, err
		}
		return m, nil
	}
	item := func(rel, corr string) string {
		return fmt.Sprintf(`{"tuple_key":{"object":"%s",`+
			`"relation":"%s","user":"%s"},`+
			`"correlation_id":"%s"}`, doc, rel, anne, corr)
	}

	res, err := batch(`{"checks":[` +
		item("viewer", "a") + `,` + item("ghost", "b") + `]}`)
	if err != nil {
		t.Fatalf("batch: %v", err)
	}
	result := res["result"].(map[string]any)
	if a := result["a"].(map[string]any); a["allowed"] != true {
		t.Errorf("item a: %v", a)
	}
	b := result["b"].(map[string]any)
	if _, ok := b["error"]; !ok {
		t.Errorf("item b should carry a captured error: %v", b)
	}

	if _, err := batch(`{"checks":[` +
		item("viewer", "dup") + `,` + item("viewer", "dup") +
		`]}`); err == nil {
		t.Error("duplicate correlation ids must refuse")
	}

	items := ""
	for i := 0; i < 51; i++ {
		if i > 0 {
			items += ","
		}
		items += item("viewer", fmt.Sprintf("c%d", i))
	}
	if _, err := batch(`{"checks":[` + items + `]}`); err == nil {
		t.Error("51 items must refuse")
	}
}
