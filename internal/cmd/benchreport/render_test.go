package main

import (
	"flag"
	"os"
	"strings"
	"testing"
)

// -update regenerates the golden files:
//
//	go test ./internal/cmd/benchreport/ -update
var update = flag.Bool("update", false,
	"rewrite the golden files")

func golden(t *testing.T, name, got string) {
	t.Helper()
	path := "testdata/" + name
	if *update {
		if err := os.WriteFile(
			path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run with -update to create)", err)
	}
	if got != string(want) {
		t.Errorf("%s drifted:\n--- got ---\n%s\n--- want "+
			"---\n%s", name, got, want)
	}
}

func TestRenderPlain(t *testing.T) {
	got, err := render(
		[]string{"testdata/candidate.json"}, "")
	if err != nil {
		t.Fatal(err)
	}
	golden(t, "plain.md", got)
	// The small-n case must be annotated.
	if !strings.Contains(got, "~ percentile") {
		t.Error("missing small-n footnote")
	}
}

func TestRenderDelta(t *testing.T) {
	got, err := render(
		[]string{"testdata/candidate.json"},
		"testdata/baseline.json")
	if err != nil {
		t.Fatal(err)
	}
	golden(t, "delta.md", got)
	for _, want := range []string{
		"Δ ops/s",
		// storage and work_mem differ between the fixtures.
		`baseline storage "tmpfs", candidate "volume"`,
		`baseline pg_settings.work_mem "8192", ` +
			`candidate "4096"`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q", want)
		}
	}
	// git fields must not warn: differing commits are the
	// point of a comparison.
	if strings.Contains(got, "baseline git") {
		t.Error("git fields must not warn")
	}
}

// A committed baseline bundles one result per scenario as a
// JSON array; the candidate matches by scenario.
func TestArrayBaseline(t *testing.T) {
	base, err := os.ReadFile("testdata/baseline.json")
	if err != nil {
		t.Fatal(err)
	}
	arr := "[" + string(base) + "]"
	path := t.TempDir() + "/baseline.json"
	if err := os.WriteFile(
		path, []byte(arr), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := render(
		[]string{"testdata/candidate.json"}, path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "Δ ops/s") {
		t.Error("array baseline produced no deltas")
	}
}

func TestRenderRefusals(t *testing.T) {
	// A baseline over a different fixture is a refusal, not a
	// warning: the numbers would not be comparable.
	if _, err := render(
		[]string{"testdata/candidate.json"},
		"testdata/mismatch.json"); err == nil ||
		!strings.Contains(err.Error(), "not comparable") {
		t.Errorf("expected a mismatch refusal, got %v", err)
	}
	if _, err := render(
		[]string{"testdata/nope.json"}, ""); err == nil {
		t.Error("expected an error for a missing file")
	}
}
