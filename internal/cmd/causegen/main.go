// causegen regenerates the cause list for docs/write-causes.json
// after a pin bump: it prints the extracted inventory as JSON with
// every disposition carried over from the existing file where the
// (file, message) pair still matches, and "open" where it does
// not. The human then attributes the "open" entries and commits.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/emfga/fga4postgres/internal/causes"
)

func main() {
	dir, version, err := causes.Module()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	extracted, err := causes.Extract(dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	prior := map[causes.Cause]causes.Attribution{}
	if inv, err := causes.Load("docs/write-causes.json"); err == nil {
		for _, a := range inv.Causes {
			prior[a.Cause] = a
		}
	}

	inv := causes.Inventory{Pin: version, Files: causes.Files}
	for _, c := range extracted {
		a, ok := prior[c]
		if !ok {
			a = causes.Attribution{Cause: c, Disposition: "open"}
		}
		inv.Causes = append(inv.Causes, a)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(inv); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
