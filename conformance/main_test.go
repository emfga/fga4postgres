// Package conformance is the fga4postgres conformance suite. It
// assumes exclusive use of the compose services (CLAUDE.md): run
// the file you are working on locally, the whole suite in CI.
package conformance

import (
	"fmt"
	"os"
	"testing"

	"github.com/emfga/fga4postgres/internal/corpus"
	"github.com/emfga/fga4postgres/internal/skiplist"
)

// phase is the plan phase the engine has completed. It gates the
// generated skip decisions below and is bumped exactly when a
// phase's exit criterion holds — the only hand-maintained input to
// the skip machinery.
const phase = 0

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
	return ""
}

// TestMain prints the generated skip register after every run — the
// no-silent-scope-reduction mechanism for the suite's own tests.
func TestMain(m *testing.M) {
	code := m.Run()
	fmt.Println()
	skiplist.Report(os.Stdout)
	os.Exit(code)
}
