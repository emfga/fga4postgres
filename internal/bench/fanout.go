package bench

import (
	"fmt"

	"github.com/google/uuid"
)

// fanout — wide usersets: group{member: [user, group#member]},
// doc{viewer: [user, group#member]}. Groups of 1000 members, two
// levels of nesting. Stresses userset expansion, the breadth
// limit and the reverse index.
//
// One unit u (10,000 tuples; units = size/10000):
//   - mid group gmid-u with 5 leaf-group members
//     gleaf-u/0..4#member                          (5 tuples)
//   - each leaf holds 1000 users guser-u/l/0..999  (5000 tuples)
//   - 2500 group docs gdoc-u/0..2499, each viewer
//     gmid-u#member (2500 tuples): a check on one expands both
//     nesting levels — "hit-deep" with a unit user, the
//     full-expansion "miss" with another unit's user, and the
//     list_users "many" object (5000 users).
//   - 499 direct docs fdoc-u/0..498 with viewers from the
//     unit's direct pool fuser-u/0..99 — users deliberately in
//     no group. Viewer counts: fdoc-u/0 has 1 (the list_users
//     "few" object), fdoc-u/1 has 9, the rest 5   (2495 tuples).
//
// 10 special users per unit fsuser-(10u+k) hold exactly one
// grant each (slot 0 of fdoc-u/2..11) — the list_objects "few"
// user. A leaf user is the "many" user: leaf → mid → 2500 docs.
type fanoutScenario struct{}

const (
	fUnit      = 10_000 // tuples per unit
	fLeaves    = 5      // leaf groups per mid
	fLeafUsers = 1000   // users per leaf group
	fGroupDocs = 2500   // docs granted to the mid group
	fDirDocs   = 499    // direct-grant docs
	fDirPool   = 100    // direct users per unit
	fDirGrants = 5      // viewers per regular direct doc
	fSpecialsU = 10     // single-grant special users per unit
)

func (fanoutScenario) Name() string  { return "fanout" }
func (fanoutScenario) Model() []byte { return model("fanout") }

func fUnits(size Size) int { return size.Tuples / fUnit }

// fViewers is direct doc d's viewer count (1+9 = 2×5 keeps each
// unit at exactly 2495 direct grants).
func fViewers(d int) int {
	switch d {
	case 0:
		return 1
	case 1:
		return 9
	default:
		return fDirGrants
	}
}

// fViewer names viewer slot j of direct doc (u, d).
func fViewer(ns uuid.UUID, u, d, j int) uuid.UUID {
	if d >= 2 && d < 2+fSpecialsU && j == 0 {
		return entity(ns, fmt.Sprintf(
			"fsuser-%d", u*fSpecialsU+(d-2)))
	}
	return entity(ns, fmt.Sprintf(
		"fuser-%d/%d", u, (d*fDirGrants+j)%fDirPool))
}

func (s fanoutScenario) Generate(
	seed uint64, size Size, emit func(Tuple) error,
) error {
	ns := namespace(s.Name(), seed)
	units := fUnits(size)

	// Docs first ("doc" < "group"): group docs are indices
	// [0, 2500U), direct docs [2500U, 2999U).
	docName := func(i int) string {
		if i < fGroupDocs*units {
			return fmt.Sprintf(
				"gdoc-%d/%d", i/fGroupDocs, i%fGroupDocs)
		}
		i -= fGroupDocs * units
		return fmt.Sprintf(
			"fdoc-%d/%d", i/fDirDocs, i%fDirDocs)
	}
	rows := make([]Tuple, 0, 9)
	for _, ref := range sortedRefs(
		(fGroupDocs+fDirDocs)*units,
		func(i int) uuid.UUID {
			return entity(ns, docName(i))
		},
	) {
		rows = rows[:0]
		if ref.idx < fGroupDocs*units {
			u := ref.idx / fGroupDocs
			rows = append(rows, Tuple{
				ObjectType:  "doc",
				ObjectID:    ref.id,
				Relation:    "viewer",
				SubjectType: "group",
				SubjectID: entity(ns,
					fmt.Sprintf("gmid-%d", u)),
				SubjectRelation: "member",
			})
		} else {
			i := ref.idx - fGroupDocs*units
			u, d := i/fDirDocs, i%fDirDocs
			for j := 0; j < fViewers(d); j++ {
				rows = append(rows, Tuple{
					ObjectType:  "doc",
					ObjectID:    ref.id,
					Relation:    "viewer",
					SubjectType: "user",
					SubjectID:   fViewer(ns, u, d, j),
				})
			}
		}
		if err := emitObject(rows, emit); err != nil {
			return err
		}
	}

	// Groups: mids are indices [0, U), leaves [U, 6U).
	groupName := func(i int) string {
		if i < units {
			return fmt.Sprintf("gmid-%d", i)
		}
		i -= units
		return fmt.Sprintf(
			"gleaf-%d/%d", i/fLeaves, i%fLeaves)
	}
	rows = make([]Tuple, 0, fLeafUsers)
	for _, ref := range sortedRefs((1+fLeaves)*units,
		func(i int) uuid.UUID {
			return entity(ns, groupName(i))
		},
	) {
		rows = rows[:0]
		if ref.idx < units {
			for l := 0; l < fLeaves; l++ {
				rows = append(rows, Tuple{
					ObjectType:  "group",
					ObjectID:    ref.id,
					Relation:    "member",
					SubjectType: "group",
					SubjectID: entity(ns, fmt.Sprintf(
						"gleaf-%d/%d", ref.idx, l)),
					SubjectRelation: "member",
				})
			}
		} else {
			i := ref.idx - units
			u, l := i/fLeaves, i%fLeaves
			for m := 0; m < fLeafUsers; m++ {
				rows = append(rows, Tuple{
					ObjectType:  "group",
					ObjectID:    ref.id,
					Relation:    "member",
					SubjectType: "user",
					SubjectID: entity(ns, fmt.Sprintf(
						"guser-%d/%d/%d", u, l, m)),
				})
			}
		}
		if err := emitObject(rows, emit); err != nil {
			return err
		}
	}
	return nil
}

func (s fanoutScenario) Query(
	seed uint64, size Size, v Variant, i int,
) Query {
	ns := namespace(s.Name(), seed)
	units := fUnits(size)
	li := uint64(i)
	doc := func(kind string, u, d int) string {
		return "doc:" + entity(ns, fmt.Sprintf(
			"%s-%d/%d", kind, u, d)).String()
	}
	user := func(id uuid.UUID) string {
		return "user:" + id.String()
	}
	guser := func(u, l, m int) string {
		return user(entity(ns, fmt.Sprintf(
			"guser-%d/%d/%d", u, l, m)))
	}
	switch v.Key() {
	case "check:hit-shallow":
		u := rndBelow(seed, units, 'q', 1, li)
		d := rndBelow(seed, fDirDocs, 'q', 2, li)
		j := rndBelow(seed, fViewers(d), 'q', 3, li)
		return Query{Object: doc("fdoc", u, d),
			Relation: "viewer",
			User:     user(fViewer(ns, u, d, j))}
	case "check:hit-deep":
		// Resolved through both nesting levels: doc →
		// gmid#member → gleaf#member → user.
		u := rndBelow(seed, units, 'q', 4, li)
		d := rndBelow(seed, fGroupDocs, 'q', 5, li)
		l := rndBelow(seed, fLeaves, 'q', 6, li)
		m := rndBelow(seed, fLeafUsers, 'q', 7, li)
		return Query{Object: doc("gdoc", u, d),
			Relation: "viewer", User: guser(u, l, m)}
	case "check:miss":
		// Another unit's user: the full group expansion runs
		// before the false.
		u := rndBelow(seed, units, 'q', 8, li)
		d := rndBelow(seed, fGroupDocs, 'q', 9, li)
		o := 1 + rndBelow(seed, units-1, 'q', 10, li)
		l := rndBelow(seed, fLeaves, 'q', 11, li)
		m := rndBelow(seed, fLeafUsers, 'q', 12, li)
		return Query{Object: doc("gdoc", u, d),
			Relation: "viewer",
			User:     guser((u+o)%units, l, m)}
	case "list_objects:few":
		k := rndBelow(seed, units*fSpecialsU, 'q', 13, li)
		return Query{Type: "doc", Relation: "viewer",
			User: user(entity(ns,
				fmt.Sprintf("fsuser-%d", k)))}
	case "list_objects:many":
		// Granted via the widest group: leaf → mid → all 2500
		// of the unit's group docs.
		u := rndBelow(seed, units, 'q', 14, li)
		l := rndBelow(seed, fLeaves, 'q', 15, li)
		m := rndBelow(seed, fLeafUsers, 'q', 16, li)
		return Query{Type: "doc", Relation: "viewer",
			User: guser(u, l, m)}
	case "list_users:few":
		u := rndBelow(seed, units, 'q', 17, li)
		return Query{Object: doc("fdoc", u, 0),
			Relation: "viewer", Type: "user"}
	case "list_users:many":
		// The object granted to the widest group: expands to
		// the mid group's 5000 transitive members.
		u := rndBelow(seed, units, 'q', 18, li)
		d := rndBelow(seed, fGroupDocs, 'q', 19, li)
		return Query{Object: doc("gdoc", u, d),
			Relation: "viewer", Type: "user"}
	case "read:first-page":
		u := rndBelow(seed, units, 'q', 20, li)
		d := rndBelow(seed, fGroupDocs, 'q', 21, li)
		return Query{Object: doc("gdoc", u, d)}
	case "read:deep-page":
		// The mid group's userset as the subject filter: 2500
		// matching rows to page over.
		u := rndBelow(seed, units, 'q', 22, li)
		return Query{Type: "doc",
			User: "group:" + entity(ns, fmt.Sprintf(
				"gmid-%d", u)).String() + "#member"}
	case "expand:deep":
		// The widest single level: a leaf's 1000 members.
		u := rndBelow(seed, units, 'q', 23, li)
		l := rndBelow(seed, fLeaves, 'q', 24, li)
		return Query{Object: "group:" + entity(ns,
			fmt.Sprintf("gleaf-%d/%d", u, l)).String(),
			Relation: "member"}
	}
	return Query{}
}
