package bench

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Per-feature call builders. Requests are the engine's public
// jsonb shapes (upstream snake_case), assembled by hand: every
// value is a uuid, a fixed relation name or a type name, so no
// JSON escaping is needed and the client-side cost stays flat.

// implemented gates the case list; features land milestone by
// milestone and the CLI validates against this map so an
// unimplemented request fails loudly instead of silently
// shrinking scope.
var implemented = map[string]bool{
	"check": true,
}

// ImplementedFeatures lists the runnable features in Variants
// order, deduplicated.
func ImplementedFeatures() []string {
	var out []string
	seen := map[string]bool{}
	for _, v := range Variants {
		if implemented[v.Feature] && !seen[v.Feature] {
			seen[v.Feature] = true
			out = append(out, v.Feature)
		}
	}
	return out
}

// newCase builds the per-op closure for one case, plus an
// optional cleanup that runs after the case finishes (outside
// any timed window).
func newCase(
	ctx context.Context, pool *pgxpool.Pool,
	s Scenario, size Size, load LoadResult, seed uint64,
	v Variant,
) (caseCall, func(), error) {
	switch v.Feature {
	case "check":
		return checkCase(pool, s, size, load, seed, v),
			nil, nil
	}
	return nil, nil, fmt.Errorf(
		"feature %q is not implemented", v.Feature)
}

func checkReq(modelID string, q Query) string {
	var b strings.Builder
	b.Grow(256)
	b.WriteString(`{"authorization_model_id":"`)
	b.WriteString(modelID)
	b.WriteString(`","tuple_key":{"object":"`)
	b.WriteString(q.Object)
	b.WriteString(`","relation":"`)
	b.WriteString(q.Relation)
	b.WriteString(`","user":"`)
	b.WriteString(q.User)
	b.WriteString(`"}}`)
	return b.String()
}

func checkCase(
	pool *pgxpool.Pool, s Scenario, size Size,
	load LoadResult, seed uint64, v Variant,
) caseCall {
	return func(ctx context.Context, i int) error {
		q := s.Query(seed, size, v, i)
		var out []byte
		return pool.QueryRow(ctx,
			"SELECT fga.check($1, $2)",
			load.Store, checkReq(load.ModelID, q),
		).Scan(&out)
	}
}
