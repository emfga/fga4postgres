# Conformance

What "conformant" claims, what it excludes, and every knowing
divergence. The conformance target is **openfga/openfga v1.19.0**,
pinned everywhere at once (CLAUDE.md decision 1). Every claim below
is backed by a test the suite runs against the live pinned
container; a divergence is *pinned from both sides*
(`conformance/pins_test.go`), so a gap upstream closes turns the
suite red and demands this file change in the same commit.

## Status

The engine is mid-implementation (plan phase: conditions
complete). Current verified surface:

- Conditions/ABAC: the whole `abac_tests.yaml` corpus passes
  differentially for check and list_objects, and upstream's own
  imported test runners (`tests/check`, `tests/listobjects` at the
  pin — the YAML replays plus the generated matrix corpora, ~3000
  assertions) run green against the engine through the SQL
  adapter, with only the list_users sub-asserts skipped until that
  API lands. Conditions evaluate through cel4postgres under the
  `openfga` env (the `ipaddress` type and `in_cidr` registered via
  its registries); typed parameters convert per upstream's
  grammar; the tuple's condition context wins over the request
  context; a missing referenced parameter refuses before
  evaluation exactly as measured.

- `check` and `batch_check`: every non-condition case of the
  upstream YAML corpus (`consolidated_1_1_tests.yaml` +
  `abac_tests.yaml`) passes differentially against the oracle, in
  both the normal and contextual-tuples replay variants.
- `list_objects` (unary and the streamed adapter): every
  non-condition corpus case passes differentially, each returned
  object confirmed by a forward check; the 1000-result cap is
  probed on both engines. The engine mirrors upstream's measured
  envelope: reverse expansion charges no tuple-hop depth (a
  100-link chain lists completely even where a forward check on
  the same chain refuses as too complex).
- `list_objects` returns complete results or an error — there is
  no deadline machinery, and it is verified that no corpus case
  depends on upstream's partial-results-on-deadline behaviour
  (different-shape property, measurements M21/M22).
- `list_users`, `expand`, and `read` are not implemented yet;
  every affected corpus case is a generated, printed skip (no
  silent scope reduction).

## Exclusions (out of v1 scope)

Streamed list-objects, read-changes, the assertions API, the
HTTP/gRPC layer, DSL parsing in-engine (DSL→JSON stays in the
harness), store-level auth and multi-tenant isolation machinery.

## Pinned divergences

Direction vocabulary: **refusing** = fga4postgres refuses what
upstream accepts (the safe direction); **granting** would be the
reverse (none exist, by policy); **different-boundary** = both
sides refuse, at different limits.

| id | divergence | direction | pinned by |
|----|-----------|-----------|-----------|
| PIN-ID-1 | Object/subject ids must be uuids; upstream accepts nearly arbitrary strings (`anne`, `café`, 300-char ids) | refusing | TestPinnedIDDomain |
| PIN-ID-2 | Only canonical lower-case hyphenated uuid spelling; upstream treats other spellings as distinct opaque ids | refusing | TestPinnedIDDomain |
| PIN-ID-3 | The nil uuid is the wildcard storage sentinel and refused as an id | refusing | TestPinnedIDDomain |
| PIN-ID-4 | Store/model ids are uuidv7; upstream-shaped ULID ids are refused as not-found, and ids never transfer between engines | refusing | TestPinnedULIDModelID |

Condition-layer divergences (measured or by construction,
measurements M15/M30/M31; none corpus-visible):

- **Accepting at model write**: a condition with type errors (a
  parse-clean expression misusing its parameters) is accepted at
  `write_authorization_model` and refused at evaluation instead —
  cel4postgres's checker has no declared-variable support.
  Upstream's CEL cost-limit-100 write refusal is likewise not
  reproduced (no interpreter cost accounting); cel4postgres's
  100KB expression cap still applies. These are the only known
  accepting-direction capability divergences, and they concern
  which *models* are storable, never which authorization answers
  are given.
- **Inherited from cel4postgres**: `matches()` runs on POSIX ARE
  rather than RE2; strings cannot contain U+0000 (a Postgres
  substrate limit); plus its measured divergence list.

Planned pins that land with their phases: the 32KiB
condition-context write boundary (different-boundary, phase 6).

## Product properties beyond upstream

- `batch_check` answers are mutually consistent: one SQL statement
  is one snapshot, where upstream's concurrent goroutines may see
  interleaved writes.
- PostgreSQL 18+ is the platform floor (native `uuidv7()`); this
  is a platform bound, not a semantic divergence.
