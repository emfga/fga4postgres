-- expand: one relation on one object, unrolled a single level
-- into upstream's UsersetTree (shapes measured against the
-- pinned oracle; re-verified by
-- conformance/probe_expand_test.go).
--
-- Expand never evaluates conditions (an unmet-able conditioned
-- tuple still appears) and never recurses: computed
-- usersets and TTU parents come back as references for the
-- caller to expand further. Every error is 2000, including
-- undefined type/relation (unlike check's 2021/2022).
-- Users lists are emitted sorted; the TTU computed list follows
-- write (ulid) order, matching upstream's tuple order; the
-- differential comparison is order-insensitive over both.

BEGIN;

CREATE OR REPLACE FUNCTION fga._expand_node(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  name text,
  ctx fga._tuple_key[],
  rw jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  users jsonb;
  kids jsonb;
BEGIN
  IF rw ? 'this' THEN
    SELECT coalesce(jsonb_agg(u ORDER BY u), '[]'::jsonb)
      INTO users
    FROM (
      SELECT DISTINCT r.subject_type || ':'
        || CASE WHEN r.subject_id =
              '00000000-0000-0000-0000-000000000000'
            AND r.subject_relation = ''
           THEN '*' ELSE r.subject_id::text END
        || CASE WHEN r.subject_relation <> ''
           THEN '#' || r.subject_relation ELSE '' END AS u
      FROM fga._read_all_tuples(
        store_id, model_id, ot, oid, rel, ctx) r
    ) s;
    RETURN jsonb_build_object('name', name, 'leaf',
      jsonb_build_object('users',
        CASE WHEN users = '[]'::jsonb THEN '{}'::jsonb
             ELSE jsonb_build_object('users', users) END));

  ELSIF rw ? 'computed_userset' THEN
    RETURN jsonb_build_object('name', name, 'leaf',
      jsonb_build_object('computed', jsonb_build_object(
        'userset', ot || ':' || oid::text || '#'
          || (rw -> 'computed_userset' ->> 'relation'))));

  ELSIF rw ? 'tuple_to_userset' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'userset', r.subject_type || ':'
          || r.subject_id::text || '#'
          || (rw -> 'tuple_to_userset'
                -> 'computed_userset' ->> 'relation'))),
      '[]'::jsonb)
      INTO kids
    FROM fga._read_tupleset(
      store_id, model_id, ot, oid,
      rw -> 'tuple_to_userset' -> 'tupleset' ->> 'relation',
      ctx) r;
    RETURN jsonb_build_object('name', name, 'leaf',
      jsonb_build_object('tuple_to_userset', jsonb_build_object(
        'tupleset', ot || ':' || oid::text || '#'
          || (rw -> 'tuple_to_userset'
                -> 'tupleset' ->> 'relation'),
        'computed', kids)));

  ELSIF rw ? 'union' OR rw ? 'intersection' THEN
    SELECT jsonb_agg(fga._expand_node(
        store_id, model_id, ot, oid, rel, name, ctx, c))
      INTO kids
    FROM jsonb_array_elements(
      coalesce(rw -> 'union' -> 'child',
               rw -> 'intersection' -> 'child')) c;
    RETURN jsonb_build_object('name', name,
      CASE WHEN rw ? 'union' THEN 'union'
           ELSE 'intersection' END,
      jsonb_build_object('nodes', kids));

  ELSIF rw ? 'difference' THEN
    RETURN jsonb_build_object('name', name, 'difference',
      jsonb_build_object(
        'base', fga._expand_node(store_id, model_id, ot, oid,
          rel, name, ctx, rw -> 'difference' -> 'base'),
        'subtract', fga._expand_node(store_id, model_id, ot,
          oid, rel, name, ctx,
          rw -> 'difference' -> 'subtract')));

  ELSE
    RAISE EXCEPTION
      'fga4postgres: unknown rewrite operator: %', rw;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fga.expand(
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
  obj text := request -> 'tuple_key' ->> 'object';
  rel text := request -> 'tuple_key' ->> 'relation';
  o record;
  oid uuid;
  rw jsonb;
  ctx fga._tuple_key[] := '{}';
  tkj jsonb;
  v record;
  name text;
BEGIN
  mid := fga._resolve_model(
    store_id, request ->> 'authorization_model_id');

  SELECT * INTO o FROM fga._parse_object(obj);
  IF NOT o.ok THEN
    RAISE EXCEPTION 'invalid ''object'' field format'
      USING ERRCODE = 'YF100';
  END IF;
  IF NOT EXISTS (
    SELECT FROM fga.model_type t
    WHERE t.store = store_id AND t.model_id = mid
      AND t.type_name = o.object_type
  ) THEN
    RAISE EXCEPTION 'type ''%'' not found', o.object_type
      USING ERRCODE = 'YF100';
  END IF;
  SELECT r.rewrite INTO rw
  FROM fga.model_relation r
  WHERE r.store = store_id AND r.model_id = mid
    AND r.type_name = o.object_type AND r.relation_name = rel;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'relation ''%#%'' not found',
      o.object_type, rel USING ERRCODE = 'YF100';
  END IF;
  oid := fga._uuid_or_null(o.id_text);
  IF oid IS NULL THEN
    RAISE EXCEPTION
      'invalid object id ''%'': not a canonical uuid '
      '(fga4postgres id domain)', o.id_text
      USING ERRCODE = 'YF100';
  END IF;

  FOR tkj IN
    SELECT * FROM jsonb_array_elements(coalesce(
      request -> 'contextual_tuples' -> 'tuple_keys',
      '[]'::jsonb))
  LOOP
    SELECT * INTO v FROM fga._validate_tuple(
      store_id, mid,
      tkj ->> 'object', tkj ->> 'relation', tkj ->> 'user',
      tkj -> 'condition' ->> 'name',
      'YF127', 'YF127');
    ctx := ctx || (v.object_type, v.object_id, v.relation,
      v.subject_type, v.subject_id, v.subject_relation,
      tkj -> 'condition' ->> 'name',
      tkj -> 'condition' -> 'context')::fga._tuple_key;
  END LOOP;

  name := o.object_type || ':' || oid::text || '#' || rel;
  RETURN jsonb_build_object('tree', jsonb_build_object(
    'root', fga._expand_node(
      store_id, mid, o.object_type, oid, rel, name, ctx, rw)));
END;
$$;

COMMIT;
