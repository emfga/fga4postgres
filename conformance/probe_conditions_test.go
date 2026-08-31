package conformance

import (
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/protobuf/types/known/structpb"

	"github.com/emfga/fga4postgres/internal/oracle"
)

const condDSL = `model
  schema 1.1
type user
type doc
  relations
    define viewer: [user with xcond]
condition xcond(x: int) {
  x == 1
}`

func condTuple(x *int) *openfgav1.TupleKey {
	t := tk("doc:1", "viewer", "user:anne")
	cond := &openfgav1.RelationshipCondition{Name: "xcond"}
	if x != nil {
		cond.Context = &structpb.Struct{
			Fields: map[string]*structpb.Value{
				"x": structpb.NewNumberValue(float64(*x)),
			},
		}
	}
	t.Condition = cond
	return t
}

func reqCtx(x int) *structpb.Struct {
	return &structpb.Struct{
		Fields: map[string]*structpb.Value{
			"x": structpb.NewNumberValue(float64(x)),
		},
	}
}

// M07: condition context precedence — tuple context vs request
// context on the same key, and a contextual tuple duplicating a
// stored tuple with a different condition context.
func TestProbeM07ConditionPrecedence(t *testing.T) {
	client := oracle.Client(t)
	two := 2

	// Store A: tuple carries x=2 (falsey).
	storeA, modelA := setup(t, client, condDSL,
		[]*openfgav1.TupleKey{condTuple(&two)})
	r := doCheck(t, client, storeA, modelA,
		"doc:1", "viewer", "user:anne", nil, reqCtx(1))
	t.Logf("OBSERVED: tuple x=2, request x=1: %v", r)
	r = doCheck(t, client, storeA, modelA,
		"doc:1", "viewer", "user:anne", nil, nil)
	t.Logf("OBSERVED: tuple x=2, no request ctx: %v", r)

	// Store B: tuple condition without context.
	storeB, modelB := setup(t, client, condDSL,
		[]*openfgav1.TupleKey{condTuple(nil)})
	r = doCheck(t, client, storeB, modelB,
		"doc:1", "viewer", "user:anne", nil, reqCtx(1))
	t.Logf("OBSERVED: tuple no-ctx, request x=1: %v", r)
	r = doCheck(t, client, storeB, modelB,
		"doc:1", "viewer", "user:anne", nil, nil)
	t.Logf("OBSERVED: tuple no-ctx, no request ctx: %v", r)

	// Contextual tuple duplicating the stored falsey tuple, with
	// a truthy context.
	one := 1
	r = doCheck(t, client, storeA, modelA,
		"doc:1", "viewer", "user:anne",
		[]*openfgav1.TupleKey{condTuple(&one)}, nil)
	t.Logf("OBSERVED: stored x=2 + contextual dup x=1: %v", r)
	r = doCheck(t, client, storeA, modelA,
		"doc:1", "viewer", "user:anne",
		[]*openfgav1.TupleKey{condTuple(&one)}, reqCtx(2))
	t.Logf("OBSERVED: stored x=2 + ctx dup x=1 + request x=2: %v",
		r)

	// The disambiguator: stored truthy, contextual dup falsey.
	// Replace semantics answer false; union semantics answer true.
	storeC, modelC := setup(t, client, condDSL,
		[]*openfgav1.TupleKey{condTuple(&one)})
	r = doCheck(t, client, storeC, modelC,
		"doc:1", "viewer", "user:anne",
		[]*openfgav1.TupleKey{condTuple(&two)}, nil)
	t.Logf("OBSERVED: stored x=1 + contextual dup x=2: %v", r)
}

const condUsersetDSL = `model
  schema 1.1
type user
type group
  relations
    define member: [user]
type doc
  relations
    define viewer: [group#member with xcond]
condition xcond(x: int) {
  x == 1
}`

// M07 continued: the iterator-shaped read (userset expansion) —
// concatenate (either row can grant) or replace?
func TestProbeM07IteratorOverlay(t *testing.T) {
	client := oracle.Client(t)
	one, two := 1, 2

	usTuple := func(x *int) *openfgav1.TupleKey {
		tp := tk("doc:1", "viewer", "group:g#member")
		cond := &openfgav1.RelationshipCondition{Name: "xcond"}
		if x != nil {
			cond.Context = &structpb.Struct{
				Fields: map[string]*structpb.Value{
					"x": structpb.NewNumberValue(float64(*x)),
				},
			}
		}
		tp.Condition = cond
		return tp
	}

	store, model := setup(t, client, condUsersetDSL,
		[]*openfgav1.TupleKey{
			usTuple(&one),
			tk("group:g", "member", "user:anne"),
		})
	r := doCheck(t, client, store, model,
		"doc:1", "viewer", "user:anne",
		[]*openfgav1.TupleKey{usTuple(&two)}, nil)
	t.Logf("OBSERVED: userset stored x=1 + ctx dup x=2: %v", r)
	r = doCheck(t, client, store, model,
		"doc:1", "viewer", "user:anne", nil, nil)
	t.Logf("OBSERVED: userset stored x=1 alone: %v", r)
}
