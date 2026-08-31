// Package conformance is the fga4postgres conformance suite. It
// assumes exclusive use of the compose services (CLAUDE.md): run
// the file you are working on locally, the whole suite in CI.
package conformance

import (
	"fmt"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/emfga/fga4postgres/internal/corpus"
	"github.com/emfga/fga4postgres/internal/skiplist"
)

// phase is the plan phase the engine has completed. It gates the
// generated skip decisions below and is bumped exactly when a
// phase's exit criterion holds — the only hand-maintained input to
// the skip machinery.
const phase = 7

// phase1b flips when the resolver grows intersection, difference
// and TTU (the plan's interior 1a/1b gate).
const phase1b = true

// suiteSeed drives every shuffle; printed on every run so any
// failure reproduces with FGA_SEED.
var suiteSeed = func() int64 {
	if s := os.Getenv("FGA_SEED"); s != "" {
		v, err := strconv.ParseInt(s, 10, 64)
		if err == nil {
			return v
		}
	}
	return time.Now().UnixNano()
}()

// skipReason computes whether a corpus case must skip at the
// current phase, from its classified features alone. An empty
// return means: run it.
func skipReason(kind string, f corpus.Features) string {
	switch kind {
	case "check":
		if phase < 1 {
			return "check replay arrives in plan phase 1"
		}
	case "list_objects":
		if phase < 3 {
			return "list_objects arrives in plan phase 3"
		}
	case "list_users":
		if phase < 5 {
			return "list_users arrives in plan phase 5"
		}
	}
	if f.Conditions && phase < 4 {
		return "phase-4-unblock: case uses conditions"
	}
	if kind == "check" && !phase1b &&
		(f.TTU || f.Intersection || f.Exclusion) {
		return "phase-1b: model uses TTU, intersection or " +
			"exclusion"
	}
	return ""
}

// TestMain prints the generated skip register after every run — the
// no-silent-scope-reduction mechanism for the suite's own tests.
func TestMain(m *testing.M) {
	fmt.Printf("suite seed: %d (reproduce with FGA_SEED=%d)\n",
		suiteSeed, suiteSeed)
	code := m.Run()
	fmt.Println()
	skiplist.Report(os.Stdout)
	os.Exit(code)
}
