# Benchmarks

How the benchmark suite measures the engine, what its numbers
mean, and how to reproduce them. The tooling lives in
`internal/bench` (library), `internal/cmd/bench` (the runner)
and `internal/cmd/benchreport` (the markdown renderer); the CI
workflow is `.github/workflows/bench.yml`.

## What the numbers are

**Closed-loop warm-cache service times.** One connection issues
one call at a time; each sample is the wall-clock around a
single SQL call, client marshalling and round-trip included.
There is no concurrency, so p99 here is *not* production tail
latency and nothing in these figures measures contention or
parallel-query behaviour. Before each scenario's cases the
runner primes the cache with a sequential scan of the scenario's
tuples, and every case starts with its own warmup (recorded as
`warmup_ops` in the result file), so numbers describe the
warm steady state by construction.

Queries draw **uniformly** over each variant's eligible
keyspace. At 10M+ rows a uniform stream is cold-heavy — most
probes touch pages no recent query warmed — which is a
deliberate, documented choice. A zipfian/hot-key option is
future work, not an omission.

Percentiles come from a pinned log-spaced histogram (1µs–100s,
×1.04 buckets, ~2% one-sided error); min, max and mean are
exact. benchreport marks any percentile computed from fewer
than 100 samples with `~`.

## Scenarios, sizes, seeds

Four scenario models — `direct` (flat grants, the floor),
`hierarchy` (depth-20 TTU chains), `fanout` (nested usersets,
1000-member groups) and `tenant` (a four-level hierarchy with
role ladders, for compiled relations; see below) — each scale
to `100k`, `1m`, `10m` and `100m` tuples. A size counts rows in
`fga.tuple` for that scenario's store. Datasets and query
streams are pure functions of (seed, scenario, size): the same
seed reproduces the same bytes on any machine. The per-query
work of every case is size-invariant by construction (chain
depth, group width and per-user grant counts are constants), so
cross-size comparisons measure the engine, not the workload —
with one deliberate exception, tenant's `all` subjects, below.

`generator_version` in the result file changes whenever the
generated fixtures change; benchreport refuses to diff results
across fixture identities (scenario, size, seed, generator).

## Compiled relations: the tenant scenario

`tenant` measures compiled relations
(`fga.enable_compiled_relations`) against the generic engine on
one synthetic model: `platform → account → project →
environment` (plus invoices), 6 types and 37 relations, only
`[user]` grants, every permission a ladder of computed usersets
and `x from parent`. The measured relation is
`environment#can_view`. An account is always 5 projects × 50
environments (250 leaves); the 100k size has 20 accounts
(**5,000 leaves**), and from 1m on there is one account per
2,500 tuples (**100,000 leaves** at 1m). The remaining tuples
are background grants on leaves to users who are never queried.

Three subject classes: `few` (reader on 3 leaves), `many`
(admin of one account: 250 leaves at every size) and `all`
(platform admin: every leaf, so its reach grows with the size).

| feature | what one op is |
|---|---|
| `check` | `fga.check`, store not opted in |
| `list_objects` | `fga.list_objects`, store not opted in (`few`, `many` only: `all` is seconds per call) |
| `compiled_check` | the generated `__check`, called directly |
| `check_opted_in` | `fga.check` on the opted-in store |
| `compiled_objects` | `count(*)` over the whole `__objects` set |
| `compiled_page` | 50 rows of the consumer's table, `id IN (SELECT x FROM __objects(...) x) ORDER BY name LIMIT 50` |

The check-shaped features share one query stream per variant
(`hit-shallow`: a direct leaf grant; `hit-deep`: a platform
admin, three parent hops up; `miss`: a leaf reader outside its
three leaves), and so do the list-shaped ones, so each compiled
case compares against the generic one call for call.
`check_opted_in` is the generic entry point on the opted-in
store: it moves exactly when `fga.check` starts dispatching to
compiled functions.

Mechanics. The loader creates the consumer's table
`fga_bench_tenant_<size>.environment (id, name)` beside the
tuples (names uncorrelated with ids or hierarchy, indexed) and
runs `ANALYZE` on it and on `fga.tuple` — every page shape needs
analyzed `fga.tuple` statistics, and without them a page of 50
runs 0.6–2.5 s. Each compiled case opts the store in to that
schema (the bench creates it; the engine never creates schemas)
for its own duration and opts it out outside the timed window,
so the generic cases always measure a store that is not opted
in. A compiled case refuses to run when `environment#can_view`
did not compile to the flattened strategy. Checks go through
pgx's statement cache like every other case; the set-shaped
cases plan every call, so the plan never depends on what ran
before (`internal/bench/compiled.go` says why).

**The envelope.** A set-shaped `__objects` page costs in
proportion to the subject's visible set, not to the page: the
planner never turns `id IN (SELECT … FROM __objects(...))` into
an early-stopping probe. The prototype that settled this design
measured ~6.6 ms at 5,000 leaves and ~108 ms at 100,000 for a
platform admin's page on this model, with a function that
flattened `can_view` into one `UNION` over its four grant
places (the leaf, its project, its account, the platform).

**Measured** (one laptop: i7-1355U, 12 threads, `powersave`
governor, the tmpfs compose stack, PostgreSQL 18.6, sharing the
machine with other workloads — load average 0.5–5.7 during the
runs; PR knobs `-warmup 3s -duration 5s -min-ops 25`). p50s;
at 100k the median of three runs with the range, at 1m one run:

| case | 100k (5,000 leaves) | 1m (100,000 leaves) |
|---|--:|--:|
| check hit-shallow | 0.36 ms (0.31–0.40) | 0.39 ms |
| check hit-deep | 1.7 ms (1.5–4.8) | 1.8 ms |
| check miss | 12.2 ms (11.8–14.3) | 61 ms (min 17) |
| compiled_check hit-shallow | 0.08 ms (0.08–0.25) | 0.07 ms |
| compiled_check hit-deep | 0.25 ms (0.22–0.27) | 0.22 ms |
| compiled_check miss | 1.5 ms (1.5–1.9) | 1.6 ms |
| check_opted_in miss | 12.7 ms (12.2–13.2) | 12.2 ms |
| list_objects few | 8.3 ms (3.1–9.7) | 19.6 ms |
| list_objects many | 33 ms (30–64) | 41 ms |
| compiled_objects few | 28 ms (27–29) | 31 ms |
| compiled_objects many | 28 ms (25–80) | 94 ms |
| compiled_objects all | 50 ms (38–119) | 783 ms |
| compiled_page few | 23 ms (23–31) | 24 ms |
| compiled_page many | 34 ms (24–59) | 26 ms |
| compiled_page all | 41 ms (41–139) | 880 ms |

The page decomposes cleanly under `EXPLAIN (ANALYZE)` on the
same fixtures: **planning is ~16–23 ms for every subject**, and
execution is 3.6–4.5 ms (`few`, `many`) and 21–24 ms (`all`) at
5,000 leaves, 4.5–7.6 ms and 780–840 ms at 100,000 (where JIT
off changed nothing). So the engine's generated
`environment#can_view` is well outside the prototype's envelope
today: at 5,000 leaves planning alone costs more than the
prototype's whole page, and at 100,000 leaves a platform admin's
set passes five nested Sort + Unique steps of 100,000–200,000
rows each (nested `UNION`s, spilling to disk at the default
`work_mem`) where the prototype had one `UNION`. A
prepared statement that settles on a generic plan skips the
planning (measured in `psql`: 3.5 / 4.1 / 19–21 ms for
`few` / `many` / `all` at 5,000 leaves), which is a consumer's
choice the bench deliberately does not make for it. These
figures say what the compiled functions cost on this model now;
they do not say the set shape cannot reach the spike's numbers.

## Fixture loading

Fixtures bypass `fga.write` and COPY straight into `fga.tuple`,
pre-sorted in primary-key order, with client-generated monotonic
ULIDs in `fga._ulid()`'s exact wire format. The bypass is
setup-only: the generator guarantees validity, and `fga.write`
throughput is measured separately as its own benchmark case.

The loader records what it loaded in a `fga_bench.manifest`
table (a schema the tooling creates and owns; the engine's
`sql/` and the release artifacts never reference it) and skips
loads whose manifest already matches. At 10M+ rows it drops the
two secondary indexes (`tuple_ulid_idx`, `tuple_reverse_idx`)
before the COPY and recreates them by re-running
`sql/050_tuple.sql` — it touches engine-owned objects during
load, which is why bench databases are dedicated. `ANALYZE` and
`CHECKPOINT` run after the load so the first measured case does
not absorb the load's WAL flush; a managed service may refuse
`CHECKPOINT`, which only softens that guarantee.

Before anything is measured the engine is **reinstalled
unconditionally** (vendored cel4postgres, then `sql/*.sql`), so
a persistent bench volume can never silently measure a stale
schema; `git_commit`/`git_dirty` in the result therefore
describe the code that was actually installed.

## Running

```bash
# Disk-backed stack (fixtures survive restarts):
docker compose -f compose.bench.yaml up -d --wait

go run ./internal/cmd/bench -size 100k          # all scenarios
go run ./internal/cmd/bench -size 1m \
  -scenario hierarchy -feature check,list_objects
go run ./internal/cmd/bench -size 10m -load-only  # prepare only
go run ./internal/cmd/bench -size 10m -skip-load  # measure only

go run ./internal/cmd/benchreport bench-results/<file>.json
go run ./internal/cmd/benchreport \
  -baseline docs/benchmarks/baseline-100k.json <file>.json
```

Any PostgreSQL 18+ works: point `DATABASE_URL` at it. The
default compose stack (`compose.yaml`) is tmpfs-backed — fine
for 100k/1M, meaningless for 10M+; `compose.bench.yaml` uses a
named volume (`docker volume rm fga4postgres-bench-pgdata`
discards the fixtures). Results land in `bench-results/`
(gitignored), overridable via `-results` or
`FGA_BENCH_RESULTS`. Bench and conformance runs never share a
database.

Mutating cases (`write`, `write_authorization_model`) always run
last and work against scratch stores recreated outside the timed
windows; the result's env block records `fga.tuple` dead-tuple
counts at start and end so churn is visible.

## Quiet-machine checklist

For numbers worth comparing across days, not just within a run:

- Use `compose.bench.yaml` (volume-backed) or an external PG18.
- AC power; `performance` governor
  (`cpupower frequency-set -g performance`); verify via the
  report's env block, which records the governor.
- No other heavy processes; `uptime` load below 1 before
  starting.
- Note turbo/SMT changes if any; defaults are assumed.
- Run each size twice; if headline p95s differ by more than
  ~5%, the machine was not quiet — rerun rather than average.
- Record nothing by hand: the result file carries the metadata
  (CPU, governor, storage class, PG settings including every
  non-default, engine and harness versions).

Nothing enforces this list; the binary records and benchreport
warns, per the methodology decision.

## Baselines and CI

CI (`bench.yml`) runs 100k on pull requests and 100k/1M on
manual dispatch, publishing the report as the job summary and
the raw JSON as an artifact. CI numbers come from shared runners
on tmpfs storage — they spot order-of-magnitude movement, not
small regressions; quiet-machine-grade comparison happens
locally.

A committed baseline lives at
`docs/benchmarks/baseline-<size>.json` — a JSON array bundling
the run's per-scenario result files (a single result object also
works) — produced by a workflow_dispatch run on a GitHub-hosted
runner so CI deltas compare like hardware. Committing or refreshing one is a
deliberate, by-hand act, with the commit body saying why the
numbers moved. Until the first baseline is committed, CI
summaries show absolute numbers only — deliberate, not an
omission. Nothing fails on a regression; deltas are
informational.

## Known limits

- Load-rate expectations at 10M/100M (O(100k rows/s), 100M in
  well under an hour on local NVMe) are extrapolated from small
  sizes and stay labelled as such until the first full local
  campaign validates them.
- The 100M fixture is ~10–15 GB of table plus indexes; GitHub
  runners cannot hold it, hence the CI/local split.
- The generator sorts each object type's ids in memory while
  streaming: ~24 bytes per object, several hundred MB at 100m.
- The deep read page pins one filter per case (the continuation
  token binds the engine's filter hash); it measures keyset
  positioning, not filter variety.
