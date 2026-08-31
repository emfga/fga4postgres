package conformance

import (
	"fmt"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
)

// Does any fast-path resolver shape change the measured depth
// boundary (first 2002 at 26 dispatches)? Probed on the two
// remaining recursion shapes: a TTU parent chain and a
// self-recursive TTU.
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
		if boundary != 26 {
			t.Errorf("%s: boundary at %d, want 26",
				side.name, boundary)
		}
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
