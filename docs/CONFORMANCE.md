# Conformance

What "conformant" claims, what it excludes, and every knowing
divergence. The conformance target is **openfga/openfga v1.19.0**,
pinned everywhere at once (CLAUDE.md decision 1). Every claim below
is backed by a test the suite runs against the live pinned
container; a divergence is *pinned from both sides*
(`conformance/pins_test.go`), so a gap upstream closes turns the
suite red and demands this file change in the same commit.

## Status

All planned v1 APIs are implemented. Current verified surface:

- Conditions/ABAC: the whole `abac_tests.yaml` corpus passes
  differentially for check, list_objects and list_users, and
  upstream's own imported test runners (`tests/check`,
  `tests/listobjects`, `tests/listusers` at the pin — the YAML
  replays plus the generated matrix corpora, list_users
  sub-asserts included) run green against the engine through the
  SQL adapter. Conditions evaluate through cel4postgres under the
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
- `list_users`: every corpus case passes differentially in both
  replay variants. The measured envelope the engine mirrors:
  exactly one user filter; userset filters are reflexive (every
  expansion node matching the filter emits itself); a wildcard
  survives concrete subtraction as an invisible exception
  (`user:*` minus `user:bob` answers `user:*`, and an
  intersection sibling cannot resurrect the excluded user); a
  wildcard subtrahend empties the result; depth refuses one
  tuple-hop earlier than check (2002 at a 25-link ladder where
  check refuses at 26); a condition error on a relevant path
  fails the request immediately with 2000, while paths that
  cannot reach the filter type are pruned before their tuples
  (or conditions) are touched.
- Tuple `write`/`delete`: the full refusal matrix runs
  differentially (`TestWriteGateMatrix`) — the operation cap
  (2053), in-request duplicates across both lists (2004), the
  empty request (2003), existing-duplicate and missing-delete
  (2017), `on_duplicate`/`on_missing` "ignore" semantics
  including the condition-conflict Abort (gRPC 10,
  `TestWriteOnDuplicate`), implicit-tuple and wildcard-shape
  refusals, condition-context gates (control characters,
  undeclared parameters, uncoercible values), and the proto
  field-length limits, all against the live oracle. The
  attribution inventory `docs/write-causes.json` bijects every
  upstream write-path error construction site at the pin onto a
  disposition, CI-enforced (`TestWriteCausesInventory`): a pin
  bump or upstream reword turns the suite red.
- Model validation: the CONFIG-* matrix runs differentially with
  raw protos (`TestModelGateMatrix`) — reserved names, undefined
  types/relations/conditions in restrictions and rewrites,
  rewrite cycles, empty restriction lists, single-operand
  intersections and unions, the three tupleset rules, condition
  compile failures, condition key/name mismatches and the schema
  version gate, all refusing 2056 on both engines.
- `fga.read`: filtered listing runs differentially
  (`TestReadDifferential`) — the measured filter rule (object
  type required plus id-or-user), keyset pagination on ulid
  (default page 50, max 100), and the invalid-token refusal
  (2007) match upstream; the token-to-filter binding is a pinned
  refusing divergence (below).
- `expand`: no upstream corpus exists; the differential suite
  (`TestExpandDifferential`) covers every operator tree shape,
  wildcard and userset leaves, TTU fan-out, contextual tuples,
  the measured no-condition-evaluation property (an unmet-able
  conditioned tuple still appears — M20), and the all-2000 error
  surface including undefined type/relation (M19 — unlike
  check's 2021/2022). Users lists compare order-insensitively:
  upstream's TTU computed list follows tuple order, the engine's
  ulid order.
- Real-world sweep: 38 production-shaped models (the openfga
  sample stores plus tsfga's large fixtures — theopenlane is
  1054 DSL lines) are written to both engines and swept with a
  seeded differential sample of checks and list_objects per
  fixture (`TestRealWorldModels`), refusals compared as
  outcomes.
- Condition-error scoping follows upstream's filtered-iterator
  rule, from source and probes at the pin (M40): a held
  condition error is scoped per model-graph edge and dropped
  when any row of that edge passes its filter; list_objects
  walks only the subgraph between the user and the target, so
  conditions on unreachable edges never evaluate.

## Exclusions (out of v1 scope)

Streamed list-objects, read-changes, the assertions API, the
read-models API and its paging (`ReadAuthorizationModels`), the
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
| PIN-READ-1 | A read continuation token reused under a changed filter is refused (2007); upstream's positional token silently continues at that offset under the new filter | refusing | TestPinnedReadTokenFilter |
| PIN-CTX-1 | The condition-context write boundary is 32768 bytes of jsonb-normalized text; upstream's is 32768 proto bytes — number-heavy contexts refuse here and pass there, near-boundary strings flip at slightly different lengths | different-boundary | TestPinnedContextBoundary |
| PIN-DEPTH-1 | Deep recursive negatives near the depth boundary are strategy-dependent upstream (M41): the engine implements the documented budget (25 dispatches resolve, the 26th refuses 2002); upstream may answer false at any depth (recursive fast path) or refuse 2002 one dispatch early depending on model and store shape. The disagreement class is only false-vs-2002, never true-vs-false; positives agree exactly on the boundary | different-boundary | TestPinnedDeepRecursionStrategy |

Condition-layer divergences (measured or by construction,
measurements M15/M30/M31; none corpus-visible):

- **Accepting at model write**: a condition with type errors (a
  parse-clean expression misusing its parameters) is accepted at
  `write_authorization_model` and refused at evaluation instead —
  cel4postgres's checker has no declared-variable support.
  Upstream's CEL cost-limit-100 write refusal is likewise not
  reproduced (no interpreter cost accounting); cel4postgres's
  100KB expression cap still applies. Two further members of the
  same family: upstream's whole-model entrypoint analysis ("no
  entrypoints defined") is not reproduced, and a TTU whose
  computed relation is undefined on every linked type is stored
  rather than refused (resolution answers false, the measured
  semantic). Upstream's model size limit is also not reproduced
  (corpus-invisible, M14). These accepting-direction divergences
  concern which *models* are storable, never which authorization
  answers are given.
- **Inherited from cel4postgres**: `matches()` runs on POSIX ARE
  rather than RE2; strings cannot contain U+0000 (a Postgres
  substrate limit); plus its measured divergence list.

## Product properties beyond upstream

- `batch_check` answers are mutually consistent: one SQL statement
  is one snapshot, where upstream's concurrent goroutines may see
  interleaved writes.
- PostgreSQL 18+ is the platform floor (native `uuidv7()`); this
  is a platform bound, not a semantic divergence.
