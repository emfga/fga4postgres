package uuidmap

import (
	"math/rand"
	"strings"
	"testing"
)

// Property: over any set of observed ids, the mapping is total,
// deterministic, and bijective — every mapped value goes back to
// exactly its original, and unmapped (grammar-refused) ids round
// trip unchanged.
func TestMappingProperties(t *testing.T) {
	m := New("uuidmap_test")
	rng := rand.New(rand.NewSource(1))

	alphabet := []rune(
		"abcdefghijklmnopqrstuvwxyz0123456789-_.|@+café★",
	)
	refused := []string{
		"a b", "a:b", "a#b", "a\tb", "a\x00b", "", "a\x1fb",
	}

	seen := map[string]string{}
	for i := 0; i < 5000; i++ {
		var sb strings.Builder
		n := 1 + rng.Intn(40)
		for j := 0; j < n; j++ {
			sb.WriteRune(alphabet[rng.Intn(len(alphabet))])
		}
		orig := sb.String()

		mapped := m.ID(orig)
		if prev, ok := seen[orig]; ok && prev != mapped {
			t.Fatalf("non-deterministic: %q -> %q then %q",
				orig, prev, mapped)
		}
		seen[orig] = mapped

		if m.ID(orig) != mapped {
			t.Fatalf("second call differs for %q", orig)
		}
		if back := m.Back(mapped); back != orig {
			t.Fatalf("round trip: %q -> %q -> %q",
				orig, mapped, back)
		}
	}

	// Bijectivity across the whole observed set.
	inverse := map[string]string{}
	for orig, mapped := range seen {
		if prev, ok := inverse[mapped]; ok && prev != orig {
			t.Fatalf("collision: %q and %q -> %s",
				prev, orig, mapped)
		}
		inverse[mapped] = orig
	}

	for _, orig := range refused {
		if got := m.ID(orig); got != orig {
			t.Fatalf("refused id %q was mapped to %q", orig, got)
		}
		if got := m.Back(orig); got != orig {
			t.Fatalf("refused id %q changed on Back: %q",
				orig, got)
		}
	}
}

// Two suites must not share a namespace; one suite must be stable
// across Map instances (i.e. across processes).
func TestNamespaceSeparation(t *testing.T) {
	a1, a2, b := New("suite-a"), New("suite-a"), New("suite-b")
	if a1.ID("anne") != a2.ID("anne") {
		t.Fatal("same suite, different mapping")
	}
	if a1.ID("anne") == b.ID("anne") {
		t.Fatal("different suites share a mapping")
	}
}
