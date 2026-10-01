package conformance

import (
	"context"
	"testing"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// A generated function that hands a question to the generic resolver
// (here a recursive relation called with contextual tuples) asks the
// resolver itself, not the public entry point: on an opted-in store
// fga.check would dispatch straight back to the same generated
// function, which would hand off again — one wasted level per call.
//
// Mutation: drop the SET fga._dispatching clause from _compiled_check
// or _compiled_objects and the generated function runs twice.
func TestCompiledHandOffIsGeneric(t *testing.T) {
	s := newDispatchStore(t, true)
	ctxTuples := jsonArg(t, []map[string]string{{
		"object":   s.ref("group", "g2"),
		"relation": "member",
		"user":     s.ref("user", "dan"),
	}})
	cases := []struct {
		name, stmt, fn string
		rows           int
	}{
		{"check", "SELECT " + s.schema + ".group__member__check(" +
			"$1::uuid, 'user', $2::uuid, p_contextual_tuples => $3)",
			s.schema + ".group__member__check", 1},
		{"objects", "SELECT x FROM " + s.schema +
			".group__member__objects('user', $2::uuid, " +
			"p_contextual_tuples => $3) x WHERE $1::uuid IS NOT NULL",
			s.schema + ".group__member__objects", 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var n int
			err := testdb.Pool(t).QueryRow(context.Background(),
				"SELECT count(*)::int FROM ("+c.stmt+") q",
				s.ids.ID("g2"), s.ids.ID("dan"), ctxTuples).Scan(&n)
			if err != nil {
				t.Fatal(err)
			}
			if n != c.rows { // g2 itself, and g1 through g2#member
				t.Fatalf("answer rows = %d, want %d", n, c.rows)
			}
			counts := callCounts(t, c.stmt, s.ids.ID("g2"),
				s.ids.ID("dan"), ctxTuples)
			if counts[c.fn] != 1 || s.generated(counts) != 1 {
				t.Errorf("%s called %d times, generated %d, "+
					"want 1 and 1: %v", c.fn, counts[c.fn],
					s.generated(counts), counts)
			}
		})
	}
}
