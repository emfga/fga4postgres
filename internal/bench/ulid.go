package bench

import (
	"fmt"
	"sync"
	"time"
)

// Client-side ULIDs for bulk loading: the same 26-char Crockford
// base32 wire format as fga._ulid() (sql/050_tuple.sql), so rows
// COPYed past the write path page and sort exactly like rows the
// engine wrote itself. Generation is monotonic within a process —
// sequential inserts into tuple_ulid_idx append instead of
// splitting random pages — which fga._ulid() does not promise and
// the loader does not need promised.

// crockford is fga._ulid()'s alphabet, verbatim.
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// ULIDGen hands out monotonically increasing ULIDs: 48-bit
// millisecond timestamp plus an 80-bit counter seeded per
// process. Goroutine-safe.
type ULIDGen struct {
	mu   sync.Mutex
	ms   uint64
	hi   uint16 // entropy bits 79..64
	lo   uint64 // entropy bits 63..0
	now  func() time.Time
	seen bool
}

// NewULIDGen seeds the entropy counter from the seed so two loads
// with the same seed produce the same suffixes (timestamps still
// differ — ULIDs are identifiers, not fixture content).
func NewULIDGen(seed uint64) *ULIDGen {
	return &ULIDGen{
		hi:  uint16(rnd(seed, 'u', 'h')),
		lo:  rnd(seed, 'u', 'l'),
		now: time.Now,
	}
}

// Next returns the next ULID, strictly greater than every ULID
// this generator returned before.
func (g *ULIDGen) Next() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	ms := uint64(g.now().UnixMilli()) & (1<<48 - 1)
	// Same or earlier millisecond: bump the counter so ordering
	// never regresses, even under clock skew.
	if g.seen && ms <= g.ms {
		ms = g.ms
		g.lo++
		if g.lo == 0 {
			g.hi++
		}
	}
	g.ms = ms
	g.seen = true
	return encodeULID(g.ms, g.hi, g.lo)
}

// encodeULID renders 48 timestamp bits and 80 entropy bits as the
// canonical 26-character string: 10 chars of time, 16 of entropy,
// 5 bits each, big-endian — the exact layout fga._ulid() emits.
func encodeULID(ms uint64, hi uint16, lo uint64) string {
	var b [26]byte
	for i := 9; i >= 0; i-- {
		b[i] = crockford[ms&31]
		ms >>= 5
	}
	// The 80 entropy bits, top to bottom, 5 at a time.
	e := func(shift uint) byte {
		// Bits [shift+4 .. shift] of the 80-bit hi:lo value.
		if shift >= 64 {
			return byte(hi >> (shift - 64) & 31)
		}
		v := lo >> shift
		if shift > 59 { // top bits spill in from hi
			v |= uint64(hi) << (64 - shift)
		}
		return byte(v & 31)
	}
	for i := 0; i < 16; i++ {
		b[10+i] = crockford[e(uint(75-5*i))]
	}
	return string(b[:])
}

// ulidTime decodes the leading 48 bits back to a millisecond
// timestamp — the same arithmetic as fga._ulid_time(), kept for
// the sort-compatibility test.
func ulidTime(u string) (uint64, error) {
	if len(u) != 26 {
		return 0, fmt.Errorf("ulid %q: not 26 chars", u)
	}
	var ms uint64
	for i := 0; i < 10; i++ {
		idx := -1
		for j := 0; j < 32; j++ {
			if crockford[j] == u[i] {
				idx = j
				break
			}
		}
		if idx < 0 {
			return 0, fmt.Errorf(
				"ulid %q: bad char %q", u, u[i])
		}
		ms = ms<<5 | uint64(idx)
	}
	return ms, nil
}
