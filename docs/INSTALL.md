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

## Compiled relations

`list_objects` answers "which documents can Anne see?" with a
list the application then has to join, sort and page itself. For
a page of 50 documents sorted by title, that is the wrong way
round: the database already holds the documents, and the
authorization rule is the filter. Compiled relations turn every
relation of a store's model into plain SQL functions the
application calls *inside* its own query, so PostgreSQL filters,
sorts and pages in one plan.

They are opt-in per store. Every model write to an opted-in store
regenerates, in the same transaction, three functions per
`(type, relation)` in a schema the application owns:

| function | answers | mirrors |
|---|---|---|
| `<type>__<relation>__objects(p_subject_type, p_subject_id, …)` | the object ids the subject has the relation on | `list_objects`, uncapped |
| `<type>__<relation>__subjects(p_object, p_subject_type, …)` | the subject ids that have the relation on the object | `list_users`, as a final list |
| `<type>__<relation>__check(p_object, p_subject_type, p_subject_id, …)` | whether the subject has the relation | `check` |

Every answer equals the generic resolver's, errors included.
Each relation compiles to the cheapest exact strategy; one that
cannot be compiled exactly gets a function with the same
signature that calls the generic resolver. Opted-in stores also
answer `fga.check`, `fga.batch_check`, `fga.list_objects` and
`fga.streamed_list_objects` through the compiled functions when
the request targets the latest model; `fga.list_users` keeps
upstream's response shape and always uses the generic resolver.

The examples below run in order, top to bottom, against a fresh
install; a test in `conformance/` executes them exactly as
written.

### 1. The application's tables, and a schema for the functions

The engine never creates or drops a schema: the application
creates the target schema, owns it, and decides who may use it.

```sql
CREATE SCHEMA app;
CREATE TABLE app.app_user (
  user_id uuid PRIMARY KEY,
  name text NOT NULL
);
CREATE TABLE app.document (
  document_id uuid PRIMARY KEY,
  title text NOT NULL
);
INSERT INTO app.app_user VALUES
  ('0192f0a0-0000-7000-8000-00000000a001', 'Anne'),
  ('0192f0a0-0000-7000-8000-00000000a002', 'Bruno'),
  ('0192f0a0-0000-7000-8000-00000000a003', 'Carla');
INSERT INTO app.document VALUES
  ('0192f0a0-0000-7000-8000-00000000d001', 'Budget'),
  ('0192f0a0-0000-7000-8000-00000000d002', 'Roadmap'),
  ('0192f0a0-0000-7000-8000-00000000d003', 'Handbook');

CREATE SCHEMA app_authz;
```

### 2. A store and its model

```sql
SELECT fga.create_store('docs-example');

SELECT fga.write_authorization_model(
  (SELECT id FROM fga.store WHERE name = 'docs-example'),
  '{"schema_version": "1.1", "type_definitions": [
     {"type": "user"},
     {"type": "folder",
      "relations": {"viewer": {"this": {}}},
      "metadata": {"relations": {"viewer": {
        "directly_related_user_types": [{"type": "user"}]}}}},
     {"type": "document",
      "relations": {
        "parent": {"this": {}},
        "viewer": {"union": {"child": [
          {"this": {}},
          {"tuple_to_userset": {
            "tupleset": {"relation": "parent"},
            "computed_userset": {"relation": "viewer"}}}]}}},
      "metadata": {"relations": {
        "parent": {"directly_related_user_types": [
          {"type": "folder"}]},
        "viewer": {"directly_related_user_types": [
          {"type": "user"}, {"type": "user", "wildcard": {}}]}}}}]}');
```

### 3. Opt in

```sql
SELECT fga.enable_compiled_relations(
  store => (SELECT id FROM fga.store WHERE name = 'docs-example'),
  target_schema => 'app_authz',
  subject_sources => '{"user": "app.app_user(user_id)"}');
```

Opting in generates the functions for the latest model at once.
`fga.compiled_relation` lists them, with the strategy each
relation compiled to and, for a relation answered by the generic
resolver, the reason. `fga.disable_compiled_relations(store)`
drops exactly the functions the engine registered; deleting the
store does the same.

`subject_sources` is optional. It names, per subject type, the
application's table and uuid column holding every subject of
that type, as `schema.table(column)`. `__subjects` needs it to
turn a wildcard grant (`user:*`) into a list of users — the
engine cannot otherwise know who "everyone" is. Without a source,
`__subjects` raises when it meets such a wildcard.

### 4. Tuples, then statistics

```sql
SELECT fga.write(
  (SELECT id FROM fga.store WHERE name = 'docs-example'),
  '{"writes": {"tuple_keys": [
     {"object": "folder:0192f0a0-0000-7000-8000-00000000f001",
      "relation": "viewer",
      "user": "user:0192f0a0-0000-7000-8000-00000000a001"},
     {"object": "document:0192f0a0-0000-7000-8000-00000000d001",
      "relation": "parent",
      "user": "folder:0192f0a0-0000-7000-8000-00000000f001"},
     {"object": "document:0192f0a0-0000-7000-8000-00000000d002",
      "relation": "viewer",
      "user": "user:0192f0a0-0000-7000-8000-00000000a002"},
     {"object": "document:0192f0a0-0000-7000-8000-00000000d003",
      "relation": "viewer",
      "user": "user:*"}]}}');

ANALYZE fga.tuple;
```

Every query shape below relies on planner statistics for
`fga.tuple`. Autovacuum keeps them current in normal operation;
after a bulk load, run `ANALYZE fga.tuple` yourself — without
statistics a page that takes milliseconds can take seconds.

### 5. A page, filtered by authorization

Call `__objects` in `FROM`, inside `IN (…)` or `EXISTS (…)`:

```sql
SELECT d.document_id, d.title
FROM app.document d
WHERE d.document_id IN (
  SELECT x
  FROM app_authz.document__viewer__objects(
    'user', '0192f0a0-0000-7000-8000-00000000a001') x)
ORDER BY d.title
LIMIT 50;
```

Anne sees Budget (through its folder) and Handbook (shared with
everyone). Called this way, PostgreSQL inlines the function into
the query and plans the authorization filter together with the
page. Calling it in the select list instead
(`SELECT app_authz.document__viewer__objects(...)`) returns the
same rows but computes the whole set first.

### 6. A check, and the subjects of one object

```sql
SELECT app_authz.document__viewer__check(
  '0192f0a0-0000-7000-8000-00000000d002',
  'user', '0192f0a0-0000-7000-8000-00000000a001');

SELECT u.name
FROM app.app_user u
WHERE u.user_id IN (
  SELECT x
  FROM app_authz.document__viewer__subjects(
    '0192f0a0-0000-7000-8000-00000000d003', 'user') x)
ORDER BY u.name;
```

The check answers false: Roadmap is shared with Bruno only. The
subjects of Handbook are every user, expanded through the
registered source. `__subjects` returns the final list — wildcards
expanded, exclusions applied, groups expanded to their members —
which is what an application renders; `fga.list_users` keeps
upstream's shape instead (`user:*` plus usersets as themselves).

Every function also takes `p_subject_relation` (to ask about a
userset such as `team#member`), `p_any_subject` (to ask about
`user:*`; the nil uuid is refused, as everywhere else),
`p_context` and `p_contextual_tuples`, all defaulted.

### 7. Privileges

The generator grants nothing: generated functions follow
PostgreSQL's rules, and their bodies read `fga` tables with the
caller's rights. A schema the application creates grants `USAGE`
to no one but its owner, so every other role that queries an
opted-in store needs it — and that includes roles that only call
`fga.check` or `fga.list_objects`, because once a store opts in
those entry points answer through the generated functions. Without
it they fail with "permission denied for schema app_authz" rather
than quietly taking the slower path. Grant it once; the default
privileges cover every function a later model write regenerates:

```sql
GRANT USAGE ON SCHEMA app_authz TO app_query_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA app_authz
  GRANT EXECUTE ON FUNCTIONS TO app_query_user;
```

`ALTER DEFAULT PRIVILEGES` applies to functions created by the
role that runs it, so run it as the role that writes models. The
calling role needs `fga_reader`'s privileges as well, since the
functions read `fga.tuple` with its rights.

### Cost

A compiled relation's cost grows with the set the subject can
reach, not with the size of the store: a page for a subject who
sees a few hundred objects stays in single-digit milliseconds,
while a subject who sees every object of a large store pays for
the whole set on every page. `docs/BENCHMARKS.md` ("tenant")
records the measured envelope. A relation with CEL conditions
evaluates its condition for every conditioned tuple on the path
(about 0.25 ms each); compilation cannot remove that floor.

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
