// skipgen turns a `go test -json` stream (stdin) into the
// run-derived skip list: every sub-test the run actually skipped,
// with its reason. Because the input is the run's own output, the
// list cannot drift from reality by hand-editing.
//
//	go test -json ./conformance/... | go run ./internal/cmd/skipgen
package main

import (
	"fmt"
	"os"
	"sort"

	"github.com/emfga/fga4postgres/internal/gotestjson"
)

func main() {
	sum, err := gotestjson.Parse(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "skipgen:", err)
		os.Exit(1)
	}
	sort.Slice(sum.Skipped, func(i, j int) bool {
		a, b := sum.Skipped[i], sum.Skipped[j]
		if a.Package != b.Package {
			return a.Package < b.Package
		}
		return a.Test < b.Test
	})
	fmt.Printf("# Skipped cases (run-derived; do not edit)\n")
	fmt.Printf("# skipped=%d passed=%d failed=%d\n",
		len(sum.Skipped), sum.Passed, sum.Failed)
	for _, s := range sum.Skipped {
		fmt.Printf("%s\t%s\t%s\n", s.Package, s.Test, s.Reason)
	}
	if sum.Bad() {
		os.Exit(1)
	}
}
