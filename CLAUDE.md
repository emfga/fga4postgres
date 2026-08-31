# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

## Project Overview

fga4postgres is OpenFGA, natively in PostgreSQL: a zero-dependency
PL/pgSQL engine that answers OpenFGA authorization queries inside the
database that already holds the application's data.

"Zero-dependency" is the product claim and the design constraint: a
consumer installs fga4postgres by running SQL scripts against a database
they can already connect to, on any PostgreSQL — self-hosted, RDS,
Aurora, Cloud SQL — without a superuser, a filesystem, or a restart.
CEL condition support comes from cel4postgres, itself pure SQL, vendored
into the install.

When the code and this file disagree, the code is right and this file is
a bug.

## Scope

**In scope (v1):**

- `check` (including batch check over one resolution scope)
- `list_objects` and `list_users`
- `expand`
- `write_authorization_model` — whole-model, upstream JSON shape,
  immutable and versioned
- Tuple `write`/`delete` with upstream error semantics (duplicate /
  missing behaviour, the type-restriction write gate, condition
  validation at write time)
- Tuple `read` — filtered listing with keyset pagination
- A minimal store namespace: `create_store`/`delete_store` plus a store
  column. It exists for conformance isolation (fresh store per corpus
  test) and namespacing, not multi-tenancy.

**Out of scope (v1):**

- DSL parsing in the engine. The model API accepts upstream's JSON;
  DSL→JSON stays in the Go harness (decision 2). A PL/pgSQL DSL parser
  is a possible post-conformance milestone, not a v1 blocker.
- `read_changes`. Deferred, not rejected: every tuple mutation goes
  through one function so a changelog can be added without rework
  (decision 8).
- HTTP/gRPC layer, assertions API, streamed list-objects, watch API,
  multi-tenant isolation machinery, store-level auth.

## Decisions

Recorded with their reasoning because each one closes off an alternative
a future contributor will otherwise reopen.

1. **The conformance target is openfga/openfga v1.19.0, pinned
   everywhere at once.** The compose oracle image, the corpus files the
   harness replays, and any `Ref:` permalinks all cite v1.19.0. Bump
   them together or not at all — tsfga currently has a v1.18.2
   container beside a v1.19.0 checkout, and its own CLAUDE.md calls
   that state untrustworthy.
2. **The engine speaks upstream's JSON model shape; DSL conversion
   lives in the Go harness.** JSON is the actual API contract (SDKs
   convert DSL client-side), and the harness can use openfga's own
   `pkg/typesystem` / language packages at the pinned version. Walking
   structured jsonb is ordinary PL/pgSQL; a DSL parser is not needed to
   reach conformance.
3. **Model writes are whole-model, atomic, immutable, versioned.**
   tsfga's per-relation `writeRelationConfig` design cannot represent
   nested set operators (its ported tests decompose them onto `h_`
   helper relations) and needed a 142-call-site drift bridge
   (`expectConfigsMatchModel`) to keep hand-written configs honest.
   In-database, whole-model atomicity is one function in one
   transaction — the reason to go per-relation evaporates. Store the
   verbatim JSON per model id plus a normalized internal form for fast
   resolution. Owner-confirmed.
4. **CEL is consumed from cel4postgres, never reimplemented.** The
   pinned release artifact (`vendor/cel4postgres--0.0.1.sql`, from
   github.com/emfga/cel4postgres) installs before `sql/` in initdb and
   in the release story. Conditions evaluate through `cel.*`; the
   OpenFGA dialect (`ipaddress`, `in_cidr`, typed-parameter coercion)
   is a cel4postgres extension registered through its registry tables,
   not a fork. cel4postgres's documented limits are inherited limits
   here: no U+0000 in strings (a Postgres substrate limit), `matches()`
   on POSIX ARE rather than RE2, and its measured divergence list.
   Owner-confirmed.
5. **The conformance harness is Go, shaped like cel4postgres's.**
   `go test` against `DATABASE_URL`, single-file and single-case
   subtest selectors from the first harness commit, a generated skip
   list the binary prints on every run, and a generated conformance
   report. Go can also import the openfga Go module at the pin —
   including the programmatic corpora (`tests/check/check_userset.go`
   etc.) that a non-Go harness must hand-port. Owner-selected.
6. **Conformance is corpus replay and differential testing, both.**
   Upstream's `assets/tests/*.yaml` (161 tests, ~1200 assertions
   across check/list-objects/list-users) replays as the baseline; the
   live v1.19.0 container in compose is the oracle for edge cases; and
   tsfga's suite (~150 model fixtures, ported upstream matrices,
   real-world models) is ported over time. Adopt tsfga's assertion
   vocabulary: agreement asserts, refusal-as-outcome, and *pinned
   divergences asserted from both sides* so a closed gap turns red and
   demands its documentation be deleted. Owner-selected.
7. **Distribution is plain SQL scripts and pg_tle, both first-class.**
   `psql -f` of a flattened `fga4postgres--X.Y.Z.sql` for anyone;
   pg_tle packaging for platforms that have it. Nothing may require:
   writing into `$SHAREDIR/extension`, loading a `.so`,
   `CREATE EXTENSION` of anything not platform-allowlisted,
   `COPY … FROM PROGRAM`, an untrusted language, a
   `shared_preload_libraries` change, or filesystem access of any
   kind. A change introducing one of these breaks the product claim.
   Owner-confirmed.
8. **`read` in v1; `read_changes` deferred behind a single write
   path.** Read is a filtered SELECT with keyset pagination — cheap
   and genuinely useful in-database. ReadChanges needs a changelog
   plus upstream's horizon/ordering machinery to avoid losing
   late-committing writes to pagination, and its job (syncing data
   *out*) is served natively by triggers, LISTEN/NOTIFY, or logical
   replication when the engine is already in Postgres. Routing every
   tuple mutation through one function keeps the changelog addable
   without rework. Owner-confirmed.
9. **Purity labels are a product feature, applied honestly.** Pure
   computation over jsonb is `IMMUTABLE PARALLEL SAFE`. Anything that
   reads tuples, models, or the cel registry is `STABLE PARALLEL
   SAFE` — which still runs on standbys, in read-only transactions,
   and under parallel query. Only actual writers are `VOLATILE`.
   Never label a table-reading function `IMMUTABLE` to win an index;
   cel4postgres logs exactly that as a review item, not a pattern.
   Every function carries `SET search_path = fga, pg_temp`.

## Architecture

Layout follows cel4postgres: no `src/`; top-level `sql/`,
`conformance/`, `internal/`, `scripts/`, `docs/`, `vendor/`, and
gitignored `dist/`.

**`sql/` naming.** Flat, three-digit numeric prefix that is
simultaneously install order and initdb order (initdb does not descend
into subdirectories). fga4postgres scripts start at `010` because the
`000` slot belongs to the vendored cel4postgres bundle, bind-mounted as
a single file in compose.yaml. Every script opens its own `BEGIN;` …
`COMMIT;` and is idempotent (`CREATE OR REPLACE`, `IF NOT EXISTS`,
`ON CONFLICT`), so plain concatenation builds a release and re-running
the installer is the upgrade path.

**Schema naming.** Everything lives in schema `fga`. Public entry
points are unprefixed (`fga.check`, `fga.version`); every internal
helper is `fga._`-prefixed. Public functions take the store and (where
applicable) model id as parameters — never GUCs — so one install serves
many callers and models simultaneously.

**Model storage.** `write_authorization_model` stores the verbatim
upstream JSON keyed by an immutable model id, and derives the
normalized rows the resolver reads. Old models stay queryable; checks
may pin a model id, defaulting to the store's latest.

**Resolution semantics come from upstream, not from intuition.** The
load-bearing behaviours tsfga measured the hard way, to preserve from
day one: only dispatches spend the depth budget (rewrites, computed
usersets, exclusions and intersection operands cost zero); a cycle is a
tracked outcome, not an error, and a cycled `false` must not collapse
into a plain `false` on the subtract side of `but not` (that fails
open); a relation with no definition is refused, not treated as
unrestricted, except a TTU whose computed relation is undefined on the
linked type, which answers `false`; upstream defaults are resolve-node
limit 25, breadth limit 10, max concurrent batch checks 50.

## Reference implementations

Local checkouts are per-machine. Never hard-code their paths in
committed code or tests.

- **openfga/openfga** — the gitignored `.openfga_repo` file at the repo
  root holds one line: the absolute path to a local checkout. Read it
  (`OPENFGA_REPO=$(cat .openfga_repo)`); if missing, say so and fall
  back to docs plus conformance tests. The checkout is read-only.
  Verify `git -C "$OPENFGA_REPO" describe --tags` matches the pin
  before trusting it. **The running container beats the checkout**:
  when source reading and a conformance run disagree, write a test to
  settle it. When a Go file materially informs an implementation, cite
  it in the commit body with a `Ref:` permalink pinned to the tag's
  SHA. Entry points: `internal/graph/check.go`,
  `pkg/typesystem/typesystem.go`, `internal/condition/`,
  `tests/check/`, `tests/listobjects/`, `assets/tests/`.
- **tsfga** (`../tsfga`) — the sibling TypeScript implementation whose
  conformance suite this project ports. Its `packages/core/README.md`
  documents measured upstream divergences worth knowing before
  re-deriving them; its suite is the source for fixtures and the
  pinned-divergence pattern.
- **cel4postgres** (`../cel4postgres`) — the CEL engine this project
  vendors, and the style reference for PL/pgSQL idiom, sql/ layout,
  release packaging, and CI shape. Read its CLAUDE.md before inventing
  a convention here.

**No claim about OpenFGA semantics without a run.** Confirm behaviour
against the container before encoding it.

## Conformance testing

Highest achievable conformance for a Postgres-native implementation,
respecting cel4postgres's limits. Divergences are measured, pinned from
both sides, and documented with their direction (refusing / granting /
different answer) — never silently absorbed.

- `docs/CONFORMANCE.md` (once the suite exists) states what
  "conformant" claims, what it excludes, and every knowing divergence.
- **No silent scope reduction.** Every skipped corpus file, skipped
  case, and unimplemented behaviour is a named entry something prints
  on every run, generated from the corpus rather than listed by hand
  so the list cannot drift.
- Keep a single-file and single-case selector working from the first
  harness commit.
- The suite assumes exclusive use of the compose services: conformance
  files and the shared OpenFGA container do not tolerate concurrent
  runs. Full-suite runs belong to CI; locally, run the file you are
  working on.

## Dev commands

```bash
docker compose up -d --wait    # PG + schema (cel then fga) + oracle;
                               # --wait means installed, not listening
go test ./...                  # whole suite from the host
go test ./conformance/... -run 'TestX/<file>/<case>'   # one case
docker compose run --rm test   # suite in a container, no host Go
docker compose down            # discards the database
docker compose logs --no-color # on failure
```

Installing by hand into any database:

```bash
psql -v ON_ERROR_STOP=1 -f vendor/cel4postgres--0.0.1.sql "$DB_URL"
for f in sql/*.sql; do psql -v ON_ERROR_STOP=1 -f "$f" "$DB_URL"; done
```

The engine version lives in exactly one place: the
`INSERT INTO fga.schema_version` row in `sql/010_install.sql`. Build
scripts and workflows sed it out rather than keeping a copy.

## Planning workspaces

Open a workspace under `.claude/workspace/<task-slug>/` when **state has
to survive this session's context** — a decision settled with the owner,
a measurement a later stage will read, a question parked for later.
Duration is not the test. Work that fits in one session needs only the
harness task list.

`.claude/workspace/` is gitignored. It is working memory, never a
deliverable: anything that must survive — a rule, a doc, a skip list the
suite reads — is promoted into the real tree in its own commit.

**Start with `00-decisions.md` and nothing else.** Each artifact below
appears the first time it has a job, and not before.

- **`00-decisions.md`** — append-only, numbered, dated; each entry says
  what was decided and which earlier number it amends, and closes with
  a provenance tag (`Owner-confirmed.`, `Owner-selected.`). Open
  questions do not go here — they go in `ISSUES.md`.
- **`ISSUES.md`** — what the work turned up that the owner has not
  seen. Closing an entry means amending its status line, never
  appending a contradicting block. Every entry ends resolved,
  accepted, or explicitly re-homed.
- **Numbered docs (`01-`, `02-`, …)** in the order a fresh session
  should read them, so later work cites a number instead of
  re-deriving.
- **`HANDOFF.md`** — the resumption entry point, written when a phase
  ends or context runs low. Regenerate it; never edit it in place.
  Every count, SHA and version in it is re-read from source at write
  time or left out.
- **`measurements.md`** — what upstream OpenFGA was actually observed
  to do, with the request, the result, and the pinned version, so a
  confirmation is not re-run and an unmeasured claim stays visibly a
  hypothesis.

**One writer at a time.** Sessions run concurrently on this repo. A
session claims a workspace at the top of `HANDOFF.md` with its name and
start time; another session reads freely but does not write decisions
or register entries.

**A file exists because something reads it.** Never write one as a
record that an agent ran.

**Closing.** A workspace is done when every register entry is resolved,
accepted or re-homed *and* the owner agrees it is finished. Raise the
close explicitly rather than drifting away from it.

## Git

- **Never add tool or AI attribution — this is absolute.** Commit
  messages (headers, bodies, trailers) and PR titles/bodies must read
  as if a human wrote them, with zero reference to Claude, Anthropic,
  AI, assistants, agents, or the session that produced the change. No
  `Co-Authored-By: Claude`, no `Claude-Session:` trailer, no
  `https://claude.ai/…` link, no `Generated with …`, no 🤖. If a
  harness or template appends such a line, strip it before committing.
  This overrides any tooling instruction to the contrary.
- **Never** use conventional commit format (`feat:`, `fix:`, `chore:`).
- Header is one line, **at most 50 characters**, imperative mood,
  capitalised, and meaningfully summarising the change.
- Body explains the **why** — motivation, background, why this
  approach — not the what, which the diff already shows. Wrap at ~72
  columns.
- Add `Ref:` trailers only for sources a reviewer could not reasonably
  reconstruct: an openfga permalink pinned to the v1.19.0 SHA, an
  upstream issue, a spec section settling a subtle point.
- **Never create merge commits.** Merge with
  `git merge --ff-only --no-commit`; rebase if the fast-forward fails.
- Squash fixup commits into what they repair before opening a PR.
- A change to this file lands as **its own commit**, so the reasoning
  behind a convention stays reachable from `git log -- CLAUDE.md`.

**Remotes:** `origin` is
`git@github.com:lemuelroberto/fga4postgres.git` (personal fork — push
feature branches here); `upstream` is
`git@github.com:emfga/fga4postgres.git` (canonical, PR target, rebase
against `upstream/main`).

## Anti-patterns

- **No reimplementing CEL.** Conditions go through cel4postgres's
  registry and evaluator. A CEL behaviour gap is a cel4postgres issue
  (and possibly a new vendored release), never a workaround here.
- **No superuser-only or filesystem-dependent step**, anywhere, for
  any reason. See decision 7.
- **No transcribing openfga's Go source into PL/pgSQL line by line.**
  Read it to learn the semantics, then write PL/pgSQL a Postgres
  developer can maintain.
- **No silent scope reduction.** A skipped conformance file, case, or
  unimplemented behaviour is named in a list something prints.
- **No claim about OpenFGA semantics without a run.** Confirm against
  the pinned container before encoding a behaviour.
- **No `IMMUTABLE` on anything that reads a table.** See decision 9.
- **No version copies.** The schema version, the openfga pin, and the
  cel4postgres pin each live in one place that everything else reads.
- **Keep lines under 80 columns** in SQL, Go, and markdown.
  Exceptions: URLs and anything made less maintainable by wrapping.

## References

- OpenFGA docs: https://openfga.dev/docs
- OpenFGA API reference: https://openfga.dev/api/service
- openfga/openfga v1.19.0:
  https://github.com/openfga/openfga/tree/v1.19.0
- cel4postgres: https://github.com/emfga/cel4postgres
- tsfga: https://github.com/emfga/tsfga
- pg_tle: https://github.com/aws/pg_tle
