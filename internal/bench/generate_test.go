package bench

import (
	"fmt"
	"hash/fnv"
	"testing"

	"github.com/google/uuid"
)

// The 100k size carries the row-level assertions; the larger
// sizes are checked arithmetically (apportionment constants must
// divide them) so the suite stays fast and DB-free.

var size100k = Sizes[0]

func TestSizesDivideIntoUnits(t *testing.T) {
	for _, size := range Sizes {
		if size.Tuples%(dGrants*dBlock) != 0 {
			t.Errorf("%s: not whole direct blocks", size.Name)
		}
		if size.Tuples%dUserDiv != 0 {
			t.Errorf("%s: fractional direct users", size.Name)
		}
		if size.Tuples%hUnit != 0 {
			t.Errorf("%s: not whole chains", size.Name)
		}
		if size.Tuples%fUnit != 0 {
			t.Errorf("%s: not whole fanout units", size.Name)
		}
		// The special-user rules need enough chains and units.
		if hChains(size) < hSpecials {
			t.Errorf("%s: fewer chains than special users",
				size.Name)
		}
		if fUnits(size) < 2 {
			t.Errorf("%s: miss rule needs 2 fanout units",
				size.Name)
		}
	}
}

// generate collects one scenario's stream at 100k, asserting the
// stream-level invariants every scenario must hold: exact count,
// PK order, no nil uuids.
func generate(
	t *testing.T, s Scenario, seed uint64,
) []Tuple {
	t.Helper()
	var rows []Tuple
	var prev Tuple
	err := s.Generate(seed, size100k,
		func(tu Tuple) error {
			// The nil uuid is the engine's wildcard sentinel;
			// the generator must never produce it.
			if tu.ObjectID == uuid.Nil ||
				tu.SubjectID == uuid.Nil {
				t.Fatalf("nil uuid in %+v", tu)
			}
			if len(rows) > 0 && !pkLess(prev, tu) {
				t.Fatalf("not PK-sorted:\n%+v\n%+v", prev, tu)
			}
			prev = tu
			rows = append(rows, tu)
			return nil
		})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != size100k.Tuples {
		t.Fatalf("%s: %d rows, want %d",
			s.Name(), len(rows), size100k.Tuples)
	}
	return rows
}

func streamHash(t *testing.T, rows []Tuple) uint64 {
	t.Helper()
	h := fnv.New64a()
	for _, r := range rows {
		fmt.Fprintf(h, "%s/%s/%s/%s/%s/%s\n",
			r.ObjectType, r.ObjectID, r.Relation,
			r.SubjectType, r.SubjectID, r.SubjectRelation)
	}
	return h.Sum64()
}

func TestGenerateDeterministic(t *testing.T) {
	for _, s := range Scenarios {
		t.Run(s.Name(), func(t *testing.T) {
			a := streamHash(t, generate(t, s, 1))
			b := streamHash(t, generate(t, s, 1))
			if a != b {
				t.Error("same seed, different stream")
			}
			c := streamHash(t, generate(t, s, 2))
			if a == c {
				t.Error("different seed, same stream")
			}
		})
	}
}

// kind buckets a tuple by its structural role so apportionment
// is assertable per scenario.
func kind(r Tuple) string {
	return r.ObjectType + "." + r.Relation + "@" +
		r.SubjectType + r.SubjectRelation
}

func TestApportionment(t *testing.T) {
	want := map[string]map[string]int{
		"direct": {
			"doc.viewer@user": 100_000,
		},
		"hierarchy": {
			// 400 chains at 100k.
			"folder.parent@folder": 19 * 400,
			"folder.viewer@user":   400,
			"doc.parent@folder":    hDeepDocs * 400,
			"doc.viewer@user":      hShallow * hGrants * 400,
		},
		"fanout": {
			// 10 units at 100k.
			"group.member@groupmember": fLeaves * 10,
			"group.member@user":        fLeaves * fLeafUsers * 10,
			"doc.viewer@groupmember":   fGroupDocs * 10,
			"doc.viewer@user":          2495 * 10,
		},
	}
	for _, s := range Scenarios {
		t.Run(s.Name(), func(t *testing.T) {
			got := map[string]int{}
			for _, r := range generate(t, s, 1) {
				got[kind(r)]++
			}
			w := want[s.Name()]
			if len(got) != len(w) {
				t.Errorf("kinds: got %v want %v", got, w)
			}
			for k, n := range w {
				if got[k] != n {
					t.Errorf("%s: got %d want %d",
						k, got[k], n)
				}
			}
		})
	}
}

func TestScratchTuples(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		a, b := ScratchTuple(7, i), ScratchTuple(7, i)
		if a != b {
			t.Fatal("scratch stream not deterministic")
		}
		k := a.ObjectID.String() + a.SubjectID.String()
		if seen[k] {
			t.Fatalf("duplicate scratch tuple at %d", i)
		}
		seen[k] = true
		if a.ObjectType != "doc" || a.Relation != "viewer" ||
			a.SubjectType != "user" {
			t.Fatalf("unexpected shape: %+v", a)
		}
	}
}

func TestParseSize(t *testing.T) {
	if s, err := ParseSize("100k"); err != nil ||
		s.Tuples != 100_000 {
		t.Fatalf("got %+v, %v", s, err)
	}
	if _, err := ParseSize("2m"); err == nil {
		t.Fatal("expected error for unknown size")
	}
	if _, err := ScenarioByName("nope"); err == nil {
		t.Fatal("expected error for unknown scenario")
	}
}
