package conformance

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// callCounts runs stmt inside a transaction with track_functions =
// 'all' and returns how many times each function was called during
// it, keyed "schema.name" (overloads summed). Counts are read from
// pg_stat_xact_user_functions in that same transaction: the
// cumulative view only sees counters after the backend flushes them,
// which happens on its own timer, so reading it would race. The xact
// view is not per transaction either: it shows the backend's pending
// counters, which still hold earlier transactions' calls until that
// same flush, so the result is the difference between a read before
// stmt and one after it. The transaction is rolled back; stmt must
// not need its writes kept.
//
// A call count is deterministic where a timing is not, which is what
// lets a cost regression fail a test instead of a benchmark.
func callCounts(
	t testing.TB, stmt string, args ...any,
) map[string]int64 {
	t.Helper()
	ctx := context.Background()
	tx, err := testdb.Pool(t).Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	_, err = tx.Exec(ctx, "SET LOCAL track_functions = 'all'")
	if err != nil {
		t.Fatal(err)
	}
	before := xactCallCounts(t, tx)
	rows, err := tx.Query(ctx, stmt, args...)
	if err != nil {
		t.Fatalf("%s: %v", stmt, err)
	}
	for rows.Next() {
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		t.Fatalf("%s: %v", stmt, err)
	}

	counts := xactCallCounts(t, tx)
	for name, n := range before {
		counts[name] -= n
		if counts[name] == 0 {
			delete(counts, name)
		}
	}
	return counts
}

// xactCallCounts reads the backend's pending per-function counters.
func xactCallCounts(t testing.TB, tx pgx.Tx) map[string]int64 {
	t.Helper()
	counts := map[string]int64{}
	rows, err := tx.Query(context.Background(), `
		SELECT schemaname || '.' || funcname, sum(calls)::bigint
		FROM pg_stat_xact_user_functions
		GROUP BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var name string
		var n int64
		if err := rows.Scan(&name, &n); err != nil {
			t.Fatal(err)
		}
		counts[name] = n
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return counts
}

// Repeated calls must not see each other: an earlier transaction's
// counters stay pending on a pooled backend until it flushes.
func TestCostHelperCountsCalls(t *testing.T) {
	for i := range 3 {
		got := callCounts(t, "SELECT fga.version(), fga.version()")
		if got["fga.version"] != 2 {
			t.Fatalf("call %d: fga.version calls = %d, want 2 "+
				"(all: %v)", i+1, got["fga.version"], got)
		}
	}
}
