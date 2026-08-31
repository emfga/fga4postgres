# fga4postgres

OpenFGA, natively in PostgreSQL: a zero-dependency PL/pgSQL engine that
answers [OpenFGA](https://openfga.dev) authorization queries inside the
database that already holds your application's data.

Zero-dependency means installation is running SQL scripts against a
database you can already connect to — self-hosted, RDS, Aurora, Cloud
SQL — without a superuser, a filesystem, or a restart. CEL condition
support comes from [cel4postgres](https://github.com/emfga/cel4postgres),
itself pure SQL, vendored into the install.

**PostgreSQL 18 or newer.** Engine-generated store and model ids are
native `uuidv7()`, used without a compatibility shim.

**The id domain is `uuid`.** Object and subject ids are native
uuids, accepted in canonical lower-case hyphenated spelling only,
where upstream OpenFGA accepts nearly arbitrary strings. This is a
deliberate, documented divergence in the safe (refusing) direction,
in exchange for native uuid storage, indexes, and joins against
your application's own tables.

**Status: early development.** The engine is being built against a
pinned conformance target,
[openfga/openfga v1.19.0](https://github.com/openfga/openfga/tree/v1.19.0).
Nothing here is ready for use yet.

## Planned v1 surface

- `check` (including batch), `expand`, `list_objects`, `list_users`
- `write_authorization_model` — whole-model, upstream JSON shape,
  immutable and versioned
- Tuple `write`/`delete` with upstream error semantics, and `read`
  with keyset pagination
- A minimal store namespace (`create_store`/`delete_store`)

Distribution will be plain SQL scripts and
[pg_tle](https://github.com/aws/pg_tle), both first-class.

## Installation

Into any database you can connect to:

```bash
psql -v ON_ERROR_STOP=1 -f vendor/cel4postgres--0.0.1.sql "$DB_URL"
for f in sql/*.sql; do
  psql -v ON_ERROR_STOP=1 -f "$f" "$DB_URL"
done
```

The scripts are idempotent; re-running the installer is the upgrade
path.

## Development environment

Requirements: Docker with the compose plugin, and Go for running the
test suite from the host (optional — see the containerised runner
below).

```bash
cp .env.example .env    # optional; every variable has a default
docker compose up -d --wait
```

This brings up two disposable services:

- **postgres** — pinned `postgres:18-alpine` with `PGDATA` on a tmpfs.
  On every start, initdb re-runs `docker/000_install.sh`, which applies
  the vendored cel4postgres bundle and then everything in `sql/`, so
  installing the schema is part of bringing the database up. `--wait`
  returns only when `cel.version()` and `fga.version()` answer —
  healthy means installed, not merely listening.
- **openfga** — the reference OpenFGA server, pinned at v1.19.0, used
  as the conformance oracle. The memory datastore makes a restart a
  reset.

Because the data directory is a tmpfs, `docker compose down` discards
the database entirely; there is no volume to clean up and no way for a
stale schema to survive into a test run.

Verify the stack:

```bash
psql "postgres://fga:password@localhost:5432/fga" \
  -c "SELECT cel.version(), fga.version()"
curl -fsS http://localhost:8080/healthz
```

If a port is taken on your machine, set `POSTGRES_PORT`,
`OPENFGA_HTTP_PORT`, or `OPENFGA_GRPC_PORT` in `.env`.

Run the tests:

```bash
go test ./...                  # from the host
docker compose run --rm test   # containerised, no host Go needed
```

See `CLAUDE.md` for the project's design decisions, conformance policy,
and conventions.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
