package conformance

import (
	"fmt"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
)

// Where does each strategy put the depth boundary? Upstream's
// recursive resolver, chosen for this self-recursive TTU chain,
// first refuses at 26 dispatches; the engine refuses the 25th on
// every relation (PIN-DEPTH-1).
const ttuChainDSL = `model
  schema 1.1
type user
type folder
  relations
    define parent: [folder]
    define viewer: [user] or viewer from parent
`

func TestProbeTTUChainBoundary(t *testing.T) {
	tuples := []*openfgav1.TupleKey{
		tk("folder:f0", "viewer", "user:anne"),
	}
	for i := 1; i <= 30; i++ {
		tuples = append(tuples, tk(
			fmt.Sprintf("folder:f%d", i), "parent",
			fmt.Sprintf("folder:f%d", i-1)))
	}
	for _, side := range bothSides(t, "ttu-chain") {
		store, model := setup(t, side.client, ttuChainDSL, tuples)
		boundary := -1
		for n := 20; n <= 30; n++ {
			r := doCheck(t, side.client, store, model,
				fmt.Sprintf("folder:f%d", n), "viewer",
				"user:anne", nil, nil)
			t.Logf("OBSERVED(%s): ttu chain n=%d: %v",
				side.name, n, r)
			if (r.err != nil || !r.allowed) && boundary == -1 {
				boundary = n
				if r.code != 2002 {
					t.Errorf("%s: boundary error code %d, "+
						"want 2002", side.name, r.code)
				}
			}
		}
		want := 26
		if side.name == "engine" {
			want = 25
		}
		if boundary != want {
			t.Errorf("%s: boundary at %d, want %d",
				side.name, boundary, want)
		}
	}
}

// Relations upstream leaves to its default resolver refuse the 25th
// dispatch, and so does the engine. Before the engine adopted that
// budget it granted here, on the oncall real-world fixture's team
// tree among others. Two shapes: a chain alternating two relations,
// and a self-recursive TTU beside a second TTU operand, which keeps
// it off the recursive resolver.
func TestProbeDefaultResolverBoundary(t *testing.T) {
	shapes := []struct{ name, dsl string }{
		{"alternating", `model
  schema 1.1
type user
type node
  relations
    define next: [node]
    define a: [user] or b from next
    define b: [user] or a from next
`},
		{"ttu-beside-ttu", `model
  schema 1.1
type user
type org
  relations
    define m: [user]
type node
  relations
    define next: [node]
    define org: [org]
    define a: [user] or a from next or m from org
`},
	}
	for _, shape := range shapes {
		t.Run(shape.name, func(t *testing.T) {
			for _, n := range []int{24, 25} {
				var tuples []*openfgav1.TupleKey
				for i := 0; i < n; i++ {
					tuples = append(tuples, tk(
						fmt.Sprintf("node:n%d", i), "next",
						fmt.Sprintf("node:n%d", i+1)))
				}
				rel := "a"
				if shape.name == "alternating" && n%2 == 1 {
					rel = "b"
				}
				tuples = append(tuples, tk(
					fmt.Sprintf("node:n%d", n), rel, "user:anne"))
				for _, side := range bothSides(t,
					fmt.Sprintf("%s-%d", shape.name, n)) {
					store, model := setup(t, side.client,
						shape.dsl, tuples)
					r := doCheck(t, side.client, store, model,
						"node:n0", "a", "user:anne", nil, nil)
					t.Logf("OBSERVED(%s): %d dispatches: %v",
						side.name, n, r)
					ok := r.err == nil && r.allowed
					if n == 24 && !ok {
						t.Errorf("%s: 24 dispatches: %v, "+
							"want allowed=true", side.name, r)
					}
					if n == 25 && r.code != 2002 {
						t.Errorf("%s: 25 dispatches: %v, "+
							"want 2002", side.name, r)
					}
				}
			}
		})
	}
}

// Wide-but-shallow weight-2 shape for the same question from the
// other side: a single userset level fanned out never charges more
// than two levels, so it must never hit the budget.
func TestProbeWeight2Wide(t *testing.T) {
	var tuples []*openfgav1.TupleKey
	for i := 0; i < 200; i++ {
		g := fmt.Sprintf("group:g%d", i)
		tuples = append(tuples,
			tk("doc:1", "deep", g+"#member"),
			tk(g, "member", "user:other"))
	}
	tuples = append(tuples,
		tk("group:g199", "member", "user:anne"))
	for _, side := range bothSides(t, "wide-fanout") {
		store, model := setup(t, side.client, depthDSL, tuples)
		r := doCheck(t, side.client, store, model,
			"doc:1", "deep", "user:anne", nil, nil)
		t.Logf("OBSERVED(%s): 200-wide weight-2: %v",
			side.name, r)
		if r.err != nil || !r.allowed {
			t.Fatalf("%s: weight-2 wide: want true, got %v",
				side.name, r)
		}
	}
}
