// confreport renders the conformance report from a
// `go test -json` stream (stdin): pass/fail/skip totals, suite
// wall time, the corpus inventory, and the skip list grouped by
// reason.
//
//	go test -json ./... | go run ./internal/cmd/confreport
package main

import (
	"fmt"
	"os"
	"sort"
	"time"

	"github.com/emfga/fga4postgres/internal/corpus"
	"github.com/emfga/fga4postgres/internal/gotestjson"
)

func main() {
	sum, err := gotestjson.Parse(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "confreport:", err)
		os.Exit(1)
	}

	fmt.Printf("# Conformance report\n\n")
	fmt.Printf("Generated: %s\n\n",
		time.Now().UTC().Format(time.RFC3339))

	fmt.Printf("## Suite\n\n")
	fmt.Printf("- passed:  %d\n", sum.Passed)
	fmt.Printf("- failed:  %d (+%d packages)\n",
		sum.Failed, sum.FailedPackages)
	fmt.Printf("- skipped: %d\n", len(sum.Skipped))
	fmt.Printf("- wall time: %.1fs\n\n", sum.Elapsed)

	files, err := corpus.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "confreport:", err)
		os.Exit(1)
	}
	var tests, stages, checks, lobjs, lusers int
	for _, f := range files {
		tests += len(f.Tests)
		for _, tc := range f.Tests {
			stages += len(tc.Stages)
			feat := corpus.Classify(tc)
			checks += feat.Check
			lobjs += feat.ListObjects
			lusers += feat.ListUsers
		}
	}
	fmt.Printf("## Corpus at the pin\n\n")
	fmt.Printf(
		"- %d tests, %d stages; assertions: %d check, "+
			"%d list_objects, %d list_users\n\n",
		tests, stages, checks, lobjs, lusers,
	)

	fmt.Printf("## Skipped (run-derived)\n\n")
	byReason := map[string][]string{}
	for _, s := range sum.Skipped {
		byReason[s.Reason] = append(byReason[s.Reason], s.Test)
	}
	reasons := make([]string, 0, len(byReason))
	for r := range byReason {
		reasons = append(reasons, r)
	}
	sort.Strings(reasons)
	for _, r := range reasons {
		fmt.Printf("- [%d] %s\n", len(byReason[r]), r)
	}

	if sum.Bad() {
		os.Exit(1)
	}
}
