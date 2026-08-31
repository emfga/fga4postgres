package conformance

import (
	"testing"

	"github.com/openfga/openfga/tests"
	"github.com/openfga/openfga/tests/check"
	"github.com/openfga/openfga/tests/listobjects"
	"github.com/openfga/openfga/tests/listusers"

	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// The imported upstream runners: the exact
// test code that gates the reference server, pointed at the
// engine through the sqlclient adapter. The compile-time
// assertion keeps the adapter honest against the pinned
// interface.
var _ tests.ClientInterface = (*sqlclient.Client)(nil)

func TestImportedCheckRunners(t *testing.T) {
	client := sqlclient.New(
		testdb.Pool(t), uuidmap.New("imported/check"))
	check.RunAllTests(t, client)
	check.RunMatrixTests(t, "fga4postgres", "main", client)
}

func TestImportedListObjectsRunners(t *testing.T) {
	client := sqlclient.New(
		testdb.Pool(t), uuidmap.New("imported/listobjects"))
	listobjects.RunAllTests(t, client)
	listobjects.RunMatrixTests(t, "fga4postgres", false, client)
}

func TestImportedListUsersRunners(t *testing.T) {
	client := sqlclient.New(
		testdb.Pool(t), uuidmap.New("imported/listusers"))
	listusers.RunAllTests(t, client)
}
