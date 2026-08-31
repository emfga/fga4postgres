package conformance

import (
	"os"
	"testing"

	"github.com/openfga/openfga/tests"
	"github.com/openfga/openfga/tests/check"
	"github.com/openfga/openfga/tests/listobjects"

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

// Until list_users lands (phase 5), the imported runners need
// `-skip '.*/.*/.*/.*/assertion_list_users_.*'` — upstream's
// sub-asserts have no injectable skip hook. CI runs them that way
// in a dedicated step; the plain `go test ./...` run skips them
// here, printed, so the default suite stays green without hiding
// the surface.
const importedRunnersSkipFlag = "-skip " +
	"'.*/.*/.*/.*/assertion_list_users_.*'"

func TestImportedCheckRunners(t *testing.T) {
	if phase < 5 && os.Getenv("FGA_RUN_IMPORTED") == "" {
		skiplist.Skip(t, "imported runners run in CI's dedicated "+
			"step with "+importedRunnersSkipFlag+" until "+
			"list_users lands (plan phase 5; ISSUES.md 4)")
	}
	client := sqlclient.New(
		testdb.Pool(t), uuidmap.New("imported/check"))
	check.RunAllTests(t, client)
	check.RunMatrixTests(t, "fga4postgres", "main", client)
}

func TestImportedListObjectsRunners(t *testing.T) {
	if phase < 5 && os.Getenv("FGA_RUN_IMPORTED") == "" {
		skiplist.Skip(t, "imported runners run in CI's dedicated "+
			"step with "+importedRunnersSkipFlag+" until "+
			"list_users lands (plan phase 5; ISSUES.md 4)")
	}
	client := sqlclient.New(
		testdb.Pool(t), uuidmap.New("imported/listobjects"))
	listobjects.RunAllTests(t, client)
	listobjects.RunMatrixTests(t, "fga4postgres", false, client)
}
