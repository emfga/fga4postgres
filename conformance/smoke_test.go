package conformance

import (
	"context"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/oracle"
	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
)

// The engine answers and carries a version.
func TestEngineVersion(t *testing.T) {
	var v string
	err := testdb.Pool(t).QueryRow(
		context.Background(), "SELECT fga.version()",
	).Scan(&v)
	if err != nil {
		t.Fatal(err)
	}
	if v == "" {
		t.Fatal("fga.version() returned an empty version")
	}
}

// CreateStore/DeleteStore round-trip through the sqlclient — the
// one live method of plan phase 0.
func TestEngineStoreRoundTrip(t *testing.T) {
	ctx := context.Background()
	client := sqlclient.New(testdb.Pool(t), nil)

	resp, err := client.CreateStore(
		ctx, &openfgav1.CreateStoreRequest{Name: t.Name()},
	)
	if err != nil {
		t.Fatal(err)
	}
	if resp.GetId() == "" || resp.GetName() != t.Name() {
		t.Fatalf("unexpected response: %v", resp)
	}
	if err := client.DeleteStore(ctx, resp.GetId()); err != nil {
		t.Fatal(err)
	}
	// Idempotent, like the oracle (measured 2026-08-31).
	if err := client.DeleteStore(ctx, resp.GetId()); err != nil {
		t.Fatal(err)
	}
}

// The oracle serves and creates stores — differential runs depend
// on it exactly as much as on the engine.
func TestOracleStoreRoundTrip(t *testing.T) {
	ctx := context.Background()
	client := oracle.Client(t)

	resp, err := client.CreateStore(
		ctx, &openfgav1.CreateStoreRequest{Name: "smoke"},
	)
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.DeleteStore(
		ctx, &openfgav1.DeleteStoreRequest{StoreId: resp.GetId()},
	)
	if err != nil {
		t.Fatal(err)
	}
}
