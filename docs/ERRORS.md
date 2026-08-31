# Error scheme

Frozen. Changing an allocation after code raises it is a breaking
change to consumers who catch these codes.

## The SQLSTATE class

Every error the engine raises deliberately uses SQLSTATE class
`YF` — chosen from PostgreSQL's implementation-defined range (a
class whose first character is not 0-4 or A-H is reserved for
implementations). The letters carry no meaning; the digits are an
internal convention described below, not part of the SQL standard.

The class gives resolver code one safe catch:

```sql
EXCEPTION WHEN SQLSTATE 'YF000' THEN ...
```

matches every `YF`-class error and nothing else. `WHEN OTHERS` is
never used to catch engine errors — it would convert genuine bugs
(typos, missing columns) into swallowed operand errors.

`YF000` itself is the class anchor and is **never raised**: raising
it would make "catch the whole class" and "catch exactly this
error" the same statement.

## Derivation rule

One SQLSTATE per upstream API error code the engine can produce,
derived mechanically so new allocations never need judgment:

- upstream `ErrorCode` 2000+nn (nn < 100)  → `YF1` + nn zero-padded
- upstream `NotFoundErrorCode` 5000+nn     → `YF5` + nn zero-padded
- a plain gRPC status code nn (no domain
  code — upstream raises the bare status)  → `YFG` + nn zero-padded

The conformance harness inverts the same rule: SQLSTATE `YF1nn`
maps back to gRPC status code 2000+nn, `YF5nn` to 5000+nn, and
`YFGnn` to the bare code nn — the numbers upstream carries as the
gRPC status code and the corpus asserts with `errorCode:`.

## Initial allocations

| SQLSTATE | upstream code | name |
|----------|---------------|------|
| YF100 | 2000 | validation_error |
| YF101 | 2001 | authorization_model_not_found |
| YF102 | 2002 | authorization_model_resolution_too_complex |
| YF117 | 2017 | write_failed_due_to_invalid_input |
| YF120 | 2020 | latest_authorization_model_not_found |
| YF121 | 2021 | type_not_found |
| YF122 | 2022 | relation_not_found |
| YF127 | 2027 | invalid_tuple |
| YF103 | 2003 | invalid_write_input |
| YF104 | 2004 | cannot_allow_duplicate_tuples_in_one_request |
| YF107 | 2007 | invalid_continuation_token |
| YF153 | 2053 | exceeded_entity_limit |
| YF156 | 2056 | invalid_authorization_model |
| YFG10 | gRPC 10 | Aborted (transactional write conflict) |
| YF502 | 5002 | store_id_not_found |

The v1.19.0 corpus asserts 2000, 2002, 2021, 2022 and 2027; the
rest are codes the engine's own write and lookup paths need. New
codes are added by the rule, recorded here in the same commit.

## Raising

```sql
RAISE EXCEPTION 'relation ''%'' not found', rel
  USING ERRCODE = 'YF122';
```

Messages are for humans and are never part of the contract; the
harness compares codes only (message text necessarily differs —
one side holds mapped uuids, the other original corpus strings).

Errors from cel4postgres (condition evaluation) are remapped into
the `YF` class at the call boundary so the resolver's class catch
sees exactly one error surface.
