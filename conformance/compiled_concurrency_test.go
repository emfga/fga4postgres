package conformance

import (
	"context"
	"testing"
	"time"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// Two model writes to one opted-in store, each in its own open
// transaction, both regenerate the same functions. Without
// serialisation the second waits on the first's rows, then carries
// on from a registry read before the first committed: the first
// model's relations stay registered (and their functions stay) under
// the second model. Regeneration takes a per-store lock first, so
// the second waits and then regenerates from the committed state.
func TestCompiledConcurrentModelWrites(t *testing.T) {
	ctx := context.Background()
	pool := testdb.Pool(t)
	client := compiledEngine(t)
	storeID, _ := setup(t, client, flatDSL, nil)
	t.Cleanup(func() { _ = client.DeleteStore(ctx, storeID) })
	enableCompiled(t, storeID, compiledSchema(t))

	first, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = first.Rollback(ctx) }()
	_, err = first.Exec(ctx,
		"SELECT fga.write_authorization_model($1, $2)",
		storeID, modelJSON(t, flatDSL+"    define auditor: [user]\n"))
	if err != nil {
		t.Fatal(err)
	}

	critic := modelJSON(t, flatDSL+"    define critic: [user]\n")
	var pid int
	done := make(chan error, 1)
	second, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = second.Rollback(ctx) }()
	if err := second.QueryRow(ctx,
		"SELECT pg_backend_pid()").Scan(&pid); err != nil {
		t.Fatal(err)
	}
	go func() {
		_, err := second.Exec(ctx,
			"SELECT fga.write_authorization_model($1, $2)",
			storeID, critic)
		if err == nil {
			err = second.Commit(ctx)
		}
		done <- err
	}()

	// Commit the first only once the second is waiting on it.
	deadline := time.Now().Add(10 * time.Second)
	for {
		var waiting bool
		err := pool.QueryRow(ctx, `SELECT coalesce(wait_event_type,
			'') = 'Lock' FROM pg_stat_activity WHERE pid = $1`,
			pid).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the second model write never waited on the first")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := first.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatalf("second model write: %v (SQLSTATE %s)", err,
			sqlState(err))
	}

	if got := queryInt(t, `SELECT count(*)::int
		FROM fga.compiled_relation r
		JOIN fga.model m ON m.id = r.model_id
		WHERE r.store = $1 AND r.relation_name = 'critic'
		  AND m.id = (SELECT id FROM fga.model WHERE store = $1
		              ORDER BY id DESC LIMIT 1)`, storeID); got != 1 {
		t.Errorf("registry not on the second model: critic rows = %d",
			got)
	}
	if got := queryInt(t, `SELECT count(*)::int
		FROM fga.compiled_relation
		WHERE store = $1 AND relation_name = 'auditor'`,
		storeID); got != 0 {
		t.Errorf("auditor rows = %d, want 0 (the second model "+
			"has no auditor)", got)
	}
}
