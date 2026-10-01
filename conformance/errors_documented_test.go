package conformance

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// Every SQLSTATE the engine raises is part of its contract (consumers
// catch them), so each one needs its row in docs/ERRORS.md. YF000 is
// the class anchor: caught, never raised, and documented in prose.
func TestErrorCodesDocumented(t *testing.T) {
	doc, err := os.ReadFile(filepath.Join("..", "docs", "ERRORS.md"))
	if err != nil {
		t.Fatal(err)
	}
	files, err := filepath.Glob(filepath.Join("..", "sql", "*.sql"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no sql files found: %v", err)
	}
	code := regexp.MustCompile(`'(YF[0-9A-Z]{3})'`)
	var missing []string
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range code.FindAllStringSubmatch(string(src), -1) {
			c := m[1]
			if c == "YF000" || slices.Contains(missing, c) {
				continue
			}
			if !strings.Contains(string(doc), "| "+c+" |") {
				missing = append(missing, c)
				t.Errorf("%s raises %s, which has no docs/ERRORS.md row",
					filepath.Base(f), c)
			}
		}
	}
}
