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

// subjectsDSL puts wildcards behind every strategy __subjects
// meets: a flattened direct wildcard (group#member), one reached
// through a userset (doc#reader), one under an exclusion the
// generator delegates (doc#viewer), and a union of both kinds.
const subjectsDSL = `model
  schema 1.1
type user
type group
  relations
    define member: [user, user:*]
type doc
  relations
    define banned: [user]
    define reader: [user, group#member]
    define viewer: [user, user:*] but not banned
    define can_read: reader or viewer`

func subjectsTuples() []*openfgav1.TupleKey {
	return []*openfgav1.TupleKey{
		tk("doc:pub", "viewer", "user:*"),
		tk("doc:pub", "viewer", "user:carl"),
		tk("doc:pub", "banned", "user:anne"),
		tk("doc:pub", "banned", "user:bob"),
		tk("doc:pub", "banned", "user:dave"),
		tk("doc:pub", "reader", "group:team#member"),
		tk("group:everyone", "member", "user:*"),
		tk("group:team", "member", "user:dave"),
		tk("doc:g", "reader", "group:everyone#member"),
		tk("doc:t", "reader", "group:team#member"),
		tk("doc:t", "reader", "user:erin"),
	}
}

// compiledStore creates a store on the plain engine client, opts it
// in to schema, writes the model and the tuples, and returns the
// store id and the test's uuid map.
func compiledStore(
	t *testing.T, schema, dsl string, tuples []*openfgav1.TupleKey,
) (string, *uuidmap.Map) {
	t.Helper()
	ctx := context.Background()
	client := compiledEngine(t)
	store, err := client.CreateStore(ctx,
		&openfgav1.CreateStoreRequest{Name: t.Name()})
	if err != nil {
		t.Fatal(err)
	}
	enableCompiled(t, store.GetId(), schema)
	storeID, modelID := setupModel(t, client, store.GetId(), dsl)
	for start := 0; start < len(tuples); start += 40 {
		end := min(start+40, len(tuples))
		_, err := client.Write(ctx, &openfgav1.WriteRequest{
			StoreId:              storeID,
			AuthorizationModelId: modelID,
			Writes: &openfgav1.WriteRequestWrites{
				TupleKeys: tuples[start:end],
			},
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		_ = client.DeleteStore(context.Background(), storeID)
	})
	return storeID, uuidmap.New("compiled/" + t.Name())
}

// uuidSet runs a query returning uuids and renders them through the
// map, sorted.
func uuidSet(
	t *testing.T, ids *uuidmap.Map, q string, args ...any,
) ([]string, error) {
	t.Helper()
	rows, err := testdb.Pool(t).Query(context.Background(), q, args...)
	if err != nil {
		return nil, err
	}
	got, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	for i, v := range got {
		got[i] = ids.Back(v)
	}
	sort.Strings(got)
	return got, nil
}

// __subjects returns the final list (decision 8): a wildcard grant
// expands over the subject source the store registered, minus the
// relation's exclusions, and usersets expand to their members. The
// reference is the engine's own check, one subject at a time over
// the same source — upstream's ListUsers answers user:* and cannot
// say who is excluded from it.
func TestCompiledSubjectsWildcard(t *testing.T) {
	ctx := context.Background()
	pool := testdb.Pool(t)
	schema := compiledSchema(t)
	storeID, ids := compiledStore(t, schema, subjectsDSL,
		subjectsTuples())
	users := []string{
		"anne", "bob", "carl", "dave", "erin", "frank", "gina",
	}
	source := schema + ".app_user(user_id)"
	_, err := pool.Exec(ctx, "CREATE TABLE "+schema+
		".app_user (user_id uuid PRIMARY KEY)")
	if err != nil {
		t.Fatal(err)
	}
	for _, u := range users {
		_, err := pool.Exec(ctx, "INSERT INTO "+schema+
			".app_user VALUES ($1)", ids.ID(u))
		if err != nil {
			t.Fatal(err)
		}
	}
	// Map every id first: Back only knows ids ID has seen.
	for _, id := range []string{"everyone", "team", "pub", "g", "t"} {
		ids.ID(id)
	}
	type ask struct{ typ, obj, rel string }
	var asks []ask
	for _, o := range []string{"everyone", "team"} {
		asks = append(asks, ask{"group", o, "member"})
	}
	for _, o := range []string{"pub", "g", "t"} {
		for _, r := range []string{
			"banned", "reader", "viewer", "can_read",
		} {
			asks = append(asks, ask{"doc", o, r})
		}
	}
	subjects := func(a ask) ([]string, error) {
		return uuidSet(t, ids, fmt.Sprintf(
			"SELECT x::text FROM %s.%s__%s__subjects($1::uuid, 'user') x",
			schema, a.typ, a.rel), ids.ID(a.obj))
	}

	t.Run("without_source", func(t *testing.T) {
		wild := map[string]bool{
			"group#member": true, "doc#reader": true,
			"doc#viewer": true, "doc#can_read": true,
		}
		rows, err := pool.Query(ctx, `
			SELECT type_name || '#' || relation_name,
			       coalesce(reason, '')
			FROM fga.compiled_relation WHERE store = $1`, storeID)
		if err != nil {
			t.Fatal(err)
		}
		reasons := map[string]string{}
		for rows.Next() {
			var rel, reason string
			if err := rows.Scan(&rel, &reason); err != nil {
				t.Fatal(err)
			}
			reasons[rel] = reason
		}
		rows.Close()
		for rel, reason := range reasons {
			says := strings.Contains(reason,
				"no subject source registered for wildcard type user")
			if says != wild[rel] {
				t.Errorf("%s reason %q: names the missing source = %v, "+
					"want %v", rel, reason, says, wild[rel])
			}
		}
		for _, a := range []ask{
			{"group", "everyone", "member"}, {"doc", "pub", "viewer"},
			{"doc", "g", "reader"}, {"doc", "pub", "can_read"},
		} {
			got, err := subjects(a)
			if err == nil || !strings.Contains(err.Error(),
				"no subject source registered for type 'user'") {
				t.Errorf("%s:%s#%s without a source: %v, %v; want the "+
					"missing-source error", a.typ, a.obj, a.rel, got, err)
			}
		}
		// No wildcard on the way: the list needs no source.
		got, err := subjects(ask{"doc", "t", "reader"})
		if err != nil || !slices.Equal(got, []string{"dave", "erin"}) {
			t.Errorf("doc:t#reader = %v, %v; want [dave erin]", got, err)
		}
	})

	_, err = pool.Exec(ctx,
		"SELECT fga.enable_compiled_relations($1, $2, $3)",
		storeID, schema, fmt.Sprintf(`{"user": %q}`, source))
	if err != nil {
		t.Fatal(err)
	}

	t.Run("source_reason_cleared", func(t *testing.T) {
		n := queryInt(t, `SELECT count(*)::int FROM fga.compiled_relation
			WHERE store = $1 AND reason LIKE '%no subject source%'`,
			storeID)
		if n != 0 {
			t.Errorf("%d relations still report a missing source", n)
		}
	})

	t.Run("matches_check", func(t *testing.T) {
		for _, a := range asks {
			want, err := uuidSet(t, ids, `
				SELECT s.user_id::text FROM `+schema+`.app_user s
				WHERE (fga.check($1, jsonb_build_object('tuple_key',
				  jsonb_build_object('object', $2::text || ':' || $3::text,
				    'relation', $4::text, 'user', 'user:' || s.user_id)))
				  ->> 'allowed')::boolean`,
				storeID, a.typ, ids.ID(a.obj), a.rel)
			if err != nil {
				t.Fatal(err)
			}
			got, err := subjects(a)
			if err != nil || !slices.Equal(got, want) {
				t.Errorf("%s:%s#%s subjects = %v (%v), check allows %v",
					a.typ, a.obj, a.rel, got, err, want)
			}
		}
	})

	t.Run("userset_filter", func(t *testing.T) {
		for _, rel := range []string{"reader", "can_read"} {
			got, err := uuidSet(t, ids, fmt.Sprintf(
				"SELECT x::text FROM %s.doc__%s__subjects($1::uuid, "+
					"'group', 'member') x", schema, rel), ids.ID("t"))
			if err != nil || !slices.Equal(got, []string{"team"}) {
				t.Errorf("doc:t#%s group#member = %v (%v), want [team]",
					rel, got, err)
			}
		}
	})

	t.Run("uncapped", subjectsUncapped)
}

// __subjects is the set the application filters or pages in its own
// query, so like __objects it carries no result cap whatever
// strategy answers it. The exclusion is delegated to the generic
// resolver, where list_users' cap could leak in.
func subjectsUncapped(t *testing.T) {
	const n = 1005
	tuples := make([]*openfgav1.TupleKey, 0, n+1)
	for i := range n {
		tuples = append(tuples,
			tk("doc:big", "viewer", fmt.Sprintf("user:u%d", i)))
	}
	tuples = append(tuples, tk("doc:big", "banned", "user:u0"))
	schema := compiledSchema(t)
	_, ids := compiledStore(t, schema, subjectsDSL, tuples)
	got := queryInt(t, fmt.Sprintf(
		`SELECT count(*)::int
		 FROM %s.doc__viewer__subjects($1::uuid, 'user') x`,
		schema), ids.ID("big"))
	if got != n-1 {
		t.Fatalf("doc:big#viewer subjects = %d, want %d", got, n-1)
	}
}
