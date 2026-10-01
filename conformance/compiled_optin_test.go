package conformance

import (
	"context"
	"testing"

	"github.com/emfga/fga4postgres/internal/testdb"
)

const optInDSL = `model
  schema 1.1
type user
type folder
  relations
    define viewer: [user]
type doc
  relations
    define parent: [folder]
    define owner: [user]
    define viewer: [user] or owner or viewer from parent
`

// The opt-in surface: what enable refuses, what the registry holds
// after a model write, and that disable and delete_store remove
// exactly the registered functions — never a function the
// application put in the same schema.
func TestCompiledOptIn(t *testing.T) {
	ctx := context.Background()
	pool := testdb.Pool(t)
	client := compiledEngine(t)
	storeID, _ := setup(t, client, optInDSL, nil)
	t.Cleanup(func() { _ = client.DeleteStore(ctx, storeID) })

	enable := func(schema string) error {
		_, err := pool.Exec(ctx,
			"SELECT fga.enable_compiled_relations($1, $2)",
			storeID, schema)
		return err
	}

	for _, refused := range []string{
		"fgac_missing_schema", "fga", "cel", "pg_catalog",
	} {
		if err := enable(refused); sqlState(err) != "YF100" {
			t.Errorf("enable into %q: want YF100, got %v",
				refused, err)
		}
	}
	_, err := pool.Exec(ctx,
		"SELECT fga.enable_compiled_relations($1, $2)",
		"00000000-0000-7000-8000-000000000001", "public")
	if sqlState(err) != "YF502" {
		t.Errorf("unknown store: want YF502, got %v", err)
	}

	schema := compiledSchema(t)
	// A function the application owns, shaped like a generated
	// name: cleanup must leave it alone.
	_, err = pool.Exec(ctx, "CREATE FUNCTION "+schema+
		".doc__helper__objects() RETURNS int LANGUAGE sql "+
		"AS 'SELECT 1'")
	if err != nil {
		t.Fatal(err)
	}

	if err := enable(schema); err != nil {
		t.Fatalf("enable: %v", err)
	}
	// 4 relations: folder#viewer, doc#parent, doc#owner, doc#viewer.
	registered := func() int {
		return queryInt(t, `SELECT count(*)::int
			FROM fga.compiled_relation WHERE store = $1`, storeID)
	}
	if n := registered(); n != 4 {
		t.Errorf("registry rows after enable = %d, want 4", n)
	}
	if n := schemaFunctions(t, schema); n != 13 {
		t.Errorf("functions after enable = %d, want 12 + 1", n)
	}

	// A model write regenerates for the new model only.
	_, modelID := setupModel(t, client, storeID, optInDSL+
		"    define editor: [user]\n")
	if n := queryInt(t, `SELECT count(*)::int
		FROM fga.compiled_relation
		WHERE store = $1 AND model_id = $2`,
		storeID, modelID); n != 5 {
		t.Errorf("rows for the new model = %d, want 5", n)
	}
	if n := registered(); n != 5 {
		t.Errorf("registry rows after rewrite = %d, want 5", n)
	}

	_, err = pool.Exec(ctx,
		"SELECT fga.disable_compiled_relations($1)", storeID)
	if err != nil {
		t.Fatalf("disable: %v", err)
	}
	if n := registered(); n != 0 {
		t.Errorf("registry rows after disable = %d, want 0", n)
	}
	if n := schemaFunctions(t, schema); n != 1 {
		t.Errorf("functions after disable = %d, want only the "+
			"application's", n)
	}

	if err := enable(schema); err != nil {
		t.Fatalf("re-enable: %v", err)
	}
	if n := registered(); n != 5 {
		t.Errorf("registry rows after re-enable = %d, want 5", n)
	}
	if err := client.DeleteStore(ctx, storeID); err != nil {
		t.Fatalf("delete store: %v", err)
	}
	if n := registered(); n != 0 {
		t.Errorf("registry rows after delete_store = %d", n)
	}
	if n := queryInt(t, `SELECT count(*)::int
		FROM fga.compiled_store WHERE store = $1`, storeID); n != 0 {
		t.Errorf("compiled_store rows after delete_store = %d", n)
	}
	if n := schemaFunctions(t, schema); n != 1 {
		t.Errorf("functions after delete_store = %d, want only "+
			"the application's", n)
	}
}
