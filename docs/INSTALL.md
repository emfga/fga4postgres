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
against `SHA256SUMS`) and run it in one transaction:

```sh
psql -v ON_ERROR_STOP=1 -1 -f fga4postgres--<version>.sql "$DB_URL"
```

That single file bundles the pinned cel4postgres release and the
whole engine. If the database already runs the pinned
cel4postgres, use `fga4postgres-engine--<version>.sql` instead —
it contains only the engine and expects schema `cel` to exist.

Each file comes in two shapes. The plain file contains no
transaction control, so it runs inside a transaction someone else
opens: psql's `-1` (`--single-transaction`), a migration tool's, or
pg_tle's `CREATE EXTENSION`. Its `-tx` twin
(`fga4postgres-tx--<version>.sql`,
`fga4postgres-engine-tx--<version>.sql`) wraps the same content in
exactly one `BEGIN;` and one `COMMIT;`, for a bare `psql -f` that
should still be all or nothing.

Every script is idempotent; re-running the installer against a
live database is the upgrade path.

From a checkout instead of a release:

```sh
psql -v ON_ERROR_STOP=1 -1 -f vendor/cel4postgres--*.sql "$DB_URL"
for f in sql/*.sql; do
  psql -v ON_ERROR_STOP=1 -1 -f "$f" "$DB_URL"
done
```

## Inside a migration tool

Migration tools (Flyway, Liquibase, Kysely, Alembic, Rails, …)
usually run each migration inside a transaction they own. Embed the
plain `fga4postgres--<version>.sql` as the body of one migration
and execute it as a single multi-statement string, without bind
parameters — the file is many statements with `$$`-quoted function
bodies, which PostgreSQL accepts only over the simple query
protocol. The whole install then commits or rolls back with the
migration. Do not embed a `-tx` file: its `COMMIT;` would end the
tool's transaction halfway through.

## pg_tle (RDS, Aurora, and anywhere pg_tle is allowed)

Wrap the plain release artifact (not a `-tx` one: transaction
control is not allowed inside `CREATE EXTENSION`, and the script
refuses it) into a `pgtle.install_extension` call and install it
as a real extension:

```sh
./scripts/pgtle-wrap.sh fga4postgres <version> \
  fga4postgres--<version>.sql > wrapped.sql
psql -v ON_ERROR_STOP=1 -f wrapped.sql "$DB_URL"
psql -c 'CREATE EXTENSION fga4postgres;' "$DB_URL"
```

`CREATE EXTENSION pg_tle;` must have happened once per database
first (on RDS/Aurora, `pg_tle` ships preinstalled; grant
`pgtle_admin` to your master user).

## Settings

`fga.setting` holds the database-wide engine configuration, the
counterpart of upstream's server flags. Two rows exist today:

| name | default | meaning |
|---|---|---|
| `list_objects_max_results` | 1000 | cap on `fga.list_objects` |
| `list_users_max_results` | 1000 | cap on `fga.list_users` |

`0` means unlimited, as upstream; a negative value is refused.
Change one with a plain `UPDATE` (the writer role can):

```sql
UPDATE fga.setting SET value = 5000
WHERE name = 'list_objects_max_results';
```

Re-running the installer never resets a value you set. The cap
ends the search as soon as it is reached, so a lower cap is also
a cheaper call. `fga.streamed_list_objects` is never capped,
like upstream's `StreamedListObjects`: it returns one row per
object, `{"object": "doc:<id>"}`, for callers that need the
whole set. It computes the whole answer before returning the
first row; it is uncapped, not incremental.

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
`fga.list_objects`, `fga.streamed_list_objects`,
`fga.list_users`, `fga.expand`, `fga.read` and `fga.version` —
including on standbys and in read-only transactions — but has
no DML on the `fga` tables, so the write entry points fail for
it at the table layer. `fga_writer` adds `fga.write`,
`fga.write_authorization_model`, `fga.create_store`,
`fga.delete_store`, `fga.enable_compiled_relations` and
`fga.disable_compiled_relations`, and can change `fga.setting`.

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
