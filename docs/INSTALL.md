# Installing fga4postgres

fga4postgres installs by running SQL scripts against a database
you can already connect to, on any PostgreSQL 18+ — self-hosted,
RDS, Aurora, Cloud SQL — without a superuser, a filesystem, or a
restart. Everything lands in schema `fga` (plus schema `cel` for
the vendored cel4postgres condition engine).

PostgreSQL 18 is the floor: the engine uses the native
`uuidv7()` function for model and store ids.

## Plain SQL (works everywhere)

Download `fga4postgres--<version>.sql` from a release (verify
against `SHA256SUMS`) and run it:

```sh
psql -v ON_ERROR_STOP=1 -f fga4postgres--<version>.sql "$DB_URL"
```

That single file bundles the pinned cel4postgres release and the
whole engine. If the database already runs the pinned
cel4postgres, use `fga4postgres-engine--<version>.sql` instead —
it contains only the engine and expects schema `cel` to exist.

Every script is idempotent; re-running the installer against a
live database is the upgrade path.

From a checkout instead of a release:

```sh
psql -v ON_ERROR_STOP=1 -f vendor/cel4postgres--*.sql "$DB_URL"
for f in sql/*.sql; do
  psql -v ON_ERROR_STOP=1 -f "$f" "$DB_URL"
done
```

## pg_tle (RDS, Aurora, and anywhere pg_tle is allowed)

Wrap the release artifact into a `pgtle.install_extension` call
and install it as a real extension:

```sh
./scripts/pgtle-wrap.sh fga4postgres <version> \
  fga4postgres--<version>.sql > wrapped.sql
psql -v ON_ERROR_STOP=1 -f wrapped.sql "$DB_URL"
psql -c 'CREATE EXTENSION fga4postgres;' "$DB_URL"
```

`CREATE EXTENSION pg_tle;` must have happened once per database
first (on RDS/Aurora, `pg_tle` ships preinstalled; grant
`pgtle_admin` to your master user).

## Consumer privileges

`sql/900_grants.sql` is a no-op until you create two group
roles; it then grants a query-only surface to one and the write
surface to the other:

```sql
CREATE ROLE fga_reader NOLOGIN;
CREATE ROLE fga_writer NOLOGIN;
```

Re-run the installer (or just `900_grants.sql`), then:

```sql
GRANT fga_reader TO app_query_user;
GRANT fga_writer TO app_admin_user;
```

`fga_reader` can call `fga.check`, `fga.batch_check`,
`fga.list_objects`, `fga.list_users`, `fga.expand`, `fga.read`
and `fga.version` — including on standbys and in read-only
transactions — but has no DML on the `fga` tables, so the write
entry points fail for it at the table layer. `fga_writer` adds
`fga.write`, `fga.write_authorization_model`,
`fga.create_store` and `fga.delete_store`.

Entry points run with caller rights (no SECURITY DEFINER); the
trust model is the database's own. Hardening beyond the
template — for example `REVOKE EXECUTE ON ALL FUNCTIONS IN
SCHEMA fga FROM PUBLIC` — is deliberate and yours to apply;
the installer never revokes anything.

## Verifying

```sql
SELECT fga.version(), cel.version();
SELECT fga.check((fga.create_store('smoke')).id,
  '{"tuple_key":{"object":"doc:11111111-1111-7111-8111-111111111111",
    "relation":"viewer",
    "user":"user:22222222-2222-7222-8222-222222222222"}}');
-- expected: an error naming the store's missing model — the
-- engine is answering.
```
