package bench

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// End-to-end runner test: every implemented feature executes
// against a loaded 100k fixture with tiny budgets, so a broken
// request shape or a misordered case fails here rather than in a
// 30-minute campaign. The direct scenario keeps it fast.
func TestRunAllFeatures(t *testing.T) {
	pool := testdb.Pool(t)
	s, err := ScenarioByName("direct")
	if err != nil {
		t.Fatal(err)
	}
	load := loadFixture(t, pool, s)

	res, err := Run(context.Background(), pool, s, size100k,
		load, RunConfig{
			Seed:     1,
			Warmup:   50 * time.Millisecond,
			Duration: 50 * time.Millisecond,
			MinOps:   3,
		}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}

	if len(res.Cases) != len(Variants) {
		t.Fatalf("%d cases, want %d",
			len(res.Cases), len(Variants))
	}
	// The two mutating cases must come last, model write after
	// write (plan §4).
	last := res.Cases[len(res.Cases)-1]
	prev := res.Cases[len(res.Cases)-2]
	if prev.Feature != "write" ||
		last.Feature != "write_authorization_model" {
		t.Errorf("mutating cases not last: %s, %s",
			prev.Feature, last.Feature)
	}
	for _, c := range res.Cases {
		if c.Ops < 3 {
			t.Errorf("%s:%s: only %d ops",
				c.Feature, c.Variant, c.Ops)
		}
		if c.Latency.P50 <= 0 || c.Latency.Max <
			c.Latency.P50 {
			t.Errorf("%s:%s: implausible latency %+v",
				c.Feature, c.Variant, c.Latency)
		}
	}
	if res.Env.EngineVersion == "" ||
		res.Env.PGVersion == "" {
		t.Errorf("env block incomplete: %+v", res.Env)
	}
	if _, err := json.Marshal(res); err != nil {
		t.Fatal(err)
	}

	// The scratch stores must be gone: only fixture stores (and
	// whatever other suites created) remain, none named
	// bench-scratch-*.
	var scratch int
	if err := pool.QueryRow(context.Background(), `
		SELECT count(*) FROM fga.store
		WHERE name LIKE 'bench-scratch-%'`,
	).Scan(&scratch); err != nil {
		t.Fatal(err)
	}
	if scratch != 0 {
		t.Errorf("%d scratch stores left behind", scratch)
	}
}
