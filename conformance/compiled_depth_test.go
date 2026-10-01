package conformance

import (
	"fmt"
	"strconv"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
)

// Each generated kind spends depth like its counterpart, on the two
// deep-chain shapes of TestProbeTTUChainBoundary and
// TestProbeDeepChainEnvelope: __check refuses exactly where
// fga.check refuses (25 dispatches resolve, the 26th raises YF102,
// never a silent false), __subjects refuses where list_users does,
// and __objects charges no depth and lists the whole chain like
// list_objects.
func TestCompiledDepthEnvelope(t *testing.T) {
	const links = 40
	ttu := []*openfgav1.TupleKey{tk("folder:f0", "viewer", "user:anne")}
	for i := 1; i <= links; i++ {
		ttu = append(ttu, tk(fmt.Sprintf("folder:f%d", i), "parent",
			fmt.Sprintf("folder:f%d", i-1)))
	}
	cases := []struct {
		name, dsl, typ, rel, prefix string
		tuples                      []*openfgav1.TupleKey
	}{
		{"ttu_chain", ttuChainDSL, "folder", "viewer", "f", ttu},
		{"userset_chain", chainGroupsDSL, "group", "member", "g",
			groupChain(links)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newCompiledFixture(t, c.dsl, c.tuples)
			if s := f.strategy(t, c.typ+"#"+c.rel); s != "recursive" {
				t.Fatalf("%s#%s: strategy %s, want recursive",
					c.typ, c.rel, s)
			}
			fn := func(kind string) string {
				return fmt.Sprintf("%s.%s__%s__%s",
					f.schema, c.typ, c.rel, kind)
			}
			for i := 0; i <= links; i++ {
				f.ids.ID(c.prefix + strconv.Itoa(i))
			}

			for i := 0; i <= links; i++ {
				obj := f.ids.ID(c.prefix + strconv.Itoa(i))
				for _, user := range []string{"anne", "dan"} {
					got := f.outcome(t, fmt.Sprintf(
						"SELECT %s($1::uuid, 'user', $2::uuid)::text",
						fn("check")), obj, f.ids.ID(user))
					want := f.outcome(t, `
						SELECT fga.check($1, jsonb_build_object(
						  'tuple_key', jsonb_build_object(
						    'object', $2 || ':' || $3,
						    'relation', $4::text,
						    'user', 'user:' || $5))) ->> 'allowed'`,
						f.storeID, c.typ, obj, c.rel, f.ids.ID(user))
					if got != want {
						t.Errorf("%s%d %s: __check %q, check %q",
							c.prefix, i, user, got, want)
					}
					// The fixture itself: 25 dispatches resolve,
					// the 26th refuses.
					if user == "anne" && i == 25 && want != "true" {
						t.Errorf("check at 25 links = %q, want true",
							want)
					}
					if i == 26 && want != "error YF102" {
						t.Errorf("check %s at 26 links = %q, want "+
							"error YF102", user, want)
					}
				}

				got := f.outcome(t, fmt.Sprintf(
					"SELECT x::text FROM %s($1::uuid, 'user') x",
					fn("subjects")), obj)
				want := f.outcome(t, `
					SELECT u -> 'object' ->> 'id'
					FROM jsonb_array_elements(fga.list_users($1,
					  jsonb_build_object(
					    'object', jsonb_build_object(
					      'type', $2::text, 'id', $3::text),
					    'relation', $4::text,
					    'user_filters',
					    '[{"type": "user"}]'::jsonb)) -> 'users') u`,
					f.storeID, c.typ, obj, c.rel)
				if got != want {
					t.Errorf("%s%d: __subjects %q, list_users %q",
						c.prefix, i, got, want)
				}
			}

			all := f.outcome(t, fmt.Sprintf(
				"SELECT x::text FROM %s('user', $1::uuid) x",
				fn("objects")), f.ids.ID("anne"))
			if n := len(strings.Split(all, ",")); n != links+1 {
				t.Errorf("__objects lists %d of %d: %s",
					n, links+1, all)
			}
		})
	}
}
