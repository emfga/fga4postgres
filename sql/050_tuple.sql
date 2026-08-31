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

-- Internal helpers whose signatures evolve between releases are
-- dropped by name first: CREATE OR REPLACE cannot change a return
-- type, and a changed argument list would otherwise leave a stale
-- overload behind. Public entry points keep stable signatures and
-- never need this.
DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'fga'
      AND p.proname IN ('_read_exact', '_read_usersets',
                        '_read_tupleset', '_validate_tuple')
  LOOP
    EXECUTE 'DROP FUNCTION ' || f.sig;
  END LOOP;
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
-- direct-only rule and field length limits.
-- errcode covers structural refusals (bad form, unknown type or
-- relation, facet mismatch); cond_errcode covers condition-layer
-- refusals (undefined condition, condition-binding mismatch). The
-- split is measured: check wraps both as invalid_tuple, while
-- list_objects reports the condition layer as validation_error
-- (measurements M38).
CREATE OR REPLACE FUNCTION fga._validate_tuple(
  store_id uuid,
  model_id uuid,
  obj text,
  rel text,
  subj text,
  cond text,
  errcode text,
  cond_errcode text
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

  -- A named condition must exist in the model.
  IF coalesce(cond, '') <> '' AND NOT EXISTS (
    SELECT FROM fga.model_condition c
    WHERE c.store = store_id
      AND c.model_id = _validate_tuple.model_id
      AND c.name = cond
  ) THEN
    RAISE EXCEPTION
      'invalid tuple ''%#%@%'': undefined condition ''%''',
      obj, rel, subj, cond USING ERRCODE = cond_errcode;
  END IF;

  -- The type-restriction write gate: facet match INCLUDING the
  -- condition binding — an unconditioned tuple needs an
  -- unconditioned restriction and vice versa (trap 5's
  -- admissibility, applied before any condition evaluates).
  IF NOT EXISTS (
    SELECT FROM fga.model_type_restriction tr
    WHERE tr.store = store_id AND tr.model_id = _validate_tuple.model_id
      AND tr.type_name = o.object_type AND tr.relation_name = rel
      AND tr.subject_type = s.subject_type
      AND tr.subject_relation = s.subject_relation
      AND tr.is_wildcard = s.is_wildcard
      AND tr.condition_name = coalesce(cond, '')
  ) THEN
    -- The facet may exist with a different condition binding —
    -- that is the condition layer, not a structural refusal.
    IF EXISTS (
      SELECT FROM fga.model_type_restriction tr
      WHERE tr.store = store_id
        AND tr.model_id = _validate_tuple.model_id
        AND tr.type_name = o.object_type
        AND tr.relation_name = rel
        AND tr.subject_type = s.subject_type
        AND tr.subject_relation = s.subject_relation
        AND tr.is_wildcard = s.is_wildcard
    ) THEN
      IF coalesce(cond, '') = '' THEN
        RAISE EXCEPTION
          'invalid tuple ''%#%@%'': condition is missing',
          obj, rel, subj USING ERRCODE = cond_errcode;
      END IF;
      RAISE EXCEPTION
        'invalid tuple ''%#%@%'': invalid condition for type '
        'restriction', obj, rel, subj
        USING ERRCODE = cond_errcode;
    END IF;
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

-- Control-character scan over a condition context: keys and
-- string values at any depth (a tab counts) refuse before
-- anything else looks at the context — measured ordering, M39.
CREATE OR REPLACE FUNCTION fga._ctx_scan(ctx jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  k text;
  v jsonb;
BEGIN
  CASE jsonb_typeof(ctx)
  WHEN 'object' THEN
    FOR k, v IN SELECT * FROM jsonb_each(ctx) LOOP
      IF k ~ '[\x01-\x1F\x7F]' THEN
        RAISE EXCEPTION
          'context key % contains forbidden characters',
          to_json(k) USING ERRCODE = 'YF100';
      END IF;
      PERFORM fga._ctx_scan(v);
    END LOOP;
  WHEN 'array' THEN
    FOR v IN SELECT * FROM jsonb_array_elements(ctx) LOOP
      PERFORM fga._ctx_scan(v);
    END LOOP;
  WHEN 'string' THEN
    IF (ctx #>> '{}') ~ '[\x01-\x1F\x7F]' THEN
      RAISE EXCEPTION
        'context value % contains forbidden characters',
        ctx USING ERRCODE = 'YF100';
    END IF;
  ELSE
    NULL;
  END CASE;
END;
$$;

-- Write-time condition-context gates (M29/M39): control chars,
-- the 32KiB jsonb-text boundary (pinned different-boundary
-- against upstream's 32768 proto bytes), undeclared parameters,
-- and declared-type coercibility. Write only — checks accept
-- undeclared keys.
CREATE OR REPLACE FUNCTION fga._validate_write_context(
  store_id uuid, model_id uuid,
  cond text, ctx jsonb,
  tuple_repr text
)
RETURNS void
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  params jsonb;
  k text;
  v jsonb;
BEGIN
  IF ctx IS NULL OR ctx = '{}'::jsonb THEN
    RETURN;
  END IF;
  PERFORM fga._ctx_scan(ctx);
  IF octet_length(ctx::text) > 32768 THEN
    RAISE EXCEPTION
      'invalid tuple ''%'': condition context size limit '
      'exceeded: % bytes exceeds 32768 bytes '
      '(jsonb-normalized; fga4postgres boundary)',
      tuple_repr, octet_length(ctx::text)
      USING ERRCODE = 'YF100';
  END IF;
  SELECT c.parameters INTO params
  FROM fga.model_condition c
  WHERE c.store = store_id
    AND c.model_id = _validate_write_context.model_id
    AND c.name = cond;
  FOR k, v IN SELECT * FROM jsonb_each(ctx) LOOP
    IF params IS NULL OR NOT params ? k THEN
      RAISE EXCEPTION
        'invalid tuple ''%'': found invalid context '
        'parameter: %', tuple_repr, k USING ERRCODE = 'YF100';
    END IF;
    -- Coercibility to the declared type. _param_value raises YF
    -- for grammar refusals; substrate conversion errors (bad
    -- numeric syntax and the like) wrap here so the write path
    -- surfaces one code.
    BEGIN
      PERFORM fga._param_value(params -> k, v);
    EXCEPTION
      WHEN SQLSTATE 'YF000' THEN
        RAISE;
      WHEN OTHERS THEN
        RAISE EXCEPTION
          'invalid tuple ''%'': parameter type error on context '
          'parameter ''%'': %', tuple_repr, k, SQLERRM
          USING ERRCODE = 'YF100';
    END;
  END LOOP;
END;
$$;

-- The single tuple write path (CLAUDE.md decision 8: every
-- mutation goes through here, so a changelog is addable without
-- rework). Request is upstream's WriteRequest JSON shape,
-- including writes.on_duplicate / deletes.on_missing (measured
-- M35): "ignore" tolerates the identical duplicate and the
-- missing delete, but a same-key row holding a DIFFERENT
-- condition aborts (gRPC 10) even under ignore.
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
  on_dup text := coalesce(
    request -> 'writes' ->> 'on_duplicate', '');
  on_miss text := coalesce(
    request -> 'deletes' ->> 'on_missing', '');
  tkj jsonb;
  v record;
  d record;
  n integer;
  seen text[] := '{}';
  key text;
  cond_name text;
  cond_ctx jsonb;
  old record;
BEGIN
  model_id := fga._resolve_model(
    store_id, request ->> 'authorization_model_id');

  IF on_dup NOT IN ('', 'error', 'ignore') THEN
    RAISE EXCEPTION 'invalid on_duplicate option: %', on_dup
      USING ERRCODE = 'YF100';
  END IF;
  IF on_miss NOT IN ('', 'error', 'ignore') THEN
    RAISE EXCEPTION 'invalid on_missing option: %', on_miss
      USING ERRCODE = 'YF100';
  END IF;

  n := jsonb_array_length(writes) + jsonb_array_length(deletes);
  IF n = 0 THEN
    RAISE EXCEPTION 'Invalid input. Make sure you provide at '
      'least one write, or at least one delete'
      USING ERRCODE = 'YF103';
  END IF;
  IF n > 100 THEN
    RAISE EXCEPTION 'The number of write operations exceeds the '
      'allowed limit of 100' USING ERRCODE = 'YF153';
  END IF;

  -- Request-level dedup across BOTH lists, before any row lands
  -- (measured M35: the same key twice in writes, or once in
  -- writes and once in deletes, refuses as 2004).
  FOR tkj IN
    SELECT * FROM jsonb_array_elements(writes)
    UNION ALL
    SELECT * FROM jsonb_array_elements(deletes)
  LOOP
    key := (tkj ->> 'object') || '#' || (tkj ->> 'relation')
      || '@' || (tkj ->> 'user');
    IF key = ANY (seen) THEN
      RAISE EXCEPTION
        'duplicate tuple in write: user: ''%'', relation: '
        '''%'', object: ''%''', tkj ->> 'user',
        tkj ->> 'relation', tkj ->> 'object'
        USING ERRCODE = 'YF104';
    END IF;
    seen := seen || key;
  END LOOP;

  FOR tkj IN SELECT * FROM jsonb_array_elements(writes) LOOP
    SELECT * INTO v FROM fga._validate_tuple(
      store_id, model_id,
      tkj ->> 'object', tkj ->> 'relation', tkj ->> 'user',
      tkj -> 'condition' ->> 'name',
      'YF100', 'YF100');

    -- Implicit tuples are a write-only refusal — the same shape
    -- is accepted contextually (measured M39; pinned both halves
    -- in tsfga's inventory).
    IF v.subject_type = v.object_type
       AND v.subject_id = v.object_id
       AND v.subject_relation = v.relation THEN
      RAISE EXCEPTION
        'invalid tuple ''%#%@%'': cannot write a tuple that is '
        'implicit', tkj ->> 'object', tkj ->> 'relation',
        tkj ->> 'user' USING ERRCODE = 'YF100';
    END IF;

    cond_name := tkj -> 'condition' ->> 'name';
    cond_ctx := tkj -> 'condition' -> 'context';
    IF coalesce(cond_name, '') <> '' THEN
      PERFORM fga._validate_write_context(
        store_id, model_id, cond_name, cond_ctx,
        (tkj ->> 'object') || '#' || (tkj ->> 'relation')
          || '@' || (tkj ->> 'user'));
    END IF;

    IF on_dup = 'ignore' THEN
      INSERT INTO fga.tuple (store, object_type, object_id,
        relation, subject_type, subject_id, subject_relation,
        condition_name, condition_context, ulid)
      VALUES (store_id, v.object_type, v.object_id, v.relation,
        v.subject_type, v.subject_id, v.subject_relation,
        cond_name, cond_ctx, fga._ulid())
      ON CONFLICT (store, object_type, object_id, relation,
        subject_type, subject_id, subject_relation)
      DO NOTHING;
      IF NOT FOUND THEN
        SELECT t.condition_name, t.condition_context INTO old
        FROM fga.tuple t
        WHERE t.store = store_id
          AND t.object_type = v.object_type
          AND t.object_id = v.object_id
          AND t.relation = v.relation
          AND t.subject_type = v.subject_type
          AND t.subject_id = v.subject_id
          AND t.subject_relation = v.subject_relation;
        IF coalesce(old.condition_name, '')
             IS DISTINCT FROM coalesce(cond_name, '')
           OR coalesce(old.condition_context, '{}'::jsonb)
             IS DISTINCT FROM coalesce(cond_ctx, '{}'::jsonb)
        THEN
          RAISE EXCEPTION
            'transactional write failed due to conflict: '
            'attempted to write a tuple which already exists '
            'with a different condition: user: ''%'', relation: '
            '''%'', object: ''%''', tkj ->> 'user',
            tkj ->> 'relation', tkj ->> 'object'
            USING ERRCODE = 'YFG10';
        END IF;
      END IF;
    ELSE
      BEGIN
        INSERT INTO fga.tuple (store, object_type, object_id,
          relation, subject_type, subject_id, subject_relation,
          condition_name, condition_context, ulid)
        VALUES (store_id, v.object_type, v.object_id, v.relation,
          v.subject_type, v.subject_id, v.subject_relation,
          cond_name, cond_ctx, fga._ulid());
      EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION
          'cannot write a tuple which already exists: %', tkj
          USING ERRCODE = 'YF117';
      END;
    END IF;
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
    IF NOT FOUND AND on_miss <> 'ignore' THEN
      RAISE EXCEPTION
        'cannot delete a tuple which does not exist: %', tkj
        USING ERRCODE = 'YF117';
    END IF;
  END LOOP;

  RETURN '{}'::jsonb;
END;
$$;

-- Filtered tuple listing with keyset pagination (plan §1.8):
-- deliberately UNFILTERED by the model — the maintenance escape
-- hatch that can see rows a model change stranded. The token is
-- bound to its filter (upstream's positional token silently
-- misaligns under a changed filter — measured M27; refusing
-- here) and pages by ulid keyset, so a page boundary never
-- loses or repeats a row.
CREATE OR REPLACE FUNCTION fga.read(
  store_id uuid,
  request jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  tkey jsonb := request -> 'tuple_key';
  o record;
  s record;
  f_otype text := '';
  f_oid uuid;
  f_rel text := '';
  f_stype text := '';
  f_sid uuid;
  f_srel text := '';
  f_swild boolean := false;
  have_user boolean := false;
  page integer := coalesce((request ->> 'page_size')::integer,
                           50);
  token text := coalesce(
    request ->> 'continuation_token', '');
  fhash text;
  after text := '';
  tok jsonb;
  rows jsonb;
  last_ulid text;
  cnt integer;
BEGIN
  IF page < 1 OR page > 100 THEN
    RAISE EXCEPTION
      'page_size must be inside range [1, 100], got %', page
      USING ERRCODE = 'YF100';
  END IF;

  IF tkey IS NOT NULL AND tkey <> '{}'::jsonb THEN
    -- Measured filter rule (M26): object TYPE is required, and
    -- object id or user must be present.
    SELECT * INTO o FROM fga._parse_object(
      coalesce(tkey ->> 'object', ''));
    IF o.object_type = ''
       OR (o.id_text = ''
           AND coalesce(tkey ->> 'user', '') = '') THEN
      RAISE EXCEPTION
        'the ''tuple_key'' field was provided but the object '
        'type field is required and both the object id and user '
        'cannot be empty' USING ERRCODE = 'YF100';
    END IF;
    f_otype := o.object_type;
    IF o.id_text <> '' THEN
      f_oid := fga._uuid_or_null(o.id_text);
      IF f_oid IS NULL THEN
        RAISE EXCEPTION
          'invalid object id ''%'': not a canonical uuid '
          '(fga4postgres id domain)', o.id_text
          USING ERRCODE = 'YF100';
      END IF;
    END IF;
    f_rel := coalesce(tkey ->> 'relation', '');
    IF coalesce(tkey ->> 'user', '') <> '' THEN
      SELECT * INTO s FROM fga._parse_subject(tkey ->> 'user');
      IF NOT s.ok THEN
        RAISE EXCEPTION 'invalid user filter ''%''',
          tkey ->> 'user' USING ERRCODE = 'YF100';
      END IF;
      have_user := true;
      f_stype := s.subject_type;
      f_srel := s.subject_relation;
      f_swild := s.is_wildcard;
      IF s.is_wildcard THEN
        f_sid := '00000000-0000-0000-0000-000000000000';
      ELSE
        f_sid := fga._uuid_or_null(s.id_text);
        IF f_sid IS NULL THEN
          RAISE EXCEPTION
            'invalid user id ''%'': not a canonical uuid '
            '(fga4postgres id domain)', s.id_text
            USING ERRCODE = 'YF100';
        END IF;
      END IF;
    END IF;
  END IF;

  fhash := md5(concat_ws('|', f_otype, f_oid::text, f_rel,
    f_stype, f_sid::text, f_srel, f_swild::text));

  IF token <> '' THEN
    BEGIN
      tok := convert_from(
        decode(translate(token, '-_', '+/'), 'base64'),
        'utf8')::jsonb;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Invalid continuation token'
        USING ERRCODE = 'YF107';
    END;
    IF tok ->> 'f' IS DISTINCT FROM fhash
       OR tok ->> 'u' IS NULL THEN
      RAISE EXCEPTION 'Invalid continuation token'
        USING ERRCODE = 'YF107';
    END IF;
    after := tok ->> 'u';
  END IF;

  SELECT coalesce(jsonb_agg(x.j), '[]'::jsonb),
         max(x.ulid), count(*)
    INTO rows, last_ulid, cnt
  FROM (
    SELECT t.ulid, jsonb_build_object(
      'key', jsonb_build_object(
        'object', t.object_type || ':' || t.object_id::text,
        'relation', t.relation,
        'user', t.subject_type || ':'
          || CASE WHEN t.subject_id =
                '00000000-0000-0000-0000-000000000000'
              AND t.subject_relation = ''
             THEN '*' ELSE t.subject_id::text END
          || CASE WHEN t.subject_relation <> ''
             THEN '#' || t.subject_relation ELSE '' END)
        || CASE WHEN coalesce(t.condition_name, '') <> ''
           THEN jsonb_build_object('condition',
             jsonb_strip_nulls(jsonb_build_object(
               'name', t.condition_name,
               'context', t.condition_context)))
           ELSE '{}'::jsonb END,
      'timestamp', fga._ulid_time(t.ulid)) AS j
    FROM fga.tuple t
    WHERE t.store = store_id
      AND (f_otype = '' OR t.object_type = f_otype)
      AND (f_oid IS NULL OR t.object_id = f_oid)
      AND (f_rel = '' OR t.relation = f_rel)
      AND (NOT have_user OR (
        t.subject_type = f_stype
        AND t.subject_id = f_sid
        AND t.subject_relation = f_srel))
      AND (after = '' OR t.ulid > after)
    ORDER BY t.ulid
    LIMIT page
  ) x;

  RETURN jsonb_build_object(
    'tuples', rows,
    'continuation_token',
    -- URL-safe base64: the proto token pattern admits only
    -- [A-Za-z0-9-_] plus padding.
    CASE WHEN cnt = page THEN
      translate(replace(encode(convert_to(jsonb_build_object(
        'u', last_ulid, 'f', fhash)::text, 'utf8'), 'base64'),
        E'\n', ''), '+/', '-_')
    ELSE '' END);
END;
$$;

-- The RFC 3339 write timestamp a ulid's leading 48 bits encode.
CREATE OR REPLACE FUNCTION fga._ulid_time(u text)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT to_char(
    to_timestamp((
      SELECT sum(
        (strpos('0123456789ABCDEFGHJKMNPQRSTVWXYZ',
                substr(u, i, 1)) - 1)::bigint
        << ((10 - i) * 5))
      FROM generate_series(1, 10) i
    )::double precision / 1000) AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
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

-- Exact-key read: contextual rows REPLACE the stored row when any
-- match (measured, M07); each returned row carries its condition
-- for the caller to evaluate. Stored rows must be valid under the
-- model including the condition binding of their facet.
CREATE OR REPLACE FUNCTION fga._read_exact(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  st text, sid uuid, srel text,
  ctx fga._tuple_key[]
)
RETURNS TABLE (condition_name text, condition_context jsonb)
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  WITH c AS (
    SELECT x.condition_name, x.condition_context
    FROM unnest(ctx) x
    WHERE x.object_type = ot AND x.object_id = oid
      AND x.relation = rel AND x.subject_type = st
      AND x.subject_id = sid AND x.subject_relation = srel
  )
  SELECT * FROM c
  UNION ALL
  SELECT t.condition_name, t.condition_context
  FROM fga.tuple t
  WHERE NOT EXISTS (SELECT FROM c)
    AND t.store = store_id
    AND t.object_type = ot AND t.object_id = oid
    AND t.relation = rel AND t.subject_type = st
    AND t.subject_id = sid AND t.subject_relation = srel
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
        AND tr.condition_name = coalesce(t.condition_name, '')
    );
$$;

-- Iterator read: contextual and stored rows CONCATENATE, no dedup
-- (measured, M07). Condition columns ride along for per-row
-- evaluation at the call site.
CREATE OR REPLACE FUNCTION fga._read_usersets(
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
    AND c.relation = rel AND c.subject_relation <> ''
  UNION ALL
  SELECT t.subject_type, t.subject_id, t.subject_relation,
         t.condition_name, t.condition_context
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
        AND tr.condition_name = coalesce(t.condition_name, '')
    );
$$;

-- Tupleset read for TTU resolution: the linked parent objects.
-- Userset and wildcard subjects are skipped — a tupleset is
-- direct-only at write time, and stranded rows from older models
-- are filtered like everywhere else.
CREATE OR REPLACE FUNCTION fga._read_tupleset(
  store_id uuid, model_id uuid,
  ot text, oid uuid, rel text,
  ctx fga._tuple_key[]
)
RETURNS TABLE (subject_type text, subject_id uuid,
               condition_name text, condition_context jsonb)
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT c.subject_type, c.subject_id,
         c.condition_name, c.condition_context
  FROM unnest(ctx) c
  WHERE c.object_type = ot AND c.object_id = oid
    AND c.relation = rel AND c.subject_relation = ''
    AND c.subject_id <> '00000000-0000-0000-0000-000000000000'
  UNION ALL
  SELECT t.subject_type, t.subject_id,
         t.condition_name, t.condition_context
  FROM fga.tuple t
  WHERE t.store = store_id
    AND t.object_type = ot AND t.object_id = oid
    AND t.relation = rel AND t.subject_relation = ''
    AND t.subject_id <> '00000000-0000-0000-0000-000000000000'
    AND EXISTS (
      SELECT FROM fga.model_type_restriction tr
      WHERE tr.store = store_id
        AND tr.model_id = _read_tupleset.model_id
        AND tr.type_name = ot AND tr.relation_name = rel
        AND tr.subject_type = t.subject_type
        AND tr.subject_relation = ''
        AND NOT tr.is_wildcard
        AND tr.condition_name = coalesce(t.condition_name, '')
    );
$$;

COMMIT;
