// Package bench is the benchmark library: named scenario models,
// a deterministic tuple generator, pinned query-selection rules,
// and the measurement primitives (ULIDs, latency histogram) the
// bench binary builds on. Everything here is a pure function of
// (seed, scenario, size): same inputs give the same dataset and
// the same query stream on any machine.
package bench

import (
	"embed"
	"fmt"
	"sort"

	"github.com/google/uuid"
)

//go:embed scenarios/*.json
var modelFS embed.FS

// GeneratorVersion stamps result files: bump it whenever a change
// here alters generated datasets or query streams, so benchreport
// can refuse to compare fixtures that are not the same fixtures.
const GeneratorVersion = 1

// Scenario is one named workload shape. Implementations pin their
// apportionment constants and query-selection rules; scaling to a
// Size never changes per-query work (the rules are
// size-invariant by design, plan §2).
type Scenario interface {
	Name() string
	// Model is the authorization model, upstream's snake_case
	// JSON shape, fed verbatim to fga.write_authorization_model.
	Model() []byte
	// Generate streams exactly size.Tuples rows in fga.tuple
	// primary-key order. It sorts object ids in memory: the peak
	// is ~24 bytes per object of the largest object type (§3 of
	// the plan flags the 100m shakedown).
	Generate(seed uint64, size Size, emit func(Tuple) error) error
	// Query returns the i-th query of the variant's stream,
	// drawn uniformly over the variant's eligible keyspace.
	// Variants the runner services without scenario input
	// (write, write_authorization_model, batch_check — composed
	// from the check streams) return the zero Query.
	Query(seed uint64, size Size, v Variant, i int) Query
}

// Query carries the target of one benchmark call. Which fields
// are set depends on the feature: check and expand use Object /
// Relation / User(check only); list_objects uses Type / Relation
// / User; list_users uses Object / Relation with Type as the user
// filter; read uses Object (first-page, type:id filter) or
// Type+User (deep-page filter).
type Query struct {
	Object   string
	Relation string
	User     string
	Type     string
}

// Variant names one measured case shape. The 13 variants and
// their selection rules are pinned in plan §2/§4.
type Variant struct{ Feature, Name string }

// Key is the variant's stable identifier, used in result files
// and in the scenarios' selection-rule dispatch.
func (v Variant) Key() string { return v.Feature + ":" + v.Name }

var Variants = []Variant{
	{"check", "hit-shallow"},
	{"check", "hit-deep"},
	{"check", "miss"},
	{"batch_check", "mixed"},
	{"list_objects", "few"},
	{"list_objects", "many"},
	{"list_users", "few"},
	{"list_users", "many"},
	{"read", "first-page"},
	{"read", "deep-page"},
	{"write", "churn"},
	{"expand", "deep"},
	{"write_authorization_model", "model"},
}

// Scenarios is the registry, in build order (decision 2: check
// leads, so direct — the floor — comes first).
var Scenarios = []Scenario{
	directScenario{},
	hierarchyScenario{},
	fanoutScenario{},
}

func ScenarioByName(name string) (Scenario, error) {
	names := make([]string, len(Scenarios))
	for i, s := range Scenarios {
		if s.Name() == name {
			return s, nil
		}
		names[i] = s.Name()
	}
	return nil, fmt.Errorf(
		"unknown scenario %q (valid: %v)", name, names)
}

func model(name string) []byte {
	b, err := modelFS.ReadFile("scenarios/" + name + ".json")
	if err != nil {
		panic(err) // embedded: unreachable after go build
	}
	return b
}

// namespace derives the per-(scenario, seed) uuidv5 namespace —
// the same construction internal/uuidmap uses per suite — so ids
// are stable across machines and the nil uuid (the engine's
// wildcard sentinel) can never be produced.
func namespace(scenario string, seed uint64) uuid.UUID {
	return uuid.NewSHA1(uuid.NameSpaceOID, []byte(fmt.Sprintf(
		"fga4postgres-bench:%s:%d", scenario, seed)))
}

func entity(ns uuid.UUID, name string) uuid.UUID {
	return uuid.NewSHA1(ns, []byte(name))
}

// objRef pairs an object's uuid with its logical index so a
// type's objects can be emitted in uuid order while their rows
// are still computed from the index.
type objRef struct {
	id  uuid.UUID
	idx int
}

// sortedRefs materialises and uuid-sorts one object type's
// references — the memory the Generate doc mentions.
func sortedRefs(n int, id func(i int) uuid.UUID) []objRef {
	refs := make([]objRef, n)
	for i := range refs {
		refs[i] = objRef{id: id(i), idx: i}
	}
	sort.Slice(refs, func(a, b int) bool {
		for k := 0; k < 16; k++ {
			if refs[a].id[k] != refs[b].id[k] {
				return refs[a].id[k] < refs[b].id[k]
			}
		}
		return false
	})
	return refs
}

// emitObject sorts one object's rows into PK order and streams
// them. Per-object row counts are small (≤ tens), so the sort is
// in-place and cheap.
func emitObject(
	rows []Tuple, emit func(Tuple) error,
) error {
	sort.Slice(rows, func(a, b int) bool {
		return pkLess(rows[a], rows[b])
	})
	for _, r := range rows {
		if err := emit(r); err != nil {
			return err
		}
	}
	return nil
}

// ScratchTuple is the i-th tuple of the write-churn stream: a
// plain doc-viewer-user grant, valid under all three scenario
// models, aimed at the scratch store the runner recreates around
// the mutating cases.
func ScratchTuple(seed uint64, i int) Tuple {
	ns := namespace("scratch", seed)
	return Tuple{
		ObjectType:  "doc",
		ObjectID:    entity(ns, fmt.Sprintf("scratch-doc-%d", i)),
		Relation:    "viewer",
		SubjectType: "user",
		SubjectID: entity(ns,
			fmt.Sprintf("scratch-user-%d", i)),
	}
}
