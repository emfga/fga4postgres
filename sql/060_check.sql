-- The check resolver.
--
-- Semantics are measured, not intuited: every load-bearing rule
-- here cites a CLOSED measurements.md entry (workspace v1-design).
--
--   M01: depth is charged only on dispatch to another object
--        (userset expansion; TTU later). Computed usersets and
--        set operands cost nothing. 25 dispatches succeed; the
--        26th raises too-complex (YF102) — never a plain false.
--   M01: a false sibling swallows an operand error in union and
--        intersection; a true sibling never does. Implemented as
--        deferred re-raise: operand errors of our own class are
--        caught per child (class catch 'YF000', never OTHERS) and
--        re-raised only if no sibling produced the swallowing
--        answer.
--   M04: a cycle is a tracked outcome (allowed=false,
--        cycled=true), threaded through every operator.
--   M05: the reachability prune answers plain false,
--        indistinguishable from an empty traversal.
--   M06: an undefined relation in the request errors (YF100); one
--        reached through a TTU link is skipped (phase 1b).
--   M10: request validation order: user form, subject type,
--        subject relation, object form, object type, request
--        relation; contextual tuples last, refused as YF127.
--
-- Phase 1a implements this/computed_userset/union; intersection,
-- difference and tuple_to_userset raise a non-YF internal error
-- until phase 1b, so hitting one is loudly a harness bug, never a
-- swallowed operand.

BEGIN;

DO $$
BEGIN
  CREATE TYPE fga._check_result AS (allowed boolean,
                                    cycled boolean);
EXCEPTION WHEN duplicate_object THEN
  NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fga._check_node(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  st text, sid uuid, srel text, s_wild boolean,
  ctx fga._tuple_key[],
  depth integer,
  visited text[]
)
RETURNS fga._check_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  node_key text := ot || ':' || oid::text || '#' || rel;
  rw jsonb;
BEGIN
  -- Cycle handling is resolver-shape-dependent at the pin (M04):
  -- a cycle that stays inside one self-recursive relation resolves
  -- to a plain false (upstream's recursive fast path deduplicates
  -- without a cycle flag); any cycle crossing relations or types
  -- carries the flag, which exclusion and intersection then refuse
  -- on. The cycle segment is everything visited since the first
  -- occurrence of this node's key.
  IF node_key = ANY (visited) THEN
    IF (
      SELECT bool_and(split_part(v, ':', 1) = ot
                      AND split_part(v, '#', 2) = rel)
      FROM unnest(
        visited[array_position(visited, node_key):]) AS v
    ) THEN
      RETURN (false, false);
    END IF;
    RETURN (false, true);
  END IF;

  -- Self-defining subject: checking T:x#r for subject T:x#r.
  IF srel <> '' AND st = ot AND sid = oid AND srel = rel THEN
    RETURN (true, false);
  END IF;

  SELECT r.rewrite INTO rw
  FROM fga.model_relation r
  WHERE r.store = store_id AND r.model_id = _check_node.model_id
    AND r.type_name = ot AND r.relation_name = rel;
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'invalid relation: relation ''%#%'' not found', ot, rel
      USING ERRCODE = 'YF100';
  END IF;

  -- Precomputed PathExists prune (M05): plain false, no flag.
  IF NOT EXISTS (
    SELECT FROM fga.model_reachable mr
    WHERE mr.store = store_id AND mr.model_id = _check_node.model_id
      AND mr.type_name = ot AND mr.relation_name = rel
      AND mr.subject_type = st
      AND mr.subject_relation
            = CASE WHEN s_wild THEN '' ELSE srel END
  ) THEN
    RETURN (false, false);
  END IF;

  RETURN fga._check_rewrite(
    store_id, model_id, ot, oid, rel,
    st, sid, srel, s_wild, ctx, depth,
    visited || node_key, rw);
END;
$$;

CREATE OR REPLACE FUNCTION fga._check_direct(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  st text, sid uuid, srel text, s_wild boolean,
  ctx fga._tuple_key[],
  depth integer,
  visited text[]
)
RETURNS fga._check_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  u record;
  r fga._check_result;
  cyc boolean := false;
  caught_state text;
  caught_msg text;
BEGIN
  -- Exact probe. A userset subject is compared, never expanded.
  IF fga._read_exact(store_id, model_id, ot, oid, rel,
       st, sid, srel, ctx)
  THEN
    RETURN (true, false);
  END IF;

  -- Wildcard probe, for plain object subjects only: a userset
  -- subject is never wildcard-matched, and a wildcard subject
  -- only matches literal wildcard tuples (the exact probe above).
  IF srel = '' AND NOT s_wild AND fga._read_exact(
       store_id, model_id, ot, oid, rel, st,
       '00000000-0000-0000-0000-000000000000', '', ctx)
  THEN
    RETURN (true, false);
  END IF;

  -- Userset expansion: a union over dispatches, with the deferred
  -- error re-raise of M01 and the dispatch-only depth charge.
  FOR u IN
    SELECT * FROM fga._read_usersets(store_id, model_id, ot, oid, rel, ctx)
  LOOP
    BEGIN
      IF depth >= 25 THEN
        RAISE EXCEPTION 'resolution too complex: depth exceeded'
          USING ERRCODE = 'YF102';
      END IF;
      r := fga._check_node(
        store_id, model_id,
        u.subject_type, u.subject_id, u.subject_relation,
        st, sid, srel, s_wild, ctx, depth + 1, visited);
      IF r.allowed THEN
        RETURN (true, false);
      END IF;
      cyc := cyc OR r.cycled;
    EXCEPTION WHEN SQLSTATE 'YF000' THEN
      GET STACKED DIAGNOSTICS
        caught_state = RETURNED_SQLSTATE,
        caught_msg = MESSAGE_TEXT;
    END;
  END LOOP;

  IF caught_state IS NOT NULL THEN
    RAISE EXCEPTION '%', caught_msg USING ERRCODE = caught_state;
  END IF;
  RETURN (false, cyc);
END;
$$;

CREATE OR REPLACE FUNCTION fga._check_rewrite(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  st text, sid uuid, srel text, s_wild boolean,
  ctx fga._tuple_key[],
  depth integer,
  visited text[],
  rw jsonb
)
RETURNS fga._check_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  child jsonb;
  r fga._check_result;
  cyc boolean := false;
  caught_state text;
  caught_msg text;
BEGIN
  IF rw ? 'this' THEN
    RETURN fga._check_direct(
      store_id, model_id, ot, oid, rel,
      st, sid, srel, s_wild, ctx, depth, visited);

  ELSIF rw ? 'computed_userset' THEN
    -- Same object, other relation: no dispatch, no depth (M01).
    RETURN fga._check_node(
      store_id, model_id,
      ot, oid, rw -> 'computed_userset' ->> 'relation',
      st, sid, srel, s_wild, ctx, depth, visited);

  ELSIF rw ? 'union' THEN
    FOR child IN
      SELECT * FROM jsonb_array_elements(rw -> 'union' -> 'child')
    LOOP
      BEGIN
        r := fga._check_rewrite(
          store_id, model_id, ot, oid, rel,
          st, sid, srel, s_wild, ctx, depth, visited, child);
        IF r.allowed THEN
          RETURN (true, false);
        END IF;
        cyc := cyc OR r.cycled;
      EXCEPTION WHEN SQLSTATE 'YF000' THEN
        GET STACKED DIAGNOSTICS
          caught_state = RETURNED_SQLSTATE,
          caught_msg = MESSAGE_TEXT;
      END;
    END LOOP;
    IF caught_state IS NOT NULL THEN
      RAISE EXCEPTION '%', caught_msg
        USING ERRCODE = caught_state;
    END IF;
    RETURN (false, cyc);

  ELSIF rw ? 'intersection' THEN
    -- Model order; the first false-or-cycled operand decides and
    -- propagates its flag; a false sibling swallows an operand
    -- error, a true one never does (M01, M11).
    FOR child IN
      SELECT * FROM jsonb_array_elements(
        rw -> 'intersection' -> 'child')
    LOOP
      BEGIN
        r := fga._check_rewrite(
          store_id, model_id, ot, oid, rel,
          st, sid, srel, s_wild, ctx, depth, visited, child);
        IF NOT r.allowed OR r.cycled THEN
          RETURN (false, r.cycled);
        END IF;
      EXCEPTION WHEN SQLSTATE 'YF000' THEN
        GET STACKED DIAGNOSTICS
          caught_state = RETURNED_SQLSTATE,
          caught_msg = MESSAGE_TEXT;
      END;
    END LOOP;
    IF caught_state IS NOT NULL THEN
      RAISE EXCEPTION '%', caught_msg
        USING ERRCODE = caught_state;
    END IF;
    RETURN (true, false);

  ELSIF rw ? 'difference' THEN
    RETURN fga._check_difference(
      store_id, model_id, ot, oid, rel,
      st, sid, srel, s_wild, ctx, depth, visited,
      rw -> 'difference' -> 'base',
      rw -> 'difference' -> 'subtract');

  ELSIF rw ? 'tuple_to_userset' THEN
    RETURN fga._check_ttu(
      store_id, model_id, ot, oid, rel,
      st, sid, srel, s_wild, ctx, depth, visited,
      rw -> 'tuple_to_userset' -> 'tupleset' ->> 'relation',
      rw -> 'tuple_to_userset' -> 'computed_userset'
         ->> 'relation');

  ELSE
    -- Not the YF class on purpose: reaching an unknown operator
    -- is a harness bug and must never be swallowed as an operand
    -- error.
    RAISE EXCEPTION
      'fga4postgres: unknown rewrite operator: %', rw;
  END IF;
END;
$$;

-- Exclusion, sequentially: a false-or-cycled base decides first, a
-- true-or-cycled subtrahend refuses, and an operand error
-- re-raises only when the other side did not produce the
-- swallowing answer (M01, M04).
CREATE OR REPLACE FUNCTION fga._check_difference(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  st text, sid uuid, srel text, s_wild boolean,
  ctx fga._tuple_key[],
  depth integer,
  visited text[],
  base jsonb,
  subtract jsonb
)
RETURNS fga._check_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  base_r fga._check_result;
  sub_r fga._check_result;
  base_state text;
  base_msg text;
  sub_state text;
  sub_msg text;
BEGIN
  BEGIN
    base_r := fga._check_rewrite(
      store_id, model_id, ot, oid, rel,
      st, sid, srel, s_wild, ctx, depth, visited, base);
    IF NOT base_r.allowed OR base_r.cycled THEN
      RETURN (false, base_r.cycled);
    END IF;
  EXCEPTION WHEN SQLSTATE 'YF000' THEN
    GET STACKED DIAGNOSTICS
      base_state = RETURNED_SQLSTATE, base_msg = MESSAGE_TEXT;
  END;

  BEGIN
    sub_r := fga._check_rewrite(
      store_id, model_id, ot, oid, rel,
      st, sid, srel, s_wild, ctx, depth, visited, subtract);
    IF sub_r.allowed OR sub_r.cycled THEN
      RETURN (false, sub_r.cycled);
    END IF;
  EXCEPTION WHEN SQLSTATE 'YF000' THEN
    GET STACKED DIAGNOSTICS
      sub_state = RETURNED_SQLSTATE, sub_msg = MESSAGE_TEXT;
  END;

  IF base_state IS NOT NULL THEN
    RAISE EXCEPTION '%', base_msg USING ERRCODE = base_state;
  END IF;
  IF sub_state IS NOT NULL THEN
    RAISE EXCEPTION '%', sub_msg USING ERRCODE = sub_state;
  END IF;
  RETURN (true, false);
END;
$$;

-- TTU: dispatch the computed relation on every linked parent. A
-- parent whose type does not define the computed relation is
-- skipped — the one asymmetric undefined-relation case (M06).
CREATE OR REPLACE FUNCTION fga._check_ttu(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  st text, sid uuid, srel text, s_wild boolean,
  ctx fga._tuple_key[],
  depth integer,
  visited text[],
  tupleset_rel text,
  computed text
)
RETURNS fga._check_result
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  u record;
  r fga._check_result;
  cyc boolean := false;
  caught_state text;
  caught_msg text;
BEGIN
  FOR u IN
    SELECT * FROM fga._read_tupleset(
      store_id, model_id, ot, oid, tupleset_rel, ctx)
  LOOP
    IF NOT EXISTS (
      SELECT FROM fga.model_relation mr
      WHERE mr.store = store_id
        AND mr.model_id = _check_ttu.model_id
        AND mr.type_name = u.subject_type
        AND mr.relation_name = computed
    ) THEN
      CONTINUE;
    END IF;
    BEGIN
      IF depth >= 25 THEN
        RAISE EXCEPTION 'resolution too complex: depth exceeded'
          USING ERRCODE = 'YF102';
      END IF;
      r := fga._check_node(
        store_id, model_id,
        u.subject_type, u.subject_id, computed,
        st, sid, srel, s_wild, ctx, depth + 1, visited);
      IF r.allowed THEN
        RETURN (true, false);
      END IF;
      cyc := cyc OR r.cycled;
    EXCEPTION WHEN SQLSTATE 'YF000' THEN
      GET STACKED DIAGNOSTICS
        caught_state = RETURNED_SQLSTATE,
        caught_msg = MESSAGE_TEXT;
    END;
  END LOOP;

  IF caught_state IS NOT NULL THEN
    RAISE EXCEPTION '%', caught_msg USING ERRCODE = caught_state;
  END IF;
  RETURN (false, cyc);
END;
$$;

-- The public check entry point. Request is upstream's
-- CheckRequest JSON shape (snake_case): tuple_key,
-- contextual_tuples.tuple_keys, context, authorization_model_id.
CREATE OR REPLACE FUNCTION fga.check(
  store_id uuid,
  request jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  mid uuid;
  user_s text := request -> 'tuple_key' ->> 'user';
  obj_s text := request -> 'tuple_key' ->> 'object';
  rel text := request -> 'tuple_key' ->> 'relation';
  s record;
  o record;
  sid uuid;
  oid uuid;
  ctx fga._tuple_key[] := '{}';
  tkj jsonb;
  v record;
  r fga._check_result;
BEGIN
  mid := fga._resolve_model(
    store_id, request ->> 'authorization_model_id');

  -- Request-key validation in the measured order (M10).
  SELECT * INTO s FROM fga._parse_subject(user_s);
  IF NOT s.ok THEN
    RAISE EXCEPTION
      'invalid relation: the ''user'' field must be an object '
      '(e.g. document:1) or an ''object#relation'' or a typed '
      'wildcard (e.g. group:*)' USING ERRCODE = 'YF100';
  END IF;
  IF s.subject_relation <> '' AND NOT EXISTS (
    SELECT FROM fga.model_relation mr
    WHERE mr.store = store_id AND mr.model_id = mid
      AND mr.type_name = s.subject_type
      AND mr.relation_name = s.subject_relation
  ) AND EXISTS (
    SELECT FROM fga.model_type mt
    WHERE mt.store = store_id AND mt.model_id = mid
      AND mt.type_name = s.subject_type
  ) THEN
    RAISE EXCEPTION
      'invalid relation: relation ''%#%'' not found',
      s.subject_type, s.subject_relation USING ERRCODE = 'YF100';
  END IF;
  IF NOT EXISTS (
    SELECT FROM fga.model_type mt
    WHERE mt.store = store_id AND mt.model_id = mid
      AND mt.type_name = s.subject_type
  ) THEN
    RAISE EXCEPTION
      'invalid relation: type ''%'' not found', s.subject_type
      USING ERRCODE = 'YF100';
  END IF;

  SELECT * INTO o FROM fga._parse_object(obj_s);
  IF NOT o.ok THEN
    RAISE EXCEPTION
      'invalid relation: invalid ''object'' field format'
      USING ERRCODE = 'YF100';
  END IF;
  IF NOT EXISTS (
    SELECT FROM fga.model_type mt
    WHERE mt.store = store_id AND mt.model_id = mid
      AND mt.type_name = o.object_type
  ) THEN
    RAISE EXCEPTION
      'invalid relation: type ''%'' not found', o.object_type
      USING ERRCODE = 'YF100';
  END IF;
  IF rel IS NULL OR NOT EXISTS (
    SELECT FROM fga.model_relation mr
    WHERE mr.store = store_id AND mr.model_id = mid
      AND mr.type_name = o.object_type
      AND mr.relation_name = rel
  ) THEN
    RAISE EXCEPTION
      'invalid relation: relation ''%#%'' not found',
      o.object_type, coalesce(rel, '') USING ERRCODE = 'YF100';
  END IF;

  -- The id-domain gate (pinned refusing divergence).
  oid := fga._uuid_or_null(o.id_text);
  IF oid IS NULL THEN
    RAISE EXCEPTION
      'invalid object id ''%'': not a canonical uuid '
      '(fga4postgres id domain)', o.id_text
      USING ERRCODE = 'YF100';
  END IF;
  IF s.is_wildcard THEN
    sid := '00000000-0000-0000-0000-000000000000';
  ELSE
    sid := fga._uuid_or_null(s.id_text);
    IF sid IS NULL THEN
      RAISE EXCEPTION
        'invalid user id ''%'': not a canonical uuid '
        '(fga4postgres id domain)', s.id_text
        USING ERRCODE = 'YF100';
    END IF;
  END IF;

  -- Contextual tuples: write-grade validation, refused as
  -- invalid_tuple (M10 step 3).
  FOR tkj IN
    SELECT * FROM jsonb_array_elements(coalesce(
      request -> 'contextual_tuples' -> 'tuple_keys',
      '[]'::jsonb))
  LOOP
    SELECT * INTO v FROM fga._validate_tuple(
      store_id, mid,
      tkj ->> 'object', tkj ->> 'relation', tkj ->> 'user',
      'YF127');
    ctx := ctx || (v.object_type, v.object_id, v.relation,
      v.subject_type, v.subject_id, v.subject_relation,
      tkj -> 'condition' ->> 'name',
      tkj -> 'condition' -> 'context')::fga._tuple_key;
  END LOOP;

  r := fga._check_node(
    store_id, mid,
    o.object_type, oid, rel,
    s.subject_type, sid, s.subject_relation, s.is_wildcard,
    ctx, 0, '{}');

  RETURN jsonb_build_object('allowed', r.allowed);
END;
$$;

-- Batch check (measured contract, M34): at most 50 items and
-- unique correlation ids are request-level refusals; an item's own
-- validation failure is captured per item under its correlation
-- id, never failing the batch. One SQL statement means one
-- snapshot: batch answers are mutually consistent — stronger than
-- upstream's concurrent goroutines, documented as a product
-- property. Identical items (same tuple key, contextual tuples
-- and context) are resolved once.
CREATE OR REPLACE FUNCTION fga.batch_check(
  store_id uuid,
  request jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  items jsonb := coalesce(request -> 'checks', '[]'::jsonb);
  item jsonb;
  corr text;
  dedup_key text;
  results jsonb := '{}'::jsonb;
  memo jsonb := '{}'::jsonb;
  one jsonb;
  err_enum text;
  err_msg text;
  err_state text;
BEGIN
  IF jsonb_array_length(items) > 50 THEN
    RAISE EXCEPTION
      'batchCheck received % checks, the maximum allowed is 50',
      jsonb_array_length(items) USING ERRCODE = 'YF100';
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(items) LOOP
    corr := item ->> 'correlation_id';
    IF results ? corr THEN
      RAISE EXCEPTION 'received duplicate correlation id: %',
        corr USING ERRCODE = 'YF100';
    END IF;

    dedup_key := (item - 'correlation_id')::text;
    one := memo -> dedup_key;
    IF one IS NULL THEN
      BEGIN
        one := jsonb_build_object('allowed',
          (fga.check(store_id, jsonb_build_object(
             'tuple_key', item -> 'tuple_key',
             'contextual_tuples', item -> 'contextual_tuples',
             'context', item -> 'context',
             'authorization_model_id',
             request ->> 'authorization_model_id'
           )) ->> 'allowed')::boolean);
      EXCEPTION WHEN SQLSTATE 'YF000' THEN
        GET STACKED DIAGNOSTICS
          err_state = RETURNED_SQLSTATE,
          err_msg = MESSAGE_TEXT;
        err_enum := CASE err_state
          WHEN 'YF102'
            THEN 'authorization_model_resolution_too_complex'
          WHEN 'YF127' THEN 'invalid_tuple'
          ELSE 'validation_error'
        END;
        one := jsonb_build_object('error', jsonb_build_object(
          'input_error', err_enum, 'message', err_msg));
      END;
      memo := memo || jsonb_build_object(dedup_key, one);
    END IF;
    results := results || jsonb_build_object(corr, one);
  END LOOP;

  RETURN jsonb_build_object('result', results);
END;
$$;

COMMIT;
