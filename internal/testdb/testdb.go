// Package testdb connects the suite to the compose-provided
// database and oracle, resolving configuration the same way the
// compose file does: process environment first, then the repo's
// .env, then the compose defaults.
package testdb

import (
	"bufio"
	"context"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Env resolves a configuration key: process environment, then the
// repo's .env file, then the given default. Compose resolves its
// variables the same way, so both sides see one configuration.
func Env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	if v, ok := dotenv()[key]; ok {
		return v
	}
	return fallback
}

var (
	dotenvOnce sync.Once
	dotenvVals map[string]string
)

// dotenv loads KEY=VALUE lines from .env at the repo root, found by
// walking up from the working directory (tests run in their package
// directory). A missing file is an empty map, not an error.
func dotenv() map[string]string {
	dotenvOnce.Do(func() {
		dotenvVals = map[string]string{}
		dir, err := os.Getwd()
		if err != nil {
			return
		}
		for {
			path := filepath.Join(dir, ".env")
			if f, err := os.Open(path); err == nil {
				defer f.Close()
				sc := bufio.NewScanner(f)
				for sc.Scan() {
					line := strings.TrimSpace(sc.Text())
					if line == "" || strings.HasPrefix(line, "#") {
						continue
					}
					k, v, ok := strings.Cut(line, "=")
					if ok {
						dotenvVals[strings.TrimSpace(k)] =
							strings.TrimSpace(v)
					}
				}
				return
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				return
			}
			dir = parent
		}
	})
	return dotenvVals
}

// DSN builds the database connection string: DATABASE_URL wins,
// otherwise it is assembled from the POSTGRES_* parts with the
// compose defaults.
func DSN() string {
	if dsn := Env("DATABASE_URL", ""); dsn != "" {
		return dsn
	}
	user := Env("POSTGRES_USER", "fga")
	pass := Env("POSTGRES_PASSWORD", "password")
	host := Env("POSTGRES_HOST", "localhost")
	port := Env("POSTGRES_PORT", "5432")
	db := Env("POSTGRES_DB", "fga")
	return fmt.Sprintf(
		"postgres://%s:%s@%s:%s/%s?sslmode=disable",
		url.QueryEscape(user), url.QueryEscape(pass),
		host, port, db,
	)
}

var (
	poolOnce sync.Once
	pool     *pgxpool.Pool
	poolErr  error
)

// Pool returns the process-wide connection pool, failing the test
// with a hint at the compose stack when the database is not there.
// One pool serves all parallel subtests; pgxpool defaults size it
// to GOMAXPROCS(0)*... which suffices until benchmarks say more.
func Pool(t testing.TB) *pgxpool.Pool {
	t.Helper()
	poolOnce.Do(func() {
		ctx := context.Background()
		cfg, err := pgxpool.ParseConfig(DSN())
		if err != nil {
			poolErr = err
			return
		}
		p, err := pgxpool.NewWithConfig(ctx, cfg)
		if err == nil {
			err = p.Ping(ctx)
		}
		pool, poolErr = p, err
	})
	if poolErr != nil {
		t.Fatalf(
			"cannot reach the test database (%s): %v\n"+
				"is the stack up? run: docker compose up -d --wait",
			DSN(), poolErr,
		)
	}
	return pool
}
