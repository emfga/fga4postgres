package conformance

import (
	"testing"

	"github.com/openfga/openfga/tests"
	"github.com/openfga/openfga/tests/check"

	"github.com/emfga/fga4postgres/internal/skiplist"
	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// The imported upstream runners (workspace decision 5): the exact
// test code that gates the reference server, pointed at the
// engine through the sqlclient adapter.
//
// A sequencing fact execution surfaced (ISSUES.md 4): the matrix's
// one shared model declares `condition xcond` and most stages
// write conditioned tuples, so the imported check runners cannot
// go green before conditions (plan phase 4). Until then this is a
// single printed skip, and the compile-time interface assertion
// below keeps the adapter honest in the meantime.
var _ tests.ClientInterface = (*sqlclient.Client)(nil)

func TestImportedCheckRunners(t *testing.T) {
	if phase < 4 {
		skiplist.Skip(t, "imported check runners blocked on "+
			"conditions: the matrix model declares xcond "+
			"(plan phase 4 lifts; ISSUES.md 4)")
	}
	client := sqlclient.New(
		testdb.Pool(t), uuidmap.New("imported/check"))
	check.RunAllTests(t, client)
	check.RunMatrixTests(t, "fga4postgres", "main", client)
}
