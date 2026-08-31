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

Three scenario models — `direct` (flat grants, the floor),
`hierarchy` (depth-20 TTU chains), `fanout` (nested usersets,
1000-member groups) — each scale to `100k`, `1m`, `10m` and
`100m` tuples. A size counts rows in `fga.tuple` for that
scenario's store. Datasets and query streams are pure functions
of (seed, scenario, size): the same seed reproduces the same
bytes on any machine. The per-query work of every case is
size-invariant by construction (chain depth, group width and
per-user grant counts are constants), so cross-size comparisons
measure the engine, not the workload.

`generator_version` in the result file changes whenever the
generated fixtures change; benchreport refuses to diff results
across fixture identities (scenario, size, seed, generator).

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
`docs/benchmarks/baseline-<size>.json`, produced by a
workflow_dispatch run on a GitHub-hosted runner so CI deltas
compare like hardware. Committing or refreshing one is a
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
