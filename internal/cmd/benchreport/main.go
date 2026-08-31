// benchreport renders benchmark result JSON (written by
// internal/cmd/bench) as markdown, optionally with deltas
// against a committed baseline file.
//
//	go run ./internal/cmd/benchreport bench-results/…json
//	go run ./internal/cmd/benchreport \
//	  -baseline docs/benchmarks/baseline-100k.json …json
//
// Deltas are informational — nothing fails on a regression
// (decision 8). The exit code is non-zero only for malformed
// input or a baseline that measured a different fixture
// (scenario, size, seed or generator version), because that
// comparison would be a lie. Environment differences between
// baseline and candidate warn in the output and still exit 0.
package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	baseline := flag.String("baseline", "",
		"baseline result JSON to diff against")
	out := flag.String("o", "",
		"write the report to a file (default stdout)")
	flag.Parse()

	if flag.NArg() == 0 {
		fmt.Fprintln(os.Stderr,
			"benchreport: no result files given")
		os.Exit(1)
	}
	if *baseline != "" && flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr,
			"benchreport: -baseline compares against exactly "+
				"one result file")
		os.Exit(1)
	}

	report, err := render(flag.Args(), *baseline)
	if err != nil {
		fmt.Fprintln(os.Stderr, "benchreport:", err)
		os.Exit(1)
	}
	if *out == "" {
		fmt.Print(report)
		return
	}
	if err := os.WriteFile(
		*out, []byte(report), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "benchreport:", err)
		os.Exit(1)
	}
}
