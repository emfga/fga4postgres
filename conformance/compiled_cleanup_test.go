package conformance

import (
	"context"
	"testing"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// An application may drop its schema before deleting the store (or
// opting out): the registered functions are then already gone, and
// cleanup drops only what is still there.
func TestCompiledDropAfterSchemaDropped(t *testing.T) {
	ctx := context.Background()
	pool := testdb.Pool(t)
	client := compiledEngine(t)
	storeID, _ := setup(t, client, flatDSL, nil)
	schema := compiledSchema(t)
	enableCompiled(t, storeID, schema)
	other, _ := setup(t, client, flatDSL, nil)
	t.Cleanup(func() { _ = client.DeleteStore(ctx, other) })
	otherSchema := schema + "_other"
	for _, stmt := range []string{
		`DELETE FROM fga.compiled_relation WHERE store IN (
		  SELECT store FROM fga.compiled_store
		  WHERE target_schema = $1)`,
		`DELETE FROM fga.compiled_store WHERE target_schema = $1`,
	} {
		if _, err := pool.Exec(ctx, stmt, otherSchema); err != nil {
			t.Fatal(err)
		}
	}
	_, err := pool.Exec(ctx, "DROP SCHEMA IF EXISTS "+otherSchema+
		" CASCADE; CREATE SCHEMA "+otherSchema)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(),
			"DROP SCHEMA IF EXISTS "+otherSchema+" CASCADE")
	})
	enableCompiled(t, other, otherSchema)

	for _, s := range []string{schema, otherSchema} {
		if _, err := pool.Exec(ctx,
			"DROP SCHEMA "+s+" CASCADE"); err != nil {
			t.Fatal(err)
		}
	}
	if err := client.DeleteStore(ctx, storeID); err != nil {
		t.Fatalf("delete_store after the schema was dropped: %v", err)
	}
	if _, err := pool.Exec(ctx,
		"SELECT fga.disable_compiled_relations($1)", other); err != nil {
		t.Fatalf("disable after the schema was dropped: %v", err)
	}
	if got := queryInt(t, `SELECT count(*)::int FROM fga.compiled_store
		WHERE store IN ($1, $2)`, storeID, other); got != 0 {
		t.Errorf("opted-in stores left behind: %d", got)
	}
}
