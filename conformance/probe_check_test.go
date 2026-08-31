package conformance

import (
	"fmt"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/oracle"
)

// Oracle probes: each test measures one load-bearing check
// behaviour against the pinned oracle; the OBSERVED lines are the
// record. These run against the oracle only — they define the
// contract the engine is built to.

// A computed-userset chain far beyond the depth limit still
// resolves — computed usersets spend no depth budget.
func TestProbeComputedChainFree(t *testing.T) {
	client := oracle.Client(t)
	store, model := setup(t, client, computedChainDSL(40),
		[]*openfgav1.TupleKey{tk("doc:1", "r0", "user:anne")})
	r := doCheck(t, client, store, model,
		"doc:1", "r40", "user:anne", nil, nil)
	t.Logf("OBSERVED: computed chain len=40: %v", r)
	if r.err != nil || !r.allowed {
		t.Fatalf("computed chain len=40: %v", r)
	}
}

// Userset dispatch chains — find the exact boundary where
// too-complex fires.
func TestProbeUsersetChainBoundary(t *testing.T) {
	client := oracle.Client(t)
	store, model := setup(
		t, client, chainGroupsDSL, groupChain(30),
	)
	boundary := -1
	for n := 20; n <= 30; n++ {
		r := doCheck(t, client, store, model,
			fmt.Sprintf("group:g%d", n), "member", "user:anne",
			nil, nil)
		t.Logf("OBSERVED: userset chain n=%d: %v", n, r)
		if r.err != nil && boundary == -1 {
			boundary = n
			if r.code != 2002 {
				t.Errorf("expected code 2002, got %d", r.code)
			}
		}
		if r.err == nil && !r.allowed {
			t.Errorf("n=%d: plain false, want true or error", n)
		}
	}
	t.Logf("OBSERVED: first error at chain length %d", boundary)
	if boundary == -1 {
		t.Fatal("no boundary found up to 30")
	}
}

// depthDSL wires a deep userset path and a direct path into
// union, intersection and exclusion shapes for the
// error-swallowing matrix.
const depthDSL = `model
  schema 1.1
type user
type group
  relations
    define member: [user, group#member]
type doc
  relations
    define direct: [user]
    define deep: [group#member]
    define union_dd: direct or deep
    define inter_dd: direct and deep
    define inter_rev: deep and direct
    define excl_base_deep: deep but not direct
    define excl_sub_deep: direct but not deep
`

// deepDocTuples links doc:1's deep relation to the top of a group
// chain long enough to exceed the depth budget.
func deepDocTuples(chainLen int) []*openfgav1.TupleKey {
	tuples := groupChain(chainLen)
	return append(tuples, tk("doc:1", "deep",
		fmt.Sprintf("group:g%d#member", chainLen)))
}

func TestProbeErrorSwallowing(t *testing.T) {
	client := oracle.Client(t)

	// Store A: direct also granted to anne.
	tuplesA := append(deepDocTuples(30),
		tk("doc:1", "direct", "user:anne"))
	storeA, modelA := setup(t, client, depthDSL, tuplesA)

	// Store B: only the deep path exists.
	storeB, modelB := setup(t, client, depthDSL,
		deepDocTuples(30))

	cases := []struct {
		store, model, relation, label string
	}{
		{storeA, modelA, "union_dd", "union, sibling true"},
		{storeB, modelB, "union_dd", "union, sibling false"},
		{storeA, modelA, "inter_dd", "inter, sibling true"},
		{storeB, modelB, "inter_dd", "inter, sibling false"},
		{storeA, modelA, "inter_rev", "inter rev, sib true"},
		{storeB, modelB, "inter_rev", "inter rev, sib false"},
		{storeA, modelA, "excl_base_deep", "excl deep base, sub true"},
		{storeB, modelB, "excl_base_deep", "excl deep base, sub false"},
		{storeA, modelA, "excl_sub_deep", "excl deep sub, base true"},
		{storeB, modelB, "excl_sub_deep", "excl deep sub, base false"},
	}
	for _, c := range cases {
		r := doCheck(t, client, c.store, c.model,
			"doc:1", c.relation, "user:anne", nil, nil)
		t.Logf("OBSERVED: %s: %v", c.label, r)
	}
}

// Tuple cycles — the cycle answer alone, and cycles feeding
// exclusion (both sides) and intersection.
const cycleDSL = `model
  schema 1.1
type user
type node
  relations
    define looped: [user, node#looped]
    define granted: [user]
    define excl_sub_cycle: granted but not looped
    define excl_base_cycle: looped but not granted
    define inter_cycle: granted and looped
    define x: [user, node#y]
    define y: [user, node#x]
    define excl_sub_mutual: granted but not x
    define inter_mutual: granted and x
`

func TestProbeCycles(t *testing.T) {
	client := oracle.Client(t)
	tuples := []*openfgav1.TupleKey{
		tk("node:1", "looped", "node:2#looped"),
		tk("node:2", "looped", "node:1#looped"),
		tk("node:1", "granted", "user:anne"),
		tk("node:1", "x", "node:2#y"),
		tk("node:2", "y", "node:1#x"),
	}
	store, model := setup(t, client, cycleDSL, tuples)
	for _, rel := range []string{
		"looped", "excl_sub_cycle", "excl_base_cycle",
		"inter_cycle", "x", "excl_sub_mutual", "inter_mutual",
	} {
		r := doCheck(t, client, store, model,
			"node:1", rel, "user:anne", nil, nil)
		t.Logf("OBSERVED: %s: %v", rel, r)
	}
}

// False-by-unreachable-type vs false-by-empty-traversal must
// be the same answer.
const pathExistsDSL = `model
  schema 1.1
type user
type employee
type doc
  relations
    define viewer: [user]
`

func TestProbePathExists(t *testing.T) {
	client := oracle.Client(t)
	store, model := setup(t, client, pathExistsDSL, nil)
	unreachable := doCheck(t, client, store, model,
		"doc:1", "viewer", "employee:eve", nil, nil)
	empty := doCheck(t, client, store, model,
		"doc:1", "viewer", "user:anne", nil, nil)
	t.Logf("OBSERVED: unreachable type: %v; empty traversal: %v",
		unreachable, empty)
	if unreachable.String() != empty.String() {
		t.Errorf("distinguishable: %v vs %v", unreachable, empty)
	}
}

// Undefined relation at the request vs undefined computed
// relation behind a TTU link.
const ttuUndefDSL = `model
  schema 1.1
type user
type team
  relations
    define exists: [user]
type folder
  relations
    define parent: [folder, team]
    define viewer: [user] or viewer from parent
`

func TestProbeUndefinedRelation(t *testing.T) {
	client := oracle.Client(t)
	tuples := []*openfgav1.TupleKey{
		// team defines no viewer: the TTU-linked undefined case.
		tk("folder:f", "parent", "team:t"),
		tk("team:t", "exists", "user:anne"),
	}
	store, model := setup(t, client, ttuUndefDSL, tuples)

	entry := doCheck(t, client, store, model,
		"folder:f", "nonexistent", "user:anne", nil, nil)
	ttu := doCheck(t, client, store, model,
		"folder:f", "viewer", "user:anne", nil, nil)
	t.Logf("OBSERVED: undefined at entry: %v; via TTU link: %v",
		entry, ttu)
	if entry.code == 0 {
		t.Error("undefined relation at entry did not error")
	}
	if ttu.err != nil || ttu.allowed {
		t.Errorf("TTU-linked undefined: want false, got %v", ttu)
	}
}

// Contextual-tuple API limits — count cap, duplicates within
// the request, duplicate against a stored tuple.
const plainDSL = `model
  schema 1.1
type user
type doc
  relations
    define viewer: [user]
`

func TestProbeContextualTupleLimits(t *testing.T) {
	client := oracle.Client(t)
	store, model := setup(t, client, plainDSL,
		[]*openfgav1.TupleKey{tk("doc:1", "viewer", "user:bob")})

	var hundred []*openfgav1.TupleKey
	for i := 0; i < 100; i++ {
		hundred = append(hundred, tk(
			fmt.Sprintf("doc:%d", i), "viewer", "user:anne"))
	}
	overCap := append(hundred[:100:100],
		tk("doc:100", "viewer", "user:anne"))

	atCap := doCheck(t, client, store, model,
		"doc:1", "viewer", "user:anne", hundred, nil)
	over := doCheck(t, client, store, model,
		"doc:1", "viewer", "user:anne", overCap, nil)
	dup := doCheck(t, client, store, model,
		"doc:1", "viewer", "user:anne",
		[]*openfgav1.TupleKey{
			tk("doc:1", "viewer", "user:anne"),
			tk("doc:1", "viewer", "user:anne"),
		}, nil)
	dupStored := doCheck(t, client, store, model,
		"doc:1", "viewer", "user:bob",
		[]*openfgav1.TupleKey{tk("doc:1", "viewer", "user:bob")},
		nil)
	t.Logf("OBSERVED: 100 ctx tuples: %v", atCap)
	t.Logf("OBSERVED: 101 ctx tuples: %v", over)
	t.Logf("OBSERVED: duplicate ctx tuples: %v", dup)
	t.Logf("OBSERVED: ctx duplicates stored: %v", dupStored)
}

// Wide fan-out is a concurrency bound, never a refusal.
func TestProbeBreadth(t *testing.T) {
	client := oracle.Client(t)
	tuples := []*openfgav1.TupleKey{
		tk("group:g90", "member", "user:anne"),
	}
	for i := 0; i < 100; i++ {
		tuples = append(tuples, tk("doc:1", "deep",
			fmt.Sprintf("group:g%d#member", i)))
	}
	store, model := setup(t, client, depthDSL, tuples)
	r := doCheck(t, client, store, model,
		"doc:1", "deep", "user:anne", nil, nil)
	t.Logf("OBSERVED: 100-userset fan-out: %v", r)
	if r.err != nil || !r.allowed {
		t.Fatalf("fan-out: want true, got %v", r)
	}
}

// Which invalid part of a check request wins when several
// are invalid at once.
func TestProbeCheckValidationOrder(t *testing.T) {
	client := oracle.Client(t)
	store, model := setup(t, client, plainDSL, nil)

	cases := []struct {
		label, object, relation, user string
		ctx                           []*openfgav1.TupleKey
	}{
		{"malformed user + undefined relation",
			"doc:1", "nonexistent", "not-a-user-ref", nil},
		{"malformed object + malformed user",
			"junk", "viewer", "also junk", nil},
		{"undefined subject relation + undefined relation",
			"doc:1", "nonexistent", "user:anne#norel", nil},
		{"undefined type in user + undefined relation",
			"doc:1", "nonexistent", "ghost:1", nil},
		{"bad ctx tuple + undefined request relation",
			"doc:1", "nonexistent", "user:anne",
			[]*openfgav1.TupleKey{tk("doc:1", "ghost", "user:anne")}},
		{"bad ctx tuple + malformed request user",
			"doc:1", "viewer", "junk",
			[]*openfgav1.TupleKey{tk("doc:1", "ghost", "user:anne")}},
		{"ctx tuple with undefined relation, valid request",
			"doc:1", "viewer", "user:anne",
			[]*openfgav1.TupleKey{tk("doc:1", "ghost", "user:anne")}},
		{"ctx tuple with undefined type, valid request",
			"doc:1", "viewer", "user:anne",
			[]*openfgav1.TupleKey{tk("ghost:1", "viewer", "user:anne")}},
		{"ctx tuple violating type restriction, valid request",
			"doc:1", "viewer", "user:anne",
			[]*openfgav1.TupleKey{tk("doc:2", "viewer", "doc:3")}},
	}
	for _, c := range cases {
		r := doCheck(t, client, store, model,
			c.object, c.relation, c.user, c.ctx, nil)
		t.Logf("OBSERVED: %s: %v", c.label, r)
	}
}
