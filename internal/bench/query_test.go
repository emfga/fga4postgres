package bench

import (
	"strings"
	"testing"
)

// The selection rules are the contract (plan §2, §9: "milestone
// 1's tests must cover the rules, not just row output"), so they
// are verified against the generated dataset itself: a tiny
// resolver replays the three models' semantics (direct grants,
// userset expansion, the parent-viewer TTU) over the in-memory
// tuple set, and every hit must resolve while every miss must
// not.

// graph indexes one generated dataset for the resolver and the
// few/many cardinality checks.
type graph struct {
	// grants: "objtype:objid#relation" -> subject strings
	// ("user:id" or "group:id#member").
	grants map[string][]string
	// parents: "objtype:objid" -> parent folder object ids.
	parents map[string][]string
	// subjectGrants counts tuples per subject string.
	subjectGrants map[string]int
	// directUsers counts subjects of subject_type user per
	// "objtype:objid#relation".
	directUsers map[string]int
	// docs lists every object of type doc ("doc:id").
	docs []string
	// memo caches resolves() verdicts; the graph is immutable.
	memo map[string]bool
}

func buildGraph(t *testing.T, s Scenario, seed uint64) *graph {
	t.Helper()
	g := &graph{
		grants:        map[string][]string{},
		parents:       map[string][]string{},
		subjectGrants: map[string]int{},
		directUsers:   map[string]int{},
		memo:          map[string]bool{},
	}
	seenDoc := map[string]bool{}
	for _, r := range generate(t, s, seed) {
		obj := r.ObjectType + ":" + r.ObjectID.String()
		if r.ObjectType == "doc" && !seenDoc[obj] {
			seenDoc[obj] = true
			g.docs = append(g.docs, obj)
		}
		subj := r.SubjectType + ":" + r.SubjectID.String()
		if r.SubjectRelation != "" {
			subj += "#" + r.SubjectRelation
		}
		if r.Relation == "parent" {
			g.parents[obj] = append(
				g.parents[obj], subj)
			continue
		}
		key := obj + "#" + r.Relation
		g.grants[key] = append(g.grants[key], subj)
		g.subjectGrants[subj]++
		if r.SubjectType == "user" {
			g.directUsers[key]++
		}
	}
	return g
}

// resolves replays the models: a user holds a relation if
// directly granted, granted through a userset subject, or (for
// viewer) granted on a parent folder — exactly the three
// scenarios' resolution shapes.
func (g *graph) resolves(obj, rel, user string) bool {
	key := obj + "#" + rel + "|" + user
	if v, ok := g.memo[key]; ok {
		return v
	}
	v := false
	for _, subj := range g.grants[obj+"#"+rel] {
		if subj == user {
			v = true
			break
		}
		if o, r, ok := strings.Cut(subj, "#"); ok &&
			g.resolves(o, r, user) {
			v = true
			break
		}
	}
	if !v && rel == "viewer" {
		for _, p := range g.parents[obj] {
			if g.resolves(p, "viewer", user) {
				v = true
				break
			}
		}
	}
	g.memo[key] = v
	return v
}

const querySamples = 25

func TestQueryDeterministic(t *testing.T) {
	for _, s := range Scenarios {
		for _, v := range Variants {
			for i := 0; i < querySamples; i++ {
				a := s.Query(1, size100k, v, i)
				b := s.Query(1, size100k, v, i)
				if a != b {
					t.Fatalf("%s %s #%d: not deterministic",
						s.Name(), v.Key(), i)
				}
			}
		}
	}
}

func TestCheckSelectionRules(t *testing.T) {
	for _, s := range Scenarios {
		t.Run(s.Name(), func(t *testing.T) {
			g := buildGraph(t, s, 1)
			for i := 0; i < querySamples; i++ {
				for _, name := range []string{
					"hit-shallow", "hit-deep",
				} {
					q := s.Query(1, size100k,
						Variant{"check", name}, i)
					if !g.resolves(
						q.Object, q.Relation, q.User) {
						t.Errorf("%s #%d does not resolve: %+v",
							name, i, q)
					}
				}
				q := s.Query(1, size100k,
					Variant{"check", "miss"}, i)
				if g.resolves(q.Object, q.Relation, q.User) {
					t.Errorf("miss #%d resolves: %+v", i, q)
				}
			}
		})
	}
}

func TestFewManySelectionRules(t *testing.T) {
	for _, s := range Scenarios {
		t.Run(s.Name(), func(t *testing.T) {
			g := buildGraph(t, s, 1)
			for i := 0; i < querySamples; i++ {
				// list_objects few: exactly one grant anywhere.
				q := s.Query(1, size100k,
					Variant{"list_objects", "few"}, i)
				if n := g.subjectGrants[q.User]; n != 1 {
					t.Errorf(
						"lo-few user %s holds %d grants",
						q.User, n)
				}
				// list_users few: exactly one direct user.
				q = s.Query(1, size100k,
					Variant{"list_users", "few"}, i)
				key := q.Object + "#" + q.Relation
				if n := g.directUsers[key]; n != 1 {
					t.Errorf(
						"lu-few object %s has %d direct users",
						q.Object, n)
				}
			}
		})
	}
}

// list_objects many: the selected user must reach an order of
// magnitude more docs than the "few" user's one — counted by
// resolving every doc, so the TTU and userset paths count. Few
// samples: the count walks the whole doc set.
func TestListObjectsManyReachesMany(t *testing.T) {
	for _, s := range Scenarios {
		t.Run(s.Name(), func(t *testing.T) {
			g := buildGraph(t, s, 1)
			for i := 0; i < 3; i++ {
				q := s.Query(1, size100k,
					Variant{"list_objects", "many"}, i)
				n := 0
				for _, d := range g.docs {
					if g.resolves(d, "viewer", q.User) {
						n++
					}
				}
				if n < 10 {
					t.Errorf("#%d: %s reaches only %d docs",
						i, q.User, n)
				}
			}
		})
	}
}

// Deep hits must not be answerable from a direct tuple: the whole
// point of the variant is the resolution path.
func TestDeepHitIsNotDirect(t *testing.T) {
	for _, name := range []string{"hierarchy", "fanout"} {
		s, err := ScenarioByName(name)
		if err != nil {
			t.Fatal(err)
		}
		g := buildGraph(t, s, 1)
		for i := 0; i < querySamples; i++ {
			q := s.Query(1, size100k,
				Variant{"check", "hit-deep"}, i)
			for _, subj := range g.grants[q.Object+"#"+
				q.Relation] {
				if subj == q.User {
					t.Errorf("%s deep hit #%d is direct: %+v",
						name, i, q)
				}
			}
		}
	}
}

// Every variant a scenario services returns a usable query; the
// runner-composed variants return the zero value.
func TestVariantCoverage(t *testing.T) {
	composed := map[string]bool{
		"batch_check:mixed":               true,
		"write:churn":                     true,
		"write_authorization_model:model": true,
	}
	for _, s := range Scenarios {
		for _, v := range Variants {
			q := s.Query(1, size100k, v, 0)
			if composed[v.Key()] {
				if q != (Query{}) {
					t.Errorf("%s %s: expected zero query",
						s.Name(), v.Key())
				}
				continue
			}
			if q == (Query{}) {
				t.Errorf("%s %s: zero query",
					s.Name(), v.Key())
			}
		}
	}
}
