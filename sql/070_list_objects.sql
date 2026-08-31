-- list_objects: reverse expansion (workspace decision 4), as an
-- iterative BFS over userset nodes with a global seen-set.
--
-- Measured contract (measurements.md):
--   M21: reverse expansion NEVER charges tuple-hop depth at the
--        pin — 40- and 100-link chains return complete results
--        while a forward check on the same chain raises 2002.
--        That upstream-internal inconsistency is mirrored, not
--        repaired: the BFS terminates on dedup alone and raises
--        no too-complex error. (No corpus list_objects case
--        asserts 2002.)
--   M37: validation order — contextual tuples (invalid_tuple),
--        then target type (type_not_found 2021), then target
--        relation (relation_not_found 2022), then the subject
--        (validation_error 2000).
--   M07: per-row conditions evaluate during expansion with the
--        merged context; condition errors are collected per
--        candidate and raised only when the result count stays
--        below the 1000 cap (upstream's scoping, doc 04 §5) —
--        otherwise tolerated.
--
-- Candidates whose path crossed a relation containing
-- intersection or difference carry a sticky taint and are
-- confirmed by the forward resolver with a fresh budget; the
-- forward check validates the entire path, so optimistic
-- expansion through such relations is sound.

BEGIN;

DO $$
BEGIN
  CREATE TYPE fga._lo_node AS (
    ntype text,
    nid uuid,
    nrel text,   -- '' = plain object / wildcard value node
    tainted boolean
  );
EXCEPTION WHEN duplicate_object THEN
  NULL;
END;
$$;

DO $$
BEGIN
  CREATE TYPE fga._lo_cand AS (
    ntype text,
    nid uuid,
    nrel text,
    tainted boolean,
    cond_name text,
    cond_ctx jsonb
  );
EXCEPTION WHEN duplicate_object THEN
  NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fga.list_objects(
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
  target_type text := request ->> 'type';
  target_rel text := request ->> 'relation';
  user_s text := request ->> 'user';
  req_ctx jsonb := request -> 'context';
  s record;
  sid uuid;
  ctx fga._tuple_key[] := '{}';
  tkj jsonb;
  v record;
  frontier fga._lo_node[];
  next_frontier fga._lo_node[];
  cands fga._lo_cand[];
  seen text[] := '{}';
  found uuid[] := '{}';
  clear_ids uuid[] := '{}';
  tainted_ids uuid[] := '{}';
  err_count integer := 0;
  first_err text;
  level_errs integer;
  level_first text;
  r fga._check_result;
  cid uuid;
  chk_state text;
  chk_msg text;
  objects text[] := '{}';
BEGIN
  mid := fga._resolve_model(
    store_id, request ->> 'authorization_model_id');

  -- Validation, in the measured order (M37).
  FOR tkj IN
    SELECT * FROM jsonb_array_elements(coalesce(
      request -> 'contextual_tuples' -> 'tuple_keys',
      '[]'::jsonb))
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

  SELECT * INTO s FROM fga._parse_subject(user_s);
  IF NOT s.ok THEN
    RAISE EXCEPTION
      'invalid ''user'' value: the ''user'' field must be an '
      'object (e.g. document:1) or an ''object#relation'' or a '
      'typed wildcard (e.g. group:*)' USING ERRCODE = 'YF100';
  END IF;
  IF NOT EXISTS (
    SELECT FROM fga.model_type mt
    WHERE mt.store = store_id AND mt.model_id = mid
      AND mt.type_name = s.subject_type
  ) THEN
    RAISE EXCEPTION 'invalid ''user'' value: type ''%'' not '
      'found', s.subject_type USING ERRCODE = 'YF100';
  END IF;
  IF s.subject_relation <> '' AND NOT EXISTS (
    SELECT FROM fga.model_relation mr
    WHERE mr.store = store_id AND mr.model_id = mid
      AND mr.type_name = s.subject_type
      AND mr.relation_name = s.subject_relation
  ) THEN
    RAISE EXCEPTION 'invalid ''user'' value: relation ''%#%'' '
      'not found', s.subject_type, s.subject_relation
      USING ERRCODE = 'YF100';
  END IF;
  IF s.is_wildcard THEN
    sid := '00000000-0000-0000-0000-000000000000';
  ELSE
    sid := fga._uuid_or_null(s.id_text);
    IF sid IS NULL THEN
      RAISE EXCEPTION
        'invalid ''user'' value: id ''%'' is not a canonical '
        'uuid (fga4postgres id domain)', s.id_text
        USING ERRCODE = 'YF100';
    END IF;
  END IF;

  -- Seeds: the subject node, plus the typed-wildcard value node
  -- for plain-object subjects (a wildcard subject IS the wildcard
  -- node; a userset subject is never wildcard-matched).
  frontier := ARRAY[(s.subject_type, sid, s.subject_relation,
                     false)::fga._lo_node];
  IF s.subject_relation = '' AND NOT s.is_wildcard THEN
    frontier := frontier || (s.subject_type,
      '00000000-0000-0000-0000-000000000000'::uuid, '',
      false)::fga._lo_node;
  END IF;

  -- The seed itself can be the self-defining result.
  IF s.subject_relation <> '' AND s.subject_type = target_type
     AND s.subject_relation = target_rel THEN
    clear_ids := clear_ids || sid;
    found := found || sid;
  END IF;

  WHILE coalesce(array_length(frontier, 1), 0) > 0
        AND coalesce(array_length(found, 1), 0) < 1000
  LOOP
    seen := seen || (
      SELECT coalesce(array_agg(
        f.ntype || ':' || f.nid || '#' || f.nrel
          || CASE WHEN f.tainted THEN '@t' ELSE '@f' END), '{}')
      FROM unnest(frontier) f);

    -- Discover candidate nodes with their row conditions.
    WITH f AS (SELECT * FROM unnest(frontier) AS f),

    direct_new AS (
      SELECT tr.type_name, t.object_id, tr.relation_name,
             f.tainted OR mr.needs_check AS tainted,
             t.cond_name, t.cond_ctx
      FROM f
      JOIN fga.model_type_restriction tr
        ON tr.store = store_id AND tr.model_id = mid
       AND tr.subject_type = f.ntype
       AND tr.subject_relation = f.nrel
       AND tr.is_wildcard
             = (f.nid = '00000000-0000-0000-0000-000000000000'
                AND f.nrel = '')
      JOIN fga.model_relation mr
        ON mr.store = store_id AND mr.model_id = mid
       AND mr.type_name = tr.type_name
       AND mr.relation_name = tr.relation_name
      JOIN LATERAL (
        SELECT t.object_id, t.condition_name AS cond_name,
               t.condition_context AS cond_ctx
        FROM fga.tuple t
        WHERE t.store = store_id
          AND t.subject_type = f.ntype
          AND t.subject_id = f.nid
          AND t.subject_relation = f.nrel
          AND t.relation = tr.relation_name
          AND t.object_type = tr.type_name
          AND tr.condition_name
                = coalesce(t.condition_name, '')
        UNION ALL
        SELECT c.object_id, c.condition_name,
               c.condition_context
        FROM unnest(ctx) c
        WHERE c.subject_type = f.ntype
          AND c.subject_id = f.nid
          AND c.subject_relation = f.nrel
          AND c.relation = tr.relation_name
          AND c.object_type = tr.type_name
          AND tr.condition_name
                = coalesce(c.condition_name, '')
      ) t ON true
    ),

    computed_new AS (
      SELECT mc.type_name, f.nid AS object_id, mc.relation_name,
             f.tainted OR mr.needs_check AS tainted,
             NULL::text AS cond_name, NULL::jsonb AS cond_ctx
      FROM f
      JOIN fga.model_computed mc
        ON mc.store = store_id AND mc.model_id = mid
       AND mc.type_name = f.ntype
       AND mc.computed_relation = f.nrel
      JOIN fga.model_relation mr
        ON mr.store = store_id AND mr.model_id = mid
       AND mr.type_name = mc.type_name
       AND mr.relation_name = mc.relation_name
      WHERE f.nrel <> ''
    ),

    ttu_new AS (
      SELECT mt.type_name, t.object_id, mt.relation_name,
             f.tainted OR mr.needs_check AS tainted,
             t.cond_name, t.cond_ctx
      FROM f
      JOIN fga.model_ttu mt
        ON mt.store = store_id AND mt.model_id = mid
       AND mt.computed_relation = f.nrel
      JOIN fga.model_relation mr
        ON mr.store = store_id AND mr.model_id = mid
       AND mr.type_name = mt.type_name
       AND mr.relation_name = mt.relation_name
      JOIN LATERAL (
        SELECT t.object_id, t.condition_name AS cond_name,
               t.condition_context AS cond_ctx
        FROM fga.tuple t
        WHERE t.store = store_id
          AND t.subject_type = f.ntype
          AND t.subject_id = f.nid
          AND t.subject_relation = ''
          AND t.relation = mt.tupleset_relation
          AND t.object_type = mt.type_name
          AND EXISTS (
            SELECT FROM fga.model_type_restriction tr
            WHERE tr.store = store_id AND tr.model_id = mid
              AND tr.type_name = mt.type_name
              AND tr.relation_name = mt.tupleset_relation
              AND tr.subject_type = f.ntype
              AND tr.subject_relation = ''
              AND NOT tr.is_wildcard
              AND tr.condition_name
                    = coalesce(t.condition_name, '')
          )
        UNION ALL
        SELECT c.object_id, c.condition_name,
               c.condition_context
        FROM unnest(ctx) c
        WHERE c.subject_type = f.ntype
          AND c.subject_id = f.nid
          AND c.subject_relation = ''
          AND c.relation = mt.tupleset_relation
          AND c.object_type = mt.type_name
      ) t ON true
      WHERE f.nrel <> ''
    )

    SELECT coalesce(array_agg(DISTINCT
      (u.type_name, u.object_id, u.relation_name, u.tainted,
       u.cond_name, u.cond_ctx)::fga._lo_cand), '{}')
    INTO cands
    FROM (
      SELECT * FROM direct_new
      UNION ALL SELECT * FROM computed_new
      UNION ALL SELECT * FROM ttu_new
    ) AS u(type_name, object_id, relation_name, tainted,
           cond_name, cond_ctx)
    -- Target pruning: upstream's reverse expansion only walks
    -- the subgraph between the user and the target relation
    -- (M40 — edges that cannot lead to the target are never
    -- read, so their conditions never evaluate, let alone
    -- error). A candidate node survives if it IS the target or
    -- the target can grant through it.
    WHERE (u.type_name = target_type
           AND u.relation_name = target_rel)
       OR EXISTS (
        SELECT FROM fga.model_reachable mr
        WHERE mr.store = store_id AND mr.model_id = mid
          AND mr.type_name = target_type
          AND mr.relation_name = target_rel
          AND mr.subject_type = u.type_name
          AND mr.subject_relation = u.relation_name
      );

    -- Evaluate row conditions; collect per-candidate errors with
    -- upstream's scoping (raised later only if results stay under
    -- the cap).
    SELECT
      coalesce(array_agg(
        (c.ntype, c.nid, c.nrel, c.tainted)::fga._lo_node)
        FILTER (WHERE coalesce(c.cond_name, '') = ''
                      OR ev.met), '{}'),
      count(*) FILTER (WHERE ev.err IS NOT NULL),
      min(ev.err) FILTER (WHERE ev.err IS NOT NULL)
    INTO next_frontier, level_errs, level_first
    FROM unnest(cands) c
    LEFT JOIN LATERAL fga._eval_condition(
      store_id, mid, c.cond_name, c.cond_ctx, req_ctx) ev
      ON coalesce(c.cond_name, '') <> ''
    WHERE NOT (
      c.ntype || ':' || c.nid || '#' || c.nrel
        || CASE WHEN c.tainted THEN '@t' ELSE '@f' END
    ) = ANY (seen);

    err_count := err_count + coalesce(level_errs, 0);
    first_err := coalesce(first_err, level_first);

    SELECT coalesce(array_agg(DISTINCT nn.nid), '{}')
    INTO clear_ids
    FROM (
      SELECT unnest(clear_ids) AS nid
      UNION
      SELECT nn.nid
      FROM unnest(next_frontier) nn
      WHERE nn.ntype = target_type AND nn.nrel = target_rel
        AND NOT nn.tainted
    ) nn;
    SELECT coalesce(array_agg(DISTINCT nn.nid), '{}')
    INTO tainted_ids
    FROM (
      SELECT unnest(tainted_ids) AS nid
      UNION
      SELECT nn.nid
      FROM unnest(next_frontier) nn
      WHERE nn.ntype = target_type AND nn.nrel = target_rel
        AND nn.tainted
    ) nn;
    SELECT coalesce(array_agg(DISTINCT x), '{}') INTO found
    FROM unnest(clear_ids || tainted_ids) x;

    frontier := next_frontier;
  END LOOP;

  -- Confirm tainted candidates with the forward resolver, fresh
  -- budget each; a refusal there joins the per-candidate error
  -- pool under the same scoping.
  FOREACH cid IN ARRAY tainted_ids LOOP
    CONTINUE WHEN cid = ANY (clear_ids);
    BEGIN
      r := fga._check_node(
        store_id, mid, target_type, cid, target_rel,
        s.subject_type, sid, s.subject_relation, s.is_wildcard,
        ctx, req_ctx, 0, '{}');
      IF r.allowed THEN
        clear_ids := clear_ids || cid;
      END IF;
    EXCEPTION WHEN SQLSTATE 'YF000' THEN
      GET STACKED DIAGNOSTICS
        chk_state = RETURNED_SQLSTATE, chk_msg = MESSAGE_TEXT;
      err_count := err_count + 1;
      first_err := coalesce(first_err, chk_msg);
    END;
  END LOOP;

  IF err_count > 0
     AND coalesce(array_length(clear_ids, 1), 0) < 1000 THEN
    RAISE EXCEPTION '%', first_err USING ERRCODE = 'YF100';
  END IF;

  SELECT coalesce(array_agg(
    target_type || ':' || x.id), '{}')
  INTO objects
  FROM (
    SELECT DISTINCT unnest(clear_ids) AS id LIMIT 1000
  ) x;

  RETURN jsonb_build_object('objects',
    to_jsonb(objects));
END;
$$;

COMMIT;
