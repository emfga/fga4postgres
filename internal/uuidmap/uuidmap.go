// Package uuidmap deterministically maps upstream corpus ids
// (nearly arbitrary strings like "anne") into the engine's
// uuid-only id domain, and back.
//
// The rules (plan §2.3):
//
//   - a well-formed id maps through uuidv5 over one per-suite
//     namespace, so the mapping is total, deterministic across
//     runs, and bijective within a run (collision-checked);
//   - an id upstream's own grammar refuses passes through
//     UNMAPPED to both engines, so both refuse it natively;
//   - "*" (the wildcard), relation names, type names and model
//     identifiers are never mapped — callers only hand this
//     package the id segment of an object or user string.
package uuidmap

import (
	"fmt"
	"regexp"
	"sync"

	"github.com/google/uuid"
)

// wellFormed is upstream's tuple id grammar at the pin: anything
// non-empty without ':', '#', whitespace or control characters.
// Ids outside it are refused by the oracle itself, so mapping them
// would hide the very refusal the corpus asserts.
var wellFormed = regexp.MustCompile(
	`^[^:#\s\x{00}-\x{1f}\x{7f}]+$`,
)

// Map is one suite's id mapping. Goroutine-safe: the upstream
// runners call t.Parallel().
type Map struct {
	ns  uuid.UUID
	mu  sync.Mutex
	fwd map[string]string
	rev map[string]string
}

// New derives the suite's uuidv5 namespace from its name, so two
// suites never share mappings but one suite's mapping is stable
// across runs and processes.
func New(suite string) *Map {
	return &Map{
		ns:  uuid.NewSHA1(uuid.NameSpaceOID, []byte(suite)),
		fwd: map[string]string{},
		rev: map[string]string{},
	}
}

// ID maps one id segment. Well-formed ids become uuids; ids
// upstream's grammar refuses pass through unmapped so both engines
// see — and refuse — the original.
func (m *Map) ID(orig string) string {
	if !wellFormed.MatchString(orig) {
		return orig
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if mapped, ok := m.fwd[orig]; ok {
		return mapped
	}
	mapped := uuid.NewSHA1(m.ns, []byte(orig)).String()
	if prev, ok := m.rev[mapped]; ok && prev != orig {
		panic(fmt.Sprintf(
			"uuidmap collision: %q and %q both map to %s",
			prev, orig, mapped,
		))
	}
	m.fwd[orig] = mapped
	m.rev[mapped] = orig
	return mapped
}

// Back inverts ID for values observed in engine output. A value
// never produced by ID comes back unchanged — that is the unmapped
// class round-tripping.
func (m *Map) Back(mapped string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	if orig, ok := m.rev[mapped]; ok {
		return orig
	}
	return mapped
}
