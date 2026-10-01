package conformance

import (
	"context"
	"fmt"
	"slices"
	"sort"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// anySubjectDSL mixes the strategies a wildcard question meets: a
// direct wildcard, one inherited through a tuple-to-userset, and an
// exclusion the generator delegates to the generic resolver.
const anySubjectDSL = `model
  schema 1.1
type user
type folder
  relations
    define viewer: [user, user:*]
type doc
  relations
    define parent: [folder]
    define banned: [user]
    define viewer: [user, user:*] or viewer from parent
    define open: [user, user:*] but not banned`

func anySubjectTuples() []*openfgav1.TupleKey {
	return []*openfgav1.TupleKey{
		tk("folder:f1", "viewer", "user:*"),
		tk("folder:f2", "viewer", "user:anne"),
		tk("doc:d1", "parent", "folder:f1"),
		tk("doc:d2", "viewer", "user:*"),
		tk("doc:d3", "viewer", "user:anne"),
		tk("doc:d4", "open", "user:*"),
		tk("doc:d4", "banned", "user:bob"),
		tk("doc:d5", "open", "user:anne"),
		tk("doc:d6", "parent", "folder:f2"),
	}
}

const nilUUID = "00000000-0000-0000-0000-000000000000"

// Generated functions answer the API's "type:*" question through
// an explicit p_any_subject flag, and refuse the nil uuid as an id
// exactly as the public API does (decision 16): nil is the
// engine's internal wildcard sentinel and must never be reachable
// as an ordinary id, or a caller passing an unset uuid would be
// asking — and granted — the wildcard question.
func TestCompiledAnySubject(t *testing.T) {
	ctx := context.Background()
	const suite = "compiled_anysubject"
	sides := bothSides(t, suite)
	tuples := anySubjectTuples()
	for i := range sides {
		sides[i].storeID, sides[i].modelID = setup(
			t, sides[i].client, anySubjectDSL, tuples)
	}
	engine, oracleSide := sides[0], sides[1]
	schema := compiledSchema(t)
	enableCompiled(t, engine.storeID, schema)
	ids := uuidmap.New("probe/" + suite)
	pool := testdb.Pool(t)

	type rel struct{ typ, name string }
	rels := []rel{
		{"folder", "viewer"}, {"doc", "viewer"},
		{"doc", "open"}, {"doc", "banned"},
	}
	objects := map[string][]string{
		"folder": {"f1", "f2"},
		"doc":    {"d1", "d2", "d3", "d4", "d5", "d6"},
	}
	fn := func(r rel, kind string) string {
		return fmt.Sprintf("%s.%s__%s__%s", schema, r.typ, r.name, kind)
	}

	// The public API's refusal of a nil id is the reference.
	var apiErr error
	_, apiErr = pool.Exec(ctx, `SELECT fga.check($1, jsonb_build_object(
		'tuple_key', jsonb_build_object('object', 'doc:' || $2,
		  'relation', 'viewer', 'user', 'user:' || $3)))`,
		engine.storeID, ids.ID("d1"), nilUUID)
	if apiErr == nil {
		t.Fatal("fga.check accepted the nil uuid as a user id")
	}
	refused := func(t *testing.T, label string, err error) {
		t.Helper()
		if err == nil {
			t.Errorf("%s: accepted, want the id-domain refusal", label)
			return
		}
		if sqlState(err) != sqlState(apiErr) ||
			!strings.Contains(err.Error(), "fga4postgres id domain") {
			t.Errorf("%s: %v, want %v", label, err, apiErr)
		}
	}
	anne := ids.ID("anne")
	d1 := ids.ID("d1")

	t.Run("nil_id_refused", func(t *testing.T) {
		for _, r := range rels {
			_, err := pool.Exec(ctx, fmt.Sprintf(
				"SELECT count(*) FROM %s('user', $1::uuid) x",
				fn(r, "objects")), nilUUID)
			refused(t, fn(r, "objects")+" subject", err)
			_, err = pool.Exec(ctx, fmt.Sprintf(
				"SELECT %s($1::uuid, 'user', $2::uuid)",
				fn(r, "check")), d1, nilUUID)
			refused(t, fn(r, "check")+" subject", err)
			_, err = pool.Exec(ctx, fmt.Sprintf(
				"SELECT %s($1::uuid, 'user', $2::uuid)",
				fn(r, "check")), nilUUID, anne)
			refused(t, fn(r, "check")+" object", err)
			_, err = pool.Exec(ctx, fmt.Sprintf(
				"SELECT count(*) FROM %s($1::uuid, 'user') x",
				fn(r, "subjects")), nilUUID)
			refused(t, fn(r, "subjects")+" object", err)
		}
	})

	t.Run("any_subject_with_id_refused", func(t *testing.T) {
		for _, r := range rels {
			_, err := pool.Exec(ctx, fmt.Sprintf(
				"SELECT count(*) FROM %s('user', $1::uuid, "+
					"p_any_subject => true) x", fn(r, "objects")), anne)
			if sqlState(err) != "YF100" {
				t.Errorf("%s: any subject with an id: %v, want YF100",
					fn(r, "objects"), err)
			}
			_, err = pool.Exec(ctx, fmt.Sprintf(
				"SELECT %s($1::uuid, 'user', $2::uuid, "+
					"p_any_subject => true)", fn(r, "check")), d1, anne)
			if sqlState(err) != "YF100" {
				t.Errorf("%s: any subject with an id: %v, want YF100",
					fn(r, "check"), err)
			}
		}
	})

	t.Run("null_id_refused", func(t *testing.T) {
		for _, r := range rels {
			_, err := pool.Exec(ctx, fmt.Sprintf(
				"SELECT count(*) FROM %s('user', NULL) x",
				fn(r, "objects")))
			if sqlState(err) != "YF100" {
				t.Errorf("%s: null subject id: %v, want YF100",
					fn(r, "objects"), err)
			}
		}
	})

	// p_any_subject = true is the API's user:* question: compare
	// every object with the oracle's check of user:*, and __objects
	// with the set the oracle allows.
	t.Run("any_subject_matches_oracle", func(t *testing.T) {
		for _, r := range rels {
			var want []string
			for _, o := range objects[r.typ] {
				res := doCheck(t, oracleSide.client, oracleSide.storeID,
					oracleSide.modelID, r.typ+":"+o, r.name, "user:*",
					nil, nil)
				var got bool
				err := pool.QueryRow(ctx, fmt.Sprintf(
					"SELECT %s($1::uuid, 'user', NULL, "+
						"p_any_subject => true)", fn(r, "check")),
					ids.ID(o)).Scan(&got)
				if res.err != nil {
					if err == nil {
						t.Errorf("%s:%s#%s user:*: compiled %v, oracle %v",
							r.typ, o, r.name, got, res)
					}
					continue
				}
				if err != nil || got != res.allowed {
					t.Errorf("%s:%s#%s user:*: compiled %v (%v), "+
						"oracle %v", r.typ, o, r.name, got, err, res)
				}
				if res.allowed {
					want = append(want, o)
				}
			}
			rows, err := pool.Query(ctx, fmt.Sprintf(
				"SELECT x::text FROM %s('user', NULL, "+
					"p_any_subject => true) x", fn(r, "objects")))
			if err != nil {
				t.Fatalf("%s: %v", fn(r, "objects"), err)
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
			sort.Strings(got)
			sort.Strings(want)
			if !slices.Equal(got, want) {
				t.Errorf("%s user:* objects = %v, oracle allows %v",
					fn(r, "objects"), got, want)
			}
		}
	})
}
