package conformance

import (
	"testing"

	"github.com/emfga/fga4postgres/internal/corpus"
	"github.com/emfga/fga4postgres/internal/skiplist"
)

// loadCorpus fails loudly: a corpus that does not parse is a
// harness bug, never a skip.
func loadCorpus(t *testing.T) []corpus.File {
	t.Helper()
	files, err := corpus.Load()
	if err != nil {
		t.Fatal(err)
	}
	return files
}

// The loader must see the whole corpus at the pin. Exact totals,
// so a decode regression (a renamed field silently dropping every
// assertion, say) turns red instead of shrinking the suite.
func TestCorpusInventory(t *testing.T) {
	var tests, stages, assertions int
	for _, f := range loadCorpus(t) {
		tests += len(f.Tests)
		for _, tc := range f.Tests {
			stages += len(tc.Stages)
			feat := corpus.Classify(tc)
			assertions += feat.Check + feat.ListObjects +
				feat.ListUsers
		}
	}
	// Counted at openfga v1.19.0 (workspace doc 06).
	if tests != 161 || stages != 188 || assertions != 1227 {
		t.Fatalf(
			"corpus inventory drifted: %d tests, %d stages, "+
				"%d assertions (want 161/188/1227)",
			tests, stages, assertions,
		)
	}
}

// corpusCases runs one subtest per corpus case for one assertion
// kind, honoring the generated skip decision. Selectors work from
// this first commit:
//
//	go test ./conformance/... -run 'TestCheckCorpus/<file>/<case>'
func corpusCases(
	t *testing.T, kind string,
	run func(t *testing.T, tc corpus.Test),
) {
	for _, f := range loadCorpus(t) {
		t.Run(f.Name, func(t *testing.T) {
			for _, tc := range f.Tests {
				t.Run(tc.Name, func(t *testing.T) {
					feat := corpus.Classify(tc)
					n := map[string]int{
						"check":        feat.Check,
						"list_objects": feat.ListObjects,
						"list_users":   feat.ListUsers,
					}[kind]
					if n == 0 {
						skiplist.Skip(t,
							"no "+kind+" assertions in this case")
					}
					if r := skipReason(kind, feat); r != "" {
						skiplist.Skip(t, r)
					}
					run(t, tc)
				})
			}
		})
	}
}

func TestCheckCorpus(t *testing.T) {
	corpusCases(t, "check",
		func(t *testing.T, tc corpus.Test) {
			t.Fatal("replay not implemented (plan phase 1)")
		})
}

func TestListObjectsCorpus(t *testing.T) {
	corpusCases(t, "list_objects",
		func(t *testing.T, tc corpus.Test) {
			t.Fatal("replay not implemented (plan phase 3)")
		})
}

func TestListUsersCorpus(t *testing.T) {
	corpusCases(t, "list_users",
		func(t *testing.T, tc corpus.Test) {
			t.Fatal("replay not implemented (plan phase 5)")
		})
}
