package bench

import (
	"fmt"

	"github.com/google/uuid"
)

// hierarchy — deep TTU chains: folders form parent chains of
// depth 20 (below the resolve-node budget of 25), docs hang off
// the deepest folder or carry direct grants. Stresses TTU
// dispatch and recursive resolution cost.
//
// One chain c (a 250-tuple unit; chains = size/250):
//   - folders folder-c/0 .. folder-c/19; folder-c/d has parent
//     folder-c/(d-1) for d ≥ 1                    (19 tuples)
//   - the chain user cuser-c is viewer on folder-c/0 (1 tuple) —
//     the only direct viewer anywhere on the chain, so
//     folder-c/0 is the list_users "few" object and cuser-c the
//     list_objects "many" user (the deepest folder subtree: the
//     chain's 20 deep docs).
//   - deep docs ddoc-c/0..19, each with parent folder-c/19
//     (20 tuples): a viewer check on one resolves through the
//     full 20-deep chain — the "hit-deep" pair with cuser-c and
//     the structural "miss" with another chain's user.
//   - shallow docs sdoc-c/0..20, each with 10 direct viewers
//     from the regular pool (210 tuples): the "hit-shallow"
//     pairs.
//
// Regular users U = size/100, round-robin over global shallow
// grant slots (~84 grants each at any size). 100 special users
// shsuser-0..99 hold exactly one grant (slot 0 of sdoc-k/0).
type hierarchyScenario struct{}

const (
	hUnit     = 250 // tuples per chain
	hDepth    = 20  // folders per chain
	hDeepDocs = 20
	hShallow  = 21 // shallow docs per chain
	hGrants   = 10 // viewers per shallow doc
	hUserDiv  = 100
	hSpecials = 100
)

func (hierarchyScenario) Name() string { return "hierarchy" }
func (hierarchyScenario) Model() []byte {
	return model("hierarchy")
}

func hChains(size Size) int { return size.Tuples / hUnit }
func hUsers(size Size) int  { return size.Tuples / hUserDiv }

// hViewer names viewer slot j of shallow doc (c, s).
func hViewer(ns uuid.UUID, c, s, j, users int) uuid.UUID {
	if c < hSpecials && s == 0 && j == 0 {
		return entity(ns, fmt.Sprintf("shsuser-%d", c))
	}
	slot := (c*hShallow+s)*hGrants + j
	return entity(ns, fmt.Sprintf("huser-%d", slot%users))
}

func (s hierarchyScenario) Generate(
	seed uint64, size Size, emit func(Tuple) error,
) error {
	ns := namespace(s.Name(), seed)
	chains := hChains(size)
	users := hUsers(size)

	// Docs first ("doc" < "folder"): deep docs are indices
	// [0, 20C), shallow docs [20C, 41C).
	docName := func(i int) string {
		if i < hDeepDocs*chains {
			return fmt.Sprintf(
				"ddoc-%d/%d", i/hDeepDocs, i%hDeepDocs)
		}
		i -= hDeepDocs * chains
		return fmt.Sprintf(
			"sdoc-%d/%d", i/hShallow, i%hShallow)
	}
	rows := make([]Tuple, 0, hGrants)
	for _, ref := range sortedRefs(
		(hDeepDocs+hShallow)*chains,
		func(i int) uuid.UUID {
			return entity(ns, docName(i))
		},
	) {
		rows = rows[:0]
		if ref.idx < hDeepDocs*chains {
			c := ref.idx / hDeepDocs
			rows = append(rows, Tuple{
				ObjectType:  "doc",
				ObjectID:    ref.id,
				Relation:    "parent",
				SubjectType: "folder",
				SubjectID: entity(ns, fmt.Sprintf(
					"folder-%d/%d", c, hDepth-1)),
			})
		} else {
			i := ref.idx - hDeepDocs*chains
			c, sd := i/hShallow, i%hShallow
			for j := 0; j < hGrants; j++ {
				rows = append(rows, Tuple{
					ObjectType:  "doc",
					ObjectID:    ref.id,
					Relation:    "viewer",
					SubjectType: "user",
					SubjectID: hViewer(
						ns, c, sd, j, users),
				})
			}
		}
		if err := emitObject(rows, emit); err != nil {
			return err
		}
	}

	// Folders: index c*20+d. folder-c/0 carries the chain
	// user's grant; every deeper folder carries its parent edge.
	for _, ref := range sortedRefs(hDepth*chains,
		func(i int) uuid.UUID {
			return entity(ns, fmt.Sprintf(
				"folder-%d/%d", i/hDepth, i%hDepth))
		},
	) {
		c, d := ref.idx/hDepth, ref.idx%hDepth
		var t Tuple
		if d == 0 {
			t = Tuple{
				ObjectType:  "folder",
				ObjectID:    ref.id,
				Relation:    "viewer",
				SubjectType: "user",
				SubjectID: entity(ns,
					fmt.Sprintf("cuser-%d", c)),
			}
		} else {
			t = Tuple{
				ObjectType:  "folder",
				ObjectID:    ref.id,
				Relation:    "parent",
				SubjectType: "folder",
				SubjectID: entity(ns, fmt.Sprintf(
					"folder-%d/%d", c, d-1)),
			}
		}
		if err := emit(t); err != nil {
			return err
		}
	}
	return nil
}

func (s hierarchyScenario) Query(
	seed uint64, size Size, v Variant, i int,
) Query {
	ns := namespace(s.Name(), seed)
	chains := hChains(size)
	users := hUsers(size)
	li := uint64(i)
	obj := func(kind string, c, n int) string {
		return "doc:" + entity(ns, fmt.Sprintf(
			"%s-%d/%d", kind, c, n)).String()
	}
	folder := func(c, d int) string {
		return "folder:" + entity(ns, fmt.Sprintf(
			"folder-%d/%d", c, d)).String()
	}
	user := func(id uuid.UUID) string {
		return "user:" + id.String()
	}
	cuser := func(c int) string {
		return user(entity(ns, fmt.Sprintf("cuser-%d", c)))
	}
	switch v.Key() {
	case "check:hit-shallow":
		c := rndBelow(seed, chains, 'q', 1, li)
		sd := rndBelow(seed, hShallow, 'q', 2, li)
		j := rndBelow(seed, hGrants, 'q', 3, li)
		return Query{Object: obj("sdoc", c, sd),
			Relation: "viewer",
			User:     user(hViewer(ns, c, sd, j, users))}
	case "check:hit-deep":
		// Resolved through the full depth-20 chain: doc →
		// folder-c/19 → … → folder-c/0 → cuser-c.
		c := rndBelow(seed, chains, 'q', 4, li)
		d := rndBelow(seed, hDeepDocs, 'q', 5, li)
		return Query{Object: obj("ddoc", c, d),
			Relation: "viewer", User: cuser(c)}
	case "check:miss":
		// Another chain's user: the resolver walks the whole
		// chain before answering false.
		c := rndBelow(seed, chains, 'q', 6, li)
		d := rndBelow(seed, hDeepDocs, 'q', 7, li)
		o := 1 + rndBelow(seed, chains-1, 'q', 8, li)
		return Query{Object: obj("ddoc", c, d),
			Relation: "viewer", User: cuser((c + o) % chains)}
	case "list_objects:few":
		k := rndBelow(seed, hSpecials, 'q', 9, li)
		return Query{Type: "doc", Relation: "viewer",
			User: user(entity(ns,
				fmt.Sprintf("shsuser-%d", k)))}
	case "list_objects:many":
		// The deepest folder subtree: the chain user reaches
		// all 20 deep docs through the chain.
		c := rndBelow(seed, chains, 'q', 10, li)
		return Query{Type: "doc", Relation: "viewer",
			User: cuser(c)}
	case "list_users:few":
		c := rndBelow(seed, chains, 'q', 11, li)
		return Query{Object: folder(c, 0),
			Relation: "viewer", Type: "user"}
	case "list_users:many":
		// One user in the result, but resolved through the
		// full chain — hierarchy's expensive list_users shape.
		c := rndBelow(seed, chains, 'q', 12, li)
		d := rndBelow(seed, hDeepDocs, 'q', 13, li)
		return Query{Object: obj("ddoc", c, d),
			Relation: "viewer", Type: "user"}
	case "read:first-page":
		c := rndBelow(seed, chains, 'q', 14, li)
		sd := rndBelow(seed, hShallow, 'q', 15, li)
		return Query{Object: obj("sdoc", c, sd)}
	case "read:deep-page":
		u := rndBelow(seed, users, 'q', 16, li)
		return Query{Type: "doc", User: user(entity(ns,
			fmt.Sprintf("huser-%d", u)))}
	case "expand:deep":
		// The deepest relation: a deep doc's viewer tree (its
		// union of direct viewers and the parent TTU).
		c := rndBelow(seed, chains, 'q', 17, li)
		d := rndBelow(seed, hDeepDocs, 'q', 18, li)
		return Query{Object: obj("ddoc", c, d),
			Relation: "viewer"}
	}
	return Query{}
}
