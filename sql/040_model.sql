-- Authorization model storage.
--
-- write_authorization_model stores the verbatim upstream JSON
-- (snake_case protojson, the shape upstream's own HTTP API serves)
-- keyed by an immutable uuidv7 model id, and derives the
-- normalized rows the resolver reads. Models are immutable and
-- versioned: old models stay queryable, checks may pin a model id,
-- defaulting to the store's latest (CLAUDE.md decision 3).
--
-- Refusal-side model validation (the CONFIG-* matrix) arrives in
-- plan phase 6; the corpus models this phase replays are pre-gated
-- by upstream's own modelgraph, so normalization is the contract
-- here, not validation.

BEGIN;

-- The id-domain gate (workspace decisions 1-3): every id the API
-- accepts must be a canonical lower-case hyphenated uuid, and the
-- nil uuid is reserved as the wildcard sentinel. Everything else
-- returns NULL; callers raise their own error code, because the
-- right code depends on where the id appeared (request key,
-- contextual tuple, write, model id).
CREATE OR REPLACE FUNCTION fga._uuid_or_null(id text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT CASE
    WHEN id ~ ('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-'
               || '[0-9a-f]{4}-[0-9a-f]{12}$')
     AND id <> '00000000-0000-0000-0000-000000000000'
    THEN id::uuid
  END;
$$;

CREATE TABLE IF NOT EXISTS fga.model (
  store uuid NOT NULL,
  id uuid NOT NULL DEFAULT uuidv7(),
  schema_version text NOT NULL,
  model jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store, id)
);

CREATE TABLE IF NOT EXISTS fga.model_type (
  store uuid NOT NULL,
  model_id uuid NOT NULL,
  type_name text NOT NULL,
  PRIMARY KEY (store, model_id, type_name)
);

CREATE TABLE IF NOT EXISTS fga.model_relation (
  store uuid NOT NULL,
  model_id uuid NOT NULL,
  type_name text NOT NULL,
  relation_name text NOT NULL,
  rewrite jsonb NOT NULL,
  is_assignable boolean NOT NULL,
  -- The rewrite tree contains intersection or difference, so a
  -- reverse-expansion candidate arriving at this relation needs a
  -- forward check (plan §1.5).
  needs_check boolean NOT NULL DEFAULT false,
  PRIMARY KEY (store, model_id, type_name, relation_name)
);

ALTER TABLE fga.model_relation
  ADD COLUMN IF NOT EXISTS needs_check boolean
  NOT NULL DEFAULT false;

-- Reverse computed-userset edges: relation_name grants to anyone
-- holding computed_relation on the same object.
CREATE TABLE IF NOT EXISTS fga.model_computed (
  store uuid NOT NULL,
  model_id uuid NOT NULL,
  type_name text NOT NULL,
  relation_name text NOT NULL,
  computed_relation text NOT NULL,
  PRIMARY KEY (store, model_id, type_name, relation_name,
               computed_relation)
);

-- One row per entry of directly_related_user_types, in model
-- order. subject_relation '' means a plain object subject;
-- is_wildcard marks the type:* form; condition_name '' means
-- unconditioned.
CREATE TABLE IF NOT EXISTS fga.model_type_restriction (
  store uuid NOT NULL,
  model_id uuid NOT NULL,
  type_name text NOT NULL,
  relation_name text NOT NULL,
  ord integer NOT NULL,
  subject_type text NOT NULL,
  subject_relation text NOT NULL DEFAULT '',
  is_wildcard boolean NOT NULL DEFAULT false,
  condition_name text NOT NULL DEFAULT '',
  PRIMARY KEY (store, model_id, type_name, relation_name, ord)
);

CREATE TABLE IF NOT EXISTS fga.model_ttu (
  store uuid NOT NULL,
  model_id uuid NOT NULL,
  type_name text NOT NULL,
  relation_name text NOT NULL,
  tupleset_relation text NOT NULL,
  computed_relation text NOT NULL,
  PRIMARY KEY (store, model_id, type_name, relation_name,
               tupleset_relation, computed_relation)
);

CREATE TABLE IF NOT EXISTS fga.model_condition (
  store uuid NOT NULL,
  model_id uuid NOT NULL,
  name text NOT NULL,
  expression text NOT NULL,
  parameters jsonb,
  compiled_ast jsonb,
  PRIMARY KEY (store, model_id, name)
);

-- The precomputed PathExists prune (plan §1.4): every graph node
-- (subject_type, subject_relation) a relation can possibly grant
-- to, computed once at model-write time so the resolver's prune is
-- one indexed lookup. subject_relation '' covers plain-object and
-- wildcard subjects.
CREATE TABLE IF NOT EXISTS fga.model_reachable (
  store uuid NOT NULL,
  model_id uuid NOT NULL,
  type_name text NOT NULL,
  relation_name text NOT NULL,
  subject_type text NOT NULL,
  subject_relation text NOT NULL DEFAULT '',
  PRIMARY KEY (store, model_id, type_name, relation_name,
               subject_type, subject_relation)
);

-- Immediate children of a set-operator rewrite node; a leaf
-- rewrite yields no rows. Pure jsonb computation.
CREATE OR REPLACE FUNCTION fga._rewrite_children(node jsonb)
RETURNS SETOF jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT jsonb_array_elements(node -> 'union' -> 'child')
  WHERE node ? 'union'
  UNION ALL
  SELECT jsonb_array_elements(node -> 'intersection' -> 'child')
  WHERE node ? 'intersection'
  UNION ALL
  SELECT node -> 'difference' -> 'base'
  WHERE node ? 'difference'
  UNION ALL
  SELECT node -> 'difference' -> 'subtract'
  WHERE node ? 'difference';
$$;

-- Every node of a rewrite tree, the root included.
CREATE OR REPLACE FUNCTION fga._rewrite_nodes(rewrite jsonb)
RETURNS SETOF jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  WITH RECURSIVE nodes(node) AS (
    SELECT rewrite
    UNION ALL
    SELECT c FROM nodes, fga._rewrite_children(nodes.node) AS c
  )
  SELECT node FROM nodes;
$$;

CREATE OR REPLACE FUNCTION fga.write_authorization_model(
  store_id uuid,
  request jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = fga, pg_temp
AS $$
DECLARE
  new_id uuid;
BEGIN
  IF jsonb_typeof(request -> 'type_definitions') IS DISTINCT
     FROM 'array'
  THEN
    RAISE EXCEPTION 'type_definitions must be an array'
      USING ERRCODE = 'YF100';
  END IF;

  INSERT INTO fga.model (store, schema_version, model)
  VALUES (
    store_id,
    coalesce(request ->> 'schema_version', '1.1'),
    request
  )
  RETURNING id INTO new_id;

  INSERT INTO fga.model_type
  SELECT store_id, new_id, td ->> 'type'
  FROM jsonb_array_elements(request -> 'type_definitions') AS td;

  -- A type with no relations key contributes no relation rows; a
  -- relation whose rewrite is absent is refused upstream before
  -- reaching us, so no defensive default here.
  INSERT INTO fga.model_relation
  SELECT store_id, new_id, td ->> 'type', rel.key, rel.value,
    coalesce(jsonb_array_length(
      td -> 'metadata' -> 'relations' -> rel.key
         -> 'directly_related_user_types') > 0, false),
    EXISTS (
      SELECT FROM fga._rewrite_nodes(rel.value) AS n
      WHERE n ? 'intersection' OR n ? 'difference'
    )
  FROM jsonb_array_elements(request -> 'type_definitions') AS td,
       jsonb_each(coalesce(td -> 'relations', '{}'::jsonb)) AS rel;

  INSERT INTO fga.model_computed
  SELECT DISTINCT store_id, new_id, r.type_name, r.relation_name,
    n -> 'computed_userset' ->> 'relation'
  FROM fga.model_relation AS r,
       fga._rewrite_nodes(r.rewrite) AS n
  WHERE r.store = store_id AND r.model_id = new_id
    AND n ? 'computed_userset';

  INSERT INTO fga.model_type_restriction
  SELECT store_id, new_id, td ->> 'type', rel.key,
    tr.ord, tr.value ->> 'type',
    coalesce(tr.value ->> 'relation', ''),
    tr.value ? 'wildcard',
    coalesce(tr.value ->> 'condition', '')
  FROM jsonb_array_elements(request -> 'type_definitions') AS td,
       jsonb_each(coalesce(td -> 'relations', '{}'::jsonb)) AS rel,
       LATERAL jsonb_array_elements(
         td -> 'metadata' -> 'relations' -> rel.key
            -> 'directly_related_user_types')
         WITH ORDINALITY AS tr(value, ord);

  INSERT INTO fga.model_ttu
  SELECT DISTINCT store_id, new_id, r.type_name, r.relation_name,
    n -> 'tuple_to_userset' -> 'tupleset' ->> 'relation',
    n -> 'tuple_to_userset' -> 'computed_userset' ->> 'relation'
  FROM fga.model_relation AS r,
       fga._rewrite_nodes(r.rewrite) AS n
  WHERE r.store = store_id AND r.model_id = new_id
    AND n ? 'tuple_to_userset';

  -- Conditions compile at write time under the openfga env; a
  -- parse failure refuses the model. (Full result-type checking
  -- needs declared-variable support upstream's cel-go has and
  -- cel4postgres's checker does not; a non-bool condition is
  -- refused at evaluation instead — measurements M15.)
  INSERT INTO fga.model_condition
  SELECT store_id, new_id, cond.key,
    cond.value ->> 'expression',
    cond.value -> 'parameters',
    cel.parse(cond.value ->> 'expression', 'openfga')
  FROM jsonb_each(coalesce(request -> 'conditions', '{}'::jsonb))
    AS cond;

  IF EXISTS (
    SELECT FROM fga.model_condition c
    WHERE c.store = store_id AND c.model_id = new_id
      AND c.compiled_ast ? 'errors'
  ) THEN
    RAISE EXCEPTION 'failed to compile expression on condition: %',
    (
      SELECT c.compiled_ast -> 'errors' -> 0 ->> 'msg'
      FROM fga.model_condition c
      WHERE c.store = store_id AND c.model_id = new_id
        AND c.compiled_ast ? 'errors' LIMIT 1
    ) USING ERRCODE = 'YF156';
  END IF;

  PERFORM fga._validate_model(store_id, new_id, request);

  -- Reachability closure. Edges lead from a relation node
  -- (type, relation) to every node it can grant through:
  -- restriction subjects (plain, wildcard and userset forms),
  -- computed usersets, and TTU-linked computed relations on the
  -- tupleset's possible subject types. Set operators contribute
  -- their children's edges (an over-approximation for
  -- intersection and difference, which only ever prunes less —
  -- the safe direction).
  INSERT INTO fga.model_reachable
  WITH RECURSIVE edge AS (
    SELECT tr.type_name, tr.relation_name,
           tr.subject_type AS to_type,
           CASE WHEN tr.is_wildcard THEN ''
                ELSE tr.subject_relation END AS to_relation
    FROM fga.model_type_restriction AS tr
    WHERE tr.store = store_id AND tr.model_id = new_id
    UNION
    SELECT r.type_name, r.relation_name,
           r.type_name, n -> 'computed_userset' ->> 'relation'
    FROM fga.model_relation AS r,
         fga._rewrite_nodes(r.rewrite) AS n
    WHERE r.store = store_id AND r.model_id = new_id
      AND n ? 'computed_userset'
    UNION
    SELECT t.type_name, t.relation_name,
           tr.subject_type, t.computed_relation
    FROM fga.model_ttu AS t
    JOIN fga.model_type_restriction AS tr
      ON tr.store = t.store AND tr.model_id = t.model_id
     AND tr.type_name = t.type_name
     AND tr.relation_name = t.tupleset_relation
    WHERE t.store = store_id AND t.model_id = new_id
  ), closure AS (
    SELECT e.type_name, e.relation_name, e.to_type, e.to_relation
    FROM edge AS e
    UNION
    SELECT c.type_name, c.relation_name, e.to_type, e.to_relation
    FROM closure AS c
    JOIN edge AS e
      ON e.type_name = c.to_type
     AND e.relation_name = c.to_relation
    WHERE c.to_relation <> ''
  )
  SELECT DISTINCT store_id, new_id,
    type_name, relation_name, to_type, to_relation
  FROM closure;

  RETURN jsonb_build_object('authorization_model_id',
                            new_id::text);
END;
$$;

-- The CONFIG-* model validation rules (plan phase 6), every one
-- measured against the oracle (measurements M16) and refused with
-- YF156 (2056 invalid_authorization_model). Whole-model atomic
-- validation (CLAUDE.md decision 3) closes the forward-reference
-- gaps a per-relation gate cannot decide.
--
-- Deliberately absent (accepting-direction divergences, in
-- docs/CONFORMANCE.md): upstream's whole-model entrypoint
-- analysis ("no entrypoints defined") and condition
-- result-type/cost checking (M15).
CREATE OR REPLACE FUNCTION fga._validate_model(
  store_id uuid,
  new_id uuid,
  request jsonb
)
RETURNS void
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  IF coalesce(request ->> 'schema_version', '1.1') <> '1.1' THEN
    RAISE EXCEPTION 'invalid schema version'
      USING ERRCODE = 'YF156';
  END IF;

  -- Names: grammar and the reserved keywords.
  FOR r IN
    SELECT t.type_name FROM fga.model_type t
    WHERE t.store = store_id AND t.model_id = new_id
      AND (t.type_name !~ '^[^:#@\s]{1,254}$'
           OR t.type_name IN ('self', 'this'))
  LOOP
    RAISE EXCEPTION 'the definition of type ''%'' is invalid',
      r.type_name USING ERRCODE = 'YF156';
  END LOOP;
  FOR r IN
    SELECT mr.type_name, mr.relation_name
    FROM fga.model_relation mr
    WHERE mr.store = store_id AND mr.model_id = new_id
      AND (mr.relation_name !~ '^[^:#@\s]{1,50}$'
           OR mr.relation_name IN ('self', 'this'))
  LOOP
    RAISE EXCEPTION
      'the definition of relation ''%'' in object type ''%'' is '
      'invalid: self and this are reserved keywords',
      r.relation_name, r.type_name USING ERRCODE = 'YF156';
  END LOOP;
  FOR r IN
    SELECT c.name FROM fga.model_condition c
    WHERE c.store = store_id AND c.model_id = new_id
      AND c.name !~ '^[^:#@\s]{1,50}$'
  LOOP
    RAISE EXCEPTION 'invalid condition name ''%''', r.name
      USING ERRCODE = 'YF156';
  END LOOP;

  -- Restrictions must reference defined types, relations and
  -- conditions.
  FOR r IN
    SELECT tr.type_name, tr.relation_name, tr.subject_type,
           tr.subject_relation, tr.condition_name
    FROM fga.model_type_restriction tr
    WHERE tr.store = store_id AND tr.model_id = new_id
  LOOP
    IF NOT EXISTS (
      SELECT FROM fga.model_type t
      WHERE t.store = store_id AND t.model_id = new_id
        AND t.type_name = r.subject_type
    ) OR (r.subject_relation <> '' AND NOT EXISTS (
      SELECT FROM fga.model_relation mr
      WHERE mr.store = store_id AND mr.model_id = new_id
        AND mr.type_name = r.subject_type
        AND mr.relation_name = r.subject_relation
    )) THEN
      RAISE EXCEPTION
        'the relation type ''%'' on ''%'' in object type ''%'' '
        'is not valid',
        r.subject_type || CASE WHEN r.subject_relation <> ''
          THEN '#' || r.subject_relation ELSE '' END,
        r.relation_name, r.type_name USING ERRCODE = 'YF156';
    END IF;
    IF r.condition_name <> '' AND NOT EXISTS (
      SELECT FROM fga.model_condition c
      WHERE c.store = store_id AND c.model_id = new_id
        AND c.name = r.condition_name
    ) THEN
      RAISE EXCEPTION
        'condition % is undefined for relation %',
        r.condition_name, r.relation_name
        USING ERRCODE = 'YF156';
    END IF;
  END LOOP;

  -- An assignable relation must admit at least one restriction;
  -- rewrites must name defined same-type relations; intersections
  -- need two operands.
  FOR r IN
    SELECT mr.type_name, mr.relation_name, mr.rewrite,
           mr.is_assignable
    FROM fga.model_relation mr
    WHERE mr.store = store_id AND mr.model_id = new_id
  LOOP
    IF EXISTS (
      SELECT FROM fga._rewrite_nodes(r.rewrite) n
      WHERE n ? 'this'
    ) AND NOT r.is_assignable THEN
      RAISE EXCEPTION
        'the assignable relation ''%'' in object type ''%'' '
        'must contain at least one relation type',
        r.relation_name, r.type_name USING ERRCODE = 'YF156';
    END IF;
    IF EXISTS (
      SELECT FROM fga._rewrite_nodes(r.rewrite) n
      WHERE n ? 'intersection'
        AND coalesce(jsonb_array_length(
              n -> 'intersection' -> 'child'), 0) < 2
    ) THEN
      RAISE EXCEPTION
        'invalid relation: ''%#%'' as intersection has less '
        'than 2 children', r.type_name, r.relation_name
        USING ERRCODE = 'YF156';
    END IF;
    IF EXISTS (
      SELECT FROM fga._rewrite_nodes(r.rewrite) n
      WHERE n ? 'union'
        AND coalesce(jsonb_array_length(
              n -> 'union' -> 'child'), 0) < 2
    ) THEN
      RAISE EXCEPTION
        'invalid relation: ''%#%'' as union has less '
        'than 2 children', r.type_name, r.relation_name
        USING ERRCODE = 'YF156';
    END IF;
  END LOOP;

  -- A conditions-map key must name its condition.
  FOR r IN
    SELECT cond.key AS k, cond.value ->> 'name' AS n
    FROM jsonb_each(coalesce(
      request -> 'conditions', '{}'::jsonb)) cond
    WHERE coalesce(cond.value ->> 'name', cond.key) <> cond.key
  LOOP
    RAISE EXCEPTION
      'condition key ''%'' does not match condition name ''%''',
      r.k, r.n USING ERRCODE = 'YF156';
  END LOOP;
  FOR r IN
    SELECT mc.type_name, mc.relation_name, mc.computed_relation
    FROM fga.model_computed mc
    WHERE mc.store = store_id AND mc.model_id = new_id
      AND NOT EXISTS (
        SELECT FROM fga.model_relation mr
        WHERE mr.store = store_id AND mr.model_id = new_id
          AND mr.type_name = mc.type_name
          AND mr.relation_name = mc.computed_relation)
  LOOP
    RAISE EXCEPTION '''%#%'' relation is undefined',
      r.type_name, r.computed_relation USING ERRCODE = 'YF156';
  END LOOP;

  -- Same-object rewrite cycles over computed-userset edges (the
  -- walk upstream does — direct assignment and TTUs are not
  -- followed). Depth-1 carries its own upstream message.
  FOR r IN
    SELECT mc.type_name, mc.relation_name
    FROM fga.model_computed mc
    WHERE mc.store = store_id AND mc.model_id = new_id
      AND mc.computed_relation = mc.relation_name
  LOOP
    RAISE EXCEPTION
      'the definition of relation ''%'' in object type ''%'' is '
      'invalid: invalid userset rewrite definition',
      r.relation_name, r.type_name USING ERRCODE = 'YF156';
  END LOOP;
  FOR r IN
    WITH RECURSIVE walk AS (
      SELECT mc.type_name, mc.relation_name AS origin,
             mc.computed_relation AS at, 1 AS n
      FROM fga.model_computed mc
      WHERE mc.store = store_id AND mc.model_id = new_id
      UNION ALL
      SELECT w.type_name, w.origin, mc.computed_relation,
             w.n + 1
      FROM walk w
      JOIN fga.model_computed mc
        ON mc.store = store_id AND mc.model_id = new_id
       AND mc.type_name = w.type_name
       AND mc.relation_name = w.at
      WHERE w.n < 60 AND w.at <> w.origin
    )
    SELECT DISTINCT w.type_name, w.origin FROM walk w
    WHERE w.at = w.origin
  LOOP
    RAISE EXCEPTION
      'the definition of relation ''%'' in object type ''%'' is '
      'invalid: potential loop',
      r.origin, r.type_name USING ERRCODE = 'YF156';
  END LOOP;

  -- The three tupleset rules: the tupleset relation must exist,
  -- be purely direct, and admit neither usersets nor wildcards.
  FOR r IN
    SELECT DISTINCT t.type_name, t.relation_name,
           t.tupleset_relation
    FROM fga.model_ttu t
    WHERE t.store = store_id AND t.model_id = new_id
  LOOP
    IF NOT EXISTS (
      SELECT FROM fga.model_relation mr
      WHERE mr.store = store_id AND mr.model_id = new_id
        AND mr.type_name = r.type_name
        AND mr.relation_name = r.tupleset_relation
    ) THEN
      RAISE EXCEPTION '''%#%'' relation is undefined',
        r.type_name, r.tupleset_relation USING ERRCODE = 'YF156';
    END IF;
    IF EXISTS (
      SELECT FROM fga.model_relation mr,
                  fga._rewrite_nodes(mr.rewrite) n
      WHERE mr.store = store_id AND mr.model_id = new_id
        AND mr.type_name = r.type_name
        AND mr.relation_name = r.tupleset_relation
        AND NOT n ? 'this'
    ) THEN
      RAISE EXCEPTION
        'the ''%#%'' relation is referenced in at least one '
        'tupleset and thus must be a direct relation',
        r.type_name, r.tupleset_relation USING ERRCODE = 'YF156';
    END IF;
    IF EXISTS (
      SELECT FROM fga.model_type_restriction tr
      WHERE tr.store = store_id AND tr.model_id = new_id
        AND tr.type_name = r.type_name
        AND tr.relation_name = r.tupleset_relation
        AND (tr.subject_relation <> '' OR tr.is_wildcard)
    ) THEN
      RAISE EXCEPTION
        'the relation type ''%'' on ''%'' in object type ''%'' '
        'is not valid', (
          SELECT tr.subject_type
            || CASE WHEN tr.is_wildcard THEN ''
               WHEN tr.subject_relation <> ''
               THEN '#' || tr.subject_relation ELSE '' END
          FROM fga.model_type_restriction tr
          WHERE tr.store = store_id AND tr.model_id = new_id
            AND tr.type_name = r.type_name
            AND tr.relation_name = r.tupleset_relation
            AND (tr.subject_relation <> '' OR tr.is_wildcard)
          LIMIT 1),
        r.tupleset_relation, r.type_name USING ERRCODE = 'YF156';
    END IF;
  END LOOP;
END;
$$;

-- Resolves the model a request pins: '' or NULL means the store's
-- latest; a non-canonical id is refused as not-found (workspace
-- decision 3 — upstream-shaped ULIDs land here); a canonical id
-- must exist.
CREATE OR REPLACE FUNCTION fga._resolve_model(
  store_id uuid,
  requested text
)
RETURNS uuid
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  resolved uuid;
BEGIN
  IF requested IS NULL OR requested = '' THEN
    SELECT id INTO resolved
    FROM fga.model WHERE store = store_id
    ORDER BY id DESC LIMIT 1;
    IF resolved IS NULL THEN
      RAISE EXCEPTION
        'no authorization models exist for store %', store_id
        USING ERRCODE = 'YF120';
    END IF;
    RETURN resolved;
  END IF;

  resolved := fga._uuid_or_null(requested);
  IF resolved IS NULL THEN
    RAISE EXCEPTION 'authorization model % not found', requested
      USING ERRCODE = 'YF101';
  END IF;
  IF NOT EXISTS (
    SELECT FROM fga.model
    WHERE store = store_id AND id = resolved
  ) THEN
    RAISE EXCEPTION 'authorization model % not found', requested
      USING ERRCODE = 'YF101';
  END IF;
  RETURN resolved;
END;
$$;

COMMIT;
