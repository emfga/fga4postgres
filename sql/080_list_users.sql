-- list_users: forward recursive expansion from object#relation,
-- collecting every user matching the single filter.
--
-- Measured contract (measurements.md M17/M18/M23/M24, probe
-- TestProbeM17To24ListUsers, corpus differentials):
--   - exactly one user filter (arity is proto-enforced; the
--     adapter's generated validators reproduce it);
--   - EVERY expansion node whose (type, relation) matches a
--     userset filter emits itself (the reflexive rule, and how
--     sub-relation usersets like document:a#viewer surface under
--     document#can_view);
--   - wildcard algebra needs exceptions: a set is
--     (plus, wild, minus) = concrete members, everyone-flag, and
--     the members excluded from 'everyone'. This is upstream's
--     NoRelationship double-negation dance: user:* minus user:bob
--     stays user:* (bob hidden in minus, never emitted), a
--     wildcard subtrahend empties the result, and
--     (* but not (* but not {c})) yields exactly {c};
--   - a condition evaluation error fails the request immediately
--     (2000) — never dropped for a granting sibling (unlike
--     check) and never tolerated by result count (unlike
--     list_objects);
--   - depth: the userset ladder errors at 25 links where check
--     errors at 26 — list_users charges one hop more; cycles
--     yield nothing (fail-closed).

BEGIN;

DO $$
BEGIN
  -- uid = nil uuid and urel = '' means the typed wildcard;
  -- urel <> '' means a userset user.
  CREATE TYPE fga._lu_user AS (
    utype text,
    uid uuid,
    urel text
  );
EXCEPTION WHEN duplicate_object THEN
  NULL;
END;
$$;

DO $$
BEGIN
  CREATE TYPE fga._lu_set AS (
    plus fga._lu_user[],
    wild boolean,
    minus fga._lu_user[]
  );
EXCEPTION WHEN duplicate_object THEN
  NULL;
END;
$$;

-- Drop evolving internal signatures (see 050 for why).
DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'fga'
      AND p.proname IN ('_lu_expand', '_lu_node')
  LOOP
    EXECUTE 'DROP FUNCTION ' || f.sig;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION fga._lu_member(
  s fga._lu_set, x fga._lu_user
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT CASE
    WHEN x = ANY (s.plus) THEN true
    WHEN s.wild THEN NOT x = ANY (s.minus)
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION fga._lu_union(
  a fga._lu_set, b fga._lu_set
)
RETURNS fga._lu_set
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  plus fga._lu_user[];
  minus fga._lu_user[] := '{}';
BEGIN
  SELECT coalesce(array_agg(DISTINCT u), '{}') INTO plus
  FROM unnest(a.plus || b.plus) u;
  IF a.wild AND b.wild THEN
    SELECT coalesce(array_agg(m), '{}') INTO minus
    FROM unnest(a.minus) m
    WHERE m = ANY (b.minus) AND NOT m = ANY (plus);
  ELSIF a.wild THEN
    SELECT coalesce(array_agg(m), '{}') INTO minus
    FROM unnest(a.minus) m WHERE NOT m = ANY (plus);
  ELSIF b.wild THEN
    SELECT coalesce(array_agg(m), '{}') INTO minus
    FROM unnest(b.minus) m WHERE NOT m = ANY (plus);
  END IF;
  RETURN (plus, a.wild OR b.wild, minus)::fga._lu_set;
END;
$$;

CREATE OR REPLACE FUNCTION fga._lu_intersect(
  a fga._lu_set, b fga._lu_set
)
RETURNS fga._lu_set
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  plus fga._lu_user[];
  minus fga._lu_user[] := '{}';
  wild boolean := a.wild AND b.wild;
BEGIN
  SELECT coalesce(array_agg(DISTINCT u), '{}') INTO plus
  FROM (
    SELECT u FROM unnest(a.plus) u WHERE fga._lu_member(b, u)
    UNION
    SELECT u FROM unnest(b.plus) u WHERE fga._lu_member(a, u)
  ) s(u);
  IF wild THEN
    SELECT coalesce(array_agg(DISTINCT m), '{}') INTO minus
    FROM unnest(a.minus || b.minus) m
    WHERE NOT m = ANY (plus);
  END IF;
  RETURN (plus, wild, minus)::fga._lu_set;
END;
$$;

CREATE OR REPLACE FUNCTION fga._lu_subtract(
  a fga._lu_set, b fga._lu_set
)
RETURNS fga._lu_set
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  plus fga._lu_user[];
  minus fga._lu_user[] := '{}';
  wild boolean := a.wild AND NOT b.wild;
BEGIN
  SELECT coalesce(array_agg(DISTINCT u), '{}') INTO plus
  FROM (
    SELECT u FROM unnest(a.plus) u
    WHERE NOT fga._lu_member(b, u)
    UNION
    -- The double negation: when both sides are wildcards, the
    -- subtrahend's exceptions are exactly who remains.
    SELECT m FROM unnest(b.minus) m
    WHERE a.wild AND b.wild AND fga._lu_member(a, m)
  ) s(u);
  IF wild THEN
    SELECT coalesce(array_agg(DISTINCT m), '{}') INTO minus
    FROM unnest(a.minus || b.plus) m
    WHERE NOT m = ANY (plus);
  END IF;
  RETURN (plus, wild, minus)::fga._lu_set;
END;
$$;

-- Can expanding (t, r) ever produce a user matching the filter?
-- Upstream prunes irrelevant paths before touching their tuples —
-- a condition error on a path that cannot reach the filter type
-- is never surfaced (imported matrix
-- assertion_list_users_no_path_to_employee).
CREATE OR REPLACE FUNCTION fga._lu_reachable(
  store_id uuid, model_id uuid,
  t text, r text,
  f_type text, f_rel text
)
RETURNS boolean
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT (f_rel <> '' AND t = f_type AND r = f_rel)
    OR EXISTS (
      SELECT FROM fga.model_reachable mr
      WHERE mr.store = store_id AND mr.model_id = model_id
        AND mr.type_name = t AND mr.relation_name = r
        AND mr.subject_type = f_type
        AND mr.subject_relation = f_rel
    );
$$;

CREATE OR REPLACE FUNCTION fga._lu_expand(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  f_type text, f_rel text,
  ctx fga._tuple_key[],
  req_ctx jsonb,
  depth integer,
  visited text[],
  rw jsonb
)
RETURNS fga._lu_set
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  acc fga._lu_set := ('{}', false, '{}')::fga._lu_set;
  child jsonb;
  child_set fga._lu_set;
  first boolean := true;
  row record;
  ev record;
BEGIN
  IF rw ? 'this' THEN
    FOR row IN
      SELECT * FROM fga._read_all_tuples(
        store_id, model_id, ot, oid, rel, ctx)
    LOOP
      -- Relevance (path pruning) precedes condition evaluation:
      -- a tuple that cannot lead to a filter match is never
      -- touched, so its condition never errors.
      IF row.subject_relation <> '' THEN
        CONTINUE WHEN NOT fga._lu_reachable(
          store_id, model_id,
          row.subject_type, row.subject_relation,
          f_type, f_rel);
      ELSIF NOT (row.subject_type = f_type AND f_rel = '') THEN
        CONTINUE;
      END IF;

      IF coalesce(row.condition_name, '') <> '' THEN
        SELECT * INTO ev FROM fga._eval_condition(
          store_id, model_id, row.condition_name,
          row.condition_context, req_ctx);
        IF ev.err IS NOT NULL THEN
          RAISE EXCEPTION '%', ev.err USING ERRCODE = 'YF100';
        END IF;
        CONTINUE WHEN NOT ev.met;
      END IF;

      IF row.subject_relation <> '' THEN
        -- Expand for transitive members; the node itself emits
        -- inside _lu_node when it matches the filter.
        acc := fga._lu_union(acc, fga._lu_node(
          store_id, model_id,
          row.subject_type, row.subject_id,
          row.subject_relation,
          f_type, f_rel, ctx, req_ctx, depth, visited));
      ELSIF row.subject_id
              = '00000000-0000-0000-0000-000000000000' THEN
        acc.wild := true;
      ELSE
        acc := fga._lu_union(acc, (
          ARRAY[(row.subject_type, row.subject_id,
                 '')::fga._lu_user],
          false, '{}')::fga._lu_set);
      END IF;
    END LOOP;
    RETURN acc;

  ELSIF rw ? 'computed_userset' THEN
    RETURN fga._lu_node(
      store_id, model_id,
      ot, oid, rw -> 'computed_userset' ->> 'relation',
      f_type, f_rel, ctx, req_ctx, depth - 1, visited);

  ELSIF rw ? 'union' THEN
    FOR child IN
      SELECT * FROM jsonb_array_elements(rw -> 'union' -> 'child')
    LOOP
      acc := fga._lu_union(acc, fga._lu_expand(
        store_id, model_id, ot, oid, rel,
        f_type, f_rel, ctx, req_ctx, depth, visited, child));
    END LOOP;
    RETURN acc;

  ELSIF rw ? 'intersection' THEN
    FOR child IN
      SELECT * FROM jsonb_array_elements(
        rw -> 'intersection' -> 'child')
    LOOP
      child_set := fga._lu_expand(
        store_id, model_id, ot, oid, rel,
        f_type, f_rel, ctx, req_ctx, depth, visited, child);
      IF first THEN
        acc := child_set;
        first := false;
      ELSE
        acc := fga._lu_intersect(acc, child_set);
      END IF;
    END LOOP;
    RETURN acc;

  ELSIF rw ? 'difference' THEN
    RETURN fga._lu_subtract(
      fga._lu_expand(
        store_id, model_id, ot, oid, rel,
        f_type, f_rel, ctx, req_ctx, depth, visited,
        rw -> 'difference' -> 'base'),
      fga._lu_expand(
        store_id, model_id, ot, oid, rel,
        f_type, f_rel, ctx, req_ctx, depth, visited,
        rw -> 'difference' -> 'subtract'));

  ELSIF rw ? 'tuple_to_userset' THEN
    FOR row IN
      SELECT * FROM fga._read_tupleset(
        store_id, model_id, ot, oid,
        rw -> 'tuple_to_userset' -> 'tupleset' ->> 'relation',
        ctx)
    LOOP
      IF NOT EXISTS (
        SELECT FROM fga.model_relation mr
        WHERE mr.store = store_id
          AND mr.model_id = _lu_expand.model_id
          AND mr.type_name = row.subject_type
          AND mr.relation_name
                = rw -> 'tuple_to_userset'
                    -> 'computed_userset' ->> 'relation'
      ) THEN
        CONTINUE;
      END IF;
      CONTINUE WHEN NOT fga._lu_reachable(
        store_id, model_id,
        row.subject_type,
        rw -> 'tuple_to_userset'
          -> 'computed_userset' ->> 'relation',
        f_type, f_rel);
      IF coalesce(row.condition_name, '') <> '' THEN
        SELECT * INTO ev FROM fga._eval_condition(
          store_id, model_id, row.condition_name,
          row.condition_context, req_ctx);
        IF ev.err IS NOT NULL THEN
          RAISE EXCEPTION '%', ev.err USING ERRCODE = 'YF100';
        END IF;
        CONTINUE WHEN NOT ev.met;
      END IF;
      acc := fga._lu_union(acc, fga._lu_node(
        store_id, model_id,
        row.subject_type, row.subject_id,
        rw -> 'tuple_to_userset'
          -> 'computed_userset' ->> 'relation',
        f_type, f_rel, ctx, req_ctx, depth, visited));
    END LOOP;
    RETURN acc;

  ELSE
    RAISE EXCEPTION
      'fga4postgres: unknown rewrite operator: %', rw;
  END IF;
END;
$$;

-- One expansion node: cycle guard (yields nothing, fail-closed),
-- depth charge per hop (the 25th link refuses), the reflexive
-- filter-match emission, rewrite lookup, dispatch.
CREATE OR REPLACE FUNCTION fga._lu_node(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  f_type text, f_rel text,
  ctx fga._tuple_key[],
  req_ctx jsonb,
  depth integer,
  visited text[]
)
RETURNS fga._lu_set
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  node_key text := ot || ':' || oid::text || '#' || rel;
  rw jsonb;
  acc fga._lu_set;
BEGIN
  IF node_key = ANY (visited) THEN
    RETURN ('{}', false, '{}')::fga._lu_set;
  END IF;
  IF depth >= 24 THEN
    RAISE EXCEPTION 'resolution too complex: depth exceeded'
      USING ERRCODE = 'YF102';
  END IF;

  SELECT r.rewrite INTO rw
  FROM fga.model_relation r
  WHERE r.store = store_id AND r.model_id = _lu_node.model_id
    AND r.type_name = ot AND r.relation_name = rel;
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'relation ''%#%'' not found', ot, rel
      USING ERRCODE = 'YF100';
  END IF;

  acc := fga._lu_expand(
    store_id, model_id, ot, oid, rel, f_type, f_rel,
    ctx, req_ctx, depth + 1, visited || node_key, rw);

  -- Reflexive emission: this node itself matches a userset
  -- filter.
  IF f_rel <> '' AND ot = f_type AND rel = f_rel THEN
    acc := fga._lu_union(acc, (
      ARRAY[(ot, oid, rel)::fga._lu_user],
      false, '{}')::fga._lu_set);
  END IF;
  RETURN acc;
END;
$$;

CREATE OR REPLACE FUNCTION fga.list_users(
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
  target_type text := request -> 'object' ->> 'type';
  target_id_text text := request -> 'object' ->> 'id';
  target_rel text := request ->> 'relation';
  f_type text := request -> 'user_filters' -> 0 ->> 'type';
  f_rel text := coalesce(
    request -> 'user_filters' -> 0 ->> 'relation', '');
  req_ctx jsonb := request -> 'context';
  oid uuid;
  ctx fga._tuple_key[] := '{}';
  tkj jsonb;
  v record;
  uset fga._lu_set;
  users fga._lu_user[];
  result jsonb;
BEGIN
  mid := fga._resolve_model(
    store_id, request ->> 'authorization_model_id');

  -- ListUsersRequest carries contextual_tuples as a flat array,
  -- unlike the other APIs' wrapped tuple_keys.
  FOR tkj IN
    SELECT * FROM jsonb_array_elements(coalesce(
      request -> 'contextual_tuples', '[]'::jsonb))
  LOOP
    SELECT * INTO v FROM fga._validate_tuple(
      store_id, mid,
      tkj ->> 'object', tkj ->> 'relation', tkj ->> 'user',
      tkj -> 'condition' ->> 'name',
      'YF127', 'YF100');
    ctx := ctx || (v.object_type, v.object_id, v.relation,
      v.subject_type, v.subject_id, v.subject_relation,
      tkj -> 'condition' ->> 'name',
      tkj -> 'condition' -> 'context')::fga._tuple_key;
  END LOOP;

  IF NOT EXISTS (
    SELECT FROM fga.model_type mt
    WHERE mt.store = store_id AND mt.model_id = mid
      AND mt.type_name = target_type
  ) THEN
    RAISE EXCEPTION 'type ''%'' not found', target_type
      USING ERRCODE = 'YF121';
  END IF;
  IF NOT EXISTS (
    SELECT FROM fga.model_relation mr
    WHERE mr.store = store_id AND mr.model_id = mid
      AND mr.type_name = target_type
      AND mr.relation_name = target_rel
  ) THEN
    RAISE EXCEPTION 'relation ''%#%'' not found',
      target_type, target_rel USING ERRCODE = 'YF122';
  END IF;
  IF NOT EXISTS (
    SELECT FROM fga.model_type mt
    WHERE mt.store = store_id AND mt.model_id = mid
      AND mt.type_name = f_type
  ) THEN
    RAISE EXCEPTION 'type ''%'' not found', f_type
      USING ERRCODE = 'YF121';
  END IF;
  IF f_rel <> '' AND NOT EXISTS (
    SELECT FROM fga.model_relation mr
    WHERE mr.store = store_id AND mr.model_id = mid
      AND mr.type_name = f_type
      AND mr.relation_name = f_rel
  ) THEN
    RAISE EXCEPTION 'relation ''%#%'' not found',
      f_type, f_rel USING ERRCODE = 'YF122';
  END IF;

  oid := fga._uuid_or_null(target_id_text);
  IF oid IS NULL THEN
    RAISE EXCEPTION
      'invalid object id ''%'': not a canonical uuid '
      '(fga4postgres id domain)', target_id_text
      USING ERRCODE = 'YF100';
  END IF;

  uset := fga._lu_node(
    store_id, mid, target_type, oid, target_rel,
    f_type, f_rel, ctx, req_ctx, -1, '{}');

  users := uset.plus;
  IF uset.wild THEN
    users := users || (f_type,
      '00000000-0000-0000-0000-000000000000'::uuid,
      '')::fga._lu_user;
  END IF;

  SELECT coalesce(jsonb_agg(u), '[]'::jsonb) INTO result
  FROM (
    SELECT DISTINCT
      CASE
        WHEN x.uid = '00000000-0000-0000-0000-000000000000'
             AND x.urel = '' THEN
          jsonb_build_object('wildcard',
            jsonb_build_object('type', x.utype))
        WHEN x.urel <> '' THEN
          jsonb_build_object('userset', jsonb_build_object(
            'type', x.utype, 'id', x.uid::text,
            'relation', x.urel))
        ELSE
          jsonb_build_object('object', jsonb_build_object(
            'type', x.utype, 'id', x.uid::text))
      END AS u
    FROM unnest(users) x
    LIMIT 1000
  ) s;

  RETURN jsonb_build_object('users', result);
END;
$$;

-- Iterator over ALL rows of one object#relation (plain, wildcard
-- and userset subjects alike), overlay-concatenated and
-- model-validity filtered — the read list_users expansion needs.
CREATE OR REPLACE FUNCTION fga._read_all_tuples(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  ctx fga._tuple_key[]
)
RETURNS TABLE (subject_type text, subject_id uuid,
               subject_relation text,
               condition_name text, condition_context jsonb)
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT c.subject_type, c.subject_id, c.subject_relation,
         c.condition_name, c.condition_context
  FROM unnest(ctx) c
  WHERE c.object_type = ot AND c.object_id = oid
    AND c.relation = rel
  UNION ALL
  SELECT t.subject_type, t.subject_id, t.subject_relation,
         t.condition_name, t.condition_context
  FROM fga.tuple t
  WHERE t.store = store_id
    AND t.object_type = ot AND t.object_id = oid
    AND t.relation = rel
    AND EXISTS (
      SELECT FROM fga.model_type_restriction tr
      WHERE tr.store = store_id
        AND tr.model_id = _read_all_tuples.model_id
        AND tr.type_name = ot AND tr.relation_name = rel
        AND tr.subject_type = t.subject_type
        AND tr.subject_relation = t.subject_relation
        AND tr.is_wildcard
              = (t.subject_id
                   = '00000000-0000-0000-0000-000000000000'
                 AND t.subject_relation = '')
        AND tr.condition_name = coalesce(t.condition_name, '')
    );
$$;

COMMIT;
