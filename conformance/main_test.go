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

	"github.com/emfga/fga4postgres/internal/skiplist"
)

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
