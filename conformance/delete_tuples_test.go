package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// fga.delete_tuples is beyond upstream, so there is no oracle to
// compare with: these tests pin its own contract (sql/050_tuple.sql).

const deleteTuplesDSL = `model
  schema 1.1
type user
type group
  relations
    define member: [user]
type doc
  relations
    define viewer: [user, user:*, group#member, user with ok]
    define editor: [user, group]
condition ok(x: string) {
  x == "a"
}`

// deleteFixture is a store holding the tuples below, created in tx.
type deleteFixture struct {
	store string
	ids   *uuidmap.Map
}

var deleteTuples = [][3]string{
	{"doc:d1", "viewer", "user:*"},
	{"doc:d1", "viewer", "group:g1#member"},
	{"doc:d1", "editor", "group:g1"},
	{"doc:d1", "editor", "user:anne"},
	{"doc:d2", "viewer", "user:anne"},
	{"doc:d2", "editor", "user:bob"},
	{"group:g1", "member", "user:anne"},
}

// The one conditioned tuple, written apart from deleteTuples.
const deleteConditioned = "doc:d1#viewer@user:anne ok{\"x\": \"a\"}"

func newDeleteFixture(t *testing.T, tx pgx.Tx) deleteFixture {
	t.Helper()
	ctx := context.Background()
	f := deleteFixture{ids: uuidmap.New("delete_tuples")}
	err := tx.QueryRow(ctx,
		"SELECT id::text FROM fga.create_store($1)", t.Name()).
		Scan(&f.store)
	if err != nil {
		t.Fatal(err)
	}
	_, err = tx.Exec(ctx,
		"SELECT fga.write_authorization_model($1, $2)",
		f.store, modelJSON(t, deleteTuplesDSL))
	if err != nil {
		t.Fatalf("model: %v", err)
	}
	keys := []map[string]any{{
		"object": f.ref("doc:d1"), "relation": "viewer",
		"user": f.ref("user:anne"),
		"condition": map[string]any{
			"name": "ok", "context": map[string]any{"x": "a"}},
	}}
	for _, k := range deleteTuples {
		keys = append(keys, map[string]any{
			"object": f.ref(k[0]), "relation": k[1],
			"user": f.ref(k[2])})
	}
	req, err := json.Marshal(map[string]any{
		"writes": map[string]any{"tuple_keys": keys}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, "SELECT fga.write($1, $2)",
		f.store, req); err != nil {
		t.Fatalf("tuples: %v", err)
	}
	return f
}

// ref maps "type:id[#rel]" to the engine's spelling; "*" stays.
func (f deleteFixture) ref(s string) string {
	typ, rest, _ := strings.Cut(s, ":")
	id, rel, hasRel := strings.Cut(rest, "#")
	if id != "*" {
		id = f.ids.ID(id)
	}
	if hasRel {
		return typ + ":" + id + "#" + rel
	}
	return typ + ":" + id
}

// back renders an id the way deleteTuples spells it.
func (f deleteFixture) back(id string) string {
	if id == nilUUID {
		return "*"
	}
	return f.ids.Back(id)
}

// deleted runs fga.delete_tuples with the given named arguments
// and renders the rows it returned, sorted. An error is returned
// as "error <SQLSTATE>".
func (f deleteFixture) deleted(
	t *testing.T, q queryer, named string, args ...any,
) string {
	t.Helper()
	rows, err := q.Query(context.Background(), `
		SELECT object_type, object_id::text, relation, subject_type,
		  subject_id::text, subject_relation,
		  coalesce(condition_name, ''),
		  coalesce(condition_context::text, '')
		FROM fga.delete_tuples($1`+named+`)`,
		append([]any{f.store}, args...)...)
	if err != nil {
		return "error " + sqlState(err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var ot, oid, rel, st, sid, srel, cn, cc string
		if err := rows.Scan(&ot, &oid, &rel, &st, &sid, &srel,
			&cn, &cc); err != nil {
			t.Fatal(err)
		}
		r := fmt.Sprintf("%s:%s#%s@%s:%s", ot, f.back(oid), rel, st,
			f.back(sid))
		if srel != "" {
			r += "#" + srel
		}
		if cn != "" {
			r += " " + cn + cc
		}
		got = append(got, r)
	}
	if err := rows.Err(); err != nil {
		return "error " + sqlState(err)
	}
	slices.Sort(got)
	return strings.Join(got, ", ")
}

type queryer interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

func (f deleteFixture) count(t *testing.T, q queryer) int {
	t.Helper()
	rows, err := q.Query(context.Background(),
		"SELECT count(*)::int FROM fga.tuple WHERE store = $1", f.store)
	if err != nil {
		t.Fatal(err)
	}
	n, err := pgx.CollectExactlyOneRow(rows, pgx.RowTo[int])
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// Each filter deletes exactly the tuples it matches and returns
// them, conditions included; nothing else in the store goes.
func TestDeleteTuples(t *testing.T) {
	ids := uuidmap.New("delete_tuples")
	anne, bob, g1 := ids.ID("anne"), ids.ID("bob"), ids.ID("g1")
	d1, d2 := ids.ID("d1"), ids.ID("d2")
	cases := []struct {
		name, named string
		args        []any
		want        []string
	}{
		{"a subject", ", subject_type => 'user', " +
			"subject_ids => ARRAY[$2::uuid]", []any{anne}, []string{
			"doc:d1#editor@user:anne", deleteConditioned,
			"doc:d2#viewer@user:anne", "group:g1#member@user:anne"}},
		{"subjects", ", subject_type => 'user', " +
			"subject_ids => ARRAY[$2::uuid, $3::uuid]",
			[]any{anne, bob}, []string{
				"doc:d1#editor@user:anne", deleteConditioned,
				"doc:d2#editor@user:bob", "doc:d2#viewer@user:anne",
				"group:g1#member@user:anne"}},
		{"a subject, narrowed", ", subject_type => 'user', " +
			"subject_ids => ARRAY[$2::uuid], object_type => 'doc', " +
			"object_ids => ARRAY[$3::uuid], relations => '{viewer}'",
			[]any{anne, d2}, []string{"doc:d2#viewer@user:anne"}},
		{"an object", ", object_type => 'doc', " +
			"object_ids => ARRAY[$2::uuid]", []any{d1}, []string{
			"doc:d1#editor@group:g1", "doc:d1#editor@user:anne",
			"doc:d1#viewer@group:g1#member", "doc:d1#viewer@user:*",
			deleteConditioned}},
		{"an object, one subject type", ", object_type => 'doc', " +
			"object_ids => ARRAY[$2::uuid], subject_type => 'user'",
			[]any{d1}, []string{
				"doc:d1#editor@user:anne", "doc:d1#viewer@user:*",
				deleteConditioned}},
		{"any subject relation", ", subject_type => 'group', " +
			"subject_ids => ARRAY[$2::uuid]", []any{g1}, []string{
			"doc:d1#editor@group:g1",
			"doc:d1#viewer@group:g1#member"}},
		{"direct subjects only", ", subject_type => 'group', " +
			"subject_ids => ARRAY[$2::uuid], subject_relation => ''",
			[]any{g1}, []string{"doc:d1#editor@group:g1"}},
		{"usersets only", ", subject_type => 'group', " +
			"subject_ids => ARRAY[$2::uuid], " +
			"subject_relation => 'member'", []any{g1},
			[]string{"doc:d1#viewer@group:g1#member"}},
		{"the wildcard", ", subject_type => 'user', " +
			"subject_ids => ARRAY[$2::uuid]", []any{nilUUID},
			[]string{"doc:d1#viewer@user:*"}},
		{"empty ids", ", subject_type => 'user', " +
			"subject_ids => '{}'", nil, nil},
		{"empty relations", ", object_type => 'doc', " +
			"object_ids => ARRAY[$2::uuid], relations => '{}'",
			[]any{d1}, nil},
		{"a type the model lacks", ", object_type => 'folder', " +
			"object_ids => ARRAY[$2::uuid]", []any{d1}, nil},
	}
	ctx := context.Background()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tx, err := testdb.Pool(t).Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(ctx) }()
			f := newDeleteFixture(t, tx)
			before := f.count(t, tx)
			got := f.deleted(t, tx, c.named, c.args...)
			want := slices.Sorted(slices.Values(c.want))
			if want := strings.Join(want, ", "); got != want {
				t.Fatalf("deleted %q\nwant    %q", got, want)
			}
			if n := f.count(t, tx); n != before-len(c.want) {
				t.Errorf("%d tuples left, want %d", n,
					before-len(c.want))
			}
			// Gone means gone: the same call again deletes nothing.
			again := f.deleted(t, tx, c.named, c.args...)
			if again != "" {
				t.Errorf("second call deleted %q", again)
			}
		})
	}
}

// A filter that names neither a whole subject nor a whole object
// is refused, never read as "everything that matches the rest".
func TestDeleteTuplesNeedsAnAnchor(t *testing.T) {
	ids := uuidmap.New("delete_tuples")
	anne, d1 := ids.ID("anne"), ids.ID("d1")
	cases := []struct {
		name, named string
		args        []any
	}{
		{"no filter", "", nil},
		{"object type only", ", object_type => 'doc'", nil},
		{"object ids only", ", object_ids => ARRAY[$2::uuid]",
			[]any{d1}},
		{"subject type only", ", subject_type => 'user'", nil},
		{"subject ids only", ", subject_ids => ARRAY[$2::uuid]",
			[]any{anne}},
		{"relations only", ", relations => '{viewer}', " +
			"subject_relation => ''", nil},
		{"halves of both", ", object_type => 'doc', " +
			"subject_ids => ARRAY[$2::uuid]", []any{anne}},
	}
	ctx := context.Background()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tx, err := testdb.Pool(t).Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(ctx) }()
			f := newDeleteFixture(t, tx)
			before := f.count(t, tx)
			// A savepoint, so the store can be counted after the
			// refusal aborts it.
			sp, err := tx.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			got := f.deleted(t, sp, c.named, c.args...)
			if got != "error YF100" {
				t.Fatalf("got %q, want error YF100", got)
			}
			if err := sp.Rollback(ctx); err != nil {
				t.Fatal(err)
			}
			if n := f.count(t, tx); n != before {
				t.Errorf("%d tuples left, want %d", n, before)
			}
		})
	}
}

// Two revokes of the same subject at once: the second waits for
// the first and, once it commits, finds nothing left to return —
// DELETE ... RETURNING's own behaviour, so a caller writing one
// audit line per returned row never writes one twice.
func TestDeleteTuplesConcurrent(t *testing.T) {
	ctx := context.Background()
	pool := testdb.Pool(t)
	setup, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	f := newDeleteFixture(t, setup)
	if err := setup.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "SELECT fga.delete_store($1)", f.store)
	})
	const named = ", subject_type => 'user', " +
		"subject_ids => ARRAY[$2::uuid]"
	anne := f.ids.ID("anne")

	first, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = first.Rollback(ctx) }()
	if got := f.deleted(t, first, named, anne); got == "" {
		t.Fatal("first revoke deleted nothing")
	}

	second, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Release()
	var pid int
	if err := second.QueryRow(ctx,
		"SELECT pg_backend_pid()").Scan(&pid); err != nil {
		t.Fatal(err)
	}
	done := make(chan string, 1)
	go func() {
		// A query error comes back as the result, not a t.Fatal
		// off the test goroutine.
		done <- f.deleted(t, second, named, anne)
	}()

	waiting := false
	for range 100 {
		var n int
		if err := pool.QueryRow(ctx, `
			SELECT count(*)::int FROM pg_stat_activity
			WHERE pid = $1 AND wait_event_type = 'Lock'`,
			pid).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n == 1 {
			waiting = true
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !waiting {
		t.Fatal("second revoke did not wait for the first")
	}
	if err := first.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-done:
		if got != "" {
			t.Errorf("second revoke returned %q, want nothing", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("second revoke still waiting after the first " +
			"committed")
	}
}
