package bench

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Per-feature call builders. Requests are the engine's public
// jsonb shapes (upstream snake_case), assembled by hand: every
// value is a uuid, a fixed relation name or a type name, so no
// JSON escaping is needed and the client-side cost stays flat.

// implemented gates the case list; the CLI validates against
// this map so an unimplemented request fails loudly instead of
// silently shrinking scope.
var implemented = map[string]bool{
	"check":                     true,
	"batch_check":               true,
	"list_objects":              true,
	"list_users":                true,
	"read":                      true,
	"write":                     true,
	"expand":                    true,
	"write_authorization_model": true,
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
	case "batch_check":
		return batchCheckCase(pool, s, size, load, seed),
			nil, nil
	case "list_objects":
		return listObjectsCase(pool, s, size, load, seed, v),
			nil, nil
	case "list_users":
		return listUsersCase(pool, s, size, load, seed, v),
			nil, nil
	case "read":
		return readCase(ctx, pool, s, size, load, seed, v)
	case "expand":
		return expandCase(pool, s, size, load, seed, v),
			nil, nil
	case "write":
		return writeCase(ctx, pool, s, seed)
	case "write_authorization_model":
		return modelWriteCase(ctx, pool, s)
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

// batchCheckCase sends 50 checks per call — the verified
// upstream cap — cycling the three check variants so each batch
// mixes shallow hits, deep hits and misses. One histogram sample
// is one batch; per-item figures divide by 50.
func batchCheckCase(
	pool *pgxpool.Pool, s Scenario, size Size,
	load LoadResult, seed uint64,
) caseCall {
	kinds := []Variant{
		{"check", "hit-shallow"},
		{"check", "hit-deep"},
		{"check", "miss"},
	}
	return func(ctx context.Context, i int) error {
		var b strings.Builder
		b.Grow(8192)
		b.WriteString(`{"authorization_model_id":"`)
		b.WriteString(load.ModelID)
		b.WriteString(`","checks":[`)
		for k := 0; k < 50; k++ {
			q := s.Query(seed, size,
				kinds[k%len(kinds)], i*50+k)
			if k > 0 {
				b.WriteByte(',')
			}
			fmt.Fprintf(&b,
				`{"correlation_id":"c%d","tuple_key":`+
					`{"object":"%s","relation":"%s",`+
					`"user":"%s"}}`,
				k, q.Object, q.Relation, q.User)
		}
		b.WriteString(`]}`)
		var out []byte
		return pool.QueryRow(ctx,
			"SELECT fga.batch_check($1, $2)",
			load.Store, b.String()).Scan(&out)
	}
}

func listObjectsCase(
	pool *pgxpool.Pool, s Scenario, size Size,
	load LoadResult, seed uint64, v Variant,
) caseCall {
	return func(ctx context.Context, i int) error {
		q := s.Query(seed, size, v, i)
		req := fmt.Sprintf(
			`{"authorization_model_id":"%s","type":"%s",`+
				`"relation":"%s","user":"%s"}`,
			load.ModelID, q.Type, q.Relation, q.User)
		var out []byte
		return pool.QueryRow(ctx,
			"SELECT fga.list_objects($1, $2)",
			load.Store, req).Scan(&out)
	}
}

func listUsersCase(
	pool *pgxpool.Pool, s Scenario, size Size,
	load LoadResult, seed uint64, v Variant,
) caseCall {
	return func(ctx context.Context, i int) error {
		q := s.Query(seed, size, v, i)
		typ, id, _ := strings.Cut(q.Object, ":")
		req := fmt.Sprintf(
			`{"authorization_model_id":"%s","object":`+
				`{"type":"%s","id":"%s"},"relation":"%s",`+
				`"user_filters":[{"type":"%s"}]}`,
			load.ModelID, typ, id, q.Relation, q.Type)
		var out []byte
		return pool.QueryRow(ctx,
			"SELECT fga.list_users($1, $2)",
			load.Store, req).Scan(&out)
	}
}

func expandCase(
	pool *pgxpool.Pool, s Scenario, size Size,
	load LoadResult, seed uint64, v Variant,
) caseCall {
	return func(ctx context.Context, i int) error {
		q := s.Query(seed, size, v, i)
		req := fmt.Sprintf(
			`{"authorization_model_id":"%s","tuple_key":`+
				`{"object":"%s","relation":"%s"}}`,
			load.ModelID, q.Object, q.Relation)
		var out []byte
		return pool.QueryRow(ctx,
			"SELECT fga.expand($1, $2)",
			load.Store, req).Scan(&out)
	}
}

// readCase pages the tuple listing. first-page filters by one
// object (type:id); deep-page starts a keyset page at the 90th
// percentile ulid of the store. The deep-page filter is pinned
// to the stream's first query: the continuation token binds the
// engine's own filter hash (fetched once from a real fga.read
// call, then repositioned), so varying the filter per op would
// need a token per op — and the case measures keyset
// positioning, not filter variety.
func readCase(
	ctx context.Context, pool *pgxpool.Pool,
	s Scenario, size Size, load LoadResult, seed uint64,
	v Variant,
) (caseCall, func(), error) {
	if v.Name == "first-page" {
		return func(ctx context.Context, i int) error {
			q := s.Query(seed, size, v, i)
			req := fmt.Sprintf(
				`{"tuple_key":{"object":"%s"},`+
					`"page_size":50}`, q.Object)
			var out []byte
			return pool.QueryRow(ctx,
				"SELECT fga.read($1, $2)",
				load.Store, req).Scan(&out)
		}, nil, nil
	}

	q := s.Query(seed, size, v, 0)
	filter := fmt.Sprintf(
		`{"object":"%s:","user":"%s"}`, q.Type, q.User)
	// The engine builds the token (and its filter hash); only
	// the keyset position is replaced.
	var first []byte
	if err := pool.QueryRow(ctx,
		"SELECT fga.read($1, $2)", load.Store,
		fmt.Sprintf(`{"tuple_key":%s,"page_size":1}`, filter),
	).Scan(&first); err != nil {
		return nil, nil, err
	}
	var page struct {
		ContinuationToken string `json:"continuation_token"`
	}
	if err := json.Unmarshal(first, &page); err != nil {
		return nil, nil, err
	}
	if page.ContinuationToken == "" {
		return nil, nil, fmt.Errorf(
			"deep-page filter %s matched fewer than 2 rows",
			filter)
	}
	raw, err := base64.URLEncoding.DecodeString(
		page.ContinuationToken)
	if err != nil {
		return nil, nil, err
	}
	var tok map[string]string
	if err := json.Unmarshal(raw, &tok); err != nil {
		return nil, nil, err
	}
	var ulid string
	if err := pool.QueryRow(ctx, `
		SELECT t.ulid FROM fga.tuple t
		WHERE t.store = $1
		ORDER BY t.ulid
		OFFSET (SELECT count(*) * 9 / 10 FROM fga.tuple
		        WHERE store = $1)
		LIMIT 1`, load.Store).Scan(&ulid); err != nil {
		return nil, nil, err
	}
	tok["u"] = ulid
	rebound, err := json.Marshal(tok)
	if err != nil {
		return nil, nil, err
	}
	token := base64.URLEncoding.EncodeToString(rebound)
	req := fmt.Sprintf(
		`{"tuple_key":%s,"page_size":50,`+
			`"continuation_token":"%s"}`, filter, token)
	return func(ctx context.Context, i int) error {
		var out []byte
		return pool.QueryRow(ctx,
			"SELECT fga.read($1, $2)",
			load.Store, req).Scan(&out)
	}, nil, nil
}

// scratchStore creates a throwaway store carrying the scenario's
// model, for the mutating cases; the returned cleanup deletes it
// outside any timed window (plan §4).
func scratchStore(
	ctx context.Context, pool *pgxpool.Pool, s Scenario,
) (store, modelID string, cleanup func(), err error) {
	if err = pool.QueryRow(ctx,
		"SELECT id::text FROM fga.create_store($1)",
		"bench-scratch-"+s.Name()).Scan(&store); err != nil {
		return "", "", nil, err
	}
	cleanup = func() {
		_, _ = pool.Exec(ctx,
			"SELECT fga.delete_store($1)", store)
	}
	var resp []byte
	if err = pool.QueryRow(ctx,
		"SELECT fga.write_authorization_model($1, $2)",
		store, s.Model()).Scan(&resp); err != nil {
		cleanup()
		return "", "", nil, err
	}
	var out struct {
		ID string `json:"authorization_model_id"`
	}
	if err = json.Unmarshal(resp, &out); err != nil {
		cleanup()
		return "", "", nil, err
	}
	return store, out.ID, cleanup, nil
}

// writeCase measures fga.write throughput: one op is a 100-op
// write followed by the matching 100-op delete against a scratch
// store, so the dataset is unchanged across iterations and every
// iteration pays the full write-gate validation twice.
func writeCase(
	ctx context.Context, pool *pgxpool.Pool, s Scenario,
	seed uint64,
) (caseCall, func(), error) {
	store, modelID, cleanup, err := scratchStore(
		ctx, pool, s)
	if err != nil {
		return nil, nil, err
	}
	var keys strings.Builder
	for i := 0; i < 100; i++ {
		t := ScratchTuple(seed, i)
		if i > 0 {
			keys.WriteByte(',')
		}
		fmt.Fprintf(&keys,
			`{"object":"doc:%s","relation":"viewer",`+
				`"user":"user:%s"}`,
			t.ObjectID, t.SubjectID)
	}
	writeReq := fmt.Sprintf(
		`{"authorization_model_id":"%s","writes":`+
			`{"tuple_keys":[%s]}}`, modelID, keys.String())
	deleteReq := fmt.Sprintf(
		`{"authorization_model_id":"%s","deletes":`+
			`{"tuple_keys":[%s]}}`, modelID, keys.String())
	return func(ctx context.Context, i int) error {
		var out []byte
		if err := pool.QueryRow(ctx,
			"SELECT fga.write($1, $2)",
			store, writeReq).Scan(&out); err != nil {
			return err
		}
		return pool.QueryRow(ctx,
			"SELECT fga.write($1, $2)",
			store, deleteReq).Scan(&out)
	}, cleanup, nil
}

// modelWriteCase measures fga.write_authorization_model: each op
// writes the scenario model to a scratch store. Models are
// immutable and accumulate, so the store is recreated by the
// cleanup after the case, never mid-measurement.
func modelWriteCase(
	ctx context.Context, pool *pgxpool.Pool, s Scenario,
) (caseCall, func(), error) {
	store, _, cleanup, err := scratchStore(ctx, pool, s)
	if err != nil {
		return nil, nil, err
	}
	model := s.Model()
	return func(ctx context.Context, i int) error {
		var out []byte
		return pool.QueryRow(ctx,
			"SELECT fga.write_authorization_model($1, $2)",
			store, model).Scan(&out)
	}, cleanup, nil
}
