package conformance

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// The OpenFGA dialect lives in the 'openfga' env only. A database
// whose installer ran under cel4postgres 0.0.2 also had the
// dialect's rows swept into 'standard'; re-running
// sql/020_dialect.sql removes them. The leak is recreated inside a
// transaction that is rolled back, the way a migration tool would
// run the script, so the shared database is left untouched.
func TestDialectStaysOutOfStandard(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "sql",
		"020_dialect.sql"))
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	tx, err := testdb.Pool(t).Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	const leaked = `
		SELECT count(*) FROM cel.env_item s
		WHERE s.env = 'standard' AND s.kind <> 'env'
		  AND EXISTS (SELECT FROM cel.env_item o
		              WHERE o.env = 'openfga' AND o.kind = s.kind
		                AND o.ref = s.ref)`
	if _, err := tx.Exec(ctx, `
		INSERT INTO cel.env_item (env, kind, ref)
		SELECT 'standard', kind, ref FROM cel.env_item
		WHERE env = 'openfga' AND kind <> 'env'
		ON CONFLICT DO NOTHING`); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := tx.QueryRow(ctx, leaked).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n == 0 {
		t.Fatal("could not recreate the leaked rows")
	}

	if _, err := tx.Exec(ctx, string(src)); err != nil {
		t.Fatalf("020_dialect.sql: %v", err)
	}
	if err := tx.QueryRow(ctx, leaked).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("%d dialect rows still in 'standard' after "+
			"reinstall", n)
	}

	// The dialect still answers under its own env, and plain
	// standard CEL does not know it (cel.evaluate returns errors
	// as tagged values).
	const expr = `ipaddress("10.0.0.1").in_cidr("10.0.0.0/8")`
	var underOpenFGA, underStandard string
	if err := tx.QueryRow(ctx, `SELECT
		cel.evaluate($1, '{}', 'openfga')::text,
		cel.evaluate($1, '{}', 'standard') ->> '@t'`, expr,
	).Scan(&underOpenFGA, &underStandard); err != nil {
		t.Fatal(err)
	}
	if underOpenFGA != `{"v": true, "@t": "bool"}` {
		t.Errorf("in_cidr under openfga: %s, want true",
			underOpenFGA)
	}
	if underStandard != "error" {
		t.Errorf("standard CEL resolved the OpenFGA dialect: %s",
			underStandard)
	}
}
