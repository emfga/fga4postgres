package conformance

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// Cost tests assert how much work a request does, counted in
// function calls (callCounts), so a performance regression fails
// deterministically instead of drifting a benchmark. Each one sets
// up its own store on the engine only: the oracle has no
// equivalent of a call count.

// costStore is an engine store holding dsl and tuples, deleted when
// the test ends, plus the uuid map its corpus-style ids went through.
type costStore struct {
	id  string
	ids *uuidmap.Map
}

func newCostStore(
	t *testing.T, dsl string, tuples []*openfgav1.TupleKey,
) costStore {
	t.Helper()
	ids := uuidmap.New("cost/" + t.Name())
	client := sqlclient.New(testdb.Pool(t), ids)
	store, _ := setup(t, client, dsl, tuples)
	t.Cleanup(func() {
		_ = client.DeleteStore(context.Background(), store)
	})
	return costStore{id: store, ids: ids}
}

// user maps a corpus-style "type:id" to the engine's id domain.
func (s costStore) user(typ, id string) string {
	return typ + ":" + s.ids.ID(id)
}

func jsonArg(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// listObjectsCount runs fga.list_objects and returns how many
// objects it answered, with the call counts of that run.
func listObjectsCount(
	t *testing.T, s costStore, typ, rel, user string,
) (int, map[string]int64) {
	t.Helper()
	req := jsonArg(t, map[string]any{
		"type": typ, "relation": rel, "user": user,
	})
	stmt := `SELECT jsonb_array_length(
	           fga.list_objects($1, $2) -> 'objects')`
	var n int
	err := testdb.Pool(t).QueryRow(context.Background(), stmt,
		s.id, req).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n, callCounts(t, stmt, s.id, req)
}

// listUsersCount is listObjectsCount for fga.list_users.
func listUsersCount(
	t *testing.T, s costStore, object, objectID, rel, filter string,
) (int, map[string]int64) {
	t.Helper()
	req := jsonArg(t, map[string]any{
		"object":       map[string]string{"type": object, "id": objectID},
		"relation":     rel,
		"user_filters": []map[string]string{{"type": filter}},
	})
	stmt := `SELECT jsonb_array_length(
	           fga.list_users($1, $2) -> 'users')`
	var n int
	err := testdb.Pool(t).QueryRow(context.Background(), stmt,
		s.id, req).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n, callCounts(t, stmt, s.id, req)
}

// A tuple without a condition has nothing to evaluate: list_objects
// must not call the condition evaluator for it at all. Evaluating
// unconditionally cost ~1.3 s of a 7.9 s request on a 5,000-object
// hierarchy.
func TestListObjectsSkipsUnconditionedEval(t *testing.T) {
	var tuples []*openfgav1.TupleKey
	for i := 0; i < 1000; i++ {
		tuples = append(tuples, tk(
			fmt.Sprintf("doc:d%d", i), "viewer", "user:anne"))
	}
	s := newCostStore(t, plainDSL, tuples)

	n, calls := listObjectsCount(t, s, "doc", "viewer",
		s.user("user", "anne"))
	if n != 1000 {
		t.Fatalf("objects = %d, want 1000", n)
	}
	if got := calls["fga._eval_condition"]; got != 0 {
		t.Errorf("fga._eval_condition calls = %d, want 0", got)
	}
}

// capConfirmDSL makes every doc#viewer candidate need confirmation
// by the forward resolver (an intersection on the path).
const capConfirmDSL = `model
  schema 1.1
type user
type doc
  relations
    define allowed: [user]
    define viewer: [user] and allowed
`

// Once the cap is reached the search stops: with 5,005 candidates
// that each need a forward check and a cap of 1,000, exactly 1,000
// are confirmed. Before, all 5,005 were checked and the answer was
// truncated afterwards.
func TestListObjectsCapStopsEarly(t *testing.T) {
	grant := func(n int) []*openfgav1.TupleKey {
		var tuples []*openfgav1.TupleKey
		for i := 0; i < n; i++ {
			doc := fmt.Sprintf("doc:d%d", i)
			tuples = append(tuples,
				tk(doc, "viewer", "user:anne"),
				tk(doc, "allowed", "user:anne"))
		}
		return tuples
	}

	// What confirming one candidate costs, measured rather than
	// assumed, so a change to the forward resolver's shape does not
	// break this test.
	one := newCostStore(t, capConfirmDSL, grant(1))
	n, calls := listObjectsCount(t, one, "doc", "viewer",
		one.user("user", "anne"))
	perConfirm := calls["fga._check_node"]
	if n != 1 || perConfirm == 0 {
		t.Fatalf("one doc: objects = %d, _check_node calls = %d;"+
			" the fixture no longer needs confirmation", n, perConfirm)
	}

	s := newCostStore(t, capConfirmDSL, grant(5005))
	n, calls = listObjectsCount(t, s, "doc", "viewer",
		s.user("user", "anne"))
	if n != 1000 {
		t.Fatalf("objects = %d, want the 1000 cap", n)
	}
	got := calls["fga._check_node"]
	if want := 1000 * perConfirm; got != want {
		t.Errorf("fga._check_node calls = %d, want %d "+
			"(1000 confirmations x %d)", got, want, perConfirm)
	}
}

// The same for list_users: 5,005 direct viewers and a cap of 1,000
// fold exactly 1,000 users into the result. Before, every row was
// folded in (quadratically, each union re-deduplicates the set) and
// the answer truncated afterwards.
func TestListUsersCapStopsEarly(t *testing.T) {
	var tuples []*openfgav1.TupleKey
	for i := 0; i < 5005; i++ {
		tuples = append(tuples, tk(
			"doc:d", "viewer", fmt.Sprintf("user:u%d", i)))
	}
	s := newCostStore(t, plainDSL, tuples)

	n, calls := listUsersCount(t, s, "doc", s.ids.ID("d"), "viewer",
		"user")
	if n != 1000 {
		t.Fatalf("users = %d, want the 1000 cap", n)
	}
	if got := calls["fga._lu_union"]; got != 1000 {
		t.Errorf("fga._lu_union calls = %d, want 1000", got)
	}
}

// The caps are database-wide settings, like upstream's server
// config: 0 lifts the cap and a negative value is refused. The
// oracle's cap is fixed by its own config, so this is engine-only.
//
// Other tests rely on the default 1000 while this one runs, so every
// change is made inside a transaction that is rolled back, with the
// list call made in that same transaction.
func TestListMaxResultsSetting(t *testing.T) {
	// anne sees 1,005 docs: d1..d1004 directly, and doc:shared,
	// whose 1,005 viewers are anne and u1..u1004.
	var tuples []*openfgav1.TupleKey
	tuples = append(tuples, tk("doc:shared", "viewer", "user:anne"))
	for i := 1; i < 1005; i++ {
		tuples = append(tuples,
			tk(fmt.Sprintf("doc:d%d", i), "viewer", "user:anne"),
			tk("doc:shared", "viewer", fmt.Sprintf("user:u%d", i)))
	}
	s := newCostStore(t, plainDSL, tuples)
	objectsReq := jsonArg(t, map[string]any{
		"type": "doc", "relation": "viewer",
		"user": s.user("user", "anne"),
	})
	usersReq := jsonArg(t, map[string]any{
		"object": map[string]string{
			"type": "doc", "id": s.ids.ID("shared"),
		},
		"relation":     "viewer",
		"user_filters": []map[string]string{{"type": "user"}},
	})
	lists := []struct {
		setting, stmt string
		req           []byte
	}{
		{"list_objects_max_results", `SELECT jsonb_array_length(
		   fga.list_objects($1, $2) -> 'objects')`, objectsReq},
		{"list_users_max_results", `SELECT jsonb_array_length(
		   fga.list_users($1, $2) -> 'users')`, usersReq},
	}

	ctx := context.Background()
	pool := testdb.Pool(t)
	for _, l := range lists {
		count := func(q interface {
			QueryRow(context.Context, string, ...any) pgx.Row
		}) int {
			var n int
			if err := q.QueryRow(ctx, l.stmt, s.id, l.req).
				Scan(&n); err != nil {
				t.Fatalf("%s: %v", l.setting, err)
			}
			return n
		}
		for _, c := range []struct{ value, want int }{
			{0, 1005}, {10, 10},
		} {
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			_, err = tx.Exec(ctx,
				"UPDATE fga.setting SET value = $1 WHERE name = $2",
				c.value, l.setting)
			if err != nil {
				t.Fatalf("%s = %d: %v", l.setting, c.value, err)
			}
			got := count(tx)
			_ = tx.Rollback(ctx)
			if got != c.want {
				t.Errorf("%s = %d: answered %d, want %d",
					l.setting, c.value, got, c.want)
			}
		}
		if got := count(pool); got != 1000 {
			t.Errorf("%s after rollback: answered %d, want 1000",
				l.setting, got)
		}

		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		_, err = tx.Exec(ctx,
			"UPDATE fga.setting SET value = -1 WHERE name = $1",
			l.setting)
		_ = tx.Rollback(ctx)
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "23514" {
			t.Errorf("%s = -1: err = %v, want a check violation",
				l.setting, err)
		}
	}
}
