package bench

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Compiled-relation cases. Each one opts the fixture store in
// for its own duration and opts it out in its cleanup, outside
// the timed window, so the generic cases always measure a store
// that is not opted in — the comparison the scenario exists for.
//
//   - compiled_check: the generated __check, called directly.
//   - check_opted_in: fga.check on the opted-in store; the same
//     entry point as the generic check, so it moves exactly when
//     fga.check starts dispatching to compiled functions.
//   - compiled_objects: the whole __objects set, counted in the
//     database so the case measures resolution, not transfer.
//   - compiled_page: a page of 50 consumer rows sorted by name,
//     filtered by `id IN (SELECT x FROM __objects(...) x)` — the
//     inlinable form.
//
// The set-shaped cases plan every call (exec mode: an unnamed
// statement, planned with that call's subject). Through a cached
// prepared statement the plan would depend on the cache's
// history — PostgreSQL picks a custom or the generic plan from
// the costs of the custom plans it has seen, and the three
// subject classes share one statement text — so a case would
// measure different plans depending on what ran before it, and
// a generic plan costs the same estimate for every subject.
// Per-call planning is
// deterministic, and it is how the page envelope was first
// measured; the planning share is reported beside the numbers
// (docs/BENCHMARKS.md).

func compiledCase(
	ctx context.Context, pool *pgxpool.Pool,
	s Scenario, size Size, load LoadResult, seed uint64,
	v Variant,
) (caseCall, func(), error) {
	schema := AppSchema(s, size)
	cleanup, err := optIn(ctx, pool, schema, load.Store)
	if err != nil {
		return nil, nil, err
	}
	q0 := s.Query(seed, size, v, 0)
	typ := q0.Type
	if typ == "" {
		typ, _, _ = strings.Cut(q0.Object, ":")
	}
	kind := "objects"
	if v.Feature == "compiled_check" {
		kind = "check"
	}
	fn, err := compiledFn(ctx, pool, load.Store, typ,
		q0.Relation, kind)
	if err != nil {
		cleanup()
		return nil, nil, err
	}

	var call caseCall
	switch v.Feature {
	case "compiled_check":
		sql := "SELECT " + fn + "($1::uuid, $2, $3::uuid)"
		call = func(ctx context.Context, i int) error {
			q := s.Query(seed, size, v, i)
			_, oid, _ := strings.Cut(q.Object, ":")
			st, sid, _ := strings.Cut(q.User, ":")
			var ok bool
			return pool.QueryRow(ctx, sql, oid, st, sid).Scan(&ok)
		}
	case "check_opted_in":
		call = checkCase(pool, s, size, load, seed, v)
	case "compiled_objects":
		sql := "SELECT count(*) FROM " + fn +
			"($1, $2::uuid) x"
		call = func(ctx context.Context, i int) error {
			q := s.Query(seed, size, v, i)
			st, sid, _ := strings.Cut(q.User, ":")
			var n int64
			return pool.QueryRow(ctx, sql,
				pgx.QueryExecModeExec, st, sid).Scan(&n)
		}
	case "compiled_page":
		table := pgx.Identifier{schema, typ}.Sanitize()
		sql := "SELECT e.id, e.name FROM " + table + " e " +
			"WHERE e.id IN (SELECT x FROM " + fn +
			"($1, $2::uuid) x) ORDER BY e.name LIMIT 50"
		call = func(ctx context.Context, i int) error {
			q := s.Query(seed, size, v, i)
			st, sid, _ := strings.Cut(q.User, ":")
			rows, err := pool.Query(ctx, sql,
				pgx.QueryExecModeExec, st, sid)
			if err != nil {
				return err
			}
			for rows.Next() {
			}
			rows.Close()
			return rows.Err()
		}
	default:
		cleanup()
		return nil, nil, fmt.Errorf(
			"feature %q is not a compiled case", v.Feature)
	}
	return call, cleanup, nil
}

// optIn creates the scenario's schema (the engine never creates
// one) and enables compiled relations on the store; the returned
// cleanup opts the store out again, dropping its functions.
func optIn(
	ctx context.Context, pool *pgxpool.Pool,
	schema, store string,
) (func(), error) {
	if _, err := pool.Exec(ctx, "CREATE SCHEMA IF NOT EXISTS "+
		pgx.Identifier{schema}.Sanitize()); err != nil {
		return nil, err
	}
	if _, err := pool.Exec(ctx,
		"SELECT fga.enable_compiled_relations($1, $2)",
		store, schema); err != nil {
		return nil, err
	}
	return func() {
		_, _ = pool.Exec(ctx,
			"SELECT fga.disable_compiled_relations($1)", store)
	}, nil
}

// compiledFn resolves one generated function through the
// engine's registry — never a name pattern — and refuses a
// relation that did not compile to the flattened strategy: a
// delegated function calls the generic resolver, and measuring
// it under a compiled label would misreport both.
func compiledFn(
	ctx context.Context, pool *pgxpool.Pool,
	store, typ, rel, kind string,
) (string, error) {
	var name, strategy, reason string
	err := pool.QueryRow(ctx, `
		SELECT format('%I.%I', n.nspname, p.proname),
		       r.strategy, coalesce(r.reason, '')
		FROM fga.compiled_relation r
		JOIN pg_proc p ON p.oid = CASE $4
		  WHEN 'check' THEN r.check_fn
		  ELSE r.objects_fn END
		JOIN pg_namespace n ON n.oid = p.pronamespace
		WHERE r.store = $1 AND r.type_name = $2
		  AND r.relation_name = $3`,
		store, typ, rel, kind,
	).Scan(&name, &strategy, &reason)
	if err != nil {
		return "", fmt.Errorf("compiled %s#%s %s: %w",
			typ, rel, kind, err)
	}
	if strategy != "flattened" {
		return "", fmt.Errorf(
			"%s#%s compiled to %s (%s); the compiled cases "+
				"measure the flattened strategy",
			typ, rel, strategy, reason)
	}
	return name, nil
}
