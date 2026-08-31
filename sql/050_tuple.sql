-- Tuples: storage, the single write path, and the read helpers
-- every resolver consumes.
--
-- The wildcard subject (type:*) is stored as the nil uuid — which
-- the id gate refuses as an id, so no real subject can collide
-- with it. Userset subjects (type:uuid#relation) carry a non-empty
-- subject_relation. The plain composite PK is the duplicate gate
-- (condition deliberately not part of tuple identity) and keeps
-- REPLICA IDENTITY intact for logical replication.

BEGIN;

CREATE TABLE IF NOT EXISTS fga.tuple (
  store uuid NOT NULL,
  object_type text NOT NULL,
  object_id uuid NOT NULL,
  relation text NOT NULL,
  subject_type text NOT NULL,
  subject_id uuid NOT NULL,
  subject_relation text NOT NULL DEFAULT '',
  condition_name text,
  condition_context jsonb,
  ulid text NOT NULL,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store, object_type, object_id, relation,
               subject_type, subject_id, subject_relation),
  -- A wildcard subject cannot be a userset.
  CHECK (subject_id <> '00000000-0000-0000-0000-000000000000'
         OR subject_relation = '')
);

-- Read pagination and (future) changelog ordering (decision 8).
CREATE UNIQUE INDEX IF NOT EXISTS tuple_ulid_idx
  ON fga.tuple (store, ulid);

-- Reverse expansion (list_objects): find objects by subject,
-- mirroring upstream's migration 006 index shape.
CREATE INDEX IF NOT EXISTS tuple_reverse_idx
  ON fga.tuple (store, subject_type, subject_id, subject_relation,
                relation, object_type, object_id);

-- The composite shape shared by stored rows and the contextual-
-- tuple overlay, so one read path serves both (plan §1.4).
DO $$
BEGIN
  CREATE TYPE fga._tuple_key AS (
    object_type text,
    object_id uuid,
    relation text,
    subject_type text,
    subject_id uuid,
    subject_relation text,
    condition_name text,
    condition_context jsonb
  );
EXCEPTION WHEN duplicate_object THEN
  NULL;
END;
$$;

-- ULID per tuple: 48-bit millisecond timestamp + 80 random bits,
-- Crockford base32. Entropy from random() only — core Postgres, no
-- pgcrypto (CLAUDE.md decision 7). Uniqueness is enforced by the
-- index; within one millisecond ordering is arbitrary, like
-- upstream's ULIDs.
CREATE OR REPLACE FUNCTION fga._ulid()
RETURNS text
LANGUAGE plpgsql
VOLATILE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  ms bigint := (extract(epoch FROM clock_timestamp()) * 1000)::bigint;
  s text := '';
  i integer;
BEGIN
  FOR i IN REVERSE 9..0 LOOP
    s := s
      || substr(alphabet, ((ms >> (i * 5)) & 31)::integer + 1, 1);
  END LOOP;
  FOR i IN 1..16 LOOP
    s := s
      || substr(alphabet, floor(random() * 32)::integer + 1, 1);
  END LOOP;
  RETURN s;
END;
$$;

-- String-form parsers. They only split and grammar-check; the
-- uuid gate and model checks belong to the validators, which know
-- which error code their context demands.
--
-- ok=false marks a string that does not even have the shape;
-- id_text carries the raw id segment for the gate.

CREATE OR REPLACE FUNCTION fga._parse_object(s text)
RETURNS TABLE (object_type text, id_text text, ok boolean)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT split_part(s, ':', 1),
         substr(s, strpos(s, ':') + 1),
         s ~ '^[^:#\s]{1,254}:[^:#\s]+$';
$$;

CREATE OR REPLACE FUNCTION fga._parse_subject(s text)
RETURNS TABLE (subject_type text, id_text text,
               subject_relation text, is_wildcard boolean,
               ok boolean)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  WITH split AS (
    SELECT split_part(s, '#', 1) AS objpart,
           CASE WHEN strpos(s, '#') > 0
                THEN substr(s, strpos(s, '#') + 1)
                ELSE '' END AS rel
  )
  SELECT split_part(objpart, ':', 1),
         substr(objpart, strpos(objpart, ':') + 1),
         rel,
         substr(objpart, strpos(objpart, ':') + 1) = '*',
         objpart ~ '^[^:#\s]{1,254}:[^:#\s]+$'
           AND (strpos(s, '#') = 0 OR rel ~ '^[^:#@\s]{1,50}$')
           AND NOT (substr(objpart, strpos(objpart, ':') + 1) = '*'
                    AND rel <> '')
  FROM split;
$$;

-- Write-grade tuple validation (upstream's tuple validation plus
-- the id-domain gate), raising every refusal with the caller's
-- error code: YF127 when the tuple is contextual, the write
-- family when it is being written. Returns the parsed ids.
--
-- Deliberately not yet here (plan phase 6): the tupleset
-- direct-only rule, condition/facet binding, field length limits.
CREATE OR REPLACE FUNCTION fga._validate_tuple(
  store_id uuid,
  model_id uuid,
  obj text,
  rel text,
  subj text,
  errcode text
)
RETURNS TABLE (object_type text, object_id uuid, relation text,
               subject_type text, subject_id uuid,
               subject_relation text)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  o record;
  s record;
  oid uuid;
  sid uuid;
BEGIN
  SELECT * INTO o FROM fga._parse_object(obj);
  IF NOT o.ok THEN
    RAISE EXCEPTION 'invalid tuple ''%#%@%'': invalid object',
      obj, rel, subj USING ERRCODE = errcode;
  END IF;
  SELECT * INTO s FROM fga._parse_subject(subj);
  IF NOT s.ok THEN
    RAISE EXCEPTION 'invalid tuple ''%#%@%'': invalid user',
      obj, rel, subj USING ERRCODE = errcode;
  END IF;
  IF rel !~ '^[^:#@\s]{1,50}$' THEN
    RAISE EXCEPTION 'invalid tuple ''%#%@%'': invalid relation',
      obj, rel, subj USING ERRCODE = errcode;
  END IF;

  IF NOT EXISTS (
    SELECT FROM fga.model_type t
    WHERE t.store = store_id AND t.model_id = _validate_tuple.model_id
      AND t.type_name = o.object_type
  ) THEN
    RAISE EXCEPTION
      'invalid tuple ''%#%@%'': type ''%'' not found',
      obj, rel, subj, o.object_type USING ERRCODE = errcode;
  END IF;
  IF NOT EXISTS (
    SELECT FROM fga.model_relation r
    WHERE r.store = store_id AND r.model_id = _validate_tuple.model_id
      AND r.type_name = o.object_type AND r.relation_name = rel
  ) THEN
    RAISE EXCEPTION
      'invalid tuple ''%#%@%'': relation ''%#%'' not found',
      obj, rel, subj, o.object_type, rel USING ERRCODE = errcode;
  END IF;
  IF NOT EXISTS (
    SELECT FROM fga.model_type t
    WHERE t.store = store_id AND t.model_id = _validate_tuple.model_id
      AND t.type_name = s.subject_type
  ) THEN
    RAISE EXCEPTION
      'invalid tuple ''%#%@%'': type ''%'' not found',
      obj, rel, subj, s.subject_type USING ERRCODE = errcode;
  END IF;
  IF s.subject_relation <> '' AND NOT EXISTS (
    SELECT FROM fga.model_relation r
    WHERE r.store = store_id AND r.model_id = _validate_tuple.model_id
      AND r.type_name = s.subject_type
      AND r.relation_name = s.subject_relation
  ) THEN
    RAISE EXCEPTION
      'invalid tuple ''%#%@%'': relation ''%#%'' not found',
      obj, rel, subj, s.subject_type, s.subject_relation
      USING ERRCODE = errcode;
  END IF;

  -- The type-restriction write gate (facet match; condition
  -- binding joins in phase 4).
  IF NOT EXISTS (
    SELECT FROM fga.model_type_restriction tr
    WHERE tr.store = store_id AND tr.model_id = _validate_tuple.model_id
      AND tr.type_name = o.object_type AND tr.relation_name = rel
      AND tr.subject_type = s.subject_type
      AND tr.subject_relation = s.subject_relation
      AND tr.is_wildcard = s.is_wildcard
  ) THEN
    RAISE EXCEPTION
      'invalid tuple ''%#%@%'': type ''%'' is not an allowed type '
      'restriction for ''%#%''',
      obj, rel, subj, s.subject_type
        || CASE WHEN s.is_wildcard THEN ':*'
                WHEN s.subject_relation <> ''
                THEN '#' || s.subject_relation
                ELSE '' END,
      o.object_type, rel
      USING ERRCODE = errcode;
  END IF;

  oid := fga._uuid_or_null(o.id_text);
  IF oid IS NULL THEN
    RAISE EXCEPTION
      'invalid tuple ''%#%@%'': object id is not a canonical '
      'uuid (fga4postgres id domain)',
      obj, rel, subj USING ERRCODE = errcode;
  END IF;
  IF s.is_wildcard THEN
    sid := '00000000-0000-0000-0000-000000000000';
  ELSE
    sid := fga._uuid_or_null(s.id_text);
    IF sid IS NULL THEN
      RAISE EXCEPTION
        'invalid tuple ''%#%@%'': user id is not a canonical '
        'uuid (fga4postgres id domain)',
        obj, rel, subj USING ERRCODE = errcode;
    END IF;
  END IF;

  RETURN QUERY SELECT o.object_type, oid, rel,
    s.subject_type, sid, s.subject_relation;
END;
$$;

-- The single tuple write path (CLAUDE.md decision 8: every
-- mutation goes through here, so a changelog is addable without
-- rework). Request is upstream's WriteRequest JSON shape.
--
-- Deferred to plan phase 6: exact upstream error codes for each
-- refusal, on_duplicate/on_missing ignore semantics, the full
-- 40-rule gate matrix.
CREATE OR REPLACE FUNCTION fga.write(
  store_id uuid,
  request jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = fga, pg_temp
AS $$
DECLARE
  model_id uuid;
  writes jsonb := coalesce(
    request -> 'writes' -> 'tuple_keys', '[]'::jsonb);
  deletes jsonb := coalesce(
    request -> 'deletes' -> 'tuple_keys', '[]'::jsonb);
  tkj jsonb;
  v record;
  d record;
  n integer;
BEGIN
  model_id := fga._resolve_model(
    store_id, request ->> 'authorization_model_id');

  n := jsonb_array_length(writes) + jsonb_array_length(deletes);
  IF n = 0 THEN
    RAISE EXCEPTION 'a write request must contain writes or '
      'deletes' USING ERRCODE = 'YF100';
  END IF;
  IF n > 100 THEN
    RAISE EXCEPTION 'a write request cannot exceed 100 tuples, '
      'got %', n USING ERRCODE = 'YF100';
  END IF;

  FOR tkj IN SELECT * FROM jsonb_array_elements(writes) LOOP
    SELECT * INTO v FROM fga._validate_tuple(
      store_id, model_id,
      tkj ->> 'object', tkj ->> 'relation', tkj ->> 'user',
      'YF100');
    BEGIN
      INSERT INTO fga.tuple (store, object_type, object_id,
        relation, subject_type, subject_id, subject_relation,
        condition_name, condition_context, ulid)
      VALUES (store_id, v.object_type, v.object_id, v.relation,
        v.subject_type, v.subject_id, v.subject_relation,
        tkj -> 'condition' ->> 'name',
        tkj -> 'condition' -> 'context',
        fga._ulid());
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION
        'cannot write a tuple which already exists: %', tkj
        USING ERRCODE = 'YF117';
    END;
  END LOOP;

  -- Deletes are validated syntactically only — never against the
  -- model — so rows stranded by a model change stay deletable
  -- (plan §1.8).
  FOR tkj IN SELECT * FROM jsonb_array_elements(deletes) LOOP
    SELECT o.object_type, fga._uuid_or_null(o.id_text) AS oid,
           s.subject_type,
           CASE WHEN s.is_wildcard
             THEN '00000000-0000-0000-0000-000000000000'::uuid
             ELSE fga._uuid_or_null(s.id_text) END AS sid,
           s.subject_relation,
           o.ok AND s.ok
             AND (tkj ->> 'relation') ~ '^[^:#@\s]{1,50}$' AS ok
      INTO d
    FROM fga._parse_object(tkj ->> 'object') o,
         fga._parse_subject(tkj ->> 'user') s;
    IF NOT d.ok OR d.oid IS NULL OR d.sid IS NULL THEN
      RAISE EXCEPTION 'invalid tuple in deletes: %', tkj
        USING ERRCODE = 'YF100';
    END IF;
    DELETE FROM fga.tuple t
    WHERE t.store = store_id
      AND t.object_type = d.object_type AND t.object_id = d.oid
      AND t.relation = tkj ->> 'relation'
      AND t.subject_type = d.subject_type
      AND t.subject_id = d.sid
      AND t.subject_relation = d.subject_relation;
    IF NOT FOUND THEN
      RAISE EXCEPTION
        'cannot delete a tuple which does not exist: %', tkj
        USING ERRCODE = 'YF117';
    END IF;
  END LOOP;

  RETURN '{}'::jsonb;
END;
$$;

-- Overlay reads (plan §1.4). With conditions out of play until
-- phase 4, replace-vs-concatenate semantics collapse to plain
-- existence/union; the composite-array shape is what phase 4
-- extends.
--
-- Stored rows are filtered against the request's model
-- (upstream's FilterInvalidTuples): a tuple written under an
-- older model whose subject facet the current model no longer
-- allows is invisible, not an error. Contextual tuples skip the
-- filter — they were already write-grade validated against this
-- very model at request time.

CREATE OR REPLACE FUNCTION fga._read_exact(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  st text, sid uuid, srel text,
  ctx fga._tuple_key[]
)
RETURNS boolean
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT EXISTS (
    SELECT FROM unnest(ctx) c
    WHERE c.object_type = ot AND c.object_id = oid
      AND c.relation = rel AND c.subject_type = st
      AND c.subject_id = sid AND c.subject_relation = srel
  ) OR (
    EXISTS (
      SELECT FROM fga.tuple t
      WHERE t.store = store_id
        AND t.object_type = ot AND t.object_id = oid
        AND t.relation = rel AND t.subject_type = st
        AND t.subject_id = sid AND t.subject_relation = srel
    )
    AND EXISTS (
      SELECT FROM fga.model_type_restriction tr
      WHERE tr.store = store_id
        AND tr.model_id = _read_exact.model_id
        AND tr.type_name = ot AND tr.relation_name = rel
        AND tr.subject_type = st
        AND tr.subject_relation = srel
        AND tr.is_wildcard
              = (sid = '00000000-0000-0000-0000-000000000000'
                 AND srel = '')
    )
  );
$$;

CREATE OR REPLACE FUNCTION fga._read_usersets(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  ctx fga._tuple_key[]
)
RETURNS TABLE (subject_type text, subject_id uuid,
               subject_relation text)
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT c.subject_type, c.subject_id, c.subject_relation
  FROM unnest(ctx) c
  WHERE c.object_type = ot AND c.object_id = oid
    AND c.relation = rel AND c.subject_relation <> ''
  UNION ALL
  SELECT t.subject_type, t.subject_id, t.subject_relation
  FROM fga.tuple t
  WHERE t.store = store_id
    AND t.object_type = ot AND t.object_id = oid
    AND t.relation = rel AND t.subject_relation <> ''
    AND EXISTS (
      SELECT FROM fga.model_type_restriction tr
      WHERE tr.store = store_id
        AND tr.model_id = _read_usersets.model_id
        AND tr.type_name = ot AND tr.relation_name = rel
        AND tr.subject_type = t.subject_type
        AND tr.subject_relation = t.subject_relation
        AND NOT tr.is_wildcard
    );
$$;

COMMIT;
