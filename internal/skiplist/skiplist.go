// Package skiplist is the suite's in-process skip register. Every
// deliberate skip goes through Skip so the run can print a single
// generated list of everything it did not exercise — the "no
// silent scope reduction" mechanism for tests we author ourselves.
// (Skips inside the imported upstream runners cannot call this;
// those are harvested from `go test -json` output by
// internal/cmd/skipgen instead.)
package skiplist

import (
	"fmt"
	"io"
	"sort"
	"sync"
	"testing"
)

type entry struct{ name, reason string }

var (
	mu      sync.Mutex
	entries []entry
)

// Skip records the skip and skips the test. The reason should name
// the phase or divergence that lifts it, so the printed list reads
// as a work register, not an excuse list.
func Skip(t testing.TB, reason string) {
	t.Helper()
	mu.Lock()
	entries = append(entries, entry{t.Name(), reason})
	mu.Unlock()
	t.Skip(reason)
}

// Report prints the register, grouped by reason with counts, then
// each skipped name. TestMain calls it after m.Run so the list is
// part of every run's output.
func Report(w io.Writer) {
	mu.Lock()
	defer mu.Unlock()
	if len(entries) == 0 {
		fmt.Fprintln(w, "skiplist: no registered skips")
		return
	}
	byReason := map[string][]string{}
	for _, e := range entries {
		byReason[e.reason] = append(byReason[e.reason], e.name)
	}
	reasons := make([]string, 0, len(byReason))
	for r := range byReason {
		reasons = append(reasons, r)
	}
	sort.Strings(reasons)
	fmt.Fprintf(w,
		"skiplist: %d skipped across %d reasons\n",
		len(entries), len(reasons),
	)
	for _, r := range reasons {
		names := byReason[r]
		sort.Strings(names)
		fmt.Fprintf(w, "  [%d] %s\n", len(names), r)
		for _, n := range names {
			fmt.Fprintf(w, "      %s\n", n)
		}
	}
}
