// Package gotestjson parses `go test -json` event streams. It
// exists for the skips the suite cannot register itself: the
// imported upstream runners call t.Skip internally, so the only
// honest source for their skip list is the run's own output.
package gotestjson

import (
	"encoding/json"
	"io"
	"regexp"
	"strings"
)

type Event struct {
	Action  string
	Package string
	Test    string
	Output  string
	Elapsed float64
}

type Summary struct {
	Passed int
	Failed int
	// FailedPackages catches what per-test counting cannot: a
	// package that failed to build emits no test events at all,
	// only a package-level fail.
	FailedPackages int
	Skipped        []Skip
	Elapsed        float64 // wall time: sum of package elapsed
}

// Bad reports whether the run failed in any way.
func (s Summary) Bad() bool {
	return s.Failed > 0 || s.FailedPackages > 0
}

type Skip struct {
	Package string
	Test    string
	Reason  string
}

var frame = regexp.MustCompile(`^\s*[\w./-]+\.go:\d+:\s*`)

// Parse consumes a -json stream. Lines that are not JSON events
// (build output, for example) are ignored rather than fatal, so a
// partially broken run still yields its skip list.
func Parse(r io.Reader) (Summary, error) {
	var s Summary
	output := map[string][]string{}
	dec := json.NewDecoder(r)
	for {
		var e Event
		if err := dec.Decode(&e); err == io.EOF {
			break
		} else if err != nil {
			// Resync: skip the offending token stream line.
			var raw json.RawMessage
			if err2 := dec.Decode(&raw); err2 != nil {
				break
			}
			continue
		}
		key := e.Package + "/" + e.Test
		switch e.Action {
		case "output":
			if e.Test != "" {
				output[key] = append(output[key], e.Output)
			}
		case "pass":
			if e.Test != "" {
				s.Passed++
			} else {
				s.Elapsed += e.Elapsed
			}
		case "fail":
			if e.Test != "" {
				s.Failed++
			} else {
				s.FailedPackages++
				s.Elapsed += e.Elapsed
			}
		case "skip":
			if e.Test == "" {
				s.Elapsed += e.Elapsed
				continue
			}
			s.Skipped = append(s.Skipped, Skip{
				Package: e.Package,
				Test:    e.Test,
				Reason:  reason(output[key]),
			})
		}
	}
	return s, nil
}

// reason extracts the t.Skip message from a test's output lines:
// the non-frame text after the "--- SKIP" marker, or failing that
// the last log line.
func reason(lines []string) string {
	var after []string
	seen := false
	for _, l := range lines {
		if strings.Contains(l, "--- SKIP") {
			seen = true
			continue
		}
		if seen {
			l = strings.TrimSpace(frame.ReplaceAllString(l, ""))
			if l != "" && !strings.HasPrefix(l, "===") {
				after = append(after, l)
			}
		}
	}
	if len(after) > 0 {
		return strings.Join(after, " ")
	}
	// t.Skip before any parallel handoff logs ahead of the marker.
	for i := len(lines) - 1; i >= 0; i-- {
		l := strings.TrimSpace(frame.ReplaceAllString(
			lines[i], "",
		))
		if l != "" && !strings.HasPrefix(l, "===") &&
			!strings.HasPrefix(l, "--- ") {
			return l
		}
	}
	return "(no reason captured)"
}
