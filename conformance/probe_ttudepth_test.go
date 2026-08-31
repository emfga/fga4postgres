package conformance

import (
	"fmt"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
)

func TestProbeTTUDepthBoundary(t *testing.T) {
	dsl := `model
  schema 1.1
type user
type role
  relations
    define parent: [role]
    define direct_member: [user]
    define member: direct_member or member from parent
`
	var tuples []*openfgav1.TupleKey
	for i := 1; i < 30; i++ {
		tuples = append(tuples, tk(
			fmt.Sprintf("role:r%02d", i), "parent",
			fmt.Sprintf("role:r%02d", i+1)))
	}
	tuples = append(tuples,
		tk("role:r30", "direct_member", "user:alice"))

	for _, s := range bothSides(t, "ttudepth") {
		store, model := setup(t, s.client, dsl, tuples)
		for _, n := range []int{3, 4, 5, 6, 7} {
			res := doCheck(t, s.client, store, model,
				fmt.Sprintf("role:r%02d", n), "member",
				"user:dan", nil, nil)
			t.Logf("OBSERVED %s: r%02d (%d hops) dan: %v",
				s.name, n, 30-n, res)
			res = doCheck(t, s.client, store, model,
				fmt.Sprintf("role:r%02d", n), "member",
				"user:alice", nil, nil)
			t.Logf("OBSERVED %s: r%02d (%d hops) alice: %v",
				s.name, n, 30-n, res)
		}
	}
}
