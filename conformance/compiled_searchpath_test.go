package conformance

import (
	"context"
	"fmt"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

func flatTuples() []*openfgav1.TupleKey {
	return []*openfgav1.TupleKey{
		tk("doc:d1", "parent", "folder:f1"),
		tk("folder:f1", "viewer", "group:g1#member"),
		tk("group:g1", "member", "user:anne"),
		tk("doc:d2", "owner", "user:bob"),
		tk("folder:f2", "viewer", "user:*"),
		tk("doc:d3", "parent", "folder:f2"),
		tk("doc:d4", "viewer", "user:carl"),
		tk("folder:f1", "owner", "user:dave"),
	}
}

// flatAnswers asks every kind of doc#viewer question the flat
// fixture can answer, on one connection, and renders the answers
// as sorted lines so two runs compare with one equality.
func flatAnswers(
	t *testing.T, tx pgx.Tx, schema string, ids *uuidmap.Map,
) []string {
	t.Helper()
	ctx := context.Background()
	users := []string{"anne", "bob", "carl", "dave", "erin"}
	docs := []string{"d1", "d2", "d3", "d4"}
	// Map every id first: Back only knows ids ID has seen.
	for _, id := range append(append([]string{}, users...), docs...) {
		ids.ID(id)
	}
	var out []string
	collect := func(label, q string, args ...any) {
		rows, err := tx.Query(ctx, q, args...)
		if err != nil {
			t.Fatalf("%s: %v", label, err)
		}
		var got []string
		for rows.Next() {
			var v string
			if err := rows.Scan(&v); err != nil {
				t.Fatal(err)
			}
			got = append(got, ids.Back(v))
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			t.Fatalf("%s: %v", label, err)
		}
		sort.Strings(got)
		out = append(out, label+" "+strings.Join(got, ","))
	}
	for _, u := range users {
		collect("objects "+u, fmt.Sprintf(
			"SELECT x::text FROM %s.doc__viewer__objects("+
				"'user', $1::uuid) x", schema), ids.ID(u))
		for _, d := range docs {
			collect("check "+d+" "+u, fmt.Sprintf(
				"SELECT %s.doc__viewer__check($1::uuid, 'user', "+
					"$2::uuid)::text", schema), ids.ID(d), ids.ID(u))
		}
	}
	collect("objects any", fmt.Sprintf(
		"SELECT x::text FROM %s.doc__viewer__objects('user', "+
			"NULL, p_any_subject => true) x", schema))
	for _, d := range []string{"d1", "d2", "d4"} {
		collect("subjects "+d, fmt.Sprintf(
			"SELECT x::text FROM %s.doc__viewer__subjects("+
				"$1::uuid, 'user') x", schema), ids.ID(d))
	}
	sort.Strings(out)
	return out
}

// Generated bodies run under the caller's search_path, because a
// SET clause would stop them inlining. A schema ahead of
// pg_catalog holding a table named tuple and an always-true
// uuid = uuid operator must not change one answer (decision 21).
func TestCompiledSearchPathIndependent(t *testing.T) {
	ctx := context.Background()
	client := compiledEngine(t)
	ids := uuidmap.New("compiled/" + t.Name())
	storeID, _ := setup(t, client, flatDSL, flatTuples())
	t.Cleanup(func() { _ = client.DeleteStore(ctx, storeID) })
	schema := compiledSchema(t)
	enableCompiled(t, storeID, schema)

	tx, err := testdb.Pool(t).Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	want := flatAnswers(t, tx, schema, ids)
	if !slices.Contains(want, "objects anne d1,d3") ||
		!slices.Contains(want, "objects erin d3") {
		t.Fatalf("fixture answers look wrong: %v", want)
	}

	decoy := schema + "_decoy"
	_, err = tx.Exec(ctx, fmt.Sprintf(`
		CREATE SCHEMA %[1]s;
		CREATE TABLE %[1]s.tuple (LIKE fga.tuple);
		INSERT INTO %[1]s.tuple SELECT * FROM fga.tuple
		  WHERE store = '%[2]s';
		INSERT INTO %[1]s.tuple
		  SELECT store, 'doc', object_id, 'viewer', 'user',
		         '%[3]s', '', NULL, NULL, ulid || 'x', now()
		  FROM fga.tuple WHERE store = '%[2]s'
		    AND object_type = 'doc';
		CREATE FUNCTION %[1]s.always(uuid, uuid) RETURNS boolean
		  LANGUAGE sql IMMUTABLE AS 'SELECT true';
		CREATE OPERATOR %[1]s.= (
		  LEFTARG = uuid, RIGHTARG = uuid,
		  FUNCTION = %[1]s.always);
		CREATE FUNCTION %[1]s.never(uuid, uuid) RETURNS boolean
		  LANGUAGE sql IMMUTABLE AS 'SELECT false';
		CREATE OPERATOR %[1]s.<> (
		  LEFTARG = uuid, RIGHTARG = uuid,
		  FUNCTION = %[1]s.never);
		SET LOCAL search_path = %[1]s, pg_catalog, fga, public`,
		decoy, storeID, ids.ID("erin")))
	if err != nil {
		t.Fatal(err)
	}

	got := flatAnswers(t, tx, schema, ids)
	if !slices.Equal(got, want) {
		for i := range want {
			if i < len(got) && got[i] != want[i] {
				t.Errorf("decoy path: %q, want %q", got[i], want[i])
			}
		}
		if len(got) != len(want) {
			t.Errorf("decoy path: %d answers, want %d",
				len(got), len(want))
		}
	}
}

// Generation is plain transactional DDL: a model write whose
// transaction fails leaves the previous functions and registry.
func TestCompiledRollback(t *testing.T) {
	ctx := context.Background()
	pool := testdb.Pool(t)
	client := compiledEngine(t)
	storeID, modelID := setup(t, client, flatDSL, nil)
	t.Cleanup(func() { _ = client.DeleteStore(ctx, storeID) })
	enableCompiled(t, storeID, compiledSchema(t))
	before := registeredFns(t, storeID)

	model := flatDSL + "    define auditor: [user]\n"
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	_, err = tx.Exec(ctx,
		"SELECT fga.write_authorization_model($1, $2)",
		storeID, modelJSON(t, model))
	if err != nil {
		t.Fatal(err)
	}
	var n int
	if err := tx.QueryRow(ctx, `SELECT count(*)::int
		FROM fga.compiled_relation WHERE store = $1
		AND relation_name = 'auditor'`, storeID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("inside the transaction: auditor rows = %d", n)
	}
	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}

	after := registeredFns(t, storeID)
	if !slices.Equal(after, before) {
		t.Errorf("registry after rollback:\n%v\nwant\n%v",
			after, before)
	}
	if got := queryInt(t, `SELECT count(DISTINCT model_id)::int
		FROM fga.compiled_relation
		WHERE store = $1 AND model_id = $2`,
		storeID, modelID); got != 1 {
		t.Errorf("registry no longer on the first model")
	}
}
