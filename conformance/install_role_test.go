package conformance

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// The install needs no more than a managed PostgreSQL gives its
// master user: a role with LOGIN, CREATEDB and CREATEROLE but not
// SUPERUSER, installing into a database it owns. Some statements
// pass for a superuser and fail for anyone else — a function
// definition carrying a custom setting (SET fga.x = ...) is one —
// and the compose role is a superuser, so the rest of the suite
// cannot see them.
//
// The vendored cel4postgres bundle and sql/ install twice, in one
// transaction each (re-running is the upgrade path), and then a
// store opted in to compiled relations answers through them.
func TestInstallWithoutSuperuser(t *testing.T) {
	ctx := context.Background()
	admin := testdb.Pool(t)
	const role, db = "fga_install_probe", "fga_install_probe"
	drop := func() {
		_, _ = admin.Exec(ctx, "DROP DATABASE IF EXISTS "+db+
			" WITH (FORCE)")
		_, _ = admin.Exec(ctx, "DROP ROLE IF EXISTS "+role)
	}
	drop()
	t.Cleanup(drop)
	for _, stmt := range []string{
		"CREATE ROLE " + role + " LOGIN NOSUPERUSER CREATEDB " +
			"CREATEROLE PASSWORD 'probe'",
		"CREATE DATABASE " + db + " OWNER " + role,
	} {
		if _, err := admin.Exec(ctx, stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}

	cfg, err := pgx.ParseConfig(testdb.DSN())
	if err != nil {
		t.Fatal(err)
	}
	cfg.User, cfg.Password, cfg.Database = role, "probe", db
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	files, err := filepath.Glob(
		filepath.Join("..", "vendor", "cel4postgres--*.sql"))
	if err != nil || len(files) != 1 {
		t.Fatalf("vendored bundle: %v %v", files, err)
	}
	engine, err := filepath.Glob(filepath.Join("..", "sql", "*.sql"))
	if err != nil {
		t.Fatal(err)
	}
	var script strings.Builder
	for _, f := range append(files, engine...) {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		script.Write(b)
		script.WriteString("\n")
	}
	for _, run := range []string{"install", "reinstall"} {
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, script.String())
			return err
		})
		if err != nil {
			t.Fatalf("%s as a non-superuser: %v", run, err)
		}
	}

	// Separate statements: a STABLE entry point does not see rows
	// a VOLATILE one wrote earlier in the same statement.
	const (
		doc  = "00000000-0000-0000-0000-00000000000d"
		anne = "00000000-0000-0000-0000-00000000000a"
	)
	var allowed, listed string
	err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		var store string
		err := tx.QueryRow(ctx,
			"SELECT id::text FROM fga.create_store('probe')").Scan(&store)
		if err != nil {
			return err
		}
		for _, stmt := range []string{
			`SELECT fga.write_authorization_model($1, '{
			  "schema_version": "1.1",
			  "type_definitions": [
			    {"type": "user"},
			    {"type": "doc",
			     "relations": {"viewer": {"this": {}}},
			     "metadata": {"relations": {"viewer": {
			       "directly_related_user_types":
			         [{"type": "user"}]}}}}]}')`,
			"CREATE SCHEMA probe_authz",
			"SELECT fga.enable_compiled_relations($1, 'probe_authz')",
			`SELECT fga.write($1, jsonb_build_object('writes',
			  jsonb_build_object('tuple_keys', jsonb_build_array(
			    jsonb_build_object('object', 'doc:` + doc + `',
			      'relation', 'viewer', 'user', 'user:` + anne + `')))))`,
		} {
			args := []any{store}
			if !strings.Contains(stmt, "$1") {
				args = nil
			}
			if _, err := tx.Exec(ctx, stmt, args...); err != nil {
				return err
			}
		}
		return tx.QueryRow(ctx, `
			SELECT fga.check($1, jsonb_build_object('tuple_key',
			    jsonb_build_object('object', 'doc:' || $2,
			      'relation', 'viewer', 'user', 'user:' || $3)))
			    ->> 'allowed',
			  fga.list_objects($1, jsonb_build_object(
			    'type', 'doc', 'relation', 'viewer',
			    'user', 'user:' || $3)) ->> 'objects'`,
			store, doc, anne).Scan(&allowed, &listed)
	})
	if err != nil {
		t.Fatalf("answering as a non-superuser: %v", err)
	}
	if allowed != "true" || !strings.Contains(listed, doc) {
		t.Fatalf("check %s, list_objects %s; want true and the doc",
			allowed, listed)
	}
}
