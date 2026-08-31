// Package causes mechanically enumerates the error construction
// sites of openfga's tuple-write, model-write and condition
// validation paths at the pinned version, so the attribution
// inventory in docs/write-causes.json cannot silently drift: a
// cause upstream adds, removes or rewords turns the gate test
// red until the inventory is regenerated and re-attributed
// (tsfga's causes-inventory CI shape, workspace doc 05 §4).
package causes

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Files is the write-path surface the inventory covers, relative
// to the openfga module root. Extending the audited surface means
// adding a file here and re-attributing its causes.
var Files = []string{
	"internal/validation/validation.go",
	"pkg/tuple/tuple.go",
	"pkg/server/commands/write.go",
	"pkg/typesystem/typesystem.go",
	"internal/condition/condition.go",
}

// Cause is one error construction site, identified by its message
// literal (line numbers drift; message text is the contract a
// human attributed).
type Cause struct {
	File    string `json:"file"`
	Message string `json:"message"`
}

// Attribution is a cause plus its disposition in fga4postgres:
// "claimed" (the engine reproduces the refusal, gate-tested),
// "pinned" (a documented divergence covers it), "n/a" (the cause
// cannot fire through the engine's API surface — e.g. it guards
// a layer the engine does not have), or "open" (not yet
// disposed; the gate fails on these).
type Attribution struct {
	Cause
	Disposition string `json:"disposition"`
	Note        string `json:"note,omitempty"`
}

// Inventory is the committed docs/write-causes.json shape.
type Inventory struct {
	Pin    string        `json:"pin"`
	Files  []string      `json:"files"`
	Causes []Attribution `json:"causes"`
}

var siteRE = regexp.MustCompile(
	`(?:errors\.New|fmt\.Errorf)\("((?:[^"\\]|\\.)*)"`)

// Module returns the openfga module's directory and version as
// the build resolves them — the module cache in CI, a local
// checkout only if go.mod is pointed at one.
func Module() (dir, version string, err error) {
	out, err := exec.Command("go", "list", "-m", "-f",
		"{{.Dir}} {{.Version}}",
		"github.com/openfga/openfga").Output()
	if err != nil {
		return "", "", fmt.Errorf("go list -m openfga: %w", err)
	}
	fields := strings.Fields(strings.TrimSpace(string(out)))
	if len(fields) != 2 {
		return "", "", fmt.Errorf(
			"unexpected go list output: %q", out)
	}
	return fields[0], fields[1], nil
}

// Extract scans Files under dir and returns every construction
// site, sorted and deduplicated (the same message constructed
// twice in one file is one cause).
func Extract(dir string) ([]Cause, error) {
	seen := map[Cause]bool{}
	var out []Cause
	for _, f := range Files {
		b, err := os.ReadFile(filepath.Join(dir, f))
		if err != nil {
			return nil, err
		}
		for _, m := range siteRE.FindAllStringSubmatch(
			string(b), -1) {
			c := Cause{File: f, Message: m[1]}
			if !seen[c] {
				seen[c] = true
				out = append(out, c)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].File != out[j].File {
			return out[i].File < out[j].File
		}
		return out[i].Message < out[j].Message
	})
	return out, nil
}

// Load reads a committed inventory.
func Load(path string) (*Inventory, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var inv Inventory
	if err := json.Unmarshal(b, &inv); err != nil {
		return nil, err
	}
	return &inv, nil
}
