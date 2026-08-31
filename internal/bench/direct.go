package bench

import (
	"fmt"

	"github.com/google/uuid"
)

// direct — flat direct grants: user, doc{viewer: [user]}. The
// floor every other number is read against: one tuple PK probe
// per check.
//
// Apportionment (pinned; total = size exactly):
//   - docs D = size/10; every tuple is a doc-viewer grant.
//   - viewers per doc: 10, except per block of 1000 docs the
//     first doc has 1 viewer (the list_users "few" object) and
//     the second has 19 (the "many" object) — 1+19 = 2×10, so
//     each block still holds exactly 10,000 grants.
//   - regular users U = size/100, assigned round-robin by global
//     grant slot, so every regular user holds ~100 grants at any
//     size (the size-invariance the selection rules need).
//   - one special user per block, suser-k, holds exactly one
//     grant (the list_objects "few" user): it replaces viewer
//     slot 0 of doc 1000k+2, so specials scale with size like
//     everything else.
type directScenario struct{}

const (
	dGrants  = 10   // viewers per regular doc
	dBlock   = 1000 // docs per few/many special block
	dUserDiv = 100  // size / regular users
)

func (directScenario) Name() string  { return "direct" }
func (directScenario) Model() []byte { return model("direct") }

func dDocs(size Size) int  { return size.Tuples / dGrants }
func dUsers(size Size) int { return size.Tuples / dUserDiv }

// dViewers is doc i's viewer count.
func dViewers(i int) int {
	switch i % dBlock {
	case 0:
		return 1
	case 1:
		return 19
	default:
		return dGrants
	}
}

// dViewer names viewer slot j of doc i.
func dViewer(ns uuid.UUID, i, j, users int) uuid.UUID {
	if i%dBlock == 2 && j == 0 {
		return entity(ns, fmt.Sprintf("suser-%d", i/dBlock))
	}
	return entity(ns,
		fmt.Sprintf("user-%d", (i*dGrants+j)%users))
}

func (s directScenario) Generate(
	seed uint64, size Size, emit func(Tuple) error,
) error {
	ns := namespace(s.Name(), seed)
	users := dUsers(size)
	rows := make([]Tuple, 0, 19)
	for _, ref := range sortedRefs(dDocs(size), func(i int) uuid.UUID {
		return entity(ns, fmt.Sprintf("doc-%d", i))
	}) {
		rows = rows[:0]
		for j := 0; j < dViewers(ref.idx); j++ {
			rows = append(rows, Tuple{
				ObjectType:  "doc",
				ObjectID:    ref.id,
				Relation:    "viewer",
				SubjectType: "user",
				SubjectID:   dViewer(ns, ref.idx, j, users),
			})
		}
		if err := emitObject(rows, emit); err != nil {
			return err
		}
	}
	return nil
}

func (s directScenario) Query(
	seed uint64, size Size, v Variant, i int,
) Query {
	ns := namespace(s.Name(), seed)
	docs, users := dDocs(size), dUsers(size)
	li := uint64(i)
	doc := func(d int) string {
		return "doc:" + entity(ns,
			fmt.Sprintf("doc-%d", d)).String()
	}
	user := func(id uuid.UUID) string {
		return "user:" + id.String()
	}
	switch v.Key() {
	case "check:hit-shallow", "check:hit-deep":
		// No deep path exists: both variants are the direct
		// probe (plan §2).
		d := rndBelow(seed, docs, 'q', 1, li)
		j := rndBelow(seed, dViewers(d), 'q', 2, li)
		return Query{Object: doc(d), Relation: "viewer",
			User: user(dViewer(ns, d, j, users))}
	case "check:miss":
		// A regular user offset past the widest viewer window
		// (19), so the pair is never granted: the one-probe
		// cheap miss, deliberately this scenario's job.
		d := rndBelow(seed, docs, 'q', 3, li)
		off := 19 + rndBelow(seed, users-19, 'q', 4, li)
		u := entity(ns, fmt.Sprintf(
			"user-%d", (d*dGrants+off)%users))
		return Query{Object: doc(d), Relation: "viewer",
			User: user(u)}
	case "list_objects:few":
		k := rndBelow(seed, docs/dBlock, 'q', 5, li)
		return Query{Type: "doc", Relation: "viewer",
			User: user(entity(ns,
				fmt.Sprintf("suser-%d", k)))}
	case "list_objects:many":
		u := rndBelow(seed, users, 'q', 6, li)
		return Query{Type: "doc", Relation: "viewer",
			User: user(entity(ns,
				fmt.Sprintf("user-%d", u)))}
	case "list_users:few":
		d := dBlock * rndBelow(seed, docs/dBlock, 'q', 7, li)
		return Query{Object: doc(d), Relation: "viewer",
			Type: "user"}
	case "list_users:many":
		d := dBlock*rndBelow(seed, docs/dBlock, 'q', 8, li) + 1
		return Query{Object: doc(d), Relation: "viewer",
			Type: "user"}
	case "read:first-page":
		d := rndBelow(seed, docs, 'q', 9, li)
		return Query{Object: doc(d)}
	case "read:deep-page":
		u := rndBelow(seed, users, 'q', 10, li)
		return Query{Type: "doc", User: user(entity(ns,
			fmt.Sprintf("user-%d", u)))}
	case "expand:deep": // the widest leaf, a 19-viewer doc
		d := dBlock*rndBelow(seed, docs/dBlock, 'q', 11, li) + 1
		return Query{Object: doc(d), Relation: "viewer"}
	}
	return Query{}
}
