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

  INSERT INTO fga.model_condition
  SELECT store_id, new_id, cond.key,
    cond.value ->> 'expression',
    cond.value -> 'parameters',
    NULL
  FROM jsonb_each(coalesce(request -> 'conditions', '{}'::jsonb))
    AS cond;

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
