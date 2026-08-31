package conformance

import (
	"path/filepath"
	"slices"
	"testing"

	"github.com/emfga/fga4postgres/internal/causes"
)

// The causes-inventory gate (a CI shape ported from tsfga):
// every error construction site in upstream's write-path
// files at the pinned version must carry a human attribution in
// docs/write-causes.json. A pin bump, an upstream reword, or a
// new cause turns this red until `go run ./internal/cmd/causegen`
// is re-run and the fresh "open" entries are disposed.
func TestWriteCausesInventory(t *testing.T) {
	dir, version, err := causes.Module()
	if err != nil {
		t.Fatalf("resolving the openfga module: %v", err)
	}
	extracted, err := causes.Extract(dir)
	if err != nil {
		t.Fatalf("extracting causes: %v", err)
	}
	inv, err := causes.Load(filepath.Join(
		"..", "docs", "write-causes.json"))
	if err != nil {
		t.Fatalf("loading docs/write-causes.json: %v", err)
	}

	if inv.Pin != version {
		t.Errorf("inventory pin %q does not match the resolved "+
			"module version %q — regenerate with causegen and "+
			"re-attribute", inv.Pin, version)
	}
	if !slices.Equal(inv.Files, causes.Files) {
		t.Errorf("inventory file list differs from "+
			"causes.Files: %v vs %v", inv.Files, causes.Files)
	}

	attributed := map[causes.Cause]causes.Attribution{}
	for _, a := range inv.Causes {
		attributed[a.Cause] = a
	}
	valid := map[string]bool{
		"claimed": true, "pinned": true, "n/a": true,
	}
	for _, c := range extracted {
		a, ok := attributed[c]
		switch {
		case !ok:
			t.Errorf("unattributed cause: %s: %q — regenerate "+
				"docs/write-causes.json and dispose it",
				c.File, c.Message)
		case !valid[a.Disposition]:
			t.Errorf("cause %s: %q has disposition %q — every "+
				"entry must be claimed, pinned or n/a",
				c.File, c.Message, a.Disposition)
		}
		delete(attributed, c)
	}
	for c := range attributed {
		t.Errorf("stale inventory entry no longer in upstream: "+
			"%s: %q — regenerate docs/write-causes.json",
			c.File, c.Message)
	}
}
