package bench

import (
	"testing"
	"time"
)

// sqlAlphabet is fga._ulid()'s alphabet (sql/050_tuple.sql),
// repeated here so a drift in either place turns this test red.
const sqlAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

func TestULIDFormat(t *testing.T) {
	if crockford != sqlAlphabet {
		t.Fatal("alphabet drifted from fga._ulid()")
	}
	g := NewULIDGen(1)
	u := g.Next()
	if len(u) != 26 {
		t.Fatalf("len(%q) = %d", u, len(u))
	}
	for i := 0; i < len(u); i++ {
		found := false
		for j := 0; j < 32; j++ {
			if u[i] == crockford[j] {
				found = true
			}
		}
		if !found {
			t.Fatalf("%q: char %q outside the alphabet",
				u, u[i])
		}
	}
}

func TestULIDMonotonic(t *testing.T) {
	g := NewULIDGen(1)
	prev := g.Next()
	for i := 0; i < 100_000; i++ {
		u := g.Next()
		if u <= prev {
			t.Fatalf("%q !> %q", u, prev)
		}
		prev = u
	}
}

// Sort compatibility with fga._ulid(): lexicographic string
// order must equal numeric (timestamp, entropy) order, and the
// leading 48 bits must decode with fga._ulid_time()'s
// arithmetic — so engine-written and loader-written rows
// interleave correctly in tuple_ulid_idx and in read's keyset.
func TestULIDSortMatchesTime(t *testing.T) {
	type sample struct {
		ms uint64
		hi uint16
		lo uint64
	}
	var prev string
	var prevS sample
	for i, s := range []sample{
		{0, 0, 0},
		{0, 0, 1},
		{0, 1, 0},
		{0, 1<<16 - 1, 1<<64 - 1},
		{1, 0, 0},
		{1_700_000_000_000, 0, 42},
		{1_700_000_000_000, 0, 43},
		{1_700_000_000_001, 0, 0},
		{1<<48 - 1, 1<<16 - 1, 1<<64 - 1},
	} {
		u := encodeULID(s.ms, s.hi, s.lo)
		ms, err := ulidTime(u)
		if err != nil {
			t.Fatal(err)
		}
		if ms != s.ms {
			t.Fatalf("%q decodes to %d, want %d", u, ms, s.ms)
		}
		if i > 0 && !(u > prev) {
			t.Fatalf("%q !> %q for %+v after %+v",
				u, prev, s, prevS)
		}
		prev, prevS = u, s
	}
}

func TestULIDClockRegression(t *testing.T) {
	g := NewULIDGen(1)
	now := time.UnixMilli(1_700_000_000_000)
	g.now = func() time.Time { return now }
	a := g.Next()
	now = now.Add(-time.Second) // clock steps backwards
	b := g.Next()
	if b <= a {
		t.Fatalf("%q !> %q under clock regression", b, a)
	}
}

func TestULIDSeedDeterminism(t *testing.T) {
	a, b := NewULIDGen(9), NewULIDGen(9)
	if a.hi != b.hi || a.lo != b.lo {
		t.Fatal("same seed, different entropy")
	}
	c := NewULIDGen(10)
	if a.hi == c.hi && a.lo == c.lo {
		t.Fatal("different seed, same entropy")
	}
}
