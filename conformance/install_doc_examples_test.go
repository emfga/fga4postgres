package conformance

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// docSQLBlocks returns the ```sql blocks of one "## " section of a
// markdown file, in order.
func docSQLBlocks(t *testing.T, path, heading string) []string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	doc := string(raw)
	start := strings.Index(doc, "\n## "+heading+"\n")
	if start < 0 {
		t.Fatalf("%s has no section %q", path, heading)
	}
	section := doc[start+1:]
	if end := strings.Index(section[3:], "\n## "); end >= 0 {
		section = section[:end+3]
	}
	fence := regexp.MustCompile("(?s)```sql\n(.*?)```")
	var blocks []string
	for _, m := range fence.FindAllStringSubmatch(section, -1) {
		blocks = append(blocks, m[1])
	}
	return blocks
}

// The "Compiled relations" walkthrough in docs/INSTALL.md is a
// contract, not an illustration: its blocks run here in order, as
// written, and the claims its prose makes about their answers are
// asserted. A renamed function or parameter breaks a block; a page
// query rewritten into a shape that does not inline fails the plan
// check — the mistake that returns right answers slowly and would
// pass a read-through.
//
// Everything runs in one transaction that is rolled back, so the
// example's schemas, store and role never outlive the test.
func TestInstallDocExamples(t *testing.T) {
	blocks := docSQLBlocks(t,
		filepath.Join("..", "docs", "INSTALL.md"), "Compiled relations")
	if len(blocks) < 6 {
		t.Fatalf("found %d sql blocks, want the full walkthrough",
			len(blocks))
	}
	ctx := context.Background()
	tx, err := testdb.Pool(t).Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// The privileges block grants to the role the earlier
	// "Consumer privileges" section introduces.
	_, err = tx.Exec(ctx, `DO $$ BEGIN
		IF NOT EXISTS (SELECT FROM pg_roles
		               WHERE rolname = 'app_query_user') THEN
		  CREATE ROLE app_query_user NOLOGIN;
		END IF; END $$`)
	if err != nil {
		t.Fatal(err)
	}

	answers := map[string][]string{}
	for i, block := range blocks {
		for _, stmt := range strings.Split(block, ";\n") {
			stmt = strings.TrimSpace(stmt)
			if stmt == "" {
				continue
			}
			rows, err := tx.Query(ctx, stmt,
				pgx.QueryExecModeSimpleProtocol)
			if err != nil {
				t.Fatalf("block %d: %v\n%s", i+1, err, stmt)
			}
			var got []string
			for rows.Next() {
				vals, err := rows.Values()
				if err != nil {
					t.Fatal(err)
				}
				got = append(got, fmtValue(vals[len(vals)-1]))
			}
			rows.Close()
			if err := rows.Err(); err != nil {
				t.Fatalf("block %d: %v\n%s", i+1, err, stmt)
			}
			if !strings.Contains(stmt, "app_authz.") {
				continue
			}
			kind := kindOf(stmt)
			answers[kind] = got
			if kind == "objects" || kind == "subjects" {
				assertInlined(t, tx, stmt)
			}
		}
	}

	want := map[string][]string{
		"objects":  {"Budget", "Handbook"},
		"check":    {"false"},
		"subjects": {"Anne", "Bruno", "Carla"},
	}
	for kind, w := range want {
		if !slices.Equal(answers[kind], w) {
			t.Errorf("%s example answered %v, the prose says %v",
				kind, answers[kind], w)
		}
	}
}

func kindOf(stmt string) string {
	for _, k := range []string{"objects", "subjects", "check"} {
		if strings.Contains(stmt, "__"+k+"(") {
			return k
		}
	}
	return ""
}

func fmtValue(v any) string {
	switch x := v.(type) {
	case bool:
		if x {
			return "true"
		}
		return "false"
	case string:
		return x
	}
	return ""
}

// assertInlined fails when the planner keeps the generated function
// as an opaque call: a Function Scan (called in FROM but not
// inlined) or a ProjectSet (called in the select list).
func assertInlined(t *testing.T, tx pgx.Tx, stmt string) {
	t.Helper()
	rows, err := tx.Query(context.Background(), "EXPLAIN "+stmt,
		pgx.QueryExecModeSimpleProtocol)
	if err != nil {
		t.Fatal(err)
	}
	var plan []string
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			t.Fatal(err)
		}
		plan = append(plan, line)
	}
	rows.Close()
	text := strings.Join(plan, "\n")
	if strings.Contains(text, "Function Scan") ||
		strings.Contains(text, "ProjectSet") {
		t.Errorf("not inlined:\n%s\n%s", stmt, text)
	}
}
