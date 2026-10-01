package conformance

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	parser "github.com/openfga/language/pkg/go/transformer"

	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// compiledSchema creates an empty schema for one test's generated
// functions and drops it when the test ends. The engine never
// creates or drops schemas (the application owns them), so the
// test plays the application here.
func compiledSchema(t testing.TB) string {
	t.Helper()
	h := fnv.New64a()
	fmt.Fprint(h, t.Name())
	name := fmt.Sprintf("fgac_%016x", h.Sum64())
	pool := testdb.Pool(t)
	ctx := context.Background()
	_, err := pool.Exec(ctx,
		"DROP SCHEMA IF EXISTS "+name+" CASCADE; "+
			"CREATE SCHEMA "+name)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(),
			"DROP SCHEMA IF EXISTS "+name+" CASCADE")
	})
	return name
}

// compiledEngine is the plain engine client with a uuid map scoped
// to the test, so DSL tuples with corpus-style ids work.
func compiledEngine(t testing.TB) *sqlclient.Client {
	return sqlclient.New(
		testdb.Pool(t), uuidmap.New("compiled/"+t.Name()))
}

// enableCompiled opts a store in, failing the test on refusal.
func enableCompiled(t testing.TB, storeID, schema string) {
	t.Helper()
	_, err := testdb.Pool(t).Exec(context.Background(),
		"SELECT fga.enable_compiled_relations($1, $2)",
		storeID, schema)
	if err != nil {
		t.Fatalf("enable_compiled_relations: %v", err)
	}
}

// sqlState returns the SQLSTATE of a database error, or "".
func sqlState(err error) string {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code
	}
	return ""
}

// queryInt runs a single-value integer query.
func queryInt(t testing.TB, sql string, args ...any) int {
	t.Helper()
	var n int
	err := testdb.Pool(t).QueryRow(context.Background(), sql,
		args...).Scan(&n)
	if err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	return n
}

// schemaFunctions counts the functions living in a schema.
func schemaFunctions(t testing.TB, schema string) int {
	return queryInt(t, `
		SELECT count(*)::int FROM pg_proc p
		JOIN pg_namespace n ON n.oid = p.pronamespace
		WHERE n.nspname = $1`, schema)
}

// setupModel writes one more model into an existing store and
// returns the store and the new model id.
func setupModel(
	t testing.TB, client probeClient, storeID, dsl string,
) (string, string) {
	t.Helper()
	model, err := parser.TransformDSLToProto(dsl)
	if err != nil {
		t.Fatalf("bad DSL: %v", err)
	}
	wm, err := client.WriteAuthorizationModel(context.Background(),
		&openfgav1.WriteAuthorizationModelRequest{
			StoreId:         storeID,
			SchemaVersion:   model.GetSchemaVersion(),
			TypeDefinitions: model.GetTypeDefinitions(),
			Conditions:      model.GetConditions(),
		})
	if err != nil {
		t.Fatalf("write model: %v", err)
	}
	return storeID, wm.GetAuthorizationModelId()
}
