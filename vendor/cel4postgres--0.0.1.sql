-- ---- sql/000_install.sql ----

-- cel4postgres -- install script.
--
-- Idempotent, and installable by any role that owns (or may create)
-- the cel schema. Nothing here requires superuser, a filesystem, or
-- a server restart: see CLAUDE.md, "Installation and privileges".
--
-- Run with:  psql -v ON_ERROR_STOP=1 -f sql/000_install.sql
-- followed by the other sql/ scripts in numbered order (or use a
-- release artifact, which bundles them already ordered).

BEGIN;

CREATE SCHEMA IF NOT EXISTS cel;

-- We have no pg_extension row to carry a version, so the schema
-- carries its own. Upgrade scripts append a row; nothing rewrites
-- history.
CREATE TABLE IF NOT EXISTS cel.schema_version (
  version     text        NOT NULL,
  applied_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (version)
);

INSERT INTO cel.schema_version (version)
VALUES ('0.0.1')
ON CONFLICT (version) DO NOTHING;

-- The installed schema version. IMMUTABLE is deliberately wrong for
-- this one -- it reads a table -- so it is STABLE, and it is the only
-- function in cel that will ever read one.
CREATE OR REPLACE FUNCTION cel.version()
RETURNS text
LANGUAGE sql
STABLE
SET search_path = cel, pg_temp
AS $$
  SELECT version
  FROM cel.schema_version
  ORDER BY applied_at DESC, version DESC
  LIMIT 1;
$$;

COMMIT;

-- ---- sql/010_registry.sql ----

-- cel4postgres -- the four registries.
--
-- An extension is rows in these tables plus PL/pgSQL functions; it is
-- never a patch to the core. The standard library itself registers
-- through them (seeded by 030_parse.sql and 060_stdlib.sql) -- if the
-- core could reach anything the registry cannot describe, the
-- registry would stop being the extension mechanism.

BEGIN;

-- Custom and well-known types: name resolution, construction,
-- equality and conversion hooks. Every row visible in an env also
-- implies an identifier of type type(T) under the type's name.
CREATE TABLE IF NOT EXISTS cel.type (
  name       text PRIMARY KEY,
  kind       jsonb NOT NULL,
  construct  regprocedure,
  equal      regprocedure,
  convert    regprocedure,
  doc        text
);

-- Overloads: the unit of dispatch. cel.check binds ids from here;
-- cel.eval dispatches on the bound id and never on a function name.
-- ordinal preserves cel-go's declaration order, because overload
-- resolution and multi-match widening are order-sensitive.
CREATE TABLE IF NOT EXISTS cel.overload (
  id          text PRIMARY KEY,
  function    text NOT NULL,
  member      boolean NOT NULL,
  arg_types   jsonb NOT NULL,
  result_type jsonb NOT NULL,
  impl        regprocedure,
  non_strict  boolean NOT NULL DEFAULT false,
  ordinal     int NOT NULL,
  doc         text
);

CREATE INDEX IF NOT EXISTS overload_function
  ON cel.overload (function, ordinal);

-- Parse-time macros. arity -1 is variadic. The expander signature is
--   expander(target jsonb, args jsonb, next_id bigint)
--     RETURNS (expr jsonb, next_id bigint, err text)
-- returning NULL expr with NULL err to decline the expansion.
CREATE TABLE IF NOT EXISTS cel.macro (
  name     text NOT NULL,
  arity    int NOT NULL,
  member   boolean NOT NULL,
  expander regprocedure NOT NULL,
  PRIMARY KEY (name, arity, member)
);

-- Named environments: a bundle of visible overloads, macros and
-- types, plus parse-level feature flags (optional_syntax, ...).
-- kind='env' composes environments; the API's env argument is
-- additionally a comma-separated union of names.
CREATE TABLE IF NOT EXISTS cel.env (
  name  text PRIMARY KEY,
  flags jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS cel.env_item (
  env  text NOT NULL REFERENCES cel.env (name),
  kind text NOT NULL CHECK (kind IN ('overload', 'macro', 'type', 'env')),
  ref  text NOT NULL,
  PRIMARY KEY (env, kind, ref)
);

-- Resolves an env argument ('standard', 'standard,strings', nested
-- includes) to the flat set of env names, cycle-safe. An unknown name
-- raises: a misconfigured environment is a caller bug, not a CEL
-- error value.
CREATE OR REPLACE FUNCTION cel._env_names(env text)
RETURNS text[]
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  pending text[];
  seen    text[] := '{}';
  current text;
  extra   text[];
BEGIN
  SELECT array_agg(btrim(n)) INTO pending
  FROM unnest(string_to_array(env, ',')) AS n
  WHERE btrim(n) <> '';

  IF pending IS NULL THEN
    RAISE 'empty env argument';
  END IF;

  WHILE cardinality(pending) > 0 LOOP
    current := pending[1];
    pending := pending[2:];
    CONTINUE WHEN current = ANY (seen);

    IF NOT EXISTS (SELECT FROM cel.env WHERE name = current) THEN
      RAISE 'unknown env %', quote_literal(current);
    END IF;
    seen := seen || current;

    SELECT array_agg(ref) INTO extra
    FROM cel.env_item
    WHERE env_item.env = current AND kind = 'env';
    IF extra IS NOT NULL THEN
      pending := pending || extra;
    END IF;
  END LOOP;

  RETURN seen;
END;
$$;

-- Merged parse-level flags of an env union. Later names win on
-- conflicting keys; flags are booleans in practice, set once by the
-- env that owns the feature, so conflicts do not arise today.
CREATE OR REPLACE FUNCTION cel._env_flags(env text)
RETURNS jsonb
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
  FROM (
    SELECT key, value,
           row_number() OVER (PARTITION BY key ORDER BY ord DESC) AS rn
    FROM unnest(cel._env_names(env)) WITH ORDINALITY AS e(name, ord)
    JOIN cel.env ON cel.env.name = e.name,
    LATERAL jsonb_each(cel.env.flags)
  ) flags
  WHERE rn = 1;
$$;

-- The macros visible to an env union, as one jsonb object the parser
-- looks up per call site without further table reads:
--   {"<name>/<arity>/<member>": "<callable name>", ...}
-- with arity -1 entries under their own key for the variadic probe.
CREATE OR REPLACE FUNCTION cel._env_macros(env text)
RETURNS jsonb
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(
    jsonb_object_agg(
      format('%s/%s/%s', m.name, m.arity, m.member::int),
      split_part(m.expander::text, '(', 1)
    ),
    '{}'::jsonb
  )
  FROM cel.macro m
  WHERE EXISTS (
    SELECT FROM cel.env_item i
    WHERE i.env = ANY (cel._env_names(env))
      AND i.kind = 'macro'
      AND i.ref = format('%s/%s/%s', m.name, m.arity, m.member::int)
  );
$$;

-- The spec-conformant default environment. Its items are seeded by
-- the scripts that create the functions they reference. The
-- identifier-escape syntax (`a-b`) is part of standard parsing
-- (cel-go enables it corpus-wide); optional syntax is not.
INSERT INTO cel.env (name, flags)
VALUES ('standard', '{"ident_escape": true}')
ON CONFLICT (name) DO NOTHING;

-- Extension environments. The rows exist from day one so an env
-- union like 'standard,strings' resolves before the extension's own
-- install script has seeded any items into them; the sql/1xx
-- extension scripts fill them in. optionals owns the
-- optional-syntax parse flag.
INSERT INTO cel.env (name, flags) VALUES
  ('strings', '{}'),
  ('math', '{}'),
  ('lists', '{}'),
  ('encoders', '{}'),
  ('bindings', '{}'),
  ('two_var_comprehensions', '{}'),
  ('optionals', '{"optional_syntax": true}'),
  ('network', '{}')
ON CONFLICT (name) DO NOTHING;

COMMIT;

-- ---- sql/020_values.sql ----

-- cel4postgres -- value helpers.
--
-- Run after 000_install.sql. Everything here is a pure function over
-- tagged jsonb values or their scalar payloads; nothing reads a table.

BEGIN;

-- Renders a finite double the way CEL's string(double) must: cel-go
-- delegates to Go's %g (common/types/double.go:141, pinned v0.32.0).
-- Postgres's own float8 output is close but measurably different in
-- two ways (both found by the fuzz test in conformance/format_test.go,
-- which holds this function to Go %g on every CI run):
--
--   1. Notation threshold. Go's shortest %g switches to scientific
--      notation when the decimal exponent is < -4 or >= 6 (strconv
--      ftoa.go: "use precision 6 for this decision"); Postgres stays
--      plain up to e+14.
--
--   2. Halfway digits. Both emit shortest-round-trip digits, but when
--      a shorter form lands exactly halfway between two doubles and
--      ties-to-even resolves back to the value, Go accepts it and
--      Postgres's Ryu does not (e.g. 4.468743327960138e+16, which Go
--      prints with 16 digits and Postgres with 17). Hence the
--      shortening loop: drop a digit while the result still casts
--      back to the same double.
--
-- Non-finite doubles never reach this function: the evaluator carries
-- them as the tagged strings "Infinity"/"-Infinity"/"NaN" and renders
-- their CEL text itself.
CREATE OR REPLACE FUNCTION cel._double_text(v float8)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE STRICT
SET search_path = cel, pg_temp
AS $$
DECLARE
  t         text := v::text;
  neg       text := '';
  mant      text;
  int_part  text;
  frac      text;
  digits    text;
  e         int;
  m         numeric;
  cand      text;
  cand_e    int;
  shortened text;
BEGIN
  IF t LIKE '-%' THEN
    neg := '-';
    t := substr(t, 2);
  END IF;

  -- Normalize to (digits, e): significant digits with no trailing
  -- zeros, and the decimal exponent of the leading digit.
  IF t LIKE '%e%' THEN
    mant := split_part(t, 'e', 1);
    e := split_part(t, 'e', 2)::int;
    digits := replace(mant, '.', '');
  ELSE
    int_part := split_part(t, '.', 1);
    frac := split_part(t, '.', 2);
    IF int_part = '0' THEN
      -- 0, or 0.00123-style: exponent from the leading zeros.
      digits := ltrim(frac, '0');
      IF digits = '' THEN
        RETURN neg || '0';
      END IF;
      e := -(length(frac) - length(digits)) - 1;
    ELSE
      digits := int_part || frac;
      e := length(int_part) - 1;
    END IF;
  END IF;
  digits := rtrim(digits, '0');
  IF digits = '' THEN
    digits := '0';
    e := 0;
  END IF;

  -- Shorten while a rounded-off form still round-trips (point 2).
  WHILE length(digits) > 1 LOOP
    m := round(digits::numeric / 10);
    cand := m::text;
    cand_e := e + length(cand) - (length(digits) - 1);
    cand := rtrim(cand, '0');
    IF cand = '' THEN
      cand := '0';
    END IF;
    -- A candidate rounded up past 1.7976931348623157e308 would make
    -- the round-trip cast raise instead of miss; it cannot be the
    -- shortest form of any finite double, so stop shortening there.
    IF cand_e > 308 OR (cand_e = 308
        AND rpad(cand, 17, '0') > '17976931348623157') THEN
      EXIT;
    END IF;
    shortened := substr(cand, 1, 1)
      || CASE WHEN length(cand) > 1
              THEN '.' || substr(cand, 2)
              ELSE '' END
      || 'e' || cand_e::text;
    EXIT WHEN (neg || shortened)::float8 IS DISTINCT FROM v;
    digits := cand;
    e := cand_e;
  END LOOP;

  -- Render per Go's %g rule (point 1).
  IF e < -4 OR e >= 6 THEN
    RETURN neg || substr(digits, 1, 1)
      || CASE WHEN length(digits) > 1
              THEN '.' || substr(digits, 2)
              ELSE '' END
      || CASE WHEN e < 0 THEN 'e-' ELSE 'e+' END
      -- At least two exponent digits, as Go prints (lpad would
      -- truncate three-digit exponents).
      || CASE WHEN abs(e) < 10 THEN '0' ELSE '' END
      || abs(e)::text;
  END IF;

  IF e >= 0 THEN
    int_part := rpad(substr(digits, 1, e + 1), e + 1, '0');
    frac := substr(digits, e + 2);
    RETURN neg || int_part
      || CASE WHEN frac <> '' THEN '.' || frac ELSE '' END;
  END IF;

  RETURN neg || '0.' || repeat('0', -e - 1) || digits;
END;
$$;

COMMIT;

BEGIN;

-- Tagged-value primitives. The kind tag carries type identity;
-- these helpers are the single place equality, ordering and payload
-- access are defined, so every impl and the evaluator agree on them.

CREATE OR REPLACE FUNCTION cel._err(msg text, id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'error',
    'v', jsonb_strip_nulls(jsonb_build_object('msg', msg, 'id', id)));
$$;

CREATE OR REPLACE FUNCTION cel._is_error(v jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT v ->> '@t' = 'error';
$$;

CREATE OR REPLACE FUNCTION cel._is_unknown(v jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT v ->> '@t' = 'unknown';
$$;

-- Unknown payloads are sorted, deduped expr-id arrays; merging is set
-- union.
CREATE OR REPLACE FUNCTION cel._unknown_merge(a jsonb, b jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'unknown', 'v',
    coalesce(jsonb_agg(id ORDER BY id), '[]'::jsonb))
  FROM (
    SELECT DISTINCT (e ->> 0)::bigint AS id
    FROM (
      SELECT jsonb_build_array(x) AS e
      FROM jsonb_array_elements(a -> 'v') x
      UNION ALL
      SELECT jsonb_build_array(x)
      FROM jsonb_array_elements(b -> 'v') x
    ) ids
  ) merged;
$$;

-- The float8 payload of a double value; the three non-finite
-- sentinels are strings in jsonb.
CREATE OR REPLACE FUNCTION cel._dbl(v jsonb)
RETURNS float8
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE v ->> 'v'
    WHEN 'Infinity'  THEN 'Infinity'::float8
    WHEN '-Infinity' THEN '-Infinity'::float8
    WHEN 'NaN'       THEN 'NaN'::float8
    ELSE (v ->> 'v')::float8
  END;
$$;

-- Wraps a float8 back into a tagged double, mapping non-finite
-- results to their sentinel strings (jsonb cannot hold them).
CREATE OR REPLACE FUNCTION cel._dbl_val(f float8)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN f = 'Infinity'::float8
      THEN jsonb_build_object('@t', 'double', 'v', 'Infinity')
    WHEN f = '-Infinity'::float8
      THEN jsonb_build_object('@t', 'double', 'v', '-Infinity')
    -- Postgres treats NaN as equal to NaN, so f <> f cannot detect
    -- it the IEEE way; the direct comparison works instead.
    WHEN f = 'NaN'::float8
      THEN jsonb_build_object('@t', 'double', 'v', 'NaN')
    ELSE jsonb_build_object('@t', 'double', 'v', to_jsonb(f))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._int_val(n numeric)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'int', 'v', to_jsonb(n));
$$;

CREATE OR REPLACE FUNCTION cel._bool_val(b boolean)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'bool', 'v', b);
$$;

-- Heterogeneous equality (cel-go v0.32.0 common/types, measured):
-- cross-kind == is false, never an error; int/uint compare exactly;
-- int-or-uint vs double bounds-checks then widens to double
-- (compare.go:23-66); NaN equals nothing; lists/maps size-first then
-- element-wise; timestamps by instant; null only equals null.
CREATE OR REPLACE FUNCTION cel._equal(a jsonb, b jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  ka text := a ->> '@t';
  kb text := b ->> '@t';
  da float8;
  db float8;
  i  int;
  ea jsonb;
  found boolean;
  used  boolean[];
  j  int;
BEGIN
  -- Numeric cross-kind equality: NaN equals nothing; otherwise
  -- exactly the ordering comparison at zero, which carries the
  -- bounds-check-then-widen behaviour of compare.go (a bare widen
  -- would call 9223372036854775807 equal to 2^63 as a double).
  IF ka IN ('int', 'uint', 'double') AND kb IN ('int', 'uint', 'double')
  THEN
    IF (ka = 'double' AND a ->> 'v' = 'NaN')
       OR (kb = 'double' AND b ->> 'v' = 'NaN') THEN
      RETURN false;
    END IF;
    RETURN (cel._compare(a, b) ->> 'v')::int = 0;
  END IF;

  IF ka <> kb THEN
    RETURN false;
  END IF;

  CASE ka
    WHEN 'null' THEN
      RETURN true;
    WHEN 'bool', 'string', 'bytes', 'type' THEN
      RETURN a -> 'v' = b -> 'v';
    WHEN 'duration' THEN
      RETURN (a ->> 'v')::numeric = (b ->> 'v')::numeric;
    WHEN 'timestamp' THEN
      RETURN (a -> 'v' ->> 's')::numeric = (b -> 'v' ->> 's')::numeric
         AND (a -> 'v' ->> 'n')::numeric = (b -> 'v' ->> 'n')::numeric;
    WHEN 'list' THEN
      IF jsonb_array_length(a -> 'v') <> jsonb_array_length(b -> 'v')
      THEN
        RETURN false;
      END IF;
      FOR i IN 0 .. jsonb_array_length(a -> 'v') - 1 LOOP
        IF NOT cel._equal(a -> 'v' -> i, b -> 'v' -> i) THEN
          RETURN false;
        END IF;
      END LOOP;
      RETURN true;
    WHEN 'map' THEN
      IF jsonb_array_length(a -> 'v') <> jsonb_array_length(b -> 'v')
      THEN
        RETURN false;
      END IF;
      used := array_fill(false, ARRAY[jsonb_array_length(b -> 'v')]);
      FOR i IN 0 .. jsonb_array_length(a -> 'v') - 1 LOOP
        ea := a -> 'v' -> i;
        found := false;
        FOR j IN 0 .. jsonb_array_length(b -> 'v') - 1 LOOP
          IF NOT used[j + 1]
             AND cel._equal(ea -> 'k', b -> 'v' -> j -> 'k')
             AND cel._equal(ea -> 'v', b -> 'v' -> j -> 'v') THEN
            used[j + 1] := true;
            found := true;
            EXIT;
          END IF;
        END LOOP;
        IF NOT found THEN
          RETURN false;
        END IF;
      END LOOP;
      RETURN true;
    ELSE
      -- Opaque and future kinds: structural payload identity unless
      -- a registered equality overrides it.
      RETURN a - '@t' = b - '@t';
  END CASE;
END;
$$;

-- Three-way ordering for the relation operators. Returns a tagged
-- int (-1/0/1) or an error value: NaN is unorderable, and kinds
-- outside the numeric cross-compare matrix order only within their
-- own kind (cel-go compare.go, measured).
CREATE OR REPLACE FUNCTION cel._compare(a jsonb, b jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  ka text := a ->> '@t';
  kb text := b ->> '@t';
  da float8;
  db float8;
  na numeric;
  nb numeric;
BEGIN
  IF ka IN ('int', 'uint', 'double') AND kb IN ('int', 'uint', 'double')
  THEN
    IF ka = 'double' OR kb = 'double' THEN
      da := CASE WHEN ka = 'double' THEN cel._dbl(a)
                 ELSE NULL END;
      db := CASE WHEN kb = 'double' THEN cel._dbl(b)
                 ELSE NULL END;
      -- Postgres NaN compares equal to NaN, so the check is direct.
      IF da = 'NaN'::float8 OR db = 'NaN'::float8 THEN
        RETURN cel._err('NaN values cannot be ordered');
      END IF;

      -- compareDoubleInt / compareDoubleUint: bounds first, then
      -- widen the integer side and compare as doubles.
      IF ka = 'double' AND kb IN ('int', 'uint') THEN
        nb := (b ->> 'v')::numeric;
        IF kb = 'int' AND da < -9223372036854775808::float8 THEN
          RETURN cel._int_val(-1);
        ELSIF kb = 'int' AND da > 9223372036854775807::float8 THEN
          RETURN cel._int_val(1);
        ELSIF kb = 'uint' AND da < 0 THEN
          RETURN cel._int_val(-1);
        ELSIF kb = 'uint' AND da > 18446744073709551615::float8 THEN
          RETURN cel._int_val(1);
        END IF;
        db := nb::float8;
      ELSIF kb = 'double' AND ka IN ('int', 'uint') THEN
        na := (a ->> 'v')::numeric;
        IF ka = 'int' AND db < -9223372036854775808::float8 THEN
          RETURN cel._int_val(1);
        ELSIF ka = 'int' AND db > 9223372036854775807::float8 THEN
          RETURN cel._int_val(-1);
        ELSIF ka = 'uint' AND db < 0 THEN
          RETURN cel._int_val(1);
        ELSIF ka = 'uint' AND db > 18446744073709551615::float8 THEN
          RETURN cel._int_val(-1);
        END IF;
        da := na::float8;
      END IF;

      RETURN cel._int_val(CASE
        WHEN da < db THEN -1 WHEN da > db THEN 1 ELSE 0 END);
    END IF;

    -- int/uint cross: exact integer comparison.
    na := (a ->> 'v')::numeric;
    nb := (b ->> 'v')::numeric;
    RETURN cel._int_val(CASE
      WHEN na < nb THEN -1 WHEN na > nb THEN 1 ELSE 0 END);
  END IF;

  IF ka <> kb THEN
    RETURN cel._err('no such overload');
  END IF;

  CASE ka
    WHEN 'bool' THEN
      RETURN cel._int_val(CASE
        WHEN a -> 'v' = b -> 'v' THEN 0
        WHEN (a ->> 'v')::boolean THEN 1 ELSE -1 END);
    WHEN 'string' THEN
      -- Byte-wise (C collation) order, not locale order.
      RETURN cel._int_val(CASE
        WHEN convert_to(a ->> 'v', 'UTF8')
             < convert_to(b ->> 'v', 'UTF8') THEN -1
        WHEN convert_to(a ->> 'v', 'UTF8')
             > convert_to(b ->> 'v', 'UTF8') THEN 1
        ELSE 0 END);
    WHEN 'bytes' THEN
      RETURN cel._int_val(CASE
        WHEN decode(a ->> 'v', 'base64') < decode(b ->> 'v', 'base64')
          THEN -1
        WHEN decode(a ->> 'v', 'base64') > decode(b ->> 'v', 'base64')
          THEN 1
        ELSE 0 END);
    WHEN 'duration' THEN
      na := (a ->> 'v')::numeric;
      nb := (b ->> 'v')::numeric;
      RETURN cel._int_val(CASE
        WHEN na < nb THEN -1 WHEN na > nb THEN 1 ELSE 0 END);
    WHEN 'timestamp' THEN
      na := (a -> 'v' ->> 's')::numeric * 1000000000
            + (a -> 'v' ->> 'n')::numeric;
      nb := (b -> 'v' ->> 's')::numeric * 1000000000
            + (b -> 'v' ->> 'n')::numeric;
      RETURN cel._int_val(CASE
        WHEN na < nb THEN -1 WHEN na > nb THEN 1 ELSE 0 END);
    ELSE
      RETURN cel._err('no such overload');
  END CASE;
END;
$$;

-- Map lookup by normalized key equality: exact kind first is not
-- needed separately -- cel._equal already implements the lossless
-- numeric coercions map.go's Find applies. Returns the entry's value
-- or NULL when absent.
CREATE OR REPLACE FUNCTION cel._map_find(m jsonb, key jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  entry jsonb;
BEGIN
  FOR entry IN SELECT e FROM jsonb_array_elements(m -> 'v') e LOOP
    IF cel._equal(entry -> 'k', key) THEN
      RETURN entry -> 'v';
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

COMMIT;

BEGIN;

-- Exact float8 -> numeric. The built-in cast goes through the
-- shortest decimal text, which identifies the double uniquely but is
-- NOT its exact binary value (36028797018963968::float8::numeric
-- ends in ...70). Halving until the value fits 2^53 and doubling
-- until integral recovers mantissa and exponent exactly; both are
-- exact float operations.
CREATE OR REPLACE FUNCTION cel._f2n(f float8)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  e int := 0;
BEGIN
  IF f = 0 THEN
    RETURN 0;
  END IF;
  WHILE abs(f) >= 9007199254740992::float8 LOOP
    f := f / 2;
    e := e + 1;
  END LOOP;
  WHILE f <> trunc(f) LOOP
    f := f * 2;
    e := e - 1;
  END LOOP;
  -- 2^e must be exact.  numeric ^ is exact for non-negative integer
  -- exponents but rounds to ~16 significant digits for negative ones,
  -- so build 2^-k as 5^k * 10^-k: an exact integer power times an
  -- exact decimal literal, combined by (always exact) multiplication.
  IF e >= 0 THEN
    RETURN f::bigint::numeric * (2::numeric ^ e);
  END IF;
  RETURN f::bigint::numeric * (5::numeric ^ (-e))
         * ('1e' || e)::numeric;
END;
$$;

COMMIT;

-- ---- sql/030_parse.sql ----

-- cel4postgres -- lexer, parser, macro engine.
--
-- Hand-written lexer + precedence-climbing parser (cel-go itself
-- carries a Pratt parser with these semantics). Errors travel as
-- OUT parameters, never exceptions: cel.parse is labelled
-- PARALLEL SAFE, and a BEGIN/EXCEPTION block's subtransaction would
-- break that promise inside a parallel worker.
--
-- The reference grammar is cel-go's parser/gen/CEL.g4 (v0.32.0);
-- lexical rules follow it exactly, including the newline
-- normalization applied to every literal form.

BEGIN;

-- Lexes one string or bytes literal. pos points at the opening quote
-- (prefixes r/R/b/B already consumed by the caller). Returns the
-- decoded value: text for strings, base64 text for bytes. ni is the
-- position after the closing quote. err set on failure.
CREATE OR REPLACE FUNCTION cel._lex_string(
  source text,
  pos int,
  raw boolean,
  is_bytes boolean,
  OUT val text,
  OUT ni int,
  OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  n      int := length(source);
  q      text := substr(source, pos, 1);
  triple boolean := substr(source, pos, 3) = repeat(q, 3);
  i      int;
  ch     text;
  sacc   text := '';
  bacc   bytea := ''::bytea;
  code   int;
  hex    text;
  esc    text;
  width  int;
BEGIN
  i := pos + CASE WHEN triple THEN 3 ELSE 1 END;

  LOOP
    IF i > n THEN
      err := 'unterminated string';
      ni := i;
      RETURN;
    END IF;
    ch := substr(source, i, 1);

    -- Closing quote.
    IF triple THEN
      IF substr(source, i, 3) = repeat(q, 3) THEN
        i := i + 3;
        EXIT;
      END IF;
    ELSIF ch = q THEN
      i := i + 1;
      EXIT;
    ELSIF ch = E'\n' OR ch = E'\r' THEN
      err := 'unterminated string';
      ni := i;
      RETURN;
    END IF;

    -- Raw literals keep backslashes verbatim.
    IF ch <> E'\\' OR raw THEN
      -- Newline normalization applies to literal source text in
      -- every form (raw included): CRLF and CR become LF. Escape-
      -- produced \r (code 13) is not source text and stays.
      IF ch = E'\r' THEN
        ch := E'\n';
        IF substr(source, i + 1, 1) = E'\n' THEN
          i := i + 1;
        END IF;
      END IF;
      IF is_bytes THEN
        bacc := bacc || convert_to(ch, 'UTF8');
      ELSE
        sacc := sacc || ch;
      END IF;
      i := i + 1;
      CONTINUE;
    END IF;

    -- Escape sequence.
    i := i + 1;
    IF i > n THEN
      err := 'unterminated escape';
      ni := i;
      RETURN;
    END IF;
    esc := substr(source, i, 1);

    IF esc IN ('a','b','f','n','r','t','v','\','''','"','?','`') THEN
      code := CASE esc
        WHEN 'a' THEN 7  WHEN 'b' THEN 8  WHEN 'f' THEN 12
        WHEN 'n' THEN 10 WHEN 'r' THEN 13 WHEN 't' THEN 9
        WHEN 'v' THEN 11
        ELSE ascii(esc)
      END;
      i := i + 1;
    ELSIF esc IN ('x', 'X') THEN
      hex := substr(source, i + 1, 2);
      IF hex !~ '^[0-9a-fA-F]{2}$' THEN
        err := 'invalid escape sequence \x';
        ni := i;
        RETURN;
      END IF;
      code := ('x' || hex)::bit(8)::int;
      i := i + 3;
    ELSIF esc IN ('u', 'U') THEN
      IF is_bytes THEN
        err := format(
          'invalid escape sequence \%s in bytes literal', esc);
        ni := i;
        RETURN;
      END IF;
      width := CASE WHEN esc = 'u' THEN 4 ELSE 8 END;
      hex := substr(source, i + 1, width);
      IF hex !~ ('^[0-9a-fA-F]{' || width || '}$') THEN
        err := format('invalid escape sequence \%s', esc);
        ni := i;
        RETURN;
      END IF;
      code := ('x' || lpad(hex, 8, '0'))::bit(32)::int;
      i := i + 1 + width;
    ELSIF esc ~ '^[0-3]$' THEN
      hex := substr(source, i, 3);
      IF hex !~ '^[0-3][0-7][0-7]$' THEN
        err := 'invalid octal escape sequence';
        ni := i;
        RETURN;
      END IF;
      code := (substr(hex, 1, 1)::int * 64)
        + (substr(hex, 2, 1)::int * 8)
        + substr(hex, 3, 1)::int;
      i := i + 3;
    ELSE
      err := format('invalid escape sequence \%s', esc);
      ni := i;
      RETURN;
    END IF;

    IF is_bytes THEN
      IF code > 255 THEN
        err := 'byte escape out of range';
        ni := i;
        RETURN;
      END IF;
      bacc := bacc || decode(lpad(to_hex(code), 2, '0'), 'hex');
    ELSE
      IF code = 0 THEN
        -- PostgreSQL text cannot carry NUL; the conformance cases
        -- that need it are skipped by name. Still a clean error.
        err := 'NUL code point not representable in PostgreSQL text';
        ni := i;
        RETURN;
      ELSIF code < 0 OR code > 1114111
            OR (code >= 55296 AND code <= 57343) THEN
        err := 'invalid unicode code point';
        ni := i;
        RETURN;
      END IF;
      sacc := sacc || chr(code);
    END IF;
  END LOOP;

  ni := i;
  IF is_bytes THEN
    val := replace(encode(bacc, 'base64'), E'\n', '');
  ELSE
    val := sacc;
  END IF;
END;
$$;

-- Lexes one numeric literal starting at pos (a digit, or '.' followed
-- by a digit). Emits t = 'int' | 'uint' | 'float' with the raw text
-- as v (uint without its u suffix, hex kept as 0x...); the parser
-- converts to a value so that a preceding '-' can fold in first.
CREATE OR REPLACE FUNCTION cel._lex_number(
  source text,
  pos int,
  OUT t text,
  OUT v text,
  OUT ni int,
  OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  rest text := substr(source, pos);
  m    text;
BEGIN
  -- Hex integer.
  m := (regexp_match(rest, '^0[xX][0-9a-fA-F]+'))[1];
  IF m IS NOT NULL THEN
    IF substr(rest, length(m) + 1, 1) IN ('u', 'U') THEN
      t := 'uint';
      v := m;
      ni := pos + length(m) + 1;
    ELSE
      t := 'int';
      v := m;
      ni := pos + length(m);
    END IF;
    RETURN;
  END IF;

  -- Float: d+.d+[exp] | d+exp | .d+[exp]
  m := (regexp_match(rest,
    '^(\d+\.\d+([eE][+-]?\d+)?|\d+[eE][+-]?\d+|\.\d+([eE][+-]?\d+)?)'
  ))[1];
  IF m IS NOT NULL THEN
    t := 'float';
    v := m;
    ni := pos + length(m);
    RETURN;
  END IF;

  -- Decimal integer.
  m := (regexp_match(rest, '^\d+'))[1];
  IF m IS NULL THEN
    err := 'invalid numeric literal';
    ni := pos;
    RETURN;
  END IF;
  IF substr(rest, length(m) + 1, 1) IN ('u', 'U') THEN
    t := 'uint';
    v := m;
    ni := pos + length(m) + 1;
  ELSE
    t := 'int';
    v := m;
    ni := pos + length(m);
  END IF;
END;
$$;

-- Lexes a whole expression into a flat token array:
--   {"t": <type>, "v": <value>, "s": <start>, "e": <end>}
-- with 0-based code-point offsets and a final {"t": "eof"} token.
-- Token types: operator/punctuation text ('&&', '(', ...), 'ident',
-- 'esc_ident', 'int', 'uint', 'float', 'string', 'bytes', 'bool',
-- 'null', 'in', 'reserved', 'eof'.
CREATE OR REPLACE FUNCTION cel._lex(
  source text,
  flags jsonb,
  OUT toks jsonb,
  OUT err text,
  OUT errpos int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  n        int := length(source);
  i        int := 1;
  ch       text;
  two      text;
  start    int;
  m        text;
  raw      boolean;
  is_bytes boolean;
  qpos     int;
  s        record;
  acc      jsonb[] := '{}';
BEGIN
  WHILE i <= n LOOP
    ch := substr(source, i, 1);

    -- Whitespace.
    IF ch IN (' ', E'\t', E'\r', E'\n', E'\f', E'\v') THEN
      i := i + 1;
      CONTINUE;
    END IF;

    -- Comment to end of line.
    IF ch = '/' AND substr(source, i + 1, 1) = '/' THEN
      WHILE i <= n AND substr(source, i, 1) <> E'\n' LOOP
        i := i + 1;
      END LOOP;
      CONTINUE;
    END IF;

    start := i;

    -- Two-character operators.
    two := substr(source, i, 2);
    IF two IN ('&&', '||', '<=', '>=', '==', '!=') THEN
      acc := acc || jsonb_build_object(
        't', two, 's', start - 1, 'e', start + 1);
      i := i + 2;
      CONTINUE;
    END IF;

    -- Number (before '.'-punctuation: '.5' is a float).
    IF ch BETWEEN '0' AND '9'
       OR (ch = '.' AND substr(source, i + 1, 1) BETWEEN '0' AND '9')
    THEN
      SELECT * INTO s FROM cel._lex_number(source, i);
      IF s.err IS NOT NULL THEN
        err := s.err;
        errpos := s.ni - 1;
        RETURN;
      END IF;
      acc := acc || jsonb_build_object(
        't', s.t, 'v', s.v, 's', start - 1, 'e', s.ni - 1);
      i := s.ni;
      CONTINUE;
    END IF;

    -- Single-character operators and punctuation.
    IF ch IN ('(', ')', '[', ']', '{', '}', ',', '.', ':', '?',
              '+', '-', '*', '/', '%', '!', '<', '>', '=')
    THEN
      acc := acc || jsonb_build_object(
        't', ch, 's', start - 1, 'e', start);
      i := i + 1;
      CONTINUE;
    END IF;

    -- String and bytes literals, with r/R/b/B prefixes. Per the
    -- grammar, bytes is (b|B) followed by a string, whose own raw
    -- prefix comes second: br'' is valid, rb'' is not.
    raw := false;
    is_bytes := false;
    qpos := i;
    IF ch IN ('b', 'B') THEN
      IF substr(source, i + 1, 1) IN ('r', 'R')
         AND substr(source, i + 2, 1) IN ('''', '"') THEN
        is_bytes := true;
        raw := true;
        qpos := i + 2;
      ELSIF substr(source, i + 1, 1) IN ('''', '"') THEN
        is_bytes := true;
        qpos := i + 1;
      END IF;
    ELSIF ch IN ('r', 'R') THEN
      IF substr(source, i + 1, 1) IN ('''', '"') THEN
        raw := true;
        qpos := i + 1;
      END IF;
    END IF;

    IF ch IN ('''', '"') OR qpos > i THEN
      SELECT * INTO s
      FROM cel._lex_string(source, qpos, raw, is_bytes);
      IF s.err IS NOT NULL THEN
        err := s.err;
        errpos := s.ni - 1;
        RETURN;
      END IF;
      acc := acc || jsonb_build_object(
        't', CASE WHEN is_bytes THEN 'bytes' ELSE 'string' END,
        'v', s.val, 's', start - 1, 'e', s.ni - 1);
      i := s.ni;
      CONTINUE;
    END IF;

    -- Escaped identifier `a-b.c/d ` -- letters, digits, and _.-/
    -- plus space; valid only where the parser allows it, and only
    -- when the env enables the syntax.
    IF ch = '`' THEN
      IF NOT coalesce((flags ->> 'ident_escape')::boolean, false) THEN
        err := 'unsupported syntax: ''`''';
        errpos := start - 1;
        RETURN;
      END IF;
      m := (regexp_match(substr(source, i), '^`([A-Za-z0-9_./\- ]*)`'))[1];
      IF m IS NULL OR m = '' THEN
        err := 'invalid escaped identifier';
        errpos := start - 1;
        RETURN;
      END IF;
      acc := acc || jsonb_build_object(
        't', 'esc_ident', 'v', m,
        's', start - 1, 'e', start + length(m) + 1);
      i := i + length(m) + 2;
      CONTINUE;
    END IF;

    -- Identifier, keyword literal, 'in', or reserved word.
    IF ch = '_' OR (ch >= 'a' AND ch <= 'z') OR (ch >= 'A' AND ch <= 'Z')
    THEN
      m := (regexp_match(substr(source, i), '^[A-Za-z_][A-Za-z0-9_]*'))[1];
      IF m = 'true' OR m = 'false' THEN
        acc := acc || jsonb_build_object(
          't', 'bool', 'v', m = 'true',
          's', start - 1, 'e', start - 1 + length(m));
      ELSIF m = 'null' THEN
        acc := acc || jsonb_build_object(
          't', 'null', 's', start - 1, 'e', start - 1 + length(m));
      ELSIF m = 'in' THEN
        acc := acc || jsonb_build_object(
          't', 'in', 's', start - 1, 'e', start - 1 + length(m));
      ELSIF m IN ('as', 'break', 'const', 'continue', 'else', 'for',
                  'function', 'if', 'import', 'let', 'loop', 'package',
                  'namespace', 'return', 'var', 'void', 'while')
      THEN
        acc := acc || jsonb_build_object(
          't', 'reserved', 'v', m,
          's', start - 1, 'e', start - 1 + length(m));
      ELSE
        acc := acc || jsonb_build_object(
          't', 'ident', 'v', m,
          's', start - 1, 'e', start - 1 + length(m));
      END IF;
      i := i + length(m);
      CONTINUE;
    END IF;

    err := format('unexpected character %s', quote_literal(ch));
    errpos := start - 1;
    RETURN;
  END LOOP;

  acc := acc || jsonb_build_object('t', 'eof', 's', n, 'e', n);
  toks := to_jsonb(acc);
END;
$$;

COMMIT;

BEGIN;

-- Line/column (both 0-based line, 0-based col) for an offset, for
-- parse error reporting. Conformance never string-matches parse
-- errors; this exists for humans.
CREATE OR REPLACE FUNCTION cel._line_col(
  source text, off int, OUT line int, OUT col int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  before text := substr(source, 1, off);
  last_nl int;
BEGIN
  line := length(before) - length(replace(before, E'\n', ''));
  last_nl := length(before)
    - position(E'\n' IN reverse(before)) + 1;
  IF position(E'\n' IN before) = 0 THEN
    col := off;
  ELSE
    col := off - last_nl;
  END IF;
END;
$$;

-- The parse-failure envelope: {"errors": [{"msg","line","col"}]}.
CREATE OR REPLACE FUNCTION cel._parse_errors(
  source text, msg text, off int
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('errors', jsonb_build_array(
    jsonb_build_object(
      'msg', msg,
      'line', lc.line + 1,
      'col', lc.col + 1
    )))
  FROM cel._line_col(source, coalesce(off, 0)) lc;
$$;

-- Rebalances a chained && / || into a balanced binary tree, as
-- cel-go's default balancer does, keeping eval recursion logarithmic
-- in chain length.
CREATE OR REPLACE FUNCTION cel._p_balance(
  elems jsonb,
  fn text,
  id bigint,
  OUT node jsonb,
  OUT nid bigint
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  cnt int := jsonb_array_length(elems);
  mid int;
  l   record;
  r   record;
BEGIN
  IF cnt = 1 THEN
    node := elems -> 0;
    nid := id;
    RETURN;
  END IF;

  mid := (cnt + 1) / 2;

  SELECT b.node, b.nid INTO l
  FROM cel._p_balance(
    (SELECT jsonb_agg(e) FROM jsonb_array_elements(elems)
       WITH ORDINALITY t(e, o) WHERE o <= mid),
    fn, id) b;
  SELECT b.node, b.nid INTO r
  FROM cel._p_balance(
    (SELECT jsonb_agg(e) FROM jsonb_array_elements(elems)
       WITH ORDINALITY t(e, o) WHERE o > mid),
    fn, l.nid) b;

  nid := r.nid + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'call', 'fn', fn,
    'args', jsonb_build_array(l.node, r.node),
    's', l.node -> 's', 'e', r.node -> 'e');
END;
$$;

-- Walks a finished tree: extracts {"<id>": [start, stop]} offsets and
-- the macro_calls recorded inline under "mc", stripping the working
-- keys from the nodes.
CREATE OR REPLACE FUNCTION cel._p_finalize(
  node jsonb,
  OUT clean jsonb,
  OUT offsets jsonb,
  OUT macro_calls jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k       text := node ->> 'k';
  child   record;
  entry   jsonb;
  cleaned jsonb;
  n_ent   jsonb[] := '{}';
  key     text;
BEGIN
  offsets := '{}'::jsonb;
  macro_calls := '{}'::jsonb;

  IF node ? 's' THEN
    offsets := jsonb_build_object(
      node ->> 'id', jsonb_build_array(node -> 's', node -> 'e'));
  END IF;
  IF node ? 'mc' THEN
    SELECT f.clean INTO cleaned FROM cel._p_finalize(node -> 'mc') f;
    macro_calls := jsonb_build_object(node ->> 'id', cleaned);
  END IF;

  clean := node - 's' - 'e' - 'mc';

  -- Recurse into child expression positions per kind.
  FOR key IN
    SELECT unnest(CASE k
      WHEN 'select' THEN ARRAY['op']
      WHEN 'call'   THEN ARRAY['target']
      WHEN 'comp'   THEN ARRAY['range','init','cond','step','result']
      ELSE ARRAY[]::text[]
    END)
  LOOP
    IF clean ? key THEN
      SELECT * INTO child FROM cel._p_finalize(clean -> key);
      clean := jsonb_set(clean, ARRAY[key], child.clean);
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
    END IF;
  END LOOP;

  IF k = 'call' AND clean ? 'args' THEN
    FOR entry IN SELECT e FROM jsonb_array_elements(clean -> 'args') e
    LOOP
      SELECT * INTO child FROM cel._p_finalize(entry);
      n_ent := n_ent || child.clean;
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
    END LOOP;
    clean := jsonb_set(clean, '{args}', to_jsonb(n_ent));
  ELSIF k = 'list' THEN
    FOR entry IN SELECT e FROM jsonb_array_elements(clean -> 'elems') e
    LOOP
      SELECT * INTO child FROM cel._p_finalize(entry);
      n_ent := n_ent || child.clean;
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
    END LOOP;
    clean := jsonb_set(clean, '{elems}', to_jsonb(n_ent));
  ELSIF k = 'map' THEN
    FOR entry IN SELECT e FROM jsonb_array_elements(clean -> 'entries') e
    LOOP
      SELECT * INTO child FROM cel._p_finalize(entry -> 'k');
      entry := jsonb_set(entry, '{k}', child.clean);
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
      SELECT * INTO child FROM cel._p_finalize(entry -> 'v');
      entry := jsonb_set(entry, '{v}', child.clean);
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
      n_ent := n_ent || entry;
    END LOOP;
    clean := jsonb_set(clean, '{entries}', to_jsonb(n_ent));
  ELSIF k = 'struct' THEN
    FOR entry IN SELECT e FROM jsonb_array_elements(clean -> 'fields') e
    LOOP
      SELECT * INTO child FROM cel._p_finalize(entry -> 'v');
      entry := jsonb_set(entry, '{v}', child.clean);
      offsets := offsets || child.offsets;
      macro_calls := macro_calls || child.macro_calls;
      n_ent := n_ent || entry;
    END LOOP;
    clean := jsonb_set(clean, '{fields}', to_jsonb(n_ent));
  END IF;
END;
$$;

COMMIT;

BEGIN;

-- Hex digits to numeric (uint64-sized values overflow bigint).
CREATE OR REPLACE FUNCTION cel._p_hex(h text)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  n numeric := 0;
  c text;
BEGIN
  FOREACH c IN ARRAY string_to_array(lower(h), NULL) LOOP
    n := n * 16 + position(c IN '0123456789abcdef') - 1;
  END LOOP;
  RETURN n;
END;
$$;

-- Converts a numeric literal token into a tagged value, applying an
-- already-folded sign. The sign folds at this level so that
-- -9223372036854775808 -- whose absolute value overflows int64 --
-- parses exactly, as in cel-go, where the minus is part of the
-- literal production.
CREATE OR REPLACE FUNCTION cel._p_number_lit(
  tok jsonb,
  negate boolean,
  OUT val jsonb,
  OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  t   text := tok ->> 't';
  raw text := tok ->> 'v';
  n   numeric;
BEGIN
  IF t = 'float' THEN
    n := raw::numeric;
    IF negate THEN
      n := -n;
    END IF;
    IF abs(n) > 1.7976931348623157e308::numeric THEN
      -- Overflow is a parse error in cel-go ("invalid double
      -- literal", measured); underflow is not: values at or below
      -- half the minimum subnormal (2^-1075, ties-to-even) round to
      -- signed zero, which Postgres's cast would instead reject as
      -- out of range, so they short-circuit here.
      err := 'invalid double literal';
      RETURN;
    END IF;
    IF n <> 0
       AND abs(n) <= 2.4703282292062327e-324::numeric THEN
      val := jsonb_build_object('@t', 'double', 'v',
        to_jsonb((CASE WHEN n < 0 THEN '-0' ELSE '0' END)::float8));
      RETURN;
    END IF;
    val := jsonb_build_object('@t', 'double', 'v', to_jsonb(n::float8));
    RETURN;
  END IF;

  IF raw ~ '^0[xX]' THEN
    n := cel._p_hex(substr(raw, 3));
  ELSE
    n := raw::numeric;
  END IF;

  IF t = 'uint' THEN
    IF negate OR n > 18446744073709551615::numeric THEN
      err := 'invalid uint literal';
      RETURN;
    END IF;
    val := jsonb_build_object('@t', 'uint', 'v', to_jsonb(n));
    RETURN;
  END IF;

  IF negate THEN
    n := -n;
  END IF;
  IF n < -9223372036854775808::numeric
     OR n > 9223372036854775807::numeric THEN
    err := 'invalid int literal';
    RETURN;
  END IF;
  val := jsonb_build_object('@t', 'int', 'v', to_jsonb(n));
END;
$$;

-- Builds a call node, expanding it through the macro registry when a
-- (function, arity, receiver-style) row is visible in the env --
-- day-one invariant 5: the standard macros take this exact path. An
-- expansion records the original call under "mc" for source info.
CREATE OR REPLACE FUNCTION cel._p_call(
  fn text,
  target jsonb,
  args jsonb,
  id bigint,
  s int,
  e int,
  mac jsonb,
  is_member boolean,
  OUT node jsonb,
  OUT nid bigint,
  OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  arity    int := jsonb_array_length(args);
  proc     text;
  original jsonb;
  x        record;
BEGIN
  nid := id + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'call', 'fn', fn, 'args', args, 's', s, 'e', e);
  IF target IS NOT NULL THEN
    node := node || jsonb_build_object('target', target);
  END IF;

  proc := coalesce(
    mac ->> format('%s/%s/%s', fn, arity, is_member::int),
    mac ->> format('%s/-1/%s', fn, is_member::int));
  IF proc IS NULL THEN
    RETURN;
  END IF;

  original := node;
  EXECUTE format('SELECT * FROM %s($1, $2, $3)', proc)
  INTO x
  USING target, args, nid;

  IF x.err IS NOT NULL THEN
    err := x.err;
    RETURN;
  END IF;
  IF x.expr IS NULL THEN
    RETURN;   -- expander declined; keep the plain call
  END IF;

  node := x.expr || jsonb_build_object('mc', original);
  nid := x.next_id_out;
END;
$$;

COMMIT;

BEGIN;

-- The recursive grammar. Every function shares one signature:
--   (tk, p, id, d, mac, fl) -> (node, np, nid, err, ep)
-- tk: token array; p: cursor; id: last assigned node id; d: depth
-- budget consumed; mac: visible macros; fl: env flags. Nodes carry
-- their source span inline as s/e until cel._p_finalize lifts the
-- spans into the envelope. err/ep report the first failure; every
-- call site checks err and bails, because errors are values here,
-- not exceptions.

-- expr: or ('?' or ':' expr)?  (ternary is right-associative)
CREATE OR REPLACE FUNCTION cel._p_expr(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c record;
  t record;
  f record;
  x record;
BEGIN
  IF d >= 200 THEN
    err := 'expression recursion limit exceeded: 200';
    ep := (tk -> p ->> 's')::int;
    RETURN;
  END IF;

  SELECT * INTO c FROM cel._p_or(tk, p, id, d + 1, mac, fl);
  IF c.err IS NOT NULL THEN
    node := NULL; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;

  IF tk -> np ->> 't' <> '?' THEN
    RETURN;
  END IF;

  SELECT * INTO t FROM cel._p_or(tk, np + 1, nid, d + 1, mac, fl);
  IF t.err IS NOT NULL THEN
    err := t.err; ep := t.ep;
    RETURN;
  END IF;
  IF tk -> t.np ->> 't' <> ':' THEN
    err := 'expected '':'' in ternary';
    ep := (tk -> t.np ->> 's')::int;
    RETURN;
  END IF;
  SELECT * INTO f FROM cel._p_expr(tk, t.np + 1, t.nid, d + 1, mac, fl);
  IF f.err IS NOT NULL THEN
    err := f.err; ep := f.ep;
    RETURN;
  END IF;

  SELECT * INTO x FROM cel._p_call(
    '_?_:_', NULL,
    jsonb_build_array(node, t.node, f.node),
    f.nid, (node ->> 's')::int, (f.node ->> 'e')::int, mac, false);
  IF x.err IS NOT NULL THEN
    err := x.err; ep := (node ->> 's')::int;
    RETURN;
  END IF;
  node := x.node; np := f.np; nid := x.nid;
END;
$$;

-- Chained || gathers operands and rebalances into a balanced tree.
CREATE OR REPLACE FUNCTION cel._p_or(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c     record;
  b     record;
  elems jsonb;
BEGIN
  SELECT * INTO c FROM cel._p_and(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;
  elems := jsonb_build_array(node);

  WHILE tk -> np ->> 't' = '||' LOOP
    SELECT * INTO c FROM cel._p_and(tk, np + 1, nid, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    elems := elems || jsonb_build_array(c.node);
    np := c.np; nid := c.nid;
  END LOOP;

  IF jsonb_array_length(elems) > 1 THEN
    SELECT * INTO b FROM cel._p_balance(elems, '_||_', nid);
    node := b.node; nid := b.nid;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION cel._p_and(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c     record;
  b     record;
  elems jsonb;
BEGIN
  SELECT * INTO c FROM cel._p_rel(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;
  elems := jsonb_build_array(node);

  WHILE tk -> np ->> 't' = '&&' LOOP
    SELECT * INTO c FROM cel._p_rel(tk, np + 1, nid, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    elems := elems || jsonb_build_array(c.node);
    np := c.np; nid := c.nid;
  END LOOP;

  IF jsonb_array_length(elems) > 1 THEN
    SELECT * INTO b FROM cel._p_balance(elems, '_&&_', nid);
    node := b.node; nid := b.nid;
  END IF;
END;
$$;

-- Left-associative binary tiers: relations, additive,
-- multiplicative. One implementation parameterized by the operator
-- map and the next-tighter parser would need dynamic SQL per call;
-- three small copies keep the hot path static.
CREATE OR REPLACE FUNCTION cel._p_rel(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c  record;
  x  record;
  tt text;
  fn text;
BEGIN
  SELECT * INTO c FROM cel._p_add(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;

  LOOP
    tt := tk -> np ->> 't';
    fn := CASE tt
      WHEN '<'  THEN '_<_'  WHEN '<=' THEN '_<=_'
      WHEN '>'  THEN '_>_'  WHEN '>=' THEN '_>=_'
      WHEN '==' THEN '_==_' WHEN '!=' THEN '_!=_'
      WHEN 'in' THEN '@in'
    END;
    EXIT WHEN fn IS NULL;

    SELECT * INTO c FROM cel._p_add(tk, np + 1, nid, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    SELECT * INTO x FROM cel._p_call(
      fn, NULL, jsonb_build_array(node, c.node), c.nid,
      (node ->> 's')::int, (c.node ->> 'e')::int, mac, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := (node ->> 's')::int;
      RETURN;
    END IF;
    node := x.node; np := c.np; nid := x.nid;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION cel._p_add(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c  record;
  x  record;
  tt text;
  fn text;
BEGIN
  SELECT * INTO c FROM cel._p_mul(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;

  LOOP
    tt := tk -> np ->> 't';
    fn := CASE tt WHEN '+' THEN '_+_' WHEN '-' THEN '_-_' END;
    EXIT WHEN fn IS NULL;

    SELECT * INTO c FROM cel._p_mul(tk, np + 1, nid, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    SELECT * INTO x FROM cel._p_call(
      fn, NULL, jsonb_build_array(node, c.node), c.nid,
      (node ->> 's')::int, (c.node ->> 'e')::int, mac, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := (node ->> 's')::int;
      RETURN;
    END IF;
    node := x.node; np := c.np; nid := x.nid;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION cel._p_mul(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c  record;
  x  record;
  tt text;
  fn text;
BEGIN
  SELECT * INTO c FROM cel._p_unary(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;

  LOOP
    tt := tk -> np ->> 't';
    fn := CASE tt
      WHEN '*' THEN '_*_' WHEN '/' THEN '_/_' WHEN '%' THEN '_%_'
    END;
    EXIT WHEN fn IS NULL;

    SELECT * INTO c FROM cel._p_unary(tk, np + 1, nid, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    SELECT * INTO x FROM cel._p_call(
      fn, NULL, jsonb_build_array(node, c.node), c.nid,
      (node ->> 's')::int, (c.node ->> 'e')::int, mac, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := (node ->> 's')::int;
      RETURN;
    END IF;
    node := x.node; np := c.np; nid := x.nid;
  END LOOP;
END;
$$;

-- Unary ! and -. Even-length chains collapse to the operand; an odd
-- chain of - directly on a numeric literal folds into the literal
-- (which is how -9223372036854775808 parses exactly).
CREATE OR REPLACE FUNCTION cel._p_unary(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  op    text := tk -> p ->> 't';
  cnt   int := 0;
  q     int := p;
  c     record;
  x     record;
  s0    int;
  tok   jsonb;
BEGIN
  IF op NOT IN ('!', '-') THEN
    SELECT * INTO c FROM cel._p_member(tk, p, id, d, mac, fl);
    node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;

  s0 := (tk -> p ->> 's')::int;
  WHILE tk -> q ->> 't' = op LOOP
    cnt := cnt + 1;
    q := q + 1;
  END LOOP;

  -- Sign fold: odd minus chain directly on a numeric literal.
  tok := tk -> q;
  IF op = '-' AND cnt % 2 = 1 AND tok ->> 't' IN ('int', 'float') THEN
    SELECT * INTO x FROM cel._p_number_lit(tok, true);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := (tok ->> 's')::int;
      RETURN;
    END IF;
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit', 'v', x.val,
      's', s0, 'e', tok -> 'e');
    -- Postfix still applies to the folded literal.
    SELECT * INTO c FROM cel._p_postfix(node, tk, q + 1, nid, d, mac, fl);
    node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;

  SELECT * INTO c FROM cel._p_member(tk, q, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  node := c.node; np := c.np; nid := c.nid;

  IF cnt % 2 = 1 THEN
    SELECT * INTO x FROM cel._p_call(
      CASE op WHEN '!' THEN '!_' ELSE '-_' END,
      NULL, jsonb_build_array(node), nid,
      s0, (node ->> 'e')::int, mac, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := s0;
      RETURN;
    END IF;
    node := x.node; nid := x.nid;
  END IF;
END;
$$;

-- member: primary + the postfix chain.
CREATE OR REPLACE FUNCTION cel._p_member(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c record;
BEGIN
  SELECT * INTO c FROM cel._p_primary(tk, p, id, d, mac, fl);
  IF c.err IS NOT NULL THEN
    np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;
  SELECT * INTO c
  FROM cel._p_postfix(c.node, tk, c.np, c.nid, d, mac, fl);
  node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
END;
$$;

-- The postfix chain on an already-parsed operand: .field, .f(args),
-- [index], and the optional-syntax forms .?field and [?index], which
-- are errors unless the env sets optional_syntax.
CREATE OR REPLACE FUNCTION cel._p_postfix(
  operand jsonb, tk jsonb, p int, id bigint, d int,
  mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  tt       text;
  nt       jsonb;
  name     text;
  optional boolean;
  c        record;
  x        record;
  args     jsonb;
  s0       int := (operand ->> 's')::int;
  opt_on   boolean :=
    coalesce((fl ->> 'optional_syntax')::boolean, false);
BEGIN
  node := operand; np := p; nid := id;

  LOOP
    tt := tk -> np ->> 't';

    IF tt = '.' THEN
      optional := false;
      nt := tk -> (np + 1);
      IF nt ->> 't' = '?' THEN
        IF NOT opt_on THEN
          err := 'unsupported syntax ''.?''';
          ep := (tk -> np ->> 's')::int;
          RETURN;
        END IF;
        optional := true;
        nt := tk -> (np + 2);
      END IF;

      -- Reserved words are permitted as selectors (the corpus's
      -- parse/selectors section) -- only true/false/null/in are
      -- full keywords and stay excluded.
      IF nt ->> 't' NOT IN ('ident', 'esc_ident', 'reserved') THEN
        err := 'expected field or method name after ''.''';
        ep := (nt ->> 's')::int;
        RETURN;
      END IF;
      name := nt ->> 'v';
      np := np + CASE WHEN optional THEN 3 ELSE 2 END;

      IF optional THEN
        -- .?f  =>  _?._(operand, "f")
        nid := nid + 1;
        SELECT * INTO x FROM cel._p_call(
          '_?._', NULL,
          jsonb_build_array(node, jsonb_build_object(
            'id', nid, 'k', 'lit',
            'v', jsonb_build_object('@t', 'string', 'v', name),
            's', nt -> 's', 'e', nt -> 'e')),
          nid, s0, (nt ->> 'e')::int, mac, false);
        IF x.err IS NOT NULL THEN
          err := x.err; ep := s0;
          RETURN;
        END IF;
        node := x.node; nid := x.nid;
        CONTINUE;
      END IF;

      IF tk -> np ->> 't' = '(' THEN
        -- Receiver-style call.
        SELECT * INTO c FROM cel._p_args(tk, np + 1, nid, d, mac, fl);
        IF c.err IS NOT NULL THEN
          err := c.err; ep := c.ep;
          RETURN;
        END IF;
        SELECT * INTO x FROM cel._p_call(
          name, node, c.node, c.nid,
          s0, (tk -> (c.np - 1) ->> 'e')::int, mac, true);
        IF x.err IS NOT NULL THEN
          err := x.err; ep := (nt ->> 's')::int;
          RETURN;
        END IF;
        node := x.node; np := c.np; nid := x.nid;
        CONTINUE;
      END IF;

      nid := nid + 1;
      node := jsonb_build_object(
        'id', nid, 'k', 'select', 'op', node, 'field', name,
        's', s0, 'e', nt -> 'e');
      CONTINUE;
    END IF;

    IF tt = '[' THEN
      optional := false;
      IF tk -> (np + 1) ->> 't' = '?' THEN
        IF NOT opt_on THEN
          err := 'unsupported syntax ''[?''';
          ep := (tk -> np ->> 's')::int;
          RETURN;
        END IF;
        optional := true;
      END IF;

      SELECT * INTO c FROM cel._p_expr(
        tk, np + CASE WHEN optional THEN 2 ELSE 1 END,
        nid, d + 1, mac, fl);
      IF c.err IS NOT NULL THEN
        err := c.err; ep := c.ep;
        RETURN;
      END IF;
      IF tk -> c.np ->> 't' <> ']' THEN
        err := 'expected '']''';
        ep := (tk -> c.np ->> 's')::int;
        RETURN;
      END IF;
      SELECT * INTO x FROM cel._p_call(
        CASE WHEN optional THEN '_[?_]' ELSE '_[_]' END,
        NULL, jsonb_build_array(node, c.node), c.nid,
        s0, (tk -> c.np ->> 'e')::int, mac, false);
      IF x.err IS NOT NULL THEN
        err := x.err; ep := s0;
        RETURN;
      END IF;
      node := x.node; np := c.np + 1; nid := x.nid;
      CONTINUE;
    END IF;

    EXIT;
  END LOOP;
END;
$$;

-- Call argument list: '(' already consumed; returns a jsonb array of
-- argument nodes and leaves np just past ')'.
CREATE OR REPLACE FUNCTION cel._p_args(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c record;
BEGIN
  node := '[]'::jsonb; np := p; nid := id;

  IF tk -> np ->> 't' = ')' THEN
    np := np + 1;
    RETURN;
  END IF;

  LOOP
    SELECT * INTO c FROM cel._p_expr(tk, np, nid, d + 1, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    node := node || jsonb_build_array(c.node);
    np := c.np; nid := c.nid;

    IF tk -> np ->> 't' = ',' THEN
      np := np + 1;
      CONTINUE;
    END IF;
    EXIT;
  END LOOP;

  IF tk -> np ->> 't' <> ')' THEN
    err := 'expected '')''';
    ep := (tk -> np ->> 's')::int;
    RETURN;
  END IF;
  np := np + 1;
END;
$$;

COMMIT;

BEGIN;

-- List literal: '[' consumed. Trailing comma allowed. '?e' elements
-- (optionals extension) record their indices under "opt".
CREATE OR REPLACE FUNCTION cel._p_list(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb, s0 int,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c     record;
  elems jsonb := '[]';
  opts  jsonb := '[]';
  idx   int := 0;
  opt_on boolean :=
    coalesce((fl ->> 'optional_syntax')::boolean, false);
BEGIN
  np := p; nid := id;

  WHILE tk -> np ->> 't' <> ']' LOOP
    IF tk -> np ->> 't' = '?' THEN
      IF NOT opt_on THEN
        err := 'unsupported syntax ''?''';
        ep := (tk -> np ->> 's')::int;
        RETURN;
      END IF;
      opts := opts || to_jsonb(idx);
      np := np + 1;
    END IF;

    SELECT * INTO c FROM cel._p_expr(tk, np, nid, d + 1, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    elems := elems || jsonb_build_array(c.node);
    np := c.np; nid := c.nid;
    idx := idx + 1;

    IF tk -> np ->> 't' = ',' THEN
      np := np + 1;
    ELSIF tk -> np ->> 't' <> ']' THEN
      err := 'expected '','' or '']''';
      ep := (tk -> np ->> 's')::int;
      RETURN;
    END IF;
  END LOOP;

  nid := nid + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'list', 'elems', elems,
    's', s0, 'e', tk -> np -> 'e');
  IF jsonb_array_length(opts) > 0 THEN
    node := node || jsonb_build_object('opt', opts);
  END IF;
  np := np + 1;
END;
$$;

-- Map literal: '{' consumed. Keys are full expressions (the checker
-- restricts them); entries carry their own ids as in cel-go.
CREATE OR REPLACE FUNCTION cel._p_map(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb, s0 int,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k       record;
  v       record;
  entries jsonb := '[]';
  optional boolean;
  opt_on  boolean :=
    coalesce((fl ->> 'optional_syntax')::boolean, false);
BEGIN
  np := p; nid := id;

  WHILE tk -> np ->> 't' <> '}' LOOP
    optional := false;
    IF tk -> np ->> 't' = '?' THEN
      IF NOT opt_on THEN
        err := 'unsupported syntax ''?''';
        ep := (tk -> np ->> 's')::int;
        RETURN;
      END IF;
      optional := true;
      np := np + 1;
    END IF;

    SELECT * INTO k FROM cel._p_expr(tk, np, nid, d + 1, mac, fl);
    IF k.err IS NOT NULL THEN
      err := k.err; ep := k.ep;
      RETURN;
    END IF;
    IF tk -> k.np ->> 't' <> ':' THEN
      err := 'expected '':''';
      ep := (tk -> k.np ->> 's')::int;
      RETURN;
    END IF;
    SELECT * INTO v FROM cel._p_expr(tk, k.np + 1, k.nid, d + 1, mac, fl);
    IF v.err IS NOT NULL THEN
      err := v.err; ep := v.ep;
      RETURN;
    END IF;

    nid := v.nid + 1;
    entries := entries || jsonb_build_array(jsonb_build_object(
      'id', nid, 'k', k.node, 'v', v.node, 'opt', optional));
    np := v.np;

    IF tk -> np ->> 't' = ',' THEN
      np := np + 1;
    ELSIF tk -> np ->> 't' <> '}' THEN
      err := 'expected '','' or ''}''';
      ep := (tk -> np ->> 's')::int;
      RETURN;
    END IF;
  END LOOP;

  nid := nid + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'map', 'entries', entries,
    's', s0, 'e', tk -> np -> 'e');
  np := np + 1;
END;
$$;

-- Message literal: the type name and '{' are consumed. Field names
-- are identifiers or escaped identifiers.
CREATE OR REPLACE FUNCTION cel._p_struct(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  type_name text, s0 int,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v       record;
  fields  jsonb := '[]';
  fname   text;
  optional boolean;
  nt      jsonb;
  opt_on  boolean :=
    coalesce((fl ->> 'optional_syntax')::boolean, false);
BEGIN
  np := p; nid := id;

  WHILE tk -> np ->> 't' <> '}' LOOP
    optional := false;
    IF tk -> np ->> 't' = '?' THEN
      IF NOT opt_on THEN
        err := 'unsupported syntax ''?''';
        ep := (tk -> np ->> 's')::int;
        RETURN;
      END IF;
      optional := true;
      np := np + 1;
    END IF;

    nt := tk -> np;
    IF nt ->> 't' NOT IN ('ident', 'esc_ident') THEN
      err := 'expected field name';
      ep := (nt ->> 's')::int;
      RETURN;
    END IF;
    fname := nt ->> 'v';
    IF tk -> (np + 1) ->> 't' <> ':' THEN
      err := 'expected '':''';
      ep := (tk -> (np + 1) ->> 's')::int;
      RETURN;
    END IF;

    SELECT * INTO v FROM cel._p_expr(tk, np + 2, nid, d + 1, mac, fl);
    IF v.err IS NOT NULL THEN
      err := v.err; ep := v.ep;
      RETURN;
    END IF;

    nid := v.nid + 1;
    fields := fields || jsonb_build_array(jsonb_build_object(
      'id', nid, 'name', fname, 'v', v.node, 'opt', optional));
    np := v.np;

    IF tk -> np ->> 't' = ',' THEN
      np := np + 1;
    ELSIF tk -> np ->> 't' <> '}' THEN
      err := 'expected '','' or ''}''';
      ep := (tk -> np ->> 's')::int;
      RETURN;
    END IF;
  END LOOP;

  nid := nid + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'struct', 'type', type_name, 'fields', fields,
    's', s0, 'e', tk -> np -> 'e');
  np := np + 1;
END;
$$;

-- primary: literals, identifiers, global calls, parens, list/map/
-- message literals. A dotted identifier path followed by '{' is a
-- message literal; the lookahead scan consumes nothing on miss.
CREATE OR REPLACE FUNCTION cel._p_primary(
  tk jsonb, p int, id bigint, d int, mac jsonb, fl jsonb,
  OUT node jsonb, OUT np int, OUT nid bigint,
  OUT err text, OUT ep int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  tok    jsonb := tk -> p;
  tt     text := tk -> p ->> 't';
  s0     int := (tk -> p ->> 's')::int;
  c      record;
  x      record;
  name   text;
  j      int;
  leading_dot boolean := false;
BEGIN
  np := p; nid := id;

  -- Literals.
  IF tt IN ('int', 'uint', 'float') THEN
    SELECT * INTO x FROM cel._p_number_lit(tok, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := s0;
      RETURN;
    END IF;
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit', 'v', x.val, 's', s0, 'e', tok -> 'e');
    np := p + 1;
    RETURN;
  ELSIF tt = 'string' THEN
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit',
      'v', jsonb_build_object('@t', 'string', 'v', tok -> 'v'),
      's', s0, 'e', tok -> 'e');
    np := p + 1;
    RETURN;
  ELSIF tt = 'bytes' THEN
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bytes', 'v', tok -> 'v'),
      's', s0, 'e', tok -> 'e');
    np := p + 1;
    RETURN;
  ELSIF tt = 'bool' THEN
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bool', 'v', tok -> 'v'),
      's', s0, 'e', tok -> 'e');
    np := p + 1;
    RETURN;
  ELSIF tt = 'null' THEN
    nid := id + 1;
    node := jsonb_build_object(
      'id', nid, 'k', 'lit',
      'v', jsonb_build_object('@t', 'null', 'v', NULL),
      's', s0, 'e', tok -> 'e');
    np := p + 1;
    RETURN;
  END IF;

  -- Parenthesized expression.
  IF tt = '(' THEN
    SELECT * INTO c FROM cel._p_expr(tk, p + 1, id, d + 1, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    IF tk -> c.np ->> 't' <> ')' THEN
      err := 'expected '')''';
      ep := (tk -> c.np ->> 's')::int;
      RETURN;
    END IF;
    node := c.node; np := c.np + 1; nid := c.nid;
    RETURN;
  END IF;

  IF tt = '[' THEN
    SELECT * INTO c
    FROM cel._p_list(tk, p + 1, id, d, mac, fl, s0);
    node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;

  IF tt = '{' THEN
    SELECT * INTO c
    FROM cel._p_map(tk, p + 1, id, d, mac, fl, s0);
    node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;

  IF tt = 'reserved' THEN
    err := format('reserved identifier: %s', tok ->> 'v');
    ep := s0;
    RETURN;
  END IF;

  -- Leading '.' root-qualifies the identifier that follows.
  IF tt = '.' THEN
    leading_dot := true;
    np := p + 1;
    tok := tk -> np;
    tt := tok ->> 't';
    IF tt = 'reserved' THEN
      err := format('reserved identifier: %s', tok ->> 'v');
      ep := (tok ->> 's')::int;
      RETURN;
    END IF;
    IF tt <> 'ident' THEN
      err := 'expected identifier after ''.''';
      ep := (tok ->> 's')::int;
      RETURN;
    END IF;
  END IF;

  IF tt <> 'ident' THEN
    IF tt = 'eof' THEN
      err := 'unexpected end of expression';
    ELSE
      err := format('unexpected token %s',
        quote_literal(coalesce(tok ->> 'v', tt)));
    END IF;
    ep := s0;
    RETURN;
  END IF;

  name := tok ->> 'v';

  -- Message-literal lookahead: ident ('.' ident)* '{'. The scan
  -- consumes nothing unless the '{' really is there.
  j := np + 1;
  WHILE tk -> j ->> 't' = '.' AND tk -> (j + 1) ->> 't' = 'ident' LOOP
    j := j + 2;
  END LOOP;
  IF tk -> j ->> 't' = '{' THEN
    -- Rebuild the dotted name from the scanned tokens.
    DECLARE
      k2 int := np + 1;
    BEGIN
      WHILE k2 < j LOOP
        name := name || '.' || (tk -> (k2 + 1) ->> 'v');
        k2 := k2 + 2;
      END LOOP;
    END;
    IF leading_dot THEN
      name := '.' || name;
    END IF;
    SELECT * INTO c
    FROM cel._p_struct(tk, j + 1, id, d, mac, fl, name, s0);
    node := c.node; np := c.np; nid := c.nid; err := c.err; ep := c.ep;
    RETURN;
  END IF;

  -- Global call.
  IF tk -> (np + 1) ->> 't' = '(' THEN
    SELECT * INTO c FROM cel._p_args(tk, np + 2, id, d, mac, fl);
    IF c.err IS NOT NULL THEN
      err := c.err; ep := c.ep;
      RETURN;
    END IF;
    SELECT * INTO x FROM cel._p_call(
      CASE WHEN leading_dot THEN '.' || name ELSE name END,
      NULL, c.node, c.nid,
      s0, (tk -> (c.np - 1) ->> 'e')::int, mac, false);
    IF x.err IS NOT NULL THEN
      err := x.err; ep := s0;
      RETURN;
    END IF;
    node := x.node; np := c.np; nid := x.nid;
    RETURN;
  END IF;

  -- Plain identifier.
  nid := id + 1;
  node := jsonb_build_object(
    'id', nid, 'k', 'ident',
    'name', CASE WHEN leading_dot THEN '.' || name ELSE name END,
    's', s0, 'e', tok -> 'e');
  np := np + 1;
END;
$$;

COMMIT;

BEGIN;

-- Macro expanders. Each has the registry signature
--   (target jsonb, args jsonb, next_id bigint)
--     -> (expr jsonb, next_id bigint, err text)
-- and builds the exact comprehension shapes cel-go's standard macros
-- produce, accumulator named @result. The standard six register
-- through cel.macro like any extension's -- no privileged path.

-- Validates a comprehension iteration variable argument.
CREATE OR REPLACE FUNCTION cel._mx_itervar(
  arg jsonb, OUT name text, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
BEGIN
  IF arg ->> 'k' <> 'ident' THEN
    IF arg ->> 'k' = 'select' THEN
      err := 'argument must be a simple name';
    ELSE
      err := 'argument is not an identifier';
    END IF;
    RETURN;
  END IF;
  name := arg ->> 'name';
  IF name IN ('@result', '__result__') THEN
    err := 'iteration variable overwrites accumulator variable';
  END IF;
END;
$$;

-- has(e): a select becomes a presence test; anything else is an
-- error. No new ids are needed.
CREATE OR REPLACE FUNCTION cel._mx_has(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  arg jsonb := args -> 0;
BEGIN
  next_id_out := next_id;
  IF arg ->> 'k' <> 'select' THEN
    err := 'invalid argument to has() macro';
    RETURN;
  END IF;
  expr := arg || jsonb_build_object('test', true);
END;
$$;

-- Shared assembly for the five standard comprehensions. kind picks
-- the init/cond/step/result wiring; p and t are the predicate /
-- transform arguments where the macro has them.
CREATE OR REPLACE FUNCTION cel._mx_fold(
  kind text,
  target jsonb, iter text, p jsonb, t jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  id bigint := next_id;
  cs jsonb := target -> 's';
  ce jsonb := coalesce(t, p, target) -> 'e';
  init jsonb;
  cond jsonb;
  step jsonb;
  result jsonb;
  accu jsonb;
  tmp jsonb;
BEGIN
  -- Helper shapes reused below; each use re-stamps a fresh id.

  IF kind = 'all' THEN
    id := id + 1;
    init := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bool', 'v', true),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    cond := jsonb_build_object('id', id, 'k', 'call',
      'fn', '@not_strictly_false', 'args', jsonb_build_array(accu),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    step := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_&&_', 'args', jsonb_build_array(accu, p),
      's', cs, 'e', ce);
    id := id + 1;
    result := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);

  ELSIF kind = 'exists' THEN
    id := id + 1;
    init := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bool', 'v', false),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    tmp := jsonb_build_object('id', id, 'k', 'call',
      'fn', '!_', 'args', jsonb_build_array(accu),
      's', cs, 'e', ce);
    id := id + 1;
    cond := jsonb_build_object('id', id, 'k', 'call',
      'fn', '@not_strictly_false', 'args', jsonb_build_array(tmp),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    step := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_||_', 'args', jsonb_build_array(accu, p),
      's', cs, 'e', ce);
    id := id + 1;
    result := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);

  ELSIF kind = 'exists_one' THEN
    id := id + 1;
    init := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'int', 'v', 0),
      's', cs, 'e', ce);
    id := id + 1;
    cond := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bool', 'v', true),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    tmp := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'int', 'v', 1),
      's', cs, 'e', ce);
    id := id + 1;
    tmp := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_+_', 'args', jsonb_build_array(accu, tmp),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    step := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_?_:_', 'args', jsonb_build_array(p, tmp, accu),
      's', cs, 'e', ce);
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    tmp := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'int', 'v', 1),
      's', cs, 'e', ce);
    id := id + 1;
    result := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_==_', 'args', jsonb_build_array(accu, tmp),
      's', cs, 'e', ce);

  ELSIF kind IN ('map', 'map_filter', 'filter') THEN
    id := id + 1;
    init := jsonb_build_object('id', id, 'k', 'list',
      'elems', '[]'::jsonb, 's', cs, 'e', ce);
    id := id + 1;
    cond := jsonb_build_object('id', id, 'k', 'lit',
      'v', jsonb_build_object('@t', 'bool', 'v', true),
      's', cs, 'e', ce);
    id := id + 1;
    tmp := jsonb_build_object('id', id, 'k', 'list',
      'elems', jsonb_build_array(
        CASE WHEN kind = 'filter'
             THEN jsonb_build_object('k', 'ident', 'name', iter,
                                     's', cs, 'e', ce)
             ELSE t END),
      's', cs, 'e', ce);
    -- The filter element ident needs its own id.
    IF kind = 'filter' THEN
      id := id + 1;
      tmp := jsonb_set(tmp, '{elems,0,id}', to_jsonb(id));
    END IF;
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    step := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_+_', 'args', jsonb_build_array(accu, tmp),
      's', cs, 'e', ce);
    IF kind <> 'map' THEN
      id := id + 1;
      accu := jsonb_build_object('id', id, 'k', 'ident',
        'name', '@result', 's', cs, 'e', ce);
      id := id + 1;
      step := jsonb_build_object('id', id, 'k', 'call',
        'fn', '_?_:_', 'args', jsonb_build_array(p, step, accu),
        's', cs, 'e', ce);
    END IF;
    id := id + 1;
    result := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
  ELSE
    err := format('unknown fold kind %s', kind);
    RETURN;
  END IF;

  id := id + 1;
  expr := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', target, 'iter', iter, 'iter2', '',
    'accu', '@result',
    'init', init, 'cond', cond, 'step', step, 'result', result,
    's', cs, 'e', ce);
  next_id_out := id;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_all(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx_itervar(args -> 0);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  SELECT * INTO f
  FROM cel._mx_fold('all', target, v.name, args -> 1, NULL, next_id);
  expr := f.expr; next_id_out := f.next_id_out; err := f.err;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_exists(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx_itervar(args -> 0);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  SELECT * INTO f
  FROM cel._mx_fold('exists', target, v.name, args -> 1, NULL, next_id);
  expr := f.expr; next_id_out := f.next_id_out; err := f.err;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_exists_one(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx_itervar(args -> 0);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  SELECT * INTO f
  FROM cel._mx_fold('exists_one', target, v.name, args -> 1, NULL,
                    next_id);
  expr := f.expr; next_id_out := f.next_id_out; err := f.err;
END;
$$;

-- map has arity 2 (transform) and arity 3 (filter + transform).
CREATE OR REPLACE FUNCTION cel._mx_map(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx_itervar(args -> 0);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  IF jsonb_array_length(args) = 3 THEN
    SELECT * INTO f FROM cel._mx_fold(
      'map_filter', target, v.name, args -> 1, args -> 2, next_id);
  ELSE
    SELECT * INTO f FROM cel._mx_fold(
      'map', target, v.name, NULL, args -> 1, next_id);
  END IF;
  expr := f.expr; next_id_out := f.next_id_out; err := f.err;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_filter(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx_itervar(args -> 0);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  SELECT * INTO f
  FROM cel._mx_fold('filter', target, v.name, args -> 1, NULL, next_id);
  expr := f.expr; next_id_out := f.next_id_out; err := f.err;
END;
$$;

-- The standard macro rows and their visibility in the standard env.
INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('has',        1, false, 'cel._mx_has(jsonb,jsonb,bigint)'),
  ('all',        2, true,  'cel._mx_all(jsonb,jsonb,bigint)'),
  ('exists',     2, true,  'cel._mx_exists(jsonb,jsonb,bigint)'),
  ('exists_one', 2, true,  'cel._mx_exists_one(jsonb,jsonb,bigint)'),
  ('map',        2, true,  'cel._mx_map(jsonb,jsonb,bigint)'),
  ('map',        3, true,  'cel._mx_map(jsonb,jsonb,bigint)'),
  ('filter',     2, true,  'cel._mx_filter(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE SET expander = excluded.expander;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'standard', 'macro', format('%s/%s/%s', name, arity, member::int)
FROM cel.macro
ON CONFLICT DO NOTHING;

-- Parses CEL source under an environment. Returns the AST envelope,
-- or {"errors": [...]} when the expression is rejected -- callers
-- and the conformance runner key on the "errors" field.
CREATE OR REPLACE FUNCTION cel.parse(source text, env text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  fl  jsonb;
  mac jsonb;
  lx  record;
  px  record;
  fin record;
  lines jsonb;
BEGIN
  IF length(source) > 100000 THEN
    RETURN cel._parse_errors(source, 'expression size limit exceeded', 0);
  END IF;

  fl := cel._env_flags(env);
  mac := cel._env_macros(env);

  SELECT * INTO lx FROM cel._lex(source, fl);
  IF lx.err IS NOT NULL THEN
    RETURN cel._parse_errors(source, lx.err, lx.errpos);
  END IF;

  SELECT * INTO px FROM cel._p_expr(lx.toks, 0, 0, 0, mac, fl);
  IF px.err IS NOT NULL THEN
    RETURN cel._parse_errors(source, px.err, px.ep);
  END IF;
  IF lx.toks -> px.np ->> 't' <> 'eof' THEN
    RETURN cel._parse_errors(
      source,
      format('unexpected token %s', quote_literal(coalesce(
        lx.toks -> px.np ->> 'v', lx.toks -> px.np ->> 't'))),
      (lx.toks -> px.np ->> 's')::int);
  END IF;
  IF px.nid > 100000 THEN
    RETURN cel._parse_errors(source, 'expression node limit exceeded', 0);
  END IF;

  SELECT * INTO fin FROM cel._p_finalize(px.node);

  SELECT coalesce(jsonb_agg(o - 1), '[]'::jsonb) INTO lines
  FROM (
    SELECT o
    FROM unnest(string_to_array(source, NULL)) WITH ORDINALITY t(ch, o)
    WHERE ch = E'\n'
  ) nl;

  RETURN jsonb_build_object(
    'v', 1,
    'expr', fin.clean,
    'source', jsonb_build_object(
      'desc', '<input>',
      'lines', lines,
      'offsets', fin.offsets,
      'macro_calls', fin.macro_calls));
END;
$$;

COMMIT;

-- ---- sql/040_check.sql ----

-- cel4postgres -- type checker.
--
-- Annotates a parse envelope with types and refs, rewriting idents,
-- qualified selects and struct type names to fully-qualified form and
-- binding overload ids into call nodes -- the ids cel.eval dispatches
-- on (day-one invariant 2). The algorithm is cel-go's
-- checker/checker.go and checker/types.go (pinned v0.32.0), ported
-- rule by rule: parameter unification with an occurs check,
-- most-general rebinding, dyn/any/error as wildcards, legacy
-- nullability, and declaration-ordered overload resolution with
-- result-type widening.
--
-- Types are the registry's json type encoding; the substitution
-- mapping is a jsonb object keyed by the parameter type's canonical
-- jsonb text.
-- Errors fail fast: conformance asserts on check-failure existence,
-- never on collecting several.

BEGIN;

-- Type formatting for error messages (checker/format.go, loosely).
CREATE OR REPLACE FUNCTION cel._t_fmt(t jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k text := t ->> 'kind';
BEGIN
  RETURN CASE k
    WHEN 'list' THEN
      format('list(%s)', cel._t_fmt(t -> 'params' -> 0))
    WHEN 'map' THEN
      format('map(%s, %s)', cel._t_fmt(t -> 'params' -> 0),
        cel._t_fmt(t -> 'params' -> 1))
    WHEN 'wrapper' THEN
      format('wrapper(%s)', cel._t_fmt(t -> 'params' -> 0))
    WHEN 'type' THEN
      CASE WHEN t ? 'params'
           THEN format('type(%s)', cel._t_fmt(t -> 'params' -> 0))
           ELSE 'type' END
    WHEN 'param' THEN t ->> 'name'
    WHEN 'opaque' THEN
      CASE WHEN jsonb_array_length(coalesce(t -> 'params', '[]')) > 0
        THEN format('%s(%s)', t ->> 'name', (
          SELECT string_agg(cel._t_fmt(p), ', ')
          FROM jsonb_array_elements(t -> 'params') p))
        ELSE t ->> 'name' END
    WHEN 'struct' THEN t ->> 'name'
    WHEN 'error' THEN '!error!'
    WHEN 'null' THEN 'null'
    WHEN 'timestamp' THEN 'google.protobuf.Timestamp'
    WHEN 'duration' THEN 'google.protobuf.Duration'
    ELSE k
  END;
END;
$$;

CREATE OR REPLACE FUNCTION cel._t_is_dyn(t jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT t ->> 'kind' IN ('dyn', 'any');
$$;

CREATE OR REPLACE FUNCTION cel._t_dyn_or_err(t jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT t ->> 'kind' IN ('dyn', 'any', 'error');
$$;

-- substitute (types.go:276): follow binding chains; optionally
-- collapse unbound parameters to dyn (the checker's final pass).
CREATE OR REPLACE FUNCTION cel._ck_subst(m jsonb, t jsonb, todyn boolean)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  sub  jsonb;
  ps   jsonb;
  p    jsonb;
BEGIN
  IF t ->> 'kind' = 'param' THEN
    sub := m -> (t::text);
    IF sub IS NOT NULL THEN
      RETURN cel._ck_subst(m, sub, todyn);
    END IF;
    IF todyn THEN
      RETURN '{"kind":"dyn"}'::jsonb;
    END IF;
    RETURN t;
  END IF;

  CASE t ->> 'kind'
    WHEN 'opaque', 'list', 'map', 'type' THEN
      IF NOT t ? 'params' THEN
        RETURN t;
      END IF;
      ps := '[]'::jsonb;
      FOR p IN SELECT e FROM jsonb_array_elements(t -> 'params') e LOOP
        ps := ps || jsonb_build_array(cel._ck_subst(m, p, todyn));
      END LOOP;
      RETURN jsonb_set(t, '{params}', ps);
    ELSE
      RETURN t;
  END CASE;
END;
$$;

-- isEqualOrLessSpecific (types.go:58).
CREATE OR REPLACE FUNCTION cel._ck_less_specific(t1 jsonb, t2 jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k1 text := t1 ->> 'kind';
  k2 text := t2 ->> 'kind';
  i  int;
BEGIN
  IF cel._t_is_dyn(t1) OR k1 = 'param' THEN
    RETURN true;
  END IF;
  IF cel._t_is_dyn(t2) OR k2 = 'param' THEN
    RETURN false;
  END IF;
  IF k1 <> k2 THEN
    RETURN false;
  END IF;
  CASE k1
    WHEN 'opaque' THEN
      IF t1 ->> 'name' <> t2 ->> 'name'
         OR jsonb_array_length(coalesce(t1 -> 'params', '[]'))
            <> jsonb_array_length(coalesce(t2 -> 'params', '[]')) THEN
        RETURN false;
      END IF;
      FOR i IN 0 .. jsonb_array_length(coalesce(t1 -> 'params', '[]')) - 1
      LOOP
        IF NOT cel._ck_less_specific(
             t1 -> 'params' -> i, t2 -> 'params' -> i) THEN
          RETURN false;
        END IF;
      END LOOP;
      RETURN true;
    WHEN 'list' THEN
      RETURN cel._ck_less_specific(
        t1 -> 'params' -> 0, t2 -> 'params' -> 0);
    WHEN 'map' THEN
      RETURN cel._ck_less_specific(
          t1 -> 'params' -> 0, t2 -> 'params' -> 0)
        AND cel._ck_less_specific(
          t1 -> 'params' -> 1, t2 -> 'params' -> 1);
    WHEN 'type' THEN
      RETURN true;
    ELSE
      RETURN t1 = t2;
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION cel._ck_most_general(t1 jsonb, t2 jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN cel._ck_less_specific(t1, t2) THEN t1 ELSE t2 END;
$$;

-- notReferencedIn (types.go:251): the occurs check.
CREATE OR REPLACE FUNCTION cel._ck_not_ref_in(m jsonb, t jsonb, w jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  sub jsonb;
  p   jsonb;
BEGIN
  IF t = w THEN
    RETURN false;
  END IF;
  CASE w ->> 'kind'
    WHEN 'param' THEN
      sub := m -> (w::text);
      IF sub IS NULL THEN
        RETURN true;
      END IF;
      RETURN cel._ck_not_ref_in(m, t, sub);
    WHEN 'opaque', 'list', 'map', 'type' THEN
      FOR p IN
        SELECT e FROM jsonb_array_elements(coalesce(w -> 'params', '[]')) e
      LOOP
        IF NOT cel._ck_not_ref_in(m, t, p) THEN
          RETURN false;
        END IF;
      END LOOP;
      RETURN true;
    ELSE
      RETURN true;
  END CASE;
END;
$$;

-- isLegacyNullable + internalIsAssignableNull (types.go:208).
CREATE OR REPLACE FUNCTION cel._ck_nullable(t jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT t ->> 'kind' IN
    ('opaque', 'struct', 'any', 'duration', 'timestamp',
     'wrapper', 'null');
$$;

-- internalIsAssignable (types.go:100), with the mapping threaded in
-- and out. jsonb is by-value, so "copy on trial" is just returning
-- the old value on failure -- the callers below rely on that.
CREATE OR REPLACE FUNCTION cel._ck_assign1(
  m jsonb, t1 jsonb, t2 jsonb,
  OUT ok boolean, OUT mo jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k1  text := t1 ->> 'kind';
  k2  text := t2 ->> 'kind';
  s   record;
BEGIN
  mo := m;

  IF k2 = 'param' THEN
    SELECT * INTO s FROM cel._ck_valid_sub(mo, t1, t2);
    IF s.ok THEN
      ok := true;
      mo := s.mo;
      RETURN;
    END IF;
    IF s.hassub THEN
      ok := false;
      RETURN;
    END IF;
  END IF;
  IF k1 = 'param' THEN
    SELECT * INTO s FROM cel._ck_valid_sub(mo, t2, t1);
    ok := s.ok;
    IF s.ok THEN
      mo := s.mo;
    END IF;
    RETURN;
  END IF;

  IF cel._t_dyn_or_err(t1) OR cel._t_dyn_or_err(t2) THEN
    ok := true;
    RETURN;
  END IF;

  IF k1 = 'null' THEN
    ok := cel._ck_nullable(t2);
    RETURN;
  END IF;
  IF k2 = 'null' THEN
    ok := cel._ck_nullable(t1);
    RETURN;
  END IF;

  -- Wrappers accept their wrapped primitive (and null, above);
  -- nothing else accepts a wrapper except another identical wrapper
  -- or the wildcards already handled.
  IF k2 = 'wrapper' THEN
    ok := (k1 = 'wrapper' AND t1 -> 'params' = t2 -> 'params')
       OR t1 = t2 -> 'params' -> 0;
    RETURN;
  END IF;
  IF k1 = 'wrapper' THEN
    ok := false;
    RETURN;
  END IF;

  CASE k1
    WHEN 'bool', 'bytes', 'double', 'int', 'string', 'uint',
         'any', 'duration', 'timestamp' THEN
      ok := k1 = k2;
      RETURN;
    WHEN 'struct' THEN
      ok := k2 = 'struct' AND t1 ->> 'name' = t2 ->> 'name';
      RETURN;
    WHEN 'type' THEN
      ok := k2 = 'type';
      RETURN;
    WHEN 'opaque', 'list', 'map' THEN
      IF k1 <> k2
         OR coalesce(t1 ->> 'name', '') <> coalesce(t2 ->> 'name', '')
      THEN
        ok := false;
        RETURN;
      END IF;
      SELECT * INTO s FROM cel._ck_assign_list(mo,
        coalesce(t1 -> 'params', '[]'),
        coalesce(t2 -> 'params', '[]'));
      ok := s.ok;
      IF s.ok THEN
        mo := s.mo;
      END IF;
      RETURN;
    ELSE
      ok := false;
      RETURN;
  END CASE;
END;
$$;

-- isValidTypeSubstitution (types.go:160): whether t2 (a parameter)
-- can substitute for t1.
CREATE OR REPLACE FUNCTION cel._ck_valid_sub(
  m jsonb, t1 jsonb, t2 jsonb,
  OUT ok boolean, OUT hassub boolean, OUT mo jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  t2sub jsonb;
  s     record;
  t2new jsonb;
BEGIN
  mo := m;
  IF t1 = t2 THEN
    ok := true;
    hassub := true;
    RETURN;
  END IF;

  t2sub := m -> (t2::text);
  IF t2sub IS NOT NULL THEN
    hassub := true;
    IF t1 = t2sub THEN
      ok := true;
      RETURN;
    END IF;
    SELECT * INTO s FROM cel._ck_assign1(mo, t1, t2sub);
    IF s.ok THEN
      mo := s.mo;
      t2new := cel._ck_most_general(t1, t2sub);
      IF cel._ck_not_ref_in(mo, t2, t2new) THEN
        mo := jsonb_set(mo, ARRAY[t2::text], t2new);
      END IF;
      ok := true;
      RETURN;
    END IF;
    ok := false;
    RETURN;
  END IF;

  hassub := false;
  IF cel._ck_not_ref_in(mo, t2, t1) THEN
    mo := jsonb_set(mo, ARRAY[t2::text], t1);
    ok := true;
    RETURN;
  END IF;
  ok := false;
END;
$$;

CREATE OR REPLACE FUNCTION cel._ck_assign_list(
  m jsonb, l1 jsonb, l2 jsonb,
  OUT ok boolean, OUT mo jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  i int;
  s record;
BEGIN
  mo := m;
  IF jsonb_array_length(l1) <> jsonb_array_length(l2) THEN
    ok := false;
    RETURN;
  END IF;
  FOR i IN 0 .. jsonb_array_length(l1) - 1 LOOP
    SELECT * INTO s FROM cel._ck_assign1(mo, l1 -> i, l2 -> i);
    IF NOT s.ok THEN
      ok := false;
      mo := m;
      RETURN;
    END IF;
    mo := s.mo;
  END LOOP;
  ok := true;
END;
$$;

-- joinTypes (checker.go:616) with cel-go's default dyn fallback for
-- heterogeneous aggregate literals.
CREATE OR REPLACE FUNCTION cel._ck_join(
  m jsonb, prev jsonb, cur jsonb,
  OUT t jsonb, OUT mo jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s record;
BEGIN
  mo := m;
  IF prev IS NULL THEN
    t := cur;
    RETURN;
  END IF;
  SELECT * INTO s FROM cel._ck_assign1(mo, prev, cur);
  IF s.ok THEN
    mo := s.mo;
    -- Joining null with a nullable type keeps the nullable type:
    -- the corpus's legacy_nullable_types section fixes this and
    -- cel-go v0.32.0 skips those cases as known-wrong (its
    -- mostGeneral would answer null).
    IF prev ->> 'kind' = 'null' AND cel._ck_nullable(cur)
       AND cur ->> 'kind' <> 'null' THEN
      t := cur;
    ELSIF cur ->> 'kind' = 'null' AND cel._ck_nullable(prev)
       AND prev ->> 'kind' <> 'null' THEN
      t := prev;
    ELSE
      t := cel._ck_most_general(prev, cur);
    END IF;
    RETURN;
  END IF;
  t := '{"kind":"dyn"}'::jsonb;
END;
$$;

COMMIT;

BEGIN;

-- Fresh type variables and parameter instantiation.
CREATE OR REPLACE FUNCTION cel._ck_collect_params(t jsonb)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  acc text[] := '{}';
  p   jsonb;
BEGIN
  IF t ->> 'kind' = 'param' THEN
    RETURN ARRAY[t ->> 'name'];
  END IF;
  FOR p IN
    SELECT e FROM jsonb_array_elements(coalesce(t -> 'params', '[]')) e
  LOOP
    acc := acc || cel._ck_collect_params(p);
  END LOOP;
  RETURN acc;
END;
$$;

-- Rewrites the named parameters of one overload's signature to fresh
-- _var<N> parameters (checker.go:388-396).
CREATE OR REPLACE FUNCTION cel._ck_instantiate(
  arg_types jsonb, result_type jsonb, n int,
  OUT args jsonb, OUT result jsonb, OUT nn int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  names text[] := '{}';
  nm    text;
  fresh jsonb := '{}'::jsonb;
  a     jsonb;
BEGIN
  nn := n;
  names := (
    SELECT coalesce(array_agg(DISTINCT p), '{}')
    FROM (
      SELECT unnest(cel._ck_collect_params(result_type)
        || (SELECT coalesce(array_agg(x), '{}')
            FROM (SELECT unnest(cel._ck_collect_params(e)) AS x
                  FROM jsonb_array_elements(arg_types) e) u)) AS p
    ) q);
  FOREACH nm IN ARRAY names LOOP
    fresh := fresh || jsonb_build_object(
      jsonb_build_object('kind', 'param', 'name', nm)::text,
      jsonb_build_object('kind', 'param', 'name', '_var' || nn));
    nn := nn + 1;
  END LOOP;

  args := '[]'::jsonb;
  FOR a IN SELECT e FROM jsonb_array_elements(arg_types) e LOOP
    args := args || jsonb_build_array(cel._ck_subst(fresh, a, false));
  END LOOP;
  result := cel._ck_subst(fresh, result_type, false);
END;
$$;

-- Overload resolution (checker.go:339): declaration order, fresh
-- instantiation, assignability trial against a copy of the mapping,
-- result-type widening across multiple matches.
CREATE OR REPLACE FUNCTION cel._ck_resolve(
  fn text,
  is_member boolean,
  argtypes jsonb,
  envs text[],
  st jsonb,
  OUT ref jsonb, OUT rtype jsonb, OUT sto jsonb, OUT err text
)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  row_r record;
  inst  record;
  a     record;
  ids   jsonb := '[]'::jsonb;
  fnres jsonb;
  m     jsonb := st -> 'map';
  n     int := (st ->> 'n')::int;
  i     int;
  fmt_args text;
BEGIN
  sto := st;

  -- The variadic-logical special case (checker.go:365): every arg
  -- must be assignable to bool; the result is bool.
  IF fn IN ('_&&_', '_||_') THEN
    FOR i IN 0 .. jsonb_array_length(argtypes) - 1 LOOP
      SELECT * INTO a FROM cel._ck_assign1(
        m, argtypes -> i, '{"kind":"bool"}');
      IF NOT a.ok THEN
        err := format('expected type ''bool'' but found %s',
          quote_literal(cel._t_fmt(argtypes -> i)));
        RETURN;
      END IF;
      m := a.mo;
    END LOOP;
    SELECT jsonb_build_object(
      'overloads', jsonb_build_array(to_jsonb(o.id)))
    INTO ref
    FROM cel.overload o
    WHERE o.function = fn ORDER BY o.ordinal LIMIT 1;
    rtype := '{"kind":"bool"}'::jsonb;
    sto := jsonb_set(jsonb_set(st, '{map}', m), '{n}', to_jsonb(n));
    RETURN;
  END IF;

  -- Registry rows first, then caller-declared overloads (options
  -- 'decls' function entries, threaded in via st -> 'fns').
  FOR row_r IN
    SELECT q.id, q.member, q.arg_types, q.result_type
    FROM (
      SELECT o.id, o.member, o.arg_types, o.result_type, o.ordinal
      FROM cel.overload o
      WHERE o.function = fn
        AND EXISTS (
          SELECT FROM cel.env_item it
          WHERE it.env = ANY (envs) AND it.kind = 'overload'
            AND it.ref = o.id)
      UNION ALL
      SELECT e ->> 'id',
             coalesce((e ->> 'member')::boolean, false),
             e -> 'arg_types', e -> 'result_type',
             1000000 + (row_number() OVER ())::int
      FROM jsonb_array_elements(
        coalesce(st -> 'fns' -> fn, '[]'::jsonb)) e
    ) q
    ORDER BY q.ordinal
  LOOP
    CONTINUE WHEN row_r.member <> is_member;

    SELECT * INTO inst
    FROM cel._ck_instantiate(row_r.arg_types, row_r.result_type, n);
    n := inst.nn;

    SELECT * INTO a
    FROM cel._ck_assign_list(m, argtypes, inst.args);
    IF a.ok THEN
      m := a.mo;
      ids := ids || to_jsonb(row_r.id);
      fnres := cel._ck_subst(m, inst.result, false);
      IF rtype IS NULL THEN
        rtype := fnres;
      ELSIF NOT cel._t_is_dyn(rtype) AND fnres <> rtype THEN
        rtype := '{"kind":"dyn"}'::jsonb;
      END IF;
    END IF;
  END LOOP;

  IF rtype IS NULL THEN
    SELECT string_agg(cel._t_fmt(cel._ck_subst(m, e, true)), ', ')
      INTO fmt_args
    FROM jsonb_array_elements(argtypes)
      WITH ORDINALITY q(e, o)
    WHERE NOT is_member OR o > 1;
    IF is_member THEN
      err := format(
        'found no matching overload for %s applied to ''%s.(%s)''',
        quote_literal(fn),
        cel._t_fmt(cel._ck_subst(m, argtypes -> 0, true)),
        coalesce(fmt_args, ''));
    ELSE
      err := format(
        'found no matching overload for %s applied to ''(%s)''',
        quote_literal(fn), coalesce(fmt_args, ''));
    END IF;
    RETURN;
  END IF;

  ref := jsonb_build_object('overloads', ids);
  sto := jsonb_set(jsonb_set(st, '{map}', m), '{n}', to_jsonb(n));
END;
$$;


-- Field-selection result typing (checker.go:215 checkSelectField):
-- shared by the select branch and the _?._ optional-select call.
-- Unwraps an optional_type operand and reports it via was_opt.
CREATE OR REPLACE FUNCTION cel._ck_sel_type(
  op_t jsonb, st jsonb,
  OUT typ jsonb, OUT sto jsonb, OUT err text, OUT was_opt boolean
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s record;
BEGIN
  sto := st;
  was_opt := op_t ->> 'kind' = 'opaque'
         AND op_t ->> 'name' = 'optional_type';
  IF was_opt THEN
    op_t := cel._ck_subst(sto -> 'map', op_t -> 'params' -> 0,
      false);
  END IF;
  CASE op_t ->> 'kind'
    WHEN 'map' THEN
      typ := op_t -> 'params' -> 1;
    WHEN 'param' THEN
      SELECT * INTO s FROM cel._ck_assign1(
        sto -> 'map', '{"kind":"dyn"}', op_t);
      IF s.ok THEN
        sto := jsonb_set(sto, '{map}', s.mo);
      END IF;
      typ := '{"kind":"dyn"}'::jsonb;
    WHEN 'dyn', 'any', 'error' THEN
      typ := '{"kind":"dyn"}'::jsonb;
    WHEN 'wrapper' THEN
      typ := '{"kind":"dyn"}'::jsonb;
    ELSE
      err := format('type %s does not support field selection',
        quote_literal(cel._t_fmt(op_t)));
  END CASE;
END;
$$;

-- Local (comprehension) scope lookup, innermost first.
CREATE OR REPLACE FUNCTION cel._ck_local(scopes jsonb, name text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  i int;
BEGIN
  FOR i IN REVERSE jsonb_array_length(scopes) - 1 .. 0 LOOP
    IF scopes -> i ? name THEN
      RETURN scopes -> i -> name;
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

-- Simple-identifier resolution (checker/env.go:152): local scope
-- first (unless absolute), then container candidates against the
-- global declarations. Returns the qualified name and its type.
CREATE OR REPLACE FUNCTION cel._ck_ident(
  name text, scopes jsonb, globals jsonb, ctr text,
  OUT qname text, OUT typ jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  absolute boolean := name LIKE '.%';
  bare     text := ltrim(name, '.');
  cand     text;
  loc      jsonb := cel._ck_local(scopes, bare);
BEGIN
  IF loc IS NOT NULL AND NOT absolute THEN
    qname := bare;
    typ := loc;
    RETURN;
  END IF;
  FOREACH cand IN ARRAY cel._name_candidates(bare, absolute, ctr) LOOP
    IF globals ? cand THEN
      -- A shadowing local forces runtime disambiguation: the dot
      -- survives into the rewritten ident so eval skips
      -- comprehension frames (checker/env.go
      -- requiresDisambiguation).
      qname := CASE WHEN loc IS NOT NULL THEN '.' || cand
                    ELSE cand END;
      typ := globals -> cand;
      RETURN;
    END IF;
  END LOOP;
END;
$$;

-- Qualified-identifier resolution (env.go:166): a local binding of
-- the root segment forces field selection instead.
CREATE OR REPLACE FUNCTION cel._ck_qualified(
  parts text[], absolute boolean, scopes jsonb, globals jsonb,
  ctr text,
  OUT qname text, OUT typ jsonb
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  cand text;
  name text;
  loc  jsonb := cel._ck_local(scopes, parts[1]);
BEGIN
  IF loc IS NOT NULL AND NOT absolute THEN
    RETURN;
  END IF;
  name := array_to_string(parts, '.');
  FOREACH cand IN ARRAY cel._name_candidates(name, absolute, ctr) LOOP
    IF globals ? cand THEN
      -- Same disambiguation rule as _ck_ident: a local root plus a
      -- won global keeps the leading dot for runtime resolution.
      qname := CASE WHEN loc IS NOT NULL THEN '.' || cand
                    ELSE cand END;
      typ := globals -> cand;
      RETURN;
    END IF;
  END LOOP;
END;
$$;

COMMIT;

BEGIN;

-- Literal kinds to checker types.
CREATE OR REPLACE FUNCTION cel._ck_lit_type(v jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('kind',
    CASE v ->> '@t' WHEN 'null' THEN 'null' ELSE v ->> '@t' END);
$$;

-- The recursive checker. Returns the (possibly rewritten) node, its
-- type, and the threaded state {"types","refs","map","n"}; err set
-- means the whole check fails with that message.
CREATE OR REPLACE FUNCTION cel._ck(
  node jsonb,
  scopes jsonb,
  globals jsonb,
  envs text[],
  ctr text,
  st jsonb,
  OUT nodeo jsonb, OUT typ jsonb, OUT sto jsonb, OUT err text
)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  selr record;
  k     text := node ->> 'k';
  nid   text := node ->> 'id';
  c     record;
  r     record;
  q     record;
  chain record;
  argtypes jsonb;
  newargs  jsonb;
  target_t jsonb;
  fname    text;
  cand     text;
  i        int;
  elem_t   jsonb;
  key_t    jsonb;
  val_t    jsonb;
  op_t     jsonb;
  ents     jsonb;
  frame    jsonb;
  range_t  jsonb;
  accu_t   jsonb;
  var_t    jsonb;
  var2_t   jsonb;
  s        record;
BEGIN
  sto := st;
  nodeo := node;

  CASE k
  WHEN 'lit' THEN
    typ := cel._ck_lit_type(node -> 'v');

  WHEN 'ident' THEN
    SELECT * INTO q FROM cel._ck_ident(
      node ->> 'name', scopes, globals, ctr);
    IF q.qname IS NULL THEN
      err := format(
        'undeclared reference to %s (in container %s)',
        quote_literal(node ->> 'name'), quote_literal(ctr));
      RETURN;
    END IF;
    typ := q.typ;
    nodeo := jsonb_build_object(
      'id', node -> 'id', 'k', 'ident', 'name', q.qname);
    sto := jsonb_set(sto, ARRAY['refs', nid],
      jsonb_build_object('name', q.qname));

  WHEN 'select' THEN
    -- Qualified-name interpretation first (checker.go:134).
    IF NOT coalesce((node -> 'test')::boolean, false) THEN
      SELECT * INTO chain FROM cel._attr_chain(node);
      IF chain.parts IS NOT NULL THEN
        SELECT * INTO q FROM cel._ck_qualified(
          chain.parts, chain.absolute, scopes, globals, ctr);
        IF q.qname IS NOT NULL THEN
          typ := q.typ;
          nodeo := jsonb_build_object(
            'id', node -> 'id', 'k', 'ident', 'name', q.qname);
          sto := jsonb_set(sto, ARRAY['refs', nid],
            jsonb_build_object('name', q.qname));
          sto := jsonb_set(sto, ARRAY['types', nid], typ);
          RETURN;
        END IF;
      END IF;
    END IF;

    -- Field selection.
    SELECT * INTO c FROM cel._ck(
      node -> 'op', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(node, '{op}', c.nodeo);
    op_t := cel._ck_subst(sto -> 'map', c.typ, false);

    SELECT * INTO selr FROM cel._ck_sel_type(op_t, sto);
    IF selr.err IS NOT NULL THEN
      err := selr.err;
      RETURN;
    END IF;
    sto := selr.sto;
    typ := selr.typ;

    IF coalesce((node -> 'test')::boolean, false) THEN
      typ := '{"kind":"bool"}'::jsonb;
    ELSE
      typ := cel._ck_subst(sto -> 'map', typ, false);
      -- An optional operand makes the selection optional too
      -- (checker.go:253).
      IF selr.was_opt THEN
        typ := jsonb_build_object('kind', 'opaque',
          'name', 'optional_type',
          'params', jsonb_build_array(typ));
      END IF;
    END IF;

  WHEN 'call' THEN
    -- Check the arguments first, in order.
    newargs := '[]'::jsonb;
    argtypes := '[]'::jsonb;
    FOR i IN 0 .. jsonb_array_length(node -> 'args') - 1 LOOP
      SELECT * INTO c FROM cel._ck(
        node -> 'args' -> i, scopes, globals, envs, ctr, sto);
      IF c.err IS NOT NULL THEN
        err := c.err;
        RETURN;
      END IF;
      sto := c.sto;
      newargs := newargs || jsonb_build_array(c.nodeo);
      argtypes := argtypes || jsonb_build_array(c.typ);
    END LOOP;
    nodeo := jsonb_set(node, '{args}', newargs);

    fname := node ->> 'fn';

    -- The optional-select operator is typed by field-selection
    -- logic, not overload resolution (checker.go:187
    -- checkOptSelect); its reference is the fixed function id.
    IF NOT node ? 'target' AND fname = '_?._' THEN
      SELECT * INTO selr FROM cel._ck_sel_type(
        cel._ck_subst(sto -> 'map', argtypes -> 0, false), sto);
      IF selr.err IS NOT NULL THEN
        err := selr.err;
        RETURN;
      END IF;
      sto := selr.sto;
      typ := jsonb_build_object('kind', 'opaque',
        'name', 'optional_type',
        'params', jsonb_build_array(
          cel._ck_subst(sto -> 'map', selr.typ, false)));
      nodeo := nodeo || jsonb_build_object('ref',
        jsonb_build_object('overloads',
          jsonb_build_array(to_jsonb('select_optional_field'::text))));
      sto := jsonb_set(sto, ARRAY['refs', nid],
        nodeo -> 'ref');
      RETURN;
    END IF;

    IF NOT node ? 'target' THEN
      -- Global call: resolve the function name through the
      -- container.
      SELECT n.c INTO cand
      FROM unnest(cel._name_candidates(
        ltrim(fname, '.'), fname LIKE '.%', ctr)) n(c)
      WHERE sto -> 'fns' ? n.c OR EXISTS (
        SELECT FROM cel.overload o
        WHERE o.function = n.c AND EXISTS (
          SELECT FROM cel.env_item it
          WHERE it.env = ANY (envs) AND it.kind = 'overload'
            AND it.ref = o.id))
      LIMIT 1;
      IF cand IS NULL THEN
        err := format(
          'undeclared reference to %s (in container %s)',
          quote_literal(fname), quote_literal(ctr));
        RETURN;
      END IF;
      nodeo := jsonb_set(nodeo, '{fn}', to_jsonb(cand));
      SELECT * INTO r FROM cel._ck_resolve(
        cand, false, argtypes, envs, sto);
    ELSE
      -- Receiver call: namespaced-function flattening first
      -- (a.b.fn() may be global function "a.b.fn").
      SELECT * INTO chain FROM cel._attr_chain(node -> 'target');
      cand := NULL;
      IF chain.parts IS NOT NULL THEN
        SELECT n.c INTO cand
        FROM unnest(cel._name_candidates(
          array_to_string(chain.parts, '.') || '.' || fname,
          chain.absolute, ctr)) n(c)
        WHERE sto -> 'fns' ? n.c OR EXISTS (
          SELECT FROM cel.overload o
          WHERE o.function = n.c AND EXISTS (
            SELECT FROM cel.env_item it
            WHERE it.env = ANY (envs) AND it.kind = 'overload'
              AND it.ref = o.id))
        LIMIT 1;
      END IF;
      IF cand IS NOT NULL THEN
        nodeo := (nodeo - 'target');
        nodeo := jsonb_set(nodeo, '{fn}', to_jsonb(cand));
        SELECT * INTO r FROM cel._ck_resolve(
          cand, false, argtypes, envs, sto);
      ELSE
        SELECT * INTO c FROM cel._ck(
          node -> 'target', scopes, globals, envs, ctr, sto);
        IF c.err IS NOT NULL THEN
          err := c.err;
          RETURN;
        END IF;
        sto := c.sto;
        nodeo := jsonb_set(nodeo, '{target}', c.nodeo);
        target_t := c.typ;

        IF NOT (sto -> 'fns' ? fname) AND NOT EXISTS (
          SELECT FROM cel.overload o
          WHERE o.function = fname AND EXISTS (
            SELECT FROM cel.env_item it
            WHERE it.env = ANY (envs) AND it.kind = 'overload'
              AND it.ref = o.id))
        THEN
          err := format(
            'undeclared reference to %s (in container %s)',
            quote_literal(fname), quote_literal(ctr));
          RETURN;
        END IF;
        SELECT * INTO r FROM cel._ck_resolve(
          fname, true,
          jsonb_build_array(target_t) || argtypes, envs, sto);
      END IF;
    END IF;

    IF r.err IS NOT NULL THEN
      err := r.err;
      RETURN;
    END IF;
    sto := r.sto;
    typ := r.rtype;
    nodeo := nodeo || jsonb_build_object('ref', r.ref);
    sto := jsonb_set(sto, ARRAY['refs', nid], r.ref);

  WHEN 'list' THEN
    elem_t := NULL;
    newargs := '[]'::jsonb;
    FOR i IN 0 .. jsonb_array_length(node -> 'elems') - 1 LOOP
      SELECT * INTO c FROM cel._ck(
        node -> 'elems' -> i, scopes, globals, envs, ctr, sto);
      IF c.err IS NOT NULL THEN
        err := c.err;
        RETURN;
      END IF;
      sto := c.sto;
      newargs := newargs || jsonb_build_array(c.nodeo);
      SELECT * INTO s FROM cel._ck_join(sto -> 'map', elem_t, c.typ);
      elem_t := s.t;
      sto := jsonb_set(sto, '{map}', s.mo);
    END LOOP;
    nodeo := jsonb_set(node, '{elems}', newargs);
    IF elem_t IS NULL THEN
      elem_t := jsonb_build_object('kind', 'param',
        'name', '_var' || (sto ->> 'n'));
      sto := jsonb_set(sto, '{n}', to_jsonb((sto ->> 'n')::int + 1));
    END IF;
    typ := jsonb_build_object(
      'kind', 'list', 'params', jsonb_build_array(elem_t));

  WHEN 'map' THEN
    key_t := NULL;
    val_t := NULL;
    ents := '[]'::jsonb;
    FOR i IN 0 .. jsonb_array_length(node -> 'entries') - 1 LOOP
      SELECT * INTO c FROM cel._ck(
        node -> 'entries' -> i -> 'k',
        scopes, globals, envs, ctr, sto);
      IF c.err IS NOT NULL THEN
        err := c.err;
        RETURN;
      END IF;
      sto := c.sto;
      SELECT * INTO s FROM cel._ck_join(sto -> 'map', key_t, c.typ);
      key_t := s.t;
      sto := jsonb_set(sto, '{map}', s.mo);
      frame := jsonb_set(node -> 'entries' -> i, '{k}', c.nodeo);

      SELECT * INTO c FROM cel._ck(
        frame -> 'v', scopes, globals, envs, ctr, sto);
      IF c.err IS NOT NULL THEN
        err := c.err;
        RETURN;
      END IF;
      sto := c.sto;
      SELECT * INTO s FROM cel._ck_join(sto -> 'map', val_t, c.typ);
      val_t := s.t;
      sto := jsonb_set(sto, '{map}', s.mo);
      ents := ents || jsonb_build_array(
        jsonb_set(frame, '{v}', c.nodeo));
    END LOOP;
    nodeo := jsonb_set(node, '{entries}', ents);
    IF key_t IS NULL THEN
      key_t := jsonb_build_object('kind', 'param',
        'name', '_var' || (sto ->> 'n'));
      val_t := jsonb_build_object('kind', 'param',
        'name', '_var' || ((sto ->> 'n')::int + 1));
      sto := jsonb_set(sto, '{n}', to_jsonb((sto ->> 'n')::int + 2));
    END IF;
    typ := jsonb_build_object(
      'kind', 'map', 'params', jsonb_build_array(key_t, val_t));

  WHEN 'struct' THEN
    -- Message construction resolves through cel.type; without a
    -- descriptor pool only registered (WKT/opaque) types exist.
    SELECT t.name, t.kind INTO q
    FROM unnest(cel._name_candidates(
      ltrim(node ->> 'type', '.'),
      (node ->> 'type') LIKE '.%', ctr)) n(c)
    JOIN cel.type t ON t.name = n.c
    WHERE EXISTS (
      SELECT FROM cel.env_item it
      WHERE it.env = ANY (envs) AND it.kind = 'type'
        AND it.ref = t.name)
    LIMIT 1;
    IF q.name IS NULL THEN
      err := format(
        'undeclared reference to %s (in container %s)',
        quote_literal(node ->> 'type'), quote_literal(ctr));
      RETURN;
    END IF;
    -- Field checking against WKT shapes arrives with 070_wkt.sql;
    -- primitive type names are not message types.
    IF (q.kind ->> 'kind') NOT IN
       ('struct', 'map', 'list', 'dyn', 'wrapper',
        'timestamp', 'duration', 'any')
    THEN
      err := format('%s is not a message type',
        quote_literal(q.name));
      RETURN;
    END IF;
    ents := '[]'::jsonb;
    FOR i IN 0 .. jsonb_array_length(node -> 'fields') - 1 LOOP
      SELECT * INTO c FROM cel._ck(
        node -> 'fields' -> i -> 'v',
        scopes, globals, envs, ctr, sto);
      IF c.err IS NOT NULL THEN
        err := c.err;
        RETURN;
      END IF;
      sto := c.sto;
      ents := ents || jsonb_build_array(
        jsonb_set(node -> 'fields' -> i, '{v}', c.nodeo));
    END LOOP;
    nodeo := jsonb_set(node, '{fields}', ents);
    nodeo := jsonb_set(nodeo, '{type}', to_jsonb(q.name));
    sto := jsonb_set(sto, ARRAY['refs', nid],
      jsonb_build_object('name', q.name));
    typ := q.kind;

  WHEN 'comp' THEN
    SELECT * INTO c FROM cel._ck(
      node -> 'range', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(node, '{range}', c.nodeo);
    range_t := cel._ck_subst(sto -> 'map', c.typ, false);

    SELECT * INTO c FROM cel._ck(
      node -> 'init', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(nodeo, '{init}', c.nodeo);
    accu_t := c.typ;

    CASE range_t ->> 'kind'
      WHEN 'list' THEN
        var_t := range_t -> 'params' -> 0;
        IF node ->> 'iter2' <> '' THEN
          var2_t := var_t;
          var_t := '{"kind":"int"}'::jsonb;
        END IF;
      WHEN 'map' THEN
        var_t := range_t -> 'params' -> 0;
        IF node ->> 'iter2' <> '' THEN
          var2_t := range_t -> 'params' -> 1;
        END IF;
      WHEN 'dyn', 'any', 'error', 'param' THEN
        SELECT * INTO s FROM cel._ck_assign1(
          sto -> 'map', '{"kind":"dyn"}', range_t);
        IF s.ok THEN
          sto := jsonb_set(sto, '{map}', s.mo);
        END IF;
        var_t := '{"kind":"dyn"}'::jsonb;
        var2_t := '{"kind":"dyn"}'::jsonb;
      ELSE
        err := format(
          'expression of type %s cannot be range of a comprehension '
          || '(must be list, map, or dynamic)',
          quote_literal(cel._t_fmt(range_t)));
        RETURN;
    END CASE;

    -- Accu scope, then the loop scope with the iteration variables.
    frame := jsonb_build_object(node ->> 'accu', accu_t);
    scopes := scopes || jsonb_build_array(frame);
    frame := jsonb_build_object(node ->> 'iter', var_t);
    IF node ->> 'iter2' <> '' THEN
      frame := frame || jsonb_build_object(node ->> 'iter2', var2_t);
    END IF;
    scopes := scopes || jsonb_build_array(frame);

    SELECT * INTO c FROM cel._ck(
      node -> 'cond', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(nodeo, '{cond}', c.nodeo);
    SELECT * INTO s FROM cel._ck_assign1(
      sto -> 'map', '{"kind":"bool"}', c.typ);
    IF NOT s.ok THEN
      err := format('expected type ''bool'' but found %s',
        quote_literal(cel._t_fmt(c.typ)));
      RETURN;
    END IF;
    sto := jsonb_set(sto, '{map}', s.mo);

    SELECT * INTO c FROM cel._ck(
      node -> 'step', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(nodeo, '{step}', c.nodeo);
    SELECT * INTO s FROM cel._ck_assign1(
      sto -> 'map', accu_t, c.typ);
    IF NOT s.ok THEN
      err := format('expected type %s but found %s',
        quote_literal(cel._t_fmt(accu_t)),
        quote_literal(cel._t_fmt(c.typ)));
      RETURN;
    END IF;
    sto := jsonb_set(sto, '{map}', s.mo);

    -- Result checks with the iteration variables out of scope.
    scopes := scopes - (jsonb_array_length(scopes) - 1);
    SELECT * INTO c FROM cel._ck(
      node -> 'result', scopes, globals, envs, ctr, sto);
    IF c.err IS NOT NULL THEN
      err := c.err;
      RETURN;
    END IF;
    sto := c.sto;
    nodeo := jsonb_set(nodeo, '{result}', c.nodeo);
    typ := cel._ck_subst(sto -> 'map', c.typ, false);

  ELSE
    err := format('unexpected AST node kind: %s', k);
    RETURN;
  END CASE;

  sto := jsonb_set(sto, ARRAY['types', nid], typ);
END;
$$;

-- Checks a parse envelope under an environment. options carries the
-- per-case container and extra ident declarations.
-- Returns the annotated envelope, or {"errors": [...]}.
CREATE OR REPLACE FUNCTION cel.check(ast jsonb, env text, options jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  envs    text[];
  ctr     text := coalesce(options ->> 'container', '');
  globals jsonb;
  st      jsonb;
  fns     jsonb := '{}'::jsonb;
  c       record;
  types   jsonb := '{}'::jsonb;
  entry   record;
BEGIN
  IF ast ? 'errors' THEN
    RAISE 'cannot check a failed parse';
  END IF;
  IF NOT ast ? 'expr' THEN
    RAISE 'not an AST envelope';
  END IF;

  envs := cel._env_names(env);

  -- Global declarations: the caller's decls plus a type(T) ident for
  -- every registered type visible in the env union.
  SELECT coalesce(jsonb_object_agg(
    t.name,
    jsonb_build_object('kind', 'type',
      'params', jsonb_build_array(t.kind))), '{}'::jsonb)
  INTO globals
  FROM cel.type t
  WHERE EXISTS (
    SELECT FROM cel.env_item it
    WHERE it.env = ANY (envs) AND it.kind = 'type'
      AND it.ref = t.name);

  -- Enum constants (kind->'enum') are int-typed idents under
  -- '<type>.<name>', mirroring cel-go's Provider.FindIdent.
  SELECT globals || coalesce(jsonb_object_agg(
    t.name || '.' || e.key, '{"kind":"int"}'::jsonb), '{}'::jsonb)
  INTO globals
  FROM cel.type t
  CROSS JOIN LATERAL jsonb_each(t.kind -> 'enum') e
  WHERE t.kind ? 'enum' AND EXISTS (
    SELECT FROM cel.env_item it
    WHERE it.env = ANY (envs) AND it.kind = 'type'
      AND it.ref = t.name);

  IF options ? 'decls' THEN
    SELECT globals || coalesce(jsonb_object_agg(
      d ->> 'name', d -> 'type'), '{}'::jsonb)
    INTO globals
    FROM jsonb_array_elements(options -> 'decls') d
    WHERE d ? 'type';
    -- Function declarations become caller-scoped overloads,
    -- threaded to _ck_resolve via the checker state.
    SELECT coalesce(jsonb_object_agg(
      d ->> 'name', d -> 'function' -> 'overloads'), '{}'::jsonb)
    INTO fns
    FROM jsonb_array_elements(options -> 'decls') d
    WHERE d ? 'function';
  END IF;

  st := jsonb_build_object(
    'types', '{}'::jsonb, 'refs', '{}'::jsonb,
    'map', '{}'::jsonb, 'n', 0, 'fns', fns);

  SELECT * INTO c FROM cel._ck(
    ast -> 'expr', '[]'::jsonb, globals, envs, ctr, st);
  IF c.err IS NOT NULL THEN
    RETURN jsonb_build_object('errors',
      jsonb_build_array(jsonb_build_object('msg', c.err)));
  END IF;

  -- Final substitution: unbound parameters collapse to dyn.
  FOR entry IN SELECT key, value FROM jsonb_each(c.sto -> 'types') LOOP
    types := types || jsonb_build_object(
      entry.key, cel._ck_subst(c.sto -> 'map', entry.value, true));
  END LOOP;

  RETURN (ast || jsonb_build_object(
    'expr', c.nodeo,
    'types', types,
    'refs', c.sto -> 'refs'));
END;
$$;

CREATE OR REPLACE FUNCTION cel.check(ast jsonb, env text)
RETURNS jsonb
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel.check(ast, env, NULL);
$$;

COMMIT;

-- ---- sql/050_eval.sql ----

-- cel4postgres -- evaluator core.
--
-- Recursive tree walk over the AST envelope. Errors and unknowns are
-- tagged values flowing up (never exceptions -- a Postgres exception
-- escaping cel.eval is by definition a bug in the evaluator), and
-- every call dispatches through cel.overload rows: the absorbing
-- overload ids (logical_and/or, conditional, not_strictly_false,
-- equals/not_equals, and the index qualifiers) are implemented here
-- because their semantics control argument evaluation or belong to
-- the attribute machinery, everything else EXECUTEs the row's impl.
-- No CASE on a function name anywhere -- day-one invariant 1.

BEGIN;

-- Signature match for runtime overload selection: does an evaluated
-- argument satisfy a declared argument type? Parameterized and
-- dynamic types erase to "match anything" at runtime; containers
-- match on their kind alone.
CREATE OR REPLACE FUNCTION cel._sig_match_one(argtype jsonb, v jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  tk text := argtype ->> 'kind';
  vk text := v ->> '@t';
BEGIN
  RETURN CASE tk
    WHEN 'dyn' THEN true
    WHEN 'any' THEN true
    WHEN 'param' THEN true
    WHEN 'wrapper' THEN
      vk = 'null' OR cel._sig_match_one(argtype -> 'params' -> 0, v)
    WHEN 'opaque' THEN
      vk = 'opaque' AND v ->> 'type' = argtype ->> 'name'
    WHEN 'struct' THEN vk = 'opaque' OR vk = 'map'
    ELSE vk = tk
  END;
END;
$$;

CREATE OR REPLACE FUNCTION cel._sig_match(arg_types jsonb, args jsonb[])
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  i int;
BEGIN
  IF jsonb_array_length(arg_types) <> cardinality(args) THEN
    RETURN false;
  END IF;
  FOR i IN 1 .. cardinality(args) LOOP
    IF NOT cel._sig_match_one(arg_types -> (i - 1), args[i]) THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END;
$$;

-- Table-driven dispatch on evaluated arguments. ref carries the
-- checker's bound overload ids when present; without it (unchecked
-- eval) the candidates are every row of the function visible in the
-- env union, tried in cel-go's declaration order.
CREATE OR REPLACE FUNCTION cel._ev_dispatch(
  fn text,
  is_member boolean,
  args jsonb[],
  ref jsonb,
  envs text[],
  node_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  row_r  record;
  result jsonb;
BEGIN
  IF ref ? 'overloads' THEN
    FOR row_r IN
      SELECT o.*
      FROM jsonb_array_elements_text(ref -> 'overloads')
        WITH ORDINALITY b(id, ord)
      JOIN cel.overload o ON o.id = b.id
      ORDER BY b.ord
    LOOP
      IF cel._sig_match(row_r.arg_types, args) THEN
        EXECUTE format('SELECT %s($1)',
          split_part(row_r.impl::text, '(', 1))
        INTO result USING args;
        RETURN result;
      END IF;
    END LOOP;
  ELSE
    FOR row_r IN
      SELECT o.*
      FROM cel.overload o
      WHERE o.function = fn
        AND o.member = is_member
        AND o.impl IS NOT NULL
        AND EXISTS (
          SELECT FROM cel.env_item i
          WHERE i.env = ANY (envs)
            AND i.kind = 'overload' AND i.ref = o.id)
      ORDER BY o.ordinal
    LOOP
      IF cel._sig_match(row_r.arg_types, args) THEN
        EXECUTE format('SELECT %s($1)',
          split_part(row_r.impl::text, '(', 1))
        INTO result USING args;
        RETURN result;
      END IF;
    END LOOP;
  END IF;

  RETURN cel._err(format('found no matching overload for %s',
    quote_literal(fn)), node_id);
END;
$$;

-- The dotted parts of a pure ident/select chain ("a.b.c" ->
-- {a,b,c}), or NULL for anything else. absolute reports a leading
-- dot (root-scoped: container resolution does not apply).
CREATE OR REPLACE FUNCTION cel._attr_chain(
  node jsonb, OUT parts text[], OUT absolute boolean
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  sub record;
BEGIN
  IF node ->> 'k' = 'ident' THEN
    absolute := (node ->> 'name') LIKE '.%';
    parts := ARRAY[ltrim(node ->> 'name', '.')];
    RETURN;
  END IF;
  IF node ->> 'k' = 'select'
     AND NOT coalesce((node -> 'test')::boolean, false) THEN
    SELECT * INTO sub FROM cel._attr_chain(node -> 'op');
    IF sub.parts IS NOT NULL THEN
      parts := sub.parts || (node ->> 'field');
      absolute := sub.absolute;
    END IF;
  END IF;
END;
$$;

-- Candidate variable names for a dotted name under a container:
-- container "a.b" tries a.b.name, a.name, name -- cel-go's namespace
-- resolution order, measured against v0.32.0.
CREATE OR REPLACE FUNCTION cel._name_candidates(
  name text, absolute boolean, ctr text
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  cands text[] := '{}';
  c     text := ctr;
BEGIN
  IF absolute OR coalesce(ctr, '') = '' THEN
    RETURN ARRAY[name];
  END IF;
  WHILE c <> '' LOOP
    cands := cands || (c || '.' || name);
    IF position('.' IN c) = 0 THEN
      EXIT;
    END IF;
    c := substr(c, 1, length(c) - position('.' IN reverse(c)));
  END LOOP;
  RETURN cands || name;
END;
$$;

-- Resolves a dotted chain against the scope stack. Scope wins over
-- name length: an inner frame binding "y" shadows an outer binding
-- of "y.z" (measured against cel-go -- the comprehension-shadowing
-- corpus cases depend on it). Within one frame, longer names win,
-- and container-qualified candidates come before bare ones.
-- Returns NULL when nothing resolves; otherwise the value and how
-- many chain parts it consumed.
CREATE OR REPLACE FUNCTION cel._resolve_chain(
  parts text[], absolute boolean, scopes jsonb, ctr text,
  OUT val jsonb, OUT used int
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  f     int;
  plen  int;
  cand  text;
  name  text;
BEGIN
  -- A leading dot pins the name to the input activation: cel-go's
  -- absoluteAttribute unwraps every comprehension frame before
  -- resolving when the checker marked the name for disambiguation
  -- (attributes.go, disambiguateNames).
  FOR f IN REVERSE CASE WHEN absolute THEN 0
                        ELSE jsonb_array_length(scopes) - 1 END .. 0
  LOOP
    FOR plen IN REVERSE cardinality(parts) .. 1 LOOP
      name := array_to_string(parts[1:plen], '.');
      FOREACH cand IN ARRAY cel._name_candidates(name, absolute, ctr)
      LOOP
        IF scopes -> f ? cand THEN
          val := scopes -> f -> cand;
          used := plen;
          RETURN;
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
END;
$$;

-- Resolves a dotted name as a registered type identifier (-> a type
-- value) or a registered enum constant (-> its tagged value, e.g.
-- google.protobuf.NullValue.NULL_VALUE -> int 0, mirroring cel-go's
-- Provider.FindIdent). NULL when the name is neither.
CREATE OR REPLACE FUNCTION cel._type_or_enum(
  name text, absolute boolean, envs text[], ctr text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  r jsonb;
BEGIN
  SELECT jsonb_build_object('@t', 'type', 'v', c) INTO r
  FROM unnest(cel._name_candidates(name, absolute, ctr)) AS c
  WHERE EXISTS (
    SELECT FROM cel.type t
    WHERE t.name = c AND EXISTS (
      SELECT FROM cel.env_item i2
      WHERE i2.env = ANY (envs) AND i2.kind = 'type'
        AND i2.ref = t.name))
  LIMIT 1;
  IF r IS NOT NULL THEN
    RETURN r;
  END IF;
  SELECT jsonb_build_object('@t', 'int', 'v', e.value::bigint)
  INTO r
  FROM unnest(cel._name_candidates(name, absolute, ctr)) AS c
  JOIN cel.type t
    ON t.kind ? 'enum' AND c LIKE t.name || '.%'
  JOIN LATERAL jsonb_each_text(t.kind -> 'enum') e ON true
  WHERE t.name || '.' || e.key = c
    AND EXISTS (
      SELECT FROM cel.env_item i2
      WHERE i2.env = ANY (envs) AND i2.kind = 'type'
        AND i2.ref = t.name)
  LIMIT 1;
  RETURN r;
END;
$$;

-- Field selection on an already-evaluated value.
CREATE OR REPLACE FUNCTION cel._sel_field(v jsonb, field text, nid bigint)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  r jsonb;
BEGIN
  IF cel._is_error(v) OR cel._is_unknown(v) THEN
    RETURN v;
  END IF;
  IF v ->> '@t' = 'map' THEN
    r := cel._map_find(v,
      jsonb_build_object('@t', 'string', 'v', field));
    IF r IS NULL THEN
      RETURN cel._err(format('no such key: %s', field), nid);
    END IF;
    RETURN r;
  END IF;
  -- Selection distributes over optional values (cel-go optional
  -- qualifiers): none stays none, a present value is selected
  -- strictly and re-wrapped.
  IF v ->> '@t' = 'opaque' AND v ->> 'type' = 'optional_type' THEN
    IF NOT (v -> 'v' ->> 'p')::boolean THEN
      RETURN v;
    END IF;
    -- If-present semantics: a missing field yields none.
    IF v -> 'v' -> 'v' ->> '@t' = 'map' THEN
      r := cel._map_find(v -> 'v' -> 'v',
        jsonb_build_object('@t', 'string', 'v', field));
      IF r IS NULL THEN
        RETURN cel._opt_none();
      END IF;
      RETURN cel._opt_of(r);
    END IF;
    r := cel._sel_field(v -> 'v' -> 'v', field, nid);
    IF cel._is_error(r) OR cel._is_unknown(r) THEN
      RETURN r;
    END IF;
    RETURN cel._opt_of(r);
  END IF;
  RETURN cel._err(format(
    'does not support field selection: %s', v ->> '@t'), nid);
END;
$$;

-- The recursive evaluator.
CREATE OR REPLACE FUNCTION cel._ev(
  node jsonb,
  scopes jsonb,
  envs text[],
  ctr text,
  d int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k    text := node ->> 'k';
  nid  bigint := (node ->> 'id')::bigint;
  fn   text;
  v    jsonb;
  l    jsonb;
  r    jsonb;
  args jsonb[];
  unk  jsonb;
  i    int;
  elems jsonb;
  entries jsonb;
  key  jsonb;
  nm   text;
  eq   boolean;
  row_r record;
  chain record;
  res  record;
BEGIN
  IF d >= 200 THEN
    RETURN cel._err('expression recursion limit exceeded: 200', nid);
  END IF;

  CASE k
  WHEN 'lit' THEN
    RETURN node -> 'v';

  WHEN 'ident' THEN
    SELECT * INTO chain FROM cel._attr_chain(node);
    SELECT * INTO res
    FROM cel._resolve_chain(chain.parts, chain.absolute, scopes, ctr);
    IF res.val IS NOT NULL THEN
      RETURN res.val;
    END IF;
    -- Registered type names are identifiers of type type(T); enum
    -- constants resolve to their values.
    v := cel._type_or_enum(
      ltrim(node ->> 'name', '.'), chain.absolute, envs, ctr);
    IF v IS NOT NULL THEN
      RETURN v;
    END IF;
    RETURN cel._err(format('no such attribute: %s',
      ltrim(node ->> 'name', '.')), nid);

  WHEN 'select' THEN
    key := jsonb_build_object('@t', 'string', 'v', node ->> 'field');

    IF coalesce((node -> 'test')::boolean, false) THEN
      v := cel._ev(node -> 'op', scopes, envs, ctr, d + 1);
      IF cel._is_error(v) OR cel._is_unknown(v) THEN
        RETURN v;
      END IF;
      IF v ->> '@t' = 'opaque' AND v ->> 'type' = 'optional_type'
      THEN
        IF NOT (v -> 'v' ->> 'p')::boolean THEN
          RETURN cel._bool_val(false);
        END IF;
        v := v -> 'v' -> 'v';
      END IF;
      IF v ->> '@t' = 'map' THEN
        RETURN cel._bool_val(cel._map_find(v, key) IS NOT NULL);
      END IF;
      RETURN cel._err(format(
        'does not support field selection: %s', v ->> '@t'), nid);
    END IF;

    -- Qualified-name resolution: the scope stack decides between a
    -- bound "a.b" and field-selecting a bound "a".
    SELECT * INTO chain FROM cel._attr_chain(node);
    IF chain.parts IS NOT NULL THEN
      SELECT * INTO res
      FROM cel._resolve_chain(chain.parts, chain.absolute, scopes, ctr);
      IF res.val IS NOT NULL THEN
        v := res.val;
        FOR i IN res.used + 1 .. cardinality(chain.parts) LOOP
          v := cel._sel_field(v, chain.parts[i], nid);
        END LOOP;
        RETURN v;
      END IF;
      -- A fully-qualified type name or enum constant written as a
      -- select chain (unchecked ASTs only; the checker rewrites
      -- these to qualified idents).
      v := cel._type_or_enum(
        array_to_string(chain.parts, '.'), chain.absolute, envs,
        ctr);
      IF v IS NOT NULL THEN
        RETURN v;
      END IF;
    END IF;

    v := cel._ev(node -> 'op', scopes, envs, ctr, d + 1);
    IF cel._is_error(v) OR cel._is_unknown(v) THEN
      RETURN v;
    END IF;
    RETURN cel._sel_field(v, node ->> 'field', nid);

  WHEN 'call' THEN
    fn := node ->> 'fn';

    -- Core-absorbed overload ids: found by the same registry lookup
    -- as everything else (impl IS NULL marks them), implemented here
    -- because their semantics control argument evaluation. The
    -- dispatch is on the row's *id*, not the function name.
    SELECT o.id INTO nm
    FROM cel.overload o
    WHERE o.function = fn AND o.impl IS NULL
      AND o.member = (node ? 'target')
      AND EXISTS (
        SELECT FROM cel.env_item i2
        WHERE i2.env = ANY (envs) AND i2.kind = 'overload'
          AND i2.ref = o.id)
    ORDER BY o.ordinal
    LIMIT 1;

    IF nm = 'logical_and' OR nm = 'logical_or' THEN
      -- false && x = false in either order; true || x = true in
      -- either order; otherwise merged unknown beats first error
      -- beats the boolean identity.
      l := cel._ev(node -> 'args' -> 0, scopes, envs, ctr, d + 1);
      IF l ->> '@t' = 'bool'
         AND (l ->> 'v')::boolean = (nm = 'logical_or') THEN
        RETURN l;
      END IF;
      r := cel._ev(node -> 'args' -> 1, scopes, envs, ctr, d + 1);
      IF r ->> '@t' = 'bool'
         AND (r ->> 'v')::boolean = (nm = 'logical_or') THEN
        RETURN r;
      END IF;
      IF l ->> '@t' = 'bool' AND r ->> '@t' = 'bool' THEN
        RETURN l;   -- both are the identity value
      END IF;
      IF cel._is_unknown(l) AND cel._is_unknown(r) THEN
        RETURN cel._unknown_merge(l, r);
      END IF;
      IF cel._is_unknown(l) THEN RETURN l; END IF;
      IF cel._is_unknown(r) THEN RETURN r; END IF;
      IF cel._is_error(l) THEN RETURN l; END IF;
      IF cel._is_error(r) THEN RETURN r; END IF;
      RETURN cel._err('no such overload', nid);

    ELSIF nm = 'conditional' THEN
      l := cel._ev(node -> 'args' -> 0, scopes, envs, ctr, d + 1);
      IF cel._is_error(l) OR cel._is_unknown(l) THEN
        RETURN l;
      END IF;
      IF l ->> '@t' <> 'bool' THEN
        RETURN cel._err('no such overload', nid);
      END IF;
      IF (l ->> 'v')::boolean THEN
        RETURN cel._ev(node -> 'args' -> 1, scopes, envs, ctr, d + 1);
      END IF;
      RETURN cel._ev(node -> 'args' -> 2, scopes, envs, ctr, d + 1);

    ELSIF nm = 'not_strictly_false' THEN
      l := cel._ev(node -> 'args' -> 0, scopes, envs, ctr, d + 1);
      IF l ->> '@t' = 'bool' THEN
        RETURN l;
      END IF;
      RETURN cel._bool_val(true);

    ELSIF nm = 'equals' OR nm = 'not_equals' THEN
      l := cel._ev(node -> 'args' -> 0, scopes, envs, ctr, d + 1);
      IF cel._is_error(l) THEN
        RETURN l;
      END IF;
      r := cel._ev(node -> 'args' -> 1, scopes, envs, ctr, d + 1);
      IF cel._is_error(r) THEN
        RETURN r;
      END IF;
      IF cel._is_unknown(l) AND cel._is_unknown(r) THEN
        RETURN cel._unknown_merge(l, r);
      END IF;
      IF cel._is_unknown(l) THEN RETURN l; END IF;
      IF cel._is_unknown(r) THEN RETURN r; END IF;
      eq := cel._equal(l, r);
      RETURN cel._bool_val(eq = (nm = 'equals'));

    ELSIF nm IN ('index_list', 'index_map') THEN
      -- Indexing is attribute machinery in cel-go's interpreter (the
      -- planner turns _[_] into a qualifier), which is what admits
      -- losslessly-coercible double/uint list indices at runtime;
      -- plain signature dispatch could not. Strict in both args.
      l := cel._ev(node -> 'args' -> 0, scopes, envs, ctr, d + 1);
      IF cel._is_error(l) THEN RETURN l; END IF;
      r := cel._ev(node -> 'args' -> 1, scopes, envs, ctr, d + 1);
      IF cel._is_error(r) THEN RETURN r; END IF;
      IF cel._is_unknown(l) AND cel._is_unknown(r) THEN
        RETURN cel._unknown_merge(l, r);
      END IF;
      IF cel._is_unknown(l) THEN RETURN l; END IF;
      IF cel._is_unknown(r) THEN RETURN r; END IF;
      IF l ->> '@t' = 'list' THEN
        RETURN cel._f_index_list(ARRAY[l, r]);
      ELSIF l ->> '@t' = 'map' THEN
        RETURN cel._f_index_map(ARRAY[l, r]);
      ELSIF l ->> '@t' = 'opaque' THEN
        -- An extension index overload (e.g. the optionals rows) may
        -- accept the opaque; fall through to normal dispatch.
        RETURN cel._ev_dispatch(fn, node ? 'target',
          ARRAY[l, r], node -> 'ref', envs, nid);
      END IF;
      RETURN cel._err('no such overload', nid);
    END IF;

    -- Strict call: arguments left to right; first error wins, then
    -- merged unknowns.
    args := '{}';
    unk := NULL;
    IF node ? 'target' THEN
      v := cel._ev(node -> 'target', scopes, envs, ctr, d + 1);
      IF cel._is_error(v) THEN RETURN v; END IF;
      IF cel._is_unknown(v) THEN
        unk := CASE WHEN unk IS NULL THEN v
                    ELSE cel._unknown_merge(unk, v) END;
      END IF;
      args := args || v;
    END IF;
    FOR i IN 0 .. jsonb_array_length(node -> 'args') - 1 LOOP
      v := cel._ev(node -> 'args' -> i, scopes, envs, ctr, d + 1);
      IF cel._is_error(v) THEN RETURN v; END IF;
      IF cel._is_unknown(v) THEN
        unk := CASE WHEN unk IS NULL THEN v
                    ELSE cel._unknown_merge(unk, v) END;
      END IF;
      args := args || v;
    END LOOP;
    IF unk IS NOT NULL THEN
      RETURN unk;
    END IF;

    RETURN cel._ev_dispatch(
      fn, node ? 'target', args, node -> 'ref', envs, nid);

  WHEN 'list' THEN
    elems := '[]'::jsonb;
    unk := NULL;
    FOR i IN 0 .. jsonb_array_length(node -> 'elems') - 1 LOOP
      v := cel._ev(node -> 'elems' -> i, scopes, envs, ctr, d + 1);
      IF cel._is_error(v) THEN RETURN v; END IF;
      IF cel._is_unknown(v) THEN
        unk := CASE WHEN unk IS NULL THEN v
                    ELSE cel._unknown_merge(unk, v) END;
      END IF;
      -- [?x] elements splice: none disappears, of(v) inlines
      -- (optionals extension list-literal support).
      IF node -> 'opt' @> to_jsonb(i) THEN
        IF v ->> '@t' = 'opaque' AND v ->> 'type' = 'optional_type'
        THEN
          IF NOT (v -> 'v' ->> 'p')::boolean THEN
            CONTINUE;
          END IF;
          v := v -> 'v' -> 'v';
        END IF;
      END IF;
      elems := elems || jsonb_build_array(v);
    END LOOP;
    IF unk IS NOT NULL THEN
      RETURN unk;
    END IF;
    RETURN jsonb_build_object('@t', 'list', 'v', elems);

  WHEN 'map' THEN
    entries := '[]'::jsonb;
    unk := NULL;
    FOR i IN 0 .. jsonb_array_length(node -> 'entries') - 1 LOOP
      key := cel._ev(node -> 'entries' -> i -> 'k',
        scopes, envs, ctr, d + 1);
      IF cel._is_error(key) THEN RETURN key; END IF;
      v := cel._ev(node -> 'entries' -> i -> 'v',
        scopes, envs, ctr, d + 1);
      IF cel._is_error(v) THEN RETURN v; END IF;
      IF cel._is_unknown(key) THEN
        unk := CASE WHEN unk IS NULL THEN key
                    ELSE cel._unknown_merge(unk, key) END;
      END IF;
      IF cel._is_unknown(v) THEN
        unk := CASE WHEN unk IS NULL THEN v
                    ELSE cel._unknown_merge(unk, v) END;
      END IF;
      IF unk IS NULL THEN
        -- {?k: v} entries splice: a none value drops the entry, a
        -- present one inlines (optionals extension).
        IF coalesce((node -> 'entries' -> i -> 'opt')::boolean,
                    false)
           AND v ->> '@t' = 'opaque'
           AND v ->> 'type' = 'optional_type' THEN
          IF NOT (v -> 'v' ->> 'p')::boolean THEN
            CONTINUE;
          END IF;
          v := v -> 'v' -> 'v';
        END IF;
        -- Key type restriction and duplicate rejection are dynamic:
        -- forbidden double/null keys and normalized duplicates both
        -- error at construction (the corpus's rule -- see
        -- docs/CONFORMANCE.md on following it over cel-go).
        IF key ->> '@t' NOT IN ('bool', 'int', 'uint', 'string') THEN
          RETURN cel._err(format(
            'unsupported map key type: %s', key ->> '@t'), nid);
        END IF;
        IF cel._map_find(
             jsonb_build_object('@t', 'map', 'v', entries), key)
           IS NOT NULL THEN
          RETURN cel._err('Failed with repeated key', nid);
        END IF;
        entries := entries || jsonb_build_array(
          jsonb_build_object('k', key, 'v', v));
      END IF;
    END LOOP;
    IF unk IS NOT NULL THEN
      RETURN unk;
    END IF;
    RETURN jsonb_build_object('@t', 'map', 'v', entries);

  WHEN 'struct' THEN
    nm := ltrim(node ->> 'type', '.');
    SELECT t.* INTO row_r
    FROM cel.type t
    WHERE t.name = ANY (cel._name_candidates(
        nm, (node ->> 'type') LIKE '.%', ctr))
      AND t.construct IS NOT NULL
      AND EXISTS (
        SELECT FROM cel.env_item i2
        WHERE i2.env = ANY (envs) AND i2.kind = 'type'
          AND i2.ref = t.name)
    LIMIT 1;
    IF NOT FOUND THEN
      RETURN cel._err(format('unknown message type: %s', nm), nid);
    END IF;
    -- Evaluate fields into an object, then hand to the type row's
    -- construct impl (invariant 3: WKTs and opaque extension types
    -- ride the same path).
    entries := '{}'::jsonb;
    unk := NULL;
    FOR i IN 0 .. jsonb_array_length(node -> 'fields') - 1 LOOP
      v := cel._ev(node -> 'fields' -> i -> 'v',
        scopes, envs, ctr, d + 1);
      IF cel._is_error(v) THEN RETURN v; END IF;
      IF cel._is_unknown(v) THEN
        unk := CASE WHEN unk IS NULL THEN v
                    ELSE cel._unknown_merge(unk, v) END;
      END IF;
      IF coalesce((node -> 'fields' -> i -> 'opt')::boolean, false)
         AND v ->> '@t' = 'opaque'
         AND v ->> 'type' = 'optional_type' THEN
        IF NOT (v -> 'v' ->> 'p')::boolean THEN
          CONTINUE;
        END IF;
        v := v -> 'v' -> 'v';
      END IF;
      entries := entries || jsonb_build_object(
        node -> 'fields' -> i ->> 'name', v);
    END LOOP;
    IF unk IS NOT NULL THEN
      RETURN unk;
    END IF;
    EXECUTE format('SELECT %s($1)',
      split_part(row_r.construct::text, '(', 1))
    INTO v USING entries;
    RETURN v;

  WHEN 'comp' THEN
    RETURN cel._ev_comp(node, scopes, envs, ctr, d);

  ELSE
    RETURN cel._err(format('unsupported AST node kind: %s', k), nid);
  END CASE;
END;
$$;

-- The comprehension fold. The loop-termination
-- rule is load-bearing: only a genuine bool false stops iteration --
-- an error or unknown condition keeps folding, which is how exists
-- recovers from early errors when a later element is true.
CREATE OR REPLACE FUNCTION cel._ev_comp(
  node jsonb,
  scopes jsonb,
  envs text[],
  ctr text,
  d int
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  nid    bigint := (node ->> 'id')::bigint;
  iter   text := node ->> 'iter';
  iter2  text := node ->> 'iter2';
  accu_n text := node ->> 'accu';
  range_v jsonb;
  accu   jsonb;
  cond   jsonb;
  frame  jsonb;
  item1  jsonb;
  item2  jsonb;
  i      int;
  rk     text;
BEGIN
  range_v := cel._ev(node -> 'range', scopes, envs, ctr, d + 1);
  IF cel._is_error(range_v) OR cel._is_unknown(range_v) THEN
    RETURN range_v;
  END IF;
  rk := range_v ->> '@t';
  IF rk NOT IN ('list', 'map') THEN
    RETURN cel._err(format(
      'cannot iterate over: %s', rk), nid);
  END IF;

  accu := cel._ev(node -> 'init', scopes, envs, ctr, d + 1);
  IF cel._is_error(accu) OR cel._is_unknown(accu) THEN
    RETURN accu;
  END IF;

  FOR i IN 0 .. jsonb_array_length(range_v -> 'v') - 1 LOOP
    IF rk = 'list' THEN
      item1 := CASE WHEN iter2 = '' THEN range_v -> 'v' -> i
                    ELSE cel._int_val(i) END;
      item2 := range_v -> 'v' -> i;
    ELSE
      item1 := range_v -> 'v' -> i -> 'k';
      item2 := range_v -> 'v' -> i -> 'v';
    END IF;

    frame := jsonb_build_object(accu_n, accu, iter, item1);
    IF iter2 <> '' THEN
      frame := frame || jsonb_build_object(iter2, item2);
    END IF;

    cond := cel._ev(node -> 'cond',
      scopes || jsonb_build_array(frame), envs, ctr, d + 1);
    IF cond ->> '@t' = 'bool' AND NOT (cond ->> 'v')::boolean THEN
      EXIT;
    END IF;

    accu := cel._ev(node -> 'step',
      scopes || jsonb_build_array(frame), envs, ctr, d + 1);
  END LOOP;

  RETURN cel._ev(node -> 'result',
    scopes || jsonb_build_array(jsonb_build_object(accu_n, accu)),
    envs, ctr, d + 1);
END;
$$;

-- Evaluates a parsed (or checked) AST envelope under an activation
-- of tagged values. options carries what the corpus calls per-case
-- environment shape: today just "container", which unchecked
-- evaluation needs for name resolution (checked ASTs resolve names
-- at check time). STABLE, not IMMUTABLE: dispatch reads the
-- registry.
CREATE OR REPLACE FUNCTION cel.eval(
  ast jsonb,
  activation jsonb,
  env text,
  options jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  envs text[];
BEGIN
  IF ast ? 'errors' THEN
    RAISE 'cannot evaluate a failed parse';
  END IF;
  IF NOT ast ? 'expr' THEN
    RAISE 'not an AST envelope';
  END IF;

  envs := cel._env_names(env);
  RETURN cel._ev(
    ast -> 'expr',
    jsonb_build_array(coalesce(activation, '{}'::jsonb)),
    envs,
    -- A checked AST already carries fully-qualified names; applying
    -- the container again would mis-resolve deliberately-bare names
    -- (the corpus disambiguation cases: a checked ident "y" must not
    -- become "com.example.y" at runtime).
    CASE WHEN ast ? 'types' THEN ''
         ELSE coalesce(options ->> 'container', '') END,
    0);
END;
$$;

CREATE OR REPLACE FUNCTION cel.eval(
  ast jsonb,
  activation jsonb,
  env text
)
RETURNS jsonb
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel.eval(ast, activation, env, '{}'::jsonb);
$$;

-- The one-shot composition: parse, check, eval. A parse or check
-- rejection comes back as a CEL error value carrying the first
-- message, so callers see one result type; callers that need the
-- distinct stages (or memoization) use them directly.
CREATE OR REPLACE FUNCTION cel.evaluate(
  source text,
  activation jsonb,
  env text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  ast jsonb := cel.parse(source, env);
BEGIN
  IF ast ? 'errors' THEN
    RETURN cel._err(ast -> 'errors' -> 0 ->> 'msg');
  END IF;
  ast := cel.check(ast, env);
  IF ast ? 'errors' THEN
    RETURN cel._err(ast -> 'errors' -> 0 ->> 'msg');
  END IF;
  RETURN cel.eval(ast, activation, env);
END;
$$;

COMMIT;

-- ---- sql/060_stdlib.sql ----

-- cel4postgres -- standard library, part 1.
--
-- Logic, arithmetic, relations, size, membership, indexing. Every
-- implementation has the uniform registry signature
-- impl(args jsonb[]) -> jsonb over already-evaluated tagged values,
-- and registers through cel.overload rows exactly as an extension
-- would -- no privileged path (CLAUDE.md, the four registries).
--
-- Semantics are cel-go v0.32.0's, encoded from measured runs and the
-- pinned source: checked int64/uint64
-- arithmetic with overflow sentinels, IEEE-754 double arithmetic
-- with the three non-finite sentinels, Go-style truncated division
-- and remainder.

BEGIN;

-- Integer (int64) checked arithmetic. Postgres numeric is exact, so
-- overflow is a range check, not a wraparound.

CREATE OR REPLACE FUNCTION cel._chk_int(n numeric, id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN n < -9223372036854775808::numeric
      OR n > 9223372036854775807::numeric
    THEN cel._err('integer overflow', id)
    ELSE cel._int_val(n)
  END;
$$;

CREATE OR REPLACE FUNCTION cel._chk_uint(n numeric, id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN n < 0 OR n > 18446744073709551615::numeric
    THEN cel._err('unsigned integer overflow', id)
    ELSE jsonb_build_object('@t', 'uint', 'v', to_jsonb(n))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_add_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_int(
    (args[1] ->> 'v')::numeric + (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_subtract_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_int(
    (args[1] ->> 'v')::numeric - (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_multiply_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_int(
    (args[1] ->> 'v')::numeric * (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_divide_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN (args[2] ->> 'v')::numeric = 0
      THEN cel._err('division by zero')
    ELSE cel._chk_int(trunc(
      (args[1] ->> 'v')::numeric / (args[2] ->> 'v')::numeric, 0))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_modulo_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  -- Go's % truncates toward zero (remainder keeps the dividend's
  -- sign), which is exactly Postgres numeric mod. MinInt64 % -1 is
  -- an overflow sentinel in cel-go, not 0.
  SELECT CASE
    WHEN (args[2] ->> 'v')::numeric = 0
      THEN cel._err('modulus by zero')
    WHEN (args[1] ->> 'v')::numeric = -9223372036854775808::numeric
     AND (args[2] ->> 'v')::numeric = -1
      THEN cel._err('integer overflow')
    ELSE cel._int_val(mod(
      (args[1] ->> 'v')::numeric, (args[2] ->> 'v')::numeric))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_negate_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_int(-(args[1] ->> 'v')::numeric);
$$;

-- Unsigned (uint64) checked arithmetic.

CREATE OR REPLACE FUNCTION cel._f_add_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_uint(
    (args[1] ->> 'v')::numeric + (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_subtract_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_uint(
    (args[1] ->> 'v')::numeric - (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_multiply_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_uint(
    (args[1] ->> 'v')::numeric * (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_divide_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN (args[2] ->> 'v')::numeric = 0
      THEN cel._err('division by zero')
    ELSE cel._chk_uint(trunc(
      (args[1] ->> 'v')::numeric / (args[2] ->> 'v')::numeric, 0))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_modulo_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN (args[2] ->> 'v')::numeric = 0
      THEN cel._err('modulus by zero')
    ELSE cel._chk_uint(mod(
      (args[1] ->> 'v')::numeric, (args[2] ->> 'v')::numeric))
  END;
$$;

-- Double (IEEE-754 binary64) arithmetic. Hardware float8 ops are
-- correctly rounded, but Postgres raises on overflow/underflow where
-- IEEE wants ±Infinity/±0, so finite operands go through an exact
-- numeric computation (+ - *) or numeric pre-checks (/) with the
-- true rounding boundaries: 2^1024 - 2^970 for overflow (at or
-- beyond rounds to Infinity, ties-to-even) and 2^-1075 for
-- underflow. Non-finite operands use float8 directly -- IEEE special
-- values never raise.
--
-- Note: float8 -> numeric goes through the shortest decimal text,
-- not the exact binary value; the discrepancy (< 1 ulp of the 17th
-- digit) only matters within one part in 1e16 of the exact overflow
-- boundary, unreachable in practice.

CREATE OR REPLACE FUNCTION cel._dbl_of_numeric(n numeric)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  boundary numeric := 18014398509481983::numeric * (2::numeric ^ 970);
BEGIN
  IF abs(n) >= boundary THEN
    RETURN jsonb_build_object('@t', 'double', 'v',
      CASE WHEN n < 0 THEN '-Infinity' ELSE 'Infinity' END);
  END IF;
  IF n <> 0 AND abs(n) <= 2.4703282292062327e-324::numeric THEN
    RETURN cel._dbl_val((CASE WHEN n < 0 THEN '-0' ELSE '0' END)::float8);
  END IF;
  RETURN cel._dbl_val(n::float8);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_dbl_bin(op text, a jsonb, b jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  fa float8 := cel._dbl(a);
  fb float8 := cel._dbl(b);
  na numeric;
  nb numeric;
  boundary numeric := 18014398509481983::numeric * (2::numeric ^ 970);
  neg boolean;
BEGIN
  IF fa = 'Infinity'::float8 OR fa = '-Infinity'::float8
     OR fa = 'NaN'::float8
     OR fb = 'Infinity'::float8 OR fb = '-Infinity'::float8
     OR fb = 'NaN'::float8
  THEN
    -- IEEE special values never raise in float8 arithmetic; the one
    -- case Postgres would reject is division by a zero divisor.
    IF op = '/' AND fb = 0 THEN
      IF fa = 'NaN'::float8 THEN
        RETURN jsonb_build_object('@t', 'double', 'v', 'NaN');
      END IF;
      neg := (fa < 0) <> (fb::text LIKE '-%');
      RETURN jsonb_build_object('@t', 'double', 'v',
        CASE WHEN neg THEN '-Infinity' ELSE 'Infinity' END);
    END IF;
    RETURN cel._dbl_val(CASE op
      WHEN '+' THEN fa + fb
      WHEN '-' THEN fa - fb
      WHEN '*' THEN fa * fb
      ELSE fa / fb
    END);
  END IF;

  IF op = '/' THEN
    IF fb = 0 THEN
      IF fa = 0 THEN
        RETURN jsonb_build_object('@t', 'double', 'v', 'NaN');
      END IF;
      -- Sign of the zero matters: 1.0 / -0.0 is -Infinity.
      neg := (fa < 0) <> (fb::text LIKE '-%');
      RETURN jsonb_build_object('@t', 'double', 'v',
        CASE WHEN neg THEN '-Infinity' ELSE 'Infinity' END);
    END IF;
    na := cel._f2n(fa);
    nb := cel._f2n(fb);
    IF abs(na) >= boundary * abs(nb) THEN
      RETURN jsonb_build_object('@t', 'double', 'v',
        CASE WHEN (fa < 0) <> (fb < 0)
             THEN '-Infinity' ELSE 'Infinity' END);
    END IF;
    IF fa <> 0
       AND abs(na) <= 2.4703282292062327e-324::numeric * abs(nb) THEN
      RETURN cel._dbl_val(
        (CASE WHEN (fa < 0) <> (fb < 0) THEN '-0' ELSE '0' END)::float8);
    END IF;
    RETURN cel._dbl_val(fa / fb);
  END IF;

  na := cel._f2n(fa);
  nb := cel._f2n(fb);
  RETURN cel._dbl_of_numeric(CASE op
    WHEN '+' THEN na + nb
    WHEN '-' THEN na - nb
    ELSE na * nb
  END);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_add_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._f_dbl_bin('+', args[1], args[2]);
$$;

CREATE OR REPLACE FUNCTION cel._f_subtract_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._f_dbl_bin('-', args[1], args[2]);
$$;

CREATE OR REPLACE FUNCTION cel._f_multiply_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._f_dbl_bin('*', args[1], args[2]);
$$;

CREATE OR REPLACE FUNCTION cel._f_divide_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._f_dbl_bin('/', args[1], args[2]);
$$;

CREATE OR REPLACE FUNCTION cel._f_negate_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dbl_val(-cel._dbl(args[1]));
$$;

-- Concatenation forms of _+_.

CREATE OR REPLACE FUNCTION cel._f_add_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v',
    (args[1] ->> 'v') || (args[2] ->> 'v'));
$$;

CREATE OR REPLACE FUNCTION cel._f_add_bytes(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'bytes', 'v',
    replace(encode(
      decode(args[1] ->> 'v', 'base64')
      || decode(args[2] ->> 'v', 'base64'), 'base64'), E'\n', ''));
$$;

CREATE OR REPLACE FUNCTION cel._f_add_list(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'list', 'v',
    (args[1] -> 'v') || (args[2] -> 'v'));
$$;

-- Logic.

CREATE OR REPLACE FUNCTION cel._f_logical_not(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(NOT (args[1] ->> 'v')::boolean);
$$;

-- Relations: four shared impls over cel._compare, which already
-- implements the numeric cross-type matrix and NaN unorderability.

CREATE OR REPLACE FUNCTION cel._f_lt(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c jsonb := cel._compare(args[1], args[2]);
BEGIN
  IF cel._is_error(c) THEN RETURN c; END IF;
  RETURN cel._bool_val((c ->> 'v')::int < 0);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_le(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c jsonb := cel._compare(args[1], args[2]);
BEGIN
  IF cel._is_error(c) THEN RETURN c; END IF;
  RETURN cel._bool_val((c ->> 'v')::int <= 0);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_gt(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c jsonb := cel._compare(args[1], args[2]);
BEGIN
  IF cel._is_error(c) THEN RETURN c; END IF;
  RETURN cel._bool_val((c ->> 'v')::int > 0);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_ge(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c jsonb := cel._compare(args[1], args[2]);
BEGIN
  IF cel._is_error(c) THEN RETURN c; END IF;
  RETURN cel._bool_val((c ->> 'v')::int >= 0);
END;
$$;

-- Size.

CREATE OR REPLACE FUNCTION cel._f_size_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(length(args[1] ->> 'v'));
$$;

CREATE OR REPLACE FUNCTION cel._f_size_bytes(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(octet_length(decode(args[1] ->> 'v', 'base64')));
$$;

CREATE OR REPLACE FUNCTION cel._f_size_list(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(jsonb_array_length(args[1] -> 'v'));
$$;

CREATE OR REPLACE FUNCTION cel._f_size_map(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(jsonb_array_length(args[1] -> 'v'));
$$;

-- Membership.

CREATE OR REPLACE FUNCTION cel._f_in_list(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  e jsonb;
BEGIN
  FOR e IN SELECT x FROM jsonb_array_elements(args[2] -> 'v') x LOOP
    IF cel._equal(args[1], e) THEN
      RETURN cel._bool_val(true);
    END IF;
  END LOOP;
  RETURN cel._bool_val(false);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_in_map(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(cel._map_find(args[2], args[1]) IS NOT NULL);
$$;

-- Indexing. List indices accept int plus losslessly-coercible
-- double/uint (cel-go list index semantics).

CREATE OR REPLACE FUNCTION cel._f_index_list(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  kind text := args[2] ->> '@t';
  n    numeric;
  size int := jsonb_array_length(args[1] -> 'v');
BEGIN
  IF kind = 'double' THEN
    n := cel._dbl(args[2])::numeric;
    IF n <> trunc(n) THEN
      RETURN cel._err(format(
        'invalid_argument: unsupported index value %s', n::text));
    END IF;
  ELSIF kind IN ('int', 'uint') THEN
    n := (args[2] ->> 'v')::numeric;
  ELSE
    RETURN cel._err('no such overload');
  END IF;

  IF n < 0 OR n >= size THEN
    RETURN cel._err(format(
      'index ''%s'' out of range in list size ''%s''', n::text, size));
  END IF;
  RETURN args[1] -> 'v' -> n::int;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_index_map(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v jsonb := cel._map_find(args[1], args[2]);
BEGIN
  IF v IS NULL THEN
    RETURN cel._err(format('no such key: %s',
      coalesce(args[2] ->> 'v', 'null')));
  END IF;
  RETURN v;
END;
$$;

-- type() and dyn().

CREATE OR REPLACE FUNCTION cel._f_type(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'type', 'v', CASE args[1] ->> '@t'
    WHEN 'null' THEN 'null_type'
    WHEN 'timestamp' THEN 'google.protobuf.Timestamp'
    WHEN 'duration' THEN 'google.protobuf.Duration'
    WHEN 'opaque' THEN args[1] ->> 'type'
    ELSE args[1] ->> '@t'
  END);
$$;

CREATE OR REPLACE FUNCTION cel._f_to_dyn(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT args[1];
$$;

COMMIT;

BEGIN;

-- Overload rows. Ids are cel-go's exactly (common/overloads); the
-- checker binds them and conformance's type_deduction output depends
-- on them. The absorbed ids carry NULL impls -- the evaluator core
-- recognizes them by id after finding them through this same table.

WITH t AS (
  SELECT
    '{"kind":"bool"}'::jsonb   AS bool,
    '{"kind":"int"}'::jsonb    AS int,
    '{"kind":"uint"}'::jsonb   AS uint,
    '{"kind":"double"}'::jsonb AS dbl,
    '{"kind":"string"}'::jsonb AS str,
    '{"kind":"bytes"}'::jsonb  AS byt,
    '{"kind":"dyn"}'::jsonb    AS dyn,
    '{"kind":"param","name":"A"}'::jsonb AS pa,
    '{"kind":"param","name":"B"}'::jsonb AS pb,
    '{"kind":"list","params":[{"kind":"param","name":"A"}]}'::jsonb AS lista,
    '{"kind":"map","params":[{"kind":"param","name":"A"},{"kind":"param","name":"B"}]}'::jsonb AS mapab,
    '{"kind":"type","params":[{"kind":"param","name":"A"}]}'::jsonb AS typea
)
INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
SELECT * FROM (
  SELECT 'logical_and', '_&&_', false,
    jsonb_build_array(t.bool, t.bool), t.bool,
    NULL::regprocedure, 10 FROM t
  UNION ALL SELECT 'logical_or', '_||_', false,
    jsonb_build_array(t.bool, t.bool), t.bool, NULL, 10 FROM t
  UNION ALL SELECT 'logical_not', '!_', false,
    jsonb_build_array(t.bool), t.bool,
    'cel._f_logical_not(jsonb[])'::regprocedure, 10 FROM t
  UNION ALL SELECT 'conditional', '_?_:_', false,
    jsonb_build_array(t.bool, t.pa, t.pa), t.pa, NULL, 10 FROM t
  UNION ALL SELECT 'not_strictly_false', '@not_strictly_false', false,
    jsonb_build_array(t.bool), t.bool, NULL, 10 FROM t
  UNION ALL SELECT 'equals', '_==_', false,
    jsonb_build_array(t.pa, t.pa), t.bool, NULL, 10 FROM t
  UNION ALL SELECT 'not_equals', '_!=_', false,
    jsonb_build_array(t.pa, t.pa), t.bool, NULL, 10 FROM t

  UNION ALL SELECT 'add_int64', '_+_', false,
    jsonb_build_array(t.int, t.int), t.int,
    'cel._f_add_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'add_uint64', '_+_', false,
    jsonb_build_array(t.uint, t.uint), t.uint,
    'cel._f_add_uint64(jsonb[])', 20 FROM t
  UNION ALL SELECT 'add_double', '_+_', false,
    jsonb_build_array(t.dbl, t.dbl), t.dbl,
    'cel._f_add_double(jsonb[])', 30 FROM t
  UNION ALL SELECT 'add_string', '_+_', false,
    jsonb_build_array(t.str, t.str), t.str,
    'cel._f_add_string(jsonb[])', 40 FROM t
  UNION ALL SELECT 'add_bytes', '_+_', false,
    jsonb_build_array(t.byt, t.byt), t.byt,
    'cel._f_add_bytes(jsonb[])', 50 FROM t
  UNION ALL SELECT 'add_list', '_+_', false,
    jsonb_build_array(t.lista, t.lista), t.lista,
    'cel._f_add_list(jsonb[])', 60 FROM t

  UNION ALL SELECT 'subtract_int64', '_-_', false,
    jsonb_build_array(t.int, t.int), t.int,
    'cel._f_subtract_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'subtract_uint64', '_-_', false,
    jsonb_build_array(t.uint, t.uint), t.uint,
    'cel._f_subtract_uint64(jsonb[])', 20 FROM t
  UNION ALL SELECT 'subtract_double', '_-_', false,
    jsonb_build_array(t.dbl, t.dbl), t.dbl,
    'cel._f_subtract_double(jsonb[])', 30 FROM t

  UNION ALL SELECT 'multiply_int64', '_*_', false,
    jsonb_build_array(t.int, t.int), t.int,
    'cel._f_multiply_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'multiply_uint64', '_*_', false,
    jsonb_build_array(t.uint, t.uint), t.uint,
    'cel._f_multiply_uint64(jsonb[])', 20 FROM t
  UNION ALL SELECT 'multiply_double', '_*_', false,
    jsonb_build_array(t.dbl, t.dbl), t.dbl,
    'cel._f_multiply_double(jsonb[])', 30 FROM t

  UNION ALL SELECT 'divide_int64', '_/_', false,
    jsonb_build_array(t.int, t.int), t.int,
    'cel._f_divide_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'divide_uint64', '_/_', false,
    jsonb_build_array(t.uint, t.uint), t.uint,
    'cel._f_divide_uint64(jsonb[])', 20 FROM t
  UNION ALL SELECT 'divide_double', '_/_', false,
    jsonb_build_array(t.dbl, t.dbl), t.dbl,
    'cel._f_divide_double(jsonb[])', 30 FROM t

  UNION ALL SELECT 'modulo_int64', '_%_', false,
    jsonb_build_array(t.int, t.int), t.int,
    'cel._f_modulo_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'modulo_uint64', '_%_', false,
    jsonb_build_array(t.uint, t.uint), t.uint,
    'cel._f_modulo_uint64(jsonb[])', 20 FROM t

  UNION ALL SELECT 'negate_int64', '-_', false,
    jsonb_build_array(t.int), t.int,
    'cel._f_negate_int64(jsonb[])', 10 FROM t
  UNION ALL SELECT 'negate_double', '-_', false,
    jsonb_build_array(t.dbl), t.dbl,
    'cel._f_negate_double(jsonb[])', 20 FROM t

  UNION ALL SELECT 'size_string', 'size', false,
    jsonb_build_array(t.str), t.int,
    'cel._f_size_string(jsonb[])', 10 FROM t
  UNION ALL SELECT 'size_bytes', 'size', false,
    jsonb_build_array(t.byt), t.int,
    'cel._f_size_bytes(jsonb[])', 20 FROM t
  UNION ALL SELECT 'size_list', 'size', false,
    jsonb_build_array(t.lista), t.int,
    'cel._f_size_list(jsonb[])', 30 FROM t
  UNION ALL SELECT 'size_map', 'size', false,
    jsonb_build_array(t.mapab), t.int,
    'cel._f_size_map(jsonb[])', 40 FROM t
  UNION ALL SELECT 'string_size', 'size', true,
    jsonb_build_array(t.str), t.int,
    'cel._f_size_string(jsonb[])', 10 FROM t
  UNION ALL SELECT 'bytes_size', 'size', true,
    jsonb_build_array(t.byt), t.int,
    'cel._f_size_bytes(jsonb[])', 20 FROM t
  UNION ALL SELECT 'list_size', 'size', true,
    jsonb_build_array(t.lista), t.int,
    'cel._f_size_list(jsonb[])', 30 FROM t
  UNION ALL SELECT 'map_size', 'size', true,
    jsonb_build_array(t.mapab), t.int,
    'cel._f_size_map(jsonb[])', 40 FROM t

  UNION ALL SELECT 'in_list', '@in', false,
    jsonb_build_array(t.pa, t.lista), t.bool,
    'cel._f_in_list(jsonb[])', 10 FROM t
  UNION ALL SELECT 'in_map', '@in', false,
    jsonb_build_array(t.pa, t.mapab), t.bool,
    'cel._f_in_map(jsonb[])', 20 FROM t

  -- Index rows carry NULL impls: indexing is core attribute
  -- machinery (runtime numeric coercion), found through this table
  -- by id like the other absorbed operations.
  UNION ALL SELECT 'index_list', '_[_]', false,
    jsonb_build_array(t.lista, t.int), t.pa, NULL, 10 FROM t
  UNION ALL SELECT 'index_map', '_[_]', false,
    jsonb_build_array(t.mapab, t.pa), t.pb, NULL, 20 FROM t

  UNION ALL SELECT 'type', 'type', false,
    jsonb_build_array(t.pa), t.typea,
    'cel._f_type(jsonb[])', 10 FROM t
  UNION ALL SELECT 'to_dyn', 'dyn', false,
    jsonb_build_array(t.pa), t.dyn,
    'cel._f_to_dyn(jsonb[])', 10 FROM t
) rows(id, fn, member, arg_types, result_type, impl, ordinal)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

-- Relation overloads: 4 operators x 12 type pairs sharing four
-- comparator impls (timestamp/duration pairs arrive with 070).
INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
SELECT
  op.prefix || CASE WHEN pair.suffix = '' THEN pair.t1
                    ELSE pair.suffix END,
  op.fn, false,
  jsonb_build_array(
    jsonb_build_object('kind', pair.t1),
    jsonb_build_object('kind', pair.t2)),
  '{"kind":"bool"}'::jsonb,
  op.impl::regprocedure,
  pair.ord
FROM (VALUES
  ('less_', '_<_', 'cel._f_lt(jsonb[])'),
  ('less_equals_', '_<=_', 'cel._f_le(jsonb[])'),
  ('greater_', '_>_', 'cel._f_gt(jsonb[])'),
  ('greater_equals_', '_>=_', 'cel._f_ge(jsonb[])')
) op(prefix, fn, impl)
CROSS JOIN (VALUES
  ('bool',          'bool',   'bool',   10),
  ('int64',         'int',    'int',    20),
  ('int64_double',  'int',    'double', 30),
  ('int64_uint64',  'int',    'uint',   40),
  ('uint64',        'uint',   'uint',   50),
  ('uint64_double', 'uint',   'double', 60),
  ('uint64_int64',  'uint',   'int',    70),
  ('double',        'double', 'double', 80),
  ('double_int64',  'double', 'int',    90),
  ('double_uint64', 'double', 'uint',   100),
  ('string',        'string', 'string', 110),
  ('bytes',         'bytes',  'bytes',  120)
) pair(suffix, t1, t2, ord)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  arg_types = excluded.arg_types,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

-- Standard type identifiers: every visible cel.type row implies an
-- ident of type type(T) under the type's name.
INSERT INTO cel.type (name, kind) VALUES
  ('bool',      '{"kind":"bool"}'),
  ('int',       '{"kind":"int"}'),
  ('uint',      '{"kind":"uint"}'),
  ('double',    '{"kind":"double"}'),
  ('string',    '{"kind":"string"}'),
  ('bytes',     '{"kind":"bytes"}'),
  ('list',      '{"kind":"list","params":[{"kind":"dyn"}]}'),
  ('map',       '{"kind":"map","params":[{"kind":"dyn"},{"kind":"dyn"}]}'),
  ('null_type', '{"kind":"null"}'),
  ('type',      '{"kind":"type"}')
ON CONFLICT (name) DO NOTHING;

-- Everything above is visible in the standard env.
INSERT INTO cel.env_item (env, kind, ref)
SELECT 'standard', 'overload', id FROM cel.overload
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'standard', 'type', name FROM cel.type
ON CONFLICT DO NOTHING;

COMMIT;

BEGIN;

-- Part 2: type conversions and string functions. Conversion
-- semantics are cel-go's exactly (common/types + overflow.go,
-- measured): double-to-int excludes both 2^63 boundaries, string
-- parsing follows Go strconv, string(double) is the %g formatter.

CREATE OR REPLACE FUNCTION cel._f_conv_identity(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT args[1];
$$;

CREATE OR REPLACE FUNCTION cel._f_int64_to_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_uint((args[1] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_uint64_to_int64(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._chk_int((args[1] ->> 'v')::numeric);
$$;

-- doubleToInt64Checked (overflow.go:302): NaN, infinities, and both
-- 2^63 boundaries are overflow; conversion truncates toward zero.
CREATE OR REPLACE FUNCTION cel._f_double_to_int64(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  f float8 := cel._dbl(args[1]);
BEGIN
  IF f = 'NaN'::float8 OR f = 'Infinity'::float8
     OR f = '-Infinity'::float8
     OR f <= (-9223372036854775808)::float8
     OR f >= 9223372036854775807::float8
  THEN
    RETURN cel._err('integer overflow');
  END IF;
  RETURN cel._int_val(trunc(cel._f2n(f), 0));
END;
$$;

-- doubleToUint64Checked (overflow.go:312).
CREATE OR REPLACE FUNCTION cel._f_double_to_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  f float8 := cel._dbl(args[1]);
BEGIN
  IF f = 'NaN'::float8 OR f = 'Infinity'::float8
     OR f = '-Infinity'::float8
     OR f < 0
     OR f >= 18446744073709551615::float8
  THEN
    RETURN cel._err('unsigned integer overflow');
  END IF;
  RETURN jsonb_build_object('@t', 'uint', 'v',
    to_jsonb(trunc(cel._f2n(f), 0)));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_int64_to_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dbl_val((args[1] ->> 'v')::numeric::float8);
$$;

CREATE OR REPLACE FUNCTION cel._f_uint64_to_double(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dbl_val((args[1] ->> 'v')::numeric::float8);
$$;

CREATE OR REPLACE FUNCTION cel._f_string_to_int64(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s text := args[1] ->> 'v';
BEGIN
  IF s !~ '^[-+]?[0-9]+$' THEN
    RETURN cel._err(format(
      'type conversion error from string to int: %s',
      quote_literal(s)));
  END IF;
  RETURN cel._chk_int(s::numeric);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_string_to_uint64(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s text := args[1] ->> 'v';
BEGIN
  -- Go's ParseUint permits no sign.
  IF s !~ '^[0-9]+$' THEN
    RETURN cel._err(format(
      'type conversion error from string to uint: %s',
      quote_literal(s)));
  END IF;
  RETURN cel._chk_uint(s::numeric);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_string_to_double(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s text := args[1] ->> 'v';
  l text := lower(s);
  n numeric;
BEGIN
  -- Go ParseFloat accepts inf/infinity/nan, case-insensitive,
  -- optionally signed.
  IF l IN ('inf', '+inf', 'infinity', '+infinity') THEN
    RETURN jsonb_build_object('@t', 'double', 'v', 'Infinity');
  ELSIF l IN ('-inf', '-infinity') THEN
    RETURN jsonb_build_object('@t', 'double', 'v', '-Infinity');
  ELSIF l = 'nan' THEN
    RETURN jsonb_build_object('@t', 'double', 'v', 'NaN');
  END IF;
  IF s !~ '^[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$' THEN
    RETURN cel._err(format(
      'type conversion error from string to double: %s',
      quote_literal(s)));
  END IF;
  n := s::numeric;
  -- ParseFloat overflow is an error for conversions (unlike literal
  -- underflow, which rounds to signed zero silently).
  IF abs(n) > 1.7976931348623157e308::numeric THEN
    RETURN cel._err(format(
      'type conversion error from string to double: %s',
      quote_literal(s)));
  END IF;
  IF n <> 0 AND abs(n) <= 2.4703282292062327e-324::numeric THEN
    RETURN cel._dbl_val(
      (CASE WHEN n < 0 THEN '-0' ELSE '0' END)::float8);
  END IF;
  RETURN cel._dbl_val(n::float8);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_string_to_bool(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s text := args[1] ->> 'v';
BEGIN
  -- Go strconv.ParseBool's exact accepted set.
  IF s IN ('1', 't', 'T', 'TRUE', 'true', 'True') THEN
    RETURN cel._bool_val(true);
  ELSIF s IN ('0', 'f', 'F', 'FALSE', 'false', 'False') THEN
    RETURN cel._bool_val(false);
  END IF;
  RETURN cel._err(format(
    'type conversion error from string to bool: %s',
    quote_literal(s)));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_int64_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v', args[1] ->> 'v');
$$;

CREATE OR REPLACE FUNCTION cel._f_uint64_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v', args[1] ->> 'v');
$$;

CREATE OR REPLACE FUNCTION cel._f_double_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v',
    CASE args[1] ->> 'v'
      WHEN 'Infinity'  THEN '+Inf'
      WHEN '-Infinity' THEN '-Inf'
      WHEN 'NaN'       THEN 'NaN'
      ELSE cel._double_text(cel._dbl(args[1]))
    END);
$$;

CREATE OR REPLACE FUNCTION cel._f_bool_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v',
    CASE WHEN (args[1] ->> 'v')::boolean THEN 'true' ELSE 'false' END);
$$;

-- UTF-8 validation for bytes->string, byte-DFA style, without an
-- exception block (convert_from would raise). NUL is additionally
-- unrepresentable in Postgres text.
CREATE OR REPLACE FUNCTION cel._utf8_valid(b bytea)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  i int := 0;
  n int := octet_length(b);
  c int;
  need int;
  j int;
  cp int;
  mins int[] := ARRAY[0, 128, 2048, 65536];
BEGIN
  WHILE i < n LOOP
    c := get_byte(b, i);
    IF c = 0 THEN
      RETURN false;  -- representable in UTF-8, not in Postgres text
    ELSIF c < 128 THEN
      need := 0;
      cp := c;
    ELSIF c BETWEEN 194 AND 223 THEN
      need := 1;
      cp := c - 192;
    ELSIF c BETWEEN 224 AND 239 THEN
      need := 2;
      cp := c - 224;
    ELSIF c BETWEEN 240 AND 244 THEN
      need := 3;
      cp := c - 240;
    ELSE
      RETURN false;
    END IF;
    FOR j IN 1 .. need LOOP
      IF i + j >= n OR get_byte(b, i + j) NOT BETWEEN 128 AND 191 THEN
        RETURN false;
      END IF;
      cp := cp * 64 + (get_byte(b, i + j) - 128);
    END LOOP;
    IF need > 0 AND cp < mins[need + 1] THEN
      RETURN false;  -- overlong encoding
    END IF;
    IF cp > 1114111 OR (cp BETWEEN 55296 AND 57343) THEN
      RETURN false;
    END IF;
    i := i + need + 1;
  END LOOP;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_bytes_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  b bytea := decode(args[1] ->> 'v', 'base64');
BEGIN
  IF NOT cel._utf8_valid(b) THEN
    RETURN cel._err(
      'invalid UTF-8 in bytes, cannot convert to string');
  END IF;
  RETURN jsonb_build_object('@t', 'string', 'v',
    convert_from(b, 'UTF8'));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_string_to_bytes(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'bytes', 'v',
    replace(encode(convert_to(args[1] ->> 'v', 'UTF8'), 'base64'),
      E'\n', ''));
$$;

-- String tests. matches() is Postgres ~ (all corpus patterns
-- measured to agree with RE2).

CREATE OR REPLACE FUNCTION cel._f_contains(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    position((args[2] ->> 'v') IN (args[1] ->> 'v')) > 0
    OR args[2] ->> 'v' = '');
$$;

CREATE OR REPLACE FUNCTION cel._f_starts_with(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    left(args[1] ->> 'v', length(args[2] ->> 'v')) = args[2] ->> 'v');
$$;

CREATE OR REPLACE FUNCTION cel._f_ends_with(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    right(args[1] ->> 'v', length(args[2] ->> 'v')) = args[2] ->> 'v');
$$;

CREATE OR REPLACE FUNCTION cel._f_matches(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val((args[1] ->> 'v') ~ (args[2] ->> 'v'));
$$;

-- Registration.
WITH t AS (
  SELECT
    '{"kind":"bool"}'::jsonb   AS bool,
    '{"kind":"int"}'::jsonb    AS int,
    '{"kind":"uint"}'::jsonb   AS uint,
    '{"kind":"double"}'::jsonb AS dbl,
    '{"kind":"string"}'::jsonb AS str,
    '{"kind":"bytes"}'::jsonb  AS byt
)
INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
SELECT * FROM (
  SELECT 'int64_to_int64', 'int', false,
    jsonb_build_array(t.int), t.int,
    'cel._f_conv_identity(jsonb[])'::regprocedure, 10 FROM t
  UNION ALL SELECT 'uint64_to_int64', 'int', false,
    jsonb_build_array(t.uint), t.int,
    'cel._f_uint64_to_int64(jsonb[])', 20 FROM t
  UNION ALL SELECT 'double_to_int64', 'int', false,
    jsonb_build_array(t.dbl), t.int,
    'cel._f_double_to_int64(jsonb[])', 30 FROM t
  UNION ALL SELECT 'string_to_int64', 'int', false,
    jsonb_build_array(t.str), t.int,
    'cel._f_string_to_int64(jsonb[])', 40 FROM t

  UNION ALL SELECT 'uint64_to_uint64', 'uint', false,
    jsonb_build_array(t.uint), t.uint,
    'cel._f_conv_identity(jsonb[])', 10 FROM t
  UNION ALL SELECT 'int64_to_uint64', 'uint', false,
    jsonb_build_array(t.int), t.uint,
    'cel._f_int64_to_uint64(jsonb[])', 20 FROM t
  UNION ALL SELECT 'double_to_uint64', 'uint', false,
    jsonb_build_array(t.dbl), t.uint,
    'cel._f_double_to_uint64(jsonb[])', 30 FROM t
  UNION ALL SELECT 'string_to_uint64', 'uint', false,
    jsonb_build_array(t.str), t.uint,
    'cel._f_string_to_uint64(jsonb[])', 40 FROM t

  UNION ALL SELECT 'double_to_double', 'double', false,
    jsonb_build_array(t.dbl), t.dbl,
    'cel._f_conv_identity(jsonb[])', 10 FROM t
  UNION ALL SELECT 'int64_to_double', 'double', false,
    jsonb_build_array(t.int), t.dbl,
    'cel._f_int64_to_double(jsonb[])', 20 FROM t
  UNION ALL SELECT 'uint64_to_double', 'double', false,
    jsonb_build_array(t.uint), t.dbl,
    'cel._f_uint64_to_double(jsonb[])', 30 FROM t
  UNION ALL SELECT 'string_to_double', 'double', false,
    jsonb_build_array(t.str), t.dbl,
    'cel._f_string_to_double(jsonb[])', 40 FROM t

  UNION ALL SELECT 'string_to_string', 'string', false,
    jsonb_build_array(t.str), t.str,
    'cel._f_conv_identity(jsonb[])', 10 FROM t
  UNION ALL SELECT 'int64_to_string', 'string', false,
    jsonb_build_array(t.int), t.str,
    'cel._f_int64_to_string(jsonb[])', 20 FROM t
  UNION ALL SELECT 'uint64_to_string', 'string', false,
    jsonb_build_array(t.uint), t.str,
    'cel._f_uint64_to_string(jsonb[])', 30 FROM t
  UNION ALL SELECT 'double_to_string', 'string', false,
    jsonb_build_array(t.dbl), t.str,
    'cel._f_double_to_string(jsonb[])', 40 FROM t
  UNION ALL SELECT 'bool_to_string', 'string', false,
    jsonb_build_array(t.bool), t.str,
    'cel._f_bool_to_string(jsonb[])', 50 FROM t
  UNION ALL SELECT 'bytes_to_string', 'string', false,
    jsonb_build_array(t.byt), t.str,
    'cel._f_bytes_to_string(jsonb[])', 60 FROM t

  UNION ALL SELECT 'bool_to_bool', 'bool', false,
    jsonb_build_array(t.bool), t.bool,
    'cel._f_conv_identity(jsonb[])', 10 FROM t
  UNION ALL SELECT 'string_to_bool', 'bool', false,
    jsonb_build_array(t.str), t.bool,
    'cel._f_string_to_bool(jsonb[])', 20 FROM t

  UNION ALL SELECT 'bytes_to_bytes', 'bytes', false,
    jsonb_build_array(t.byt), t.byt,
    'cel._f_conv_identity(jsonb[])', 10 FROM t
  UNION ALL SELECT 'string_to_bytes', 'bytes', false,
    jsonb_build_array(t.str), t.byt,
    'cel._f_string_to_bytes(jsonb[])', 20 FROM t

  UNION ALL SELECT 'contains_string', 'contains', true,
    jsonb_build_array(t.str, t.str), t.bool,
    'cel._f_contains(jsonb[])', 10 FROM t
  UNION ALL SELECT 'starts_with_string', 'startsWith', true,
    jsonb_build_array(t.str, t.str), t.bool,
    'cel._f_starts_with(jsonb[])', 10 FROM t
  UNION ALL SELECT 'ends_with_string', 'endsWith', true,
    jsonb_build_array(t.str, t.str), t.bool,
    'cel._f_ends_with(jsonb[])', 10 FROM t
  UNION ALL SELECT 'matches_string', 'matches', true,
    jsonb_build_array(t.str, t.str), t.bool,
    'cel._f_matches(jsonb[])', 10 FROM t
  UNION ALL SELECT 'matches', 'matches', false,
    jsonb_build_array(t.str, t.str), t.bool,
    'cel._f_matches(jsonb[])', 10 FROM t
) rows(id, fn, member, arg_types, result_type, impl, ordinal)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'standard', 'overload', id FROM cel.overload
ON CONFLICT DO NOTHING;

COMMIT;

-- ---- sql/070_wkt.sql ----

-- Well-known types: timestamps, durations, the wrapper types,
-- Struct/Value/ListValue, Any and NullValue. Everything registers
-- through the same four tables the standard library uses; nothing
-- here is a core patch.
--
-- Timestamp values are {"s": epoch seconds, "n": nanos 0..1e9-1,
-- "tz": fixed offset minutes}; durations are total nanoseconds.
-- Semantics are cel-go v0.32.0's (common/types/timestamp.go,
-- duration.go, overflow.go), confirmed by conformance runs.

BEGIN;

-- Range-checked constructors ------------------------------------------

-- Seconds range is year 0001..9999 (timestamp.go:54-56); outside it
-- construction and arithmetic yield 'timestamp overflow'
-- (overflow.go:239).
CREATE OR REPLACE FUNCTION cel._ts_val(
  s numeric, n numeric, tzm int, id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN s < -62135596800 OR s > 253402300799
      THEN cel._err('timestamp overflow', id)
    ELSE jsonb_build_object('@t', 'timestamp', 'v',
      jsonb_build_object('s', to_jsonb(s), 'n', to_jsonb(n),
        'tz', to_jsonb(tzm)))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._dur_val(ns numeric, id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN ns < -9223372036854775808::numeric
      OR ns > 9223372036854775807::numeric
      THEN cel._err('integer overflow', id)
    ELSE jsonb_build_object('@t', 'duration', 'v', to_jsonb(ns))
  END;
$$;

CREATE OR REPLACE FUNCTION cel._ts_ns(v jsonb)
RETURNS numeric
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT (v -> 'v' ->> 's')::numeric * 1000000000
       + (v -> 'v' ->> 'n')::numeric;
$$;

-- Builds a timestamp from total nanoseconds, flooring so nanos stay
-- in [0, 1e9). div() (truncating integer division) then a manual
-- floor correction: numeric '/' selects a result scale that can drop
-- fractional digits on 20-digit quotients, so it cannot be trusted
-- here.
CREATE OR REPLACE FUNCTION cel._ts_of_ns(
  total numeric, tzm int, id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s numeric := div(total, 1000000000);
  n numeric;
BEGIN
  n := total - s * 1000000000;
  IF n < 0 THEN
    s := s - 1;
    n := n + 1000000000;
  END IF;
  RETURN cel._ts_val(s, n, tzm, id);
END;
$$;

-- Conversions ----------------------------------------------------------

-- Strict RFC 3339 (timestamp.go isStrictRFC3339 + Go time.Parse):
-- fixed-width date-time, 'T'/'t' separator, optional fraction,
-- 'Z'/'z' or +-HH:MM offset. Go's parser rejects leap seconds and
-- impossible dates.
CREATE OR REPLACE FUNCTION cel._f_string_to_timestamp(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  str text := args[1] ->> 'v';
  m   text[];
  y int; mo int; dd int; hh int; mi int; ss int;
  n numeric := 0;
  tzm int := 0;
  days numeric;
BEGIN
  m := regexp_match(str,
    '^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})' ||
    '(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$');
  IF m IS NULL THEN
    RETURN cel._err(
      format('invalid RFC 3339 timestamp %s', quote_literal(str)));
  END IF;
  y := m[1]::int; mo := m[2]::int; dd := m[3]::int;
  hh := m[4]::int; mi := m[5]::int; ss := m[6]::int;
  IF y < 1 OR mo < 1 OR mo > 12 OR hh > 23 OR mi > 59 OR ss > 59
     OR dd < 1
     OR dd > extract(day FROM
          (make_date(y, mo, 1) + interval '1 month - 1 day'))
  THEN
    RETURN cel._err(
      format('invalid RFC 3339 timestamp %s', quote_literal(str)));
  END IF;
  IF m[7] IS NOT NULL THEN
    n := rpad(substr(substr(m[7], 2), 1, 9), 9, '0')::numeric;
  END IF;
  IF lower(m[8]) <> 'z' THEN
    hh := NULL;  -- reuse below is confusing; parse offset afresh
    tzm := substr(m[8], 2, 2)::int * 60 + substr(m[8], 5, 2)::int;
    IF left(m[8], 1) = '-' THEN
      tzm := -tzm;
    END IF;
    IF abs(tzm) > 23 * 60 + 59 THEN
      RETURN cel._err(
        format('invalid RFC 3339 timestamp %s', quote_literal(str)));
    END IF;
  END IF;
  days := (make_date(y, mo, dd) - date '1970-01-01')::numeric;
  RETURN cel._ts_val(
    days * 86400 + m[4]::int * 3600 + mi * 60 + ss - tzm * 60,
    n, tzm);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_int_to_timestamp(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._ts_val((args[1] ->> 'v')::numeric, 0, 0);
$$;

CREATE OR REPLACE FUNCTION cel._f_timestamp_to_int(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val((args[1] -> 'v' ->> 's')::numeric);
$$;

-- RFC3339Nano in the value's own offset: fraction with trailing
-- zeros trimmed, 'Z' for a zero offset (timestamp.go:190).
CREATE OR REPLACE FUNCTION cel._f_timestamp_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s   numeric := (args[1] -> 'v' ->> 's')::numeric;
  n   int := (args[1] -> 'v' ->> 'n')::numeric;
  tzm int := coalesce((args[1] -> 'v' ->> 'tz')::int, 0);
  wall numeric := s + tzm * 60;
  days int := floor(wall / 86400);
  rem  int;
  frac text := '';
  off  text;
BEGIN
  rem := wall - days::numeric * 86400;
  IF n > 0 THEN
    frac := '.' || rtrim(lpad(n::text, 9, '0'), '0');
  END IF;
  IF tzm = 0 THEN
    off := 'Z';
  ELSE
    off := CASE WHEN tzm < 0 THEN '-' ELSE '+' END
        || lpad((abs(tzm) / 60)::text, 2, '0') || ':'
        || lpad((abs(tzm) % 60)::text, 2, '0');
  END IF;
  RETURN jsonb_build_object('@t', 'string', 'v',
    to_char(date '1970-01-01' + days, 'YYYY-MM-DD') || 'T'
    || lpad((rem / 3600)::text, 2, '0') || ':'
    || lpad(((rem / 60) % 60)::text, 2, '0') || ':'
    || lpad((rem % 60)::text, 2, '0') || frac || off);
END;
$$;

-- Go time.ParseDuration: signed sequence of decimal numbers with
-- units ns/us/µs/μs/ms/s/m/h; bare "0" allowed.
CREATE OR REPLACE FUNCTION cel._f_string_to_duration(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  str   text := args[1] ->> 'v';
  s     text := str;
  neg   boolean := false;
  total numeric := 0;
  m     text[];
BEGIN
  IF s ~ '^[+-]' THEN
    neg := left(s, 1) = '-';
    s := substr(s, 2);
  END IF;
  IF s = '0' THEN
    RETURN cel._dur_val(0);
  END IF;
  IF s = '' THEN
    RETURN cel._err(
      format('invalid duration %s', quote_literal(str)));
  END IF;
  WHILE s <> '' LOOP
    m := regexp_match(s,
      '^(\d+(?:\.\d*)?|\.\d+)(ns|us|µs|μs|ms|s|m|h)(.*)$');
    IF m IS NULL THEN
      RETURN cel._err(
        format('invalid duration %s', quote_literal(str)));
    END IF;
    total := total + trunc(m[1]::numeric * CASE m[2]
      WHEN 'ns' THEN 1
      WHEN 'ms' THEN 1000000
      WHEN 's'  THEN 1000000000
      WHEN 'm'  THEN 60000000000
      WHEN 'h'  THEN 3600000000000
      ELSE 1000  -- us / µs / μs
    END::numeric);
    s := m[3];
  END LOOP;
  RETURN cel._dur_val(CASE WHEN neg THEN -total ELSE total END);
END;
$$;

-- Renders scientific notation as plain decimal, for Go's
-- FormatFloat(f, 'f', -1, 64): same shortest digits as %g, fixed
-- rendering.
CREATE OR REPLACE FUNCTION cel._sci_to_plain(t text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  m      text[];
  digits text;
  p      int;
BEGIN
  m := regexp_match(t, '^(-?)(\d+)(?:\.(\d+))?e([+-]?\d+)$');
  IF m IS NULL THEN
    RETURN t;
  END IF;
  digits := m[2] || coalesce(m[3], '');
  p := length(m[2]) + m[4]::int;
  IF p <= 0 THEN
    RETURN m[1] || '0.' || repeat('0', -p) || digits;
  ELSIF p >= length(digits) THEN
    RETURN m[1] || digits || repeat('0', p - length(digits));
  END IF;
  RETURN m[1] || substr(digits, 1, p) || '.' || substr(digits, p + 1);
END;
$$;

-- duration.go:125: FormatFloat(d.Seconds(), 'f', -1, 64) + "s",
-- where Seconds() = float64(sec) + float64(nsec)/1e9.
CREATE OR REPLACE FUNCTION cel._f_duration_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  ns  numeric := (args[1] ->> 'v')::numeric;
  sec float8;
BEGIN
  sec := trunc(ns / 1000000000)::float8
       + (ns - trunc(ns / 1000000000) * 1000000000)::float8 / 1e9;
  RETURN jsonb_build_object('@t', 'string', 'v',
    cel._sci_to_plain(cel._double_text(sec)) || 's');
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_duration_to_int(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val((args[1] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_identity(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT args[1];
$$;

-- Arithmetic (overflow.go:236-260) ------------------------------------

CREATE OR REPLACE FUNCTION cel._f_add_ts_dur(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._ts_of_ns(
    cel._ts_ns(args[1]) + (args[2] ->> 'v')::numeric,
    coalesce((args[1] -> 'v' ->> 'tz')::int, 0), NULL);
$$;

CREATE OR REPLACE FUNCTION cel._f_add_dur_ts(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._ts_of_ns(
    cel._ts_ns(args[2]) + (args[1] ->> 'v')::numeric,
    coalesce((args[2] -> 'v' ->> 'tz')::int, 0), NULL);
$$;

CREATE OR REPLACE FUNCTION cel._f_add_dur_dur(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dur_val(
    (args[1] ->> 'v')::numeric + (args[2] ->> 'v')::numeric);
$$;

CREATE OR REPLACE FUNCTION cel._f_sub_ts_ts(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dur_val(cel._ts_ns(args[1]) - cel._ts_ns(args[2]));
$$;

CREATE OR REPLACE FUNCTION cel._f_sub_ts_dur(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._ts_of_ns(
    cel._ts_ns(args[1]) - (args[2] ->> 'v')::numeric,
    coalesce((args[1] -> 'v' ->> 'tz')::int, 0), NULL);
$$;

CREATE OR REPLACE FUNCTION cel._f_sub_dur_dur(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dur_val(
    (args[1] ->> 'v')::numeric - (args[2] ->> 'v')::numeric);
$$;

-- Getters --------------------------------------------------------------

-- Wall-clock timestamp for a value under an optional tz override
-- (timestamp.go timeZone): NULL -> the value's own fixed offset; a
-- string with ':' -> +-H:MM fixed offset; otherwise an IANA name
-- resolved by Postgres's tzdata.
CREATE OR REPLACE FUNCTION cel._ts_wall(
  v jsonb, tz text, OUT wall timestamp, OUT err jsonb
)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s    numeric := (v -> 'v' ->> 's')::numeric;
  offm int;
  hr   int;
  mi   int;
BEGIN
  IF tz IS NULL THEN
    offm := coalesce((v -> 'v' ->> 'tz')::int, 0);
  ELSIF position(':' IN tz) = 0 THEN
    BEGIN
      wall := to_timestamp(s::float8) AT TIME ZONE tz;
      RETURN;
    EXCEPTION WHEN OTHERS THEN
      err := cel._err(format('unknown time zone %s',
        quote_literal(tz)));
      RETURN;
    END;
  ELSE
    BEGIN
      hr := split_part(tz, ':', 1)::int;
      mi := split_part(tz, ':', 2)::int;
    EXCEPTION WHEN OTHERS THEN
      err := cel._err(format('invalid timezone %s',
        quote_literal(tz)));
      RETURN;
    END;
    IF hr < -23 OR hr > 23 OR mi < 0 OR mi > 59 THEN
      err := cel._err(format(
        'timezone offset out of range: %s', tz));
      RETURN;
    END IF;
    offm := CASE WHEN left(tz, 1) = '-' THEN hr * 60 - mi
                 ELSE hr * 60 + mi END;
  END IF;
  wall := timestamp '1970-01-01'
        + make_interval(secs => (s + offm * 60)::float8);
END;
$$;

-- One impl per getter; a two-element args array carries the tz
-- override, so each impl serves both the 0- and 1-arg overloads.
CREATE OR REPLACE FUNCTION cel._ts_get(args jsonb[], part text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  w record;
BEGIN
  IF part = 'milliseconds' THEN
    RETURN cel._int_val(
      trunc((args[1] -> 'v' ->> 'n')::numeric / 1000000));
  END IF;
  SELECT * INTO w FROM cel._ts_wall(args[1],
    CASE WHEN cardinality(args) > 1 THEN args[2] ->> 'v' END);
  IF w.err IS NOT NULL THEN
    RETURN w.err;
  END IF;
  RETURN cel._int_val(CASE part
    WHEN 'year'         THEN extract(year FROM w.wall)
    WHEN 'month'        THEN extract(month FROM w.wall) - 1
    WHEN 'day_of_year'  THEN extract(doy FROM w.wall) - 1
    WHEN 'day_of_month' THEN extract(day FROM w.wall) - 1
    WHEN 'date'         THEN extract(day FROM w.wall)
    WHEN 'day_of_week'  THEN extract(dow FROM w.wall)
    WHEN 'hours'        THEN extract(hour FROM w.wall)
    WHEN 'minutes'      THEN extract(minute FROM w.wall)
    WHEN 'seconds'      THEN floor(extract(second FROM w.wall))
  END);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_ts_year(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'year') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_month(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'month') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_doy(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'day_of_year') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_dom0(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'day_of_month') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_dom1(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'date') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_dow(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'day_of_week') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_hours(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'hours') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_minutes(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'minutes') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_seconds(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'seconds') $$;
CREATE OR REPLACE FUNCTION cel._f_ts_ms(args jsonb[])
RETURNS jsonb LANGUAGE sql STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._ts_get(args, 'milliseconds') $$;

-- Duration getters are truncated totals, except getMilliseconds,
-- which is the sub-second component: the corpus and cel-java agree
-- against cel-go v0.32.0 here.
CREATE OR REPLACE FUNCTION cel._f_dur_hours(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(
    trunc((args[1] ->> 'v')::numeric / 3600000000000));
$$;
CREATE OR REPLACE FUNCTION cel._f_dur_minutes(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(
    trunc((args[1] ->> 'v')::numeric / 60000000000));
$$;
CREATE OR REPLACE FUNCTION cel._f_dur_seconds(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(
    trunc((args[1] ->> 'v')::numeric / 1000000000));
$$;
CREATE OR REPLACE FUNCTION cel._f_dur_ms(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(
    trunc((args[1] ->> 'v')::numeric / 1000000) % 1000);
$$;

COMMIT;

BEGIN;

-- Construction impls ---------------------------------------------------
-- Each receives the evaluated fields as a jsonb object of tagged
-- values (050_eval.sql struct branch). Wrappers unwrap to their
-- primitive; an unset field takes the proto3 default.

CREATE OR REPLACE FUNCTION cel._wkt_bool(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value',
    '{"@t": "bool", "v": false}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_int(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value', '{"@t": "int", "v": 0}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_uint(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value', '{"@t": "uint", "v": 0}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_double(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value',
    '{"@t": "double", "v": 0}'::jsonb);
$$;

-- FloatValue narrows to float32 (dynamic/float/literal_not_double).
CREATE OR REPLACE FUNCTION cel._wkt_float(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN fields ? 'value'
    THEN cel._dbl_val(
      ((fields -> 'value' ->> 'v')::float8::float4)::float8)
    ELSE '{"@t": "double", "v": 0}'::jsonb
  END;
$$;

CREATE OR REPLACE FUNCTION cel._wkt_string(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value',
    '{"@t": "string", "v": ""}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_bytes(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'value',
    '{"@t": "bytes", "v": ""}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_struct(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'fields',
    '{"@t": "map", "v": []}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_listvalue(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT coalesce(fields -> 'values',
    '{"@t": "list", "v": []}'::jsonb);
$$;

-- google.protobuf.Value: whichever field is set decides the JSON
-- kind; unset means null.
CREATE OR REPLACE FUNCTION cel._wkt_value(fields jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
BEGIN
  IF fields ? 'number_value' THEN
    RETURN jsonb_build_object('@t', 'double', 'v',
      fields -> 'number_value' -> 'v');
  ELSIF fields ? 'string_value' THEN
    RETURN fields -> 'string_value';
  ELSIF fields ? 'bool_value' THEN
    RETURN fields -> 'bool_value';
  ELSIF fields ? 'struct_value' THEN
    RETURN fields -> 'struct_value';
  ELSIF fields ? 'list_value' THEN
    RETURN fields -> 'list_value';
  END IF;
  RETURN '{"@t": "null", "v": null}'::jsonb;
END;
$$;

CREATE OR REPLACE FUNCTION cel._wkt_timestamp(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._ts_val(
    coalesce((fields -> 'seconds' ->> 'v')::numeric, 0),
    coalesce((fields -> 'nanos' ->> 'v')::numeric, 0), 0);
$$;

CREATE OR REPLACE FUNCTION cel._wkt_duration(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dur_val(
    coalesce((fields -> 'seconds' ->> 'v')::numeric, 0) * 1000000000
    + coalesce((fields -> 'nanos' ->> 'v')::numeric, 0));
$$;

-- Any needs a descriptor pool to pack; its row exists so the name
-- resolves.
CREATE OR REPLACE FUNCTION cel._wkt_any(fields jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._err(
    'cannot construct google.protobuf.Any without descriptors');
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.type (name, kind, construct) VALUES
  ('google.protobuf.Timestamp', '{"kind": "timestamp"}',
   'cel._wkt_timestamp(jsonb)'),
  ('google.protobuf.Duration', '{"kind": "duration"}',
   'cel._wkt_duration(jsonb)'),
  ('google.protobuf.BoolValue',
   '{"kind": "wrapper", "params": [{"kind": "bool"}]}',
   'cel._wkt_bool(jsonb)'),
  ('google.protobuf.Int32Value',
   '{"kind": "wrapper", "params": [{"kind": "int"}]}',
   'cel._wkt_int(jsonb)'),
  ('google.protobuf.Int64Value',
   '{"kind": "wrapper", "params": [{"kind": "int"}]}',
   'cel._wkt_int(jsonb)'),
  ('google.protobuf.UInt32Value',
   '{"kind": "wrapper", "params": [{"kind": "uint"}]}',
   'cel._wkt_uint(jsonb)'),
  ('google.protobuf.UInt64Value',
   '{"kind": "wrapper", "params": [{"kind": "uint"}]}',
   'cel._wkt_uint(jsonb)'),
  ('google.protobuf.FloatValue',
   '{"kind": "wrapper", "params": [{"kind": "double"}]}',
   'cel._wkt_float(jsonb)'),
  ('google.protobuf.DoubleValue',
   '{"kind": "wrapper", "params": [{"kind": "double"}]}',
   'cel._wkt_double(jsonb)'),
  ('google.protobuf.StringValue',
   '{"kind": "wrapper", "params": [{"kind": "string"}]}',
   'cel._wkt_string(jsonb)'),
  ('google.protobuf.BytesValue',
   '{"kind": "wrapper", "params": [{"kind": "bytes"}]}',
   'cel._wkt_bytes(jsonb)'),
  ('google.protobuf.Struct',
   '{"kind": "map", "params": [{"kind": "string"}, {"kind": "dyn"}]}',
   'cel._wkt_struct(jsonb)'),
  ('google.protobuf.Value', '{"kind": "dyn"}',
   'cel._wkt_value(jsonb)'),
  ('google.protobuf.ListValue',
   '{"kind": "list", "params": [{"kind": "dyn"}]}',
   'cel._wkt_listvalue(jsonb)'),
  ('google.protobuf.Any', '{"kind": "any"}', 'cel._wkt_any(jsonb)'),
  ('google.protobuf.NullValue',
   '{"kind": "int", "enum": {"NULL_VALUE": 0}}', NULL)
ON CONFLICT (name) DO UPDATE SET
  kind = excluded.kind,
  construct = excluded.construct;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  -- arithmetic (cel-go standard.go declaration order)
  ('add_duration_duration', '_+_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "duration"}', 'cel._f_add_dur_dur(jsonb[])', 70),
  ('add_duration_timestamp', '_+_', false,
   '[{"kind": "duration"}, {"kind": "timestamp"}]',
   '{"kind": "timestamp"}', 'cel._f_add_dur_ts(jsonb[])', 80),
  ('add_timestamp_duration', '_+_', false,
   '[{"kind": "timestamp"}, {"kind": "duration"}]',
   '{"kind": "timestamp"}', 'cel._f_add_ts_dur(jsonb[])', 90),
  ('subtract_duration_duration', '_-_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "duration"}', 'cel._f_sub_dur_dur(jsonb[])', 40),
  ('subtract_timestamp_duration', '_-_', false,
   '[{"kind": "timestamp"}, {"kind": "duration"}]',
   '{"kind": "timestamp"}', 'cel._f_sub_ts_dur(jsonb[])', 50),
  ('subtract_timestamp_timestamp', '_-_', false,
   '[{"kind": "timestamp"}, {"kind": "timestamp"}]',
   '{"kind": "duration"}', 'cel._f_sub_ts_ts(jsonb[])', 60),
  -- relations
  ('less_timestamp', '_<_', false,
   '[{"kind": "timestamp"}, {"kind": "timestamp"}]',
   '{"kind": "bool"}', 'cel._f_lt(jsonb[])', 130),
  ('less_duration', '_<_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "bool"}', 'cel._f_lt(jsonb[])', 140),
  ('less_equals_timestamp', '_<=_', false,
   '[{"kind": "timestamp"}, {"kind": "timestamp"}]',
   '{"kind": "bool"}', 'cel._f_le(jsonb[])', 130),
  ('less_equals_duration', '_<=_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "bool"}', 'cel._f_le(jsonb[])', 140),
  ('greater_timestamp', '_>_', false,
   '[{"kind": "timestamp"}, {"kind": "timestamp"}]',
   '{"kind": "bool"}', 'cel._f_gt(jsonb[])', 130),
  ('greater_duration', '_>_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "bool"}', 'cel._f_gt(jsonb[])', 140),
  ('greater_equals_timestamp', '_>=_', false,
   '[{"kind": "timestamp"}, {"kind": "timestamp"}]',
   '{"kind": "bool"}', 'cel._f_ge(jsonb[])', 130),
  ('greater_equals_duration', '_>=_', false,
   '[{"kind": "duration"}, {"kind": "duration"}]',
   '{"kind": "bool"}', 'cel._f_ge(jsonb[])', 140),
  -- conversions
  ('duration_to_int64', 'int', false,
   '[{"kind": "duration"}]', '{"kind": "int"}',
   'cel._f_duration_to_int(jsonb[])', 50),
  ('timestamp_to_int64', 'int', false,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_timestamp_to_int(jsonb[])', 60),
  ('duration_to_string', 'string', false,
   '[{"kind": "duration"}]', '{"kind": "string"}',
   'cel._f_duration_to_string(jsonb[])', 70),
  ('timestamp_to_string', 'string', false,
   '[{"kind": "timestamp"}]', '{"kind": "string"}',
   'cel._f_timestamp_to_string(jsonb[])', 80),
  ('timestamp_to_timestamp', 'timestamp', false,
   '[{"kind": "timestamp"}]', '{"kind": "timestamp"}',
   'cel._f_identity(jsonb[])', 10),
  ('int64_to_timestamp', 'timestamp', false,
   '[{"kind": "int"}]', '{"kind": "timestamp"}',
   'cel._f_int_to_timestamp(jsonb[])', 20),
  ('string_to_timestamp', 'timestamp', false,
   '[{"kind": "string"}]', '{"kind": "timestamp"}',
   'cel._f_string_to_timestamp(jsonb[])', 30),
  ('duration_to_duration', 'duration', false,
   '[{"kind": "duration"}]', '{"kind": "duration"}',
   'cel._f_identity(jsonb[])', 10),
  ('string_to_duration', 'duration', false,
   '[{"kind": "string"}]', '{"kind": "duration"}',
   'cel._f_string_to_duration(jsonb[])', 20),
  -- timestamp getters
  ('timestamp_to_year', 'getFullYear', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_year(jsonb[])', 10),
  ('timestamp_to_year_with_tz', 'getFullYear', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_year(jsonb[])', 20),
  ('timestamp_to_month', 'getMonth', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_month(jsonb[])', 10),
  ('timestamp_to_month_with_tz', 'getMonth', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_month(jsonb[])', 20),
  ('timestamp_to_day_of_year', 'getDayOfYear', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_doy(jsonb[])', 10),
  ('timestamp_to_day_of_year_with_tz', 'getDayOfYear', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_doy(jsonb[])', 20),
  ('timestamp_to_day_of_month', 'getDayOfMonth', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_dom0(jsonb[])', 10),
  ('timestamp_to_day_of_month_with_tz', 'getDayOfMonth', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_dom0(jsonb[])', 20),
  ('timestamp_to_day_of_month_1_based', 'getDate', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_dom1(jsonb[])', 10),
  ('timestamp_to_day_of_month_1_based_with_tz', 'getDate', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_dom1(jsonb[])', 20),
  ('timestamp_to_day_of_week', 'getDayOfWeek', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_dow(jsonb[])', 10),
  ('timestamp_to_day_of_week_with_tz', 'getDayOfWeek', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_dow(jsonb[])', 20),
  ('timestamp_to_hours', 'getHours', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_hours(jsonb[])', 10),
  ('timestamp_to_hours_with_tz', 'getHours', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_hours(jsonb[])', 20),
  ('timestamp_to_minutes', 'getMinutes', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_minutes(jsonb[])', 10),
  ('timestamp_to_minutes_with_tz', 'getMinutes', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_minutes(jsonb[])', 20),
  ('timestamp_to_seconds', 'getSeconds', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_seconds(jsonb[])', 10),
  ('timestamp_to_seconds_tz', 'getSeconds', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_seconds(jsonb[])', 20),
  ('timestamp_to_milliseconds', 'getMilliseconds', true,
   '[{"kind": "timestamp"}]', '{"kind": "int"}',
   'cel._f_ts_ms(jsonb[])', 10),
  ('timestamp_to_milliseconds_with_tz', 'getMilliseconds', true,
   '[{"kind": "timestamp"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_ts_ms(jsonb[])', 20),
  -- duration getters
  ('duration_to_hours', 'getHours', true,
   '[{"kind": "duration"}]', '{"kind": "int"}',
   'cel._f_dur_hours(jsonb[])', 30),
  ('duration_to_minutes', 'getMinutes', true,
   '[{"kind": "duration"}]', '{"kind": "int"}',
   'cel._f_dur_minutes(jsonb[])', 30),
  ('duration_to_seconds', 'getSeconds', true,
   '[{"kind": "duration"}]', '{"kind": "int"}',
   'cel._f_dur_seconds(jsonb[])', 30),
  ('duration_to_milliseconds', 'getMilliseconds', true,
   '[{"kind": "duration"}]', '{"kind": "int"}',
   'cel._f_dur_ms(jsonb[])', 30)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'standard', 'type', name FROM cel.type
WHERE name LIKE 'google.protobuf.%'
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'standard', 'overload', id FROM cel.overload
ON CONFLICT DO NOTHING;

COMMIT;

-- ---- sql/100_ext_comprehensions.sql ----

-- The two-variable comprehensions extension (cel-go
-- ext.TwoVarComprehensions, ext/comprehensions.go at the pinned
-- v0.32.0): all/exists/existsOne/exists_one, transformList,
-- transformMap and transformMapEntry over (index, value) or
-- (key, value) pairs, plus the cel.@mapInsert helper the map
-- transforms expand to. Registered under the
-- 'two_var_comprehensions' env; nothing ships in 'standard'.
--
-- Extension scripts live at the top of sql/ with a 1xx prefix
-- because initdb runs only the directory's top level; a
-- subdirectory would silently not install.

BEGIN;

-- Extracts and validates the two iteration variables
-- (ext/comprehensions.go extractIterVars).
CREATE OR REPLACE FUNCTION cel._mx2_vars(
  a0 jsonb, a1 jsonb, OUT v1 text, OUT v2 text, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  SELECT * INTO r FROM cel._mx_itervar(a0);
  IF r.err IS NOT NULL THEN
    err := r.err;
    RETURN;
  END IF;
  v1 := r.name;
  SELECT * INTO r FROM cel._mx_itervar(a1);
  IF r.err IS NOT NULL THEN
    err := r.err;
    RETURN;
  END IF;
  v2 := r.name;
  IF v1 = v2 THEN
    err := format('duplicate variable name: %s', v1);
  END IF;
END;
$$;

-- The quantifiers and transformList share their fold wiring with
-- the one-variable macros; only the second iteration variable is
-- new.
CREATE OR REPLACE FUNCTION cel._mx2_quant(
  kind text, target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx2_vars(args -> 0, args -> 1);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  SELECT * INTO f
  FROM cel._mx_fold(kind, target, v.v1, args -> 2, NULL, next_id);
  IF f.err IS NOT NULL THEN
    err := f.err;
    RETURN;
  END IF;
  expr := jsonb_set(f.expr, '{iter2}', to_jsonb(v.v2));
  next_id_out := f.next_id_out;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx2_all(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx2_quant('all', target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx2_exists(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx2_quant('exists', target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx2_exists_one(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx2_quant('exists_one', target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx2_transform_list(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  f record;
BEGIN
  SELECT * INTO v FROM cel._mx2_vars(args -> 0, args -> 1);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  IF jsonb_array_length(args) = 4 THEN
    SELECT * INTO f FROM cel._mx_fold(
      'map_filter', target, v.v1, args -> 2, args -> 3, next_id);
  ELSE
    SELECT * INTO f FROM cel._mx_fold(
      'map', target, v.v1, NULL, args -> 2, next_id);
  END IF;
  IF f.err IS NOT NULL THEN
    err := f.err;
    RETURN;
  END IF;
  expr := jsonb_set(f.expr, '{iter2}', to_jsonb(v.v2));
  next_id_out := f.next_id_out;
END;
$$;

-- transformMap / transformMapEntry: fold into a map through
-- cel.@mapInsert (ext/comprehensions.go:333-397). entry_mode picks
-- the two-argument @mapInsert(accu, transform) form.
CREATE OR REPLACE FUNCTION cel._mx2_transform_map(
  entry_mode boolean, target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v record;
  id bigint := next_id;
  cs jsonb := target -> 's';
  ce jsonb := target -> 'e';
  filter jsonb;
  transform jsonb;
  init jsonb;
  cond jsonb;
  step jsonb;
  accu jsonb;
  result jsonb;
  cargs jsonb;
BEGIN
  SELECT * INTO v FROM cel._mx2_vars(args -> 0, args -> 1);
  IF v.err IS NOT NULL THEN
    err := v.err;
    RETURN;
  END IF;
  IF jsonb_array_length(args) = 4 THEN
    filter := args -> 2;
    transform := args -> 3;
  ELSE
    transform := args -> 2;
  END IF;

  id := id + 1;
  init := jsonb_build_object('id', id, 'k', 'map',
    'entries', '[]'::jsonb, 's', cs, 'e', ce);
  id := id + 1;
  cond := jsonb_build_object('id', id, 'k', 'lit',
    'v', jsonb_build_object('@t', 'bool', 'v', true),
    's', cs, 'e', ce);
  id := id + 1;
  accu := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@result', 's', cs, 'e', ce);
  IF entry_mode THEN
    cargs := jsonb_build_array(accu, transform);
  ELSE
    id := id + 1;
    cargs := jsonb_build_array(accu,
      jsonb_build_object('id', id, 'k', 'ident', 'name', v.v1,
        's', cs, 'e', ce),
      transform);
  END IF;
  id := id + 1;
  step := jsonb_build_object('id', id, 'k', 'call',
    'fn', 'cel.@mapInsert', 'args', cargs, 's', cs, 'e', ce);
  IF filter IS NOT NULL THEN
    id := id + 1;
    accu := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@result', 's', cs, 'e', ce);
    id := id + 1;
    step := jsonb_build_object('id', id, 'k', 'call',
      'fn', '_?_:_', 'args', jsonb_build_array(filter, step, accu),
      's', cs, 'e', ce);
  END IF;
  id := id + 1;
  result := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@result', 's', cs, 'e', ce);

  id := id + 1;
  expr := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', target, 'iter', v.v1, 'iter2', v.v2,
    'accu', '@result',
    'init', init, 'cond', cond, 'step', step, 'result', result,
    's', cs, 'e', ce);
  next_id_out := id;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx2_transform_map_3(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT *
  FROM cel._mx2_transform_map(false, target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx2_transform_map_entry(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT *
  FROM cel._mx2_transform_map(true, target, args, next_id);
$$;

-- cel.@mapInsert impls: inserting an existing key is an error
-- (cel-go types.InsertMapKeyValue).

CREATE OR REPLACE FUNCTION cel._f_map_insert_kv(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
BEGIN
  IF cel._map_find(args[1], args[2]) IS NOT NULL THEN
    RETURN cel._err(format('insert failed: key %s already exists',
      args[2] ->> 'v'));
  END IF;
  RETURN jsonb_set(args[1], '{v}',
    (args[1] -> 'v') || jsonb_build_array(
      jsonb_build_object('k', args[2], 'v', args[3])));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_map_insert_map(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  acc jsonb := args[1];
  i   int;
BEGIN
  FOR i IN 0 .. jsonb_array_length(args[2] -> 'v') - 1 LOOP
    acc := cel._f_map_insert_kv(ARRAY[
      acc,
      args[2] -> 'v' -> i -> 'k',
      args[2] -> 'v' -> i -> 'v']);
    IF cel._is_error(acc) THEN
      RETURN acc;
    END IF;
  END LOOP;
  RETURN acc;
END;
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('all',               3, true,
   'cel._mx2_all(jsonb,jsonb,bigint)'),
  ('exists',            3, true,
   'cel._mx2_exists(jsonb,jsonb,bigint)'),
  ('existsOne',         3, true,
   'cel._mx2_exists_one(jsonb,jsonb,bigint)'),
  ('exists_one',        3, true,
   'cel._mx2_exists_one(jsonb,jsonb,bigint)'),
  ('transformList',     3, true,
   'cel._mx2_transform_list(jsonb,jsonb,bigint)'),
  ('transformList',     4, true,
   'cel._mx2_transform_list(jsonb,jsonb,bigint)'),
  ('transformMap',      3, true,
   'cel._mx2_transform_map_3(jsonb,jsonb,bigint)'),
  ('transformMap',      4, true,
   'cel._mx2_transform_map_3(jsonb,jsonb,bigint)'),
  ('transformMapEntry', 3, true,
   'cel._mx2_transform_map_entry(jsonb,jsonb,bigint)'),
  ('transformMapEntry', 4, true,
   'cel._mx2_transform_map_entry(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE
  SET expander = excluded.expander;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('@mapInsert_map_key_value', 'cel.@mapInsert', false,
   '[{"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]},
     {"kind": "param", "name": "K"},
     {"kind": "param", "name": "V"}]',
   '{"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]}',
   'cel._f_map_insert_kv(jsonb[])', 10),
  ('@mapInsert_map_map', 'cel.@mapInsert', false,
   '[{"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]},
     {"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]}]',
   '{"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]}',
   'cel._f_map_insert_map(jsonb[])', 20)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'two_var_comprehensions', 'macro',
  format('%s/%s/%s', name, arity, member::int)
FROM cel.macro
WHERE arity IN (3, 4) AND member
  AND name IN ('all', 'exists', 'existsOne', 'exists_one',
               'transformList', 'transformMap', 'transformMapEntry')
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('two_var_comprehensions', 'overload', '@mapInsert_map_key_value'),
  ('two_var_comprehensions', 'overload', '@mapInsert_map_map')
ON CONFLICT DO NOTHING;

COMMIT;

-- ---- sql/110_ext_optionals.sql ----

-- The optionals extension, part one: the optional_type opaque type
-- and the optional.of / optional.ofNonZeroValue / optional.none /
-- value / hasValue functions (cel-go cel/library.go optionals, pinned
-- v0.32.0). Part two, further down, adds the optional-syntax sugar
-- (x.?f, [?x], {?k: v}), or / orValue, and the optMap/optFlatMap
-- macros.
--
-- An optional value is the opaque
--   {"@t": "opaque", "type": "optional_type", "v":
--     {"p": <present?>, "v": <value when present>}}
-- (day-one invariant 3: extension types are registry rows over the
-- opaque kind, never new core kinds).

BEGIN;

CREATE OR REPLACE FUNCTION cel._opt_of(v jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'opaque', 'type', 'optional_type',
    'v', jsonb_build_object('p', true, 'v', v));
$$;

CREATE OR REPLACE FUNCTION cel._opt_none()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'opaque', 'type', 'optional_type',
    'v', jsonb_build_object('p', false));
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_of(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._opt_of(args[1]);
$$;

-- ofNonZeroValue: none when the argument is its type's zero value
-- (cel-go types/optional.go / library.go).
CREATE OR REPLACE FUNCTION cel._f_opt_of_nonzero(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v jsonb := args[1];
  zero boolean;
BEGIN
  zero := CASE v ->> '@t'
    WHEN 'int'    THEN (v ->> 'v')::numeric = 0
    WHEN 'uint'   THEN (v ->> 'v')::numeric = 0
    WHEN 'double' THEN (v ->> 'v') = '0'
                    OR (v ->> 'v')::float8 = 0
    WHEN 'bool'   THEN NOT (v ->> 'v')::boolean
    WHEN 'string' THEN v ->> 'v' = ''
    WHEN 'bytes'  THEN v ->> 'v' = ''
    WHEN 'list'   THEN jsonb_array_length(v -> 'v') = 0
    WHEN 'map'    THEN jsonb_array_length(v -> 'v') = 0
    WHEN 'null'   THEN true
    ELSE false
  END;
  RETURN CASE WHEN zero THEN cel._opt_none()
              ELSE cel._opt_of(v) END;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_none(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._opt_none();
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_value(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN (args[1] -> 'v' ->> 'p')::boolean THEN args[1] -> 'v' -> 'v'
    ELSE cel._err('optional.none() dereference')
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_has_value(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val((args[1] -> 'v' ->> 'p')::boolean);
$$;

INSERT INTO cel.type (name, kind) VALUES
  ('optional_type',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}')
ON CONFLICT (name) DO UPDATE SET kind = excluded.kind;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('optional_of', 'optional.of', false,
   '[{"kind": "param", "name": "V"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_of(jsonb[])', 10),
  ('optional_ofNonZeroValue', 'optional.ofNonZeroValue', false,
   '[{"kind": "param", "name": "V"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_of_nonzero(jsonb[])', 10),
  ('optional_none', 'optional.none', false,
   '[]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_none(jsonb[])', 10),
  ('optional_value', 'value', true,
   '[{"kind": "opaque", "name": "optional_type",
      "params": [{"kind": "param", "name": "V"}]}]',
   '{"kind": "param", "name": "V"}',
   'cel._f_opt_value(jsonb[])', 10),
  ('optional_hasValue', 'hasValue', true,
   '[{"kind": "opaque", "name": "optional_type",
      "params": [{"kind": "param", "name": "V"}]}]',
   '{"kind": "bool"}',
   'cel._f_opt_has_value(jsonb[])', 10)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('optionals', 'type', 'optional_type'),
  ('optionals', 'overload', 'optional_of'),
  ('optionals', 'overload', 'optional_ofNonZeroValue'),
  ('optionals', 'overload', 'optional_none'),
  ('optionals', 'overload', 'optional_value'),
  ('optionals', 'overload', 'optional_hasValue')
ON CONFLICT DO NOTHING;

COMMIT;

BEGIN;

-- Part two: the optional-syntax operators, or/orValue, and the
-- optMap/optFlatMap macros (cel/library.go optionals block,
-- cel/library.go:430-560 at the pinned v0.32.0).

-- select_optional_field (_?._): field presence lifted into an
-- optional; distributes over an optional operand.
CREATE OR REPLACE FUNCTION cel._f_opt_select(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v jsonb := args[1];
  r jsonb;
BEGIN
  IF v ->> '@t' = 'opaque' AND v ->> 'type' = 'optional_type' THEN
    IF NOT (v -> 'v' ->> 'p')::boolean THEN
      RETURN v;
    END IF;
    RETURN cel._f_opt_select(ARRAY[v -> 'v' -> 'v', args[2]]);
  END IF;
  IF v ->> '@t' = 'map' THEN
    r := cel._map_find(v, args[2]);
    IF r IS NULL THEN
      RETURN cel._opt_none();
    END IF;
    RETURN cel._opt_of(r);
  END IF;
  RETURN cel._err(format(
    'does not support field selection: %s', v ->> '@t'));
END;
$$;

-- _[?_]: index presence lifted into an optional; distributes over
-- an optional operand.
CREATE OR REPLACE FUNCTION cel._f_opt_index(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v jsonb := args[1];
  k jsonb := args[2];
  r jsonb;
  n numeric;
BEGIN
  IF v ->> '@t' = 'opaque' AND v ->> 'type' = 'optional_type' THEN
    IF NOT (v -> 'v' ->> 'p')::boolean THEN
      RETURN v;
    END IF;
    RETURN cel._f_opt_index(ARRAY[v -> 'v' -> 'v', k]);
  END IF;
  IF v ->> '@t' = 'list' THEN
    IF k ->> '@t' NOT IN ('int', 'uint', 'double') THEN
      RETURN cel._err(format('no such overload: %s[?%s]',
        v ->> '@t', k ->> '@t'));
    END IF;
    n := (k ->> 'v')::numeric;
    IF n <> trunc(n) OR n < 0
       OR n >= jsonb_array_length(v -> 'v') THEN
      RETURN cel._opt_none();
    END IF;
    RETURN cel._opt_of(v -> 'v' -> n::int);
  END IF;
  IF v ->> '@t' = 'map' THEN
    r := cel._map_find(v, k);
    IF r IS NULL THEN
      RETURN cel._opt_none();
    END IF;
    RETURN cel._opt_of(r);
  END IF;
  RETURN cel._err(format('no such overload: %s[?_]', v ->> '@t'));
END;
$$;

-- Plain _[_] with an optional operand: none stays none, a present
-- container indexes strictly and re-wraps.
CREATE OR REPLACE FUNCTION cel._f_opt_index_strict(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
BEGIN
  -- Qualification of an optional is always if-present in cel-go's
  -- attribute machinery: a missing key or index yields none, not an
  -- error (measured: optionals/optional_chaining_5..11).
  RETURN cel._f_opt_index(args);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_or(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN (args[1] -> 'v' ->> 'p')::boolean
              THEN args[1] ELSE args[2] END;
$$;

CREATE OR REPLACE FUNCTION cel._f_opt_or_value(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN (args[1] -> 'v' ->> 'p')::boolean
              THEN args[1] -> 'v' -> 'v' ELSE args[2] END;
$$;

-- optMap / optFlatMap (cel/library.go optMap/optFlatMap): expand to
--   target.hasValue()
--     ? <of?>(bind(v, target.value(), expr))
--     : optional.none()
-- with the target itself bound to @target first when it is not a
-- simple identifier.
CREATE OR REPLACE FUNCTION cel._mx_opt_map(
  flat boolean, target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  cs jsonb := target -> 's';
  ce jsonb := target -> 'e';
  id bigint := next_id;
  nm text;
  tgt jsonb;
  hasv jsonb;
  valv jsonb;
  innerc jsonb;
  cond jsonb;
  step jsonb;
  nonec jsonb;
  branch jsonb;
BEGIN
  IF args -> 0 ->> 'k' <> 'ident' THEN
    err := format('opt%s() variable name must be a simple '
      || 'identifier', CASE WHEN flat THEN 'FlatMap' ELSE 'Map' END);
    RETURN;
  END IF;
  nm := args -> 0 ->> 'name';

  IF target ->> 'k' = 'ident' THEN
    tgt := target;
  ELSE
    id := id + 1;
    tgt := jsonb_build_object('id', id, 'k', 'ident',
      'name', '@target', 's', cs, 'e', ce);
  END IF;

  id := id + 1;
  hasv := jsonb_build_object('id', id, 'k', 'call',
    'fn', 'hasValue', 'target', tgt, 'args', '[]'::jsonb,
    's', cs, 'e', ce);
  id := id + 1;
  valv := jsonb_build_object('id', id, 'k', 'call',
    'fn', 'value', 'target', tgt, 'args', '[]'::jsonb,
    's', cs, 'e', ce);
  id := id + 1;
  cond := jsonb_build_object('id', id, 'k', 'lit',
    'v', jsonb_build_object('@t', 'bool', 'v', false),
    's', cs, 'e', ce);
  id := id + 1;
  step := jsonb_build_object('id', id, 'k', 'ident',
    'name', nm, 's', cs, 'e', ce);
  id := id + 1;
  innerc := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', jsonb_build_object('id', id, 'k', 'list',
      'elems', '[]'::jsonb, 's', cs, 'e', ce),
    'iter', '#unused', 'iter2', '', 'accu', nm,
    'init', valv, 'cond', cond, 'step', step,
    'result', args -> 1, 's', cs, 'e', ce);
  IF NOT flat THEN
    id := id + 1;
    innerc := jsonb_build_object('id', id, 'k', 'call',
      'fn', 'optional.of', 'args', jsonb_build_array(innerc),
      's', cs, 'e', ce);
  END IF;
  id := id + 1;
  nonec := jsonb_build_object('id', id, 'k', 'call',
    'fn', 'optional.none', 'args', '[]'::jsonb, 's', cs, 'e', ce);
  id := id + 1;
  branch := jsonb_build_object('id', id, 'k', 'call',
    'fn', '_?_:_',
    'args', jsonb_build_array(hasv, innerc, nonec),
    's', cs, 'e', ce);

  IF target ->> 'k' = 'ident' THEN
    expr := branch;
    next_id_out := id;
    RETURN;
  END IF;

  id := id + 1;
  step := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@target', 's', cs, 'e', ce);
  id := id + 1;
  cond := jsonb_build_object('id', id, 'k', 'lit',
    'v', jsonb_build_object('@t', 'bool', 'v', false),
    's', cs, 'e', ce);
  id := id + 1;
  expr := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', jsonb_build_object('id', id, 'k', 'list',
      'elems', '[]'::jsonb, 's', cs, 'e', ce),
    'iter', '#unused', 'iter2', '', 'accu', '@target',
    'init', target, 'cond', cond, 'step', step,
    'result', branch, 's', cs, 'e', ce);
  next_id_out := id;
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_opt_map_2(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx_opt_map(false, target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx_opt_flat_map(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx_opt_map(true, target, args, next_id);
$$;

INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('optMap', 2, true, 'cel._mx_opt_map_2(jsonb,jsonb,bigint)'),
  ('optFlatMap', 2, true,
   'cel._mx_opt_flat_map(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE
  SET expander = excluded.expander;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('optional_or_optional', 'or', true,
   '[{"kind": "opaque", "name": "optional_type",
      "params": [{"kind": "param", "name": "V"}]},
     {"kind": "opaque", "name": "optional_type",
      "params": [{"kind": "param", "name": "V"}]}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_or(jsonb[])', 10),
  ('optional_orValue_value', 'orValue', true,
   '[{"kind": "opaque", "name": "optional_type",
      "params": [{"kind": "param", "name": "V"}]},
     {"kind": "param", "name": "V"}]',
   '{"kind": "param", "name": "V"}',
   'cel._f_opt_or_value(jsonb[])', 10),
  ('select_optional_field', '_?._', false,
   '[{"kind": "dyn"}, {"kind": "string"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_select(jsonb[])', 10),
  ('list_optindex_optional_int', '_[?_]', false,
   '[{"kind": "list", "params": [{"kind": "param", "name": "V"}]},
     {"kind": "int"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index(jsonb[])', 10),
  ('optional_list_optindex_optional_int', '_[?_]', false,
   '[{"kind": "opaque", "name": "optional_type", "params":
      [{"kind": "list", "params": [{"kind": "param",
        "name": "V"}]}]},
     {"kind": "int"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index(jsonb[])', 20),
  ('map_optindex_optional_value', '_[?_]', false,
   '[{"kind": "map", "params": [{"kind": "param", "name": "K"},
      {"kind": "param", "name": "V"}]},
     {"kind": "param", "name": "K"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index(jsonb[])', 30),
  ('optional_map_optindex_optional_value', '_[?_]', false,
   '[{"kind": "opaque", "name": "optional_type", "params":
      [{"kind": "map", "params": [{"kind": "param", "name": "K"},
        {"kind": "param", "name": "V"}]}]},
     {"kind": "param", "name": "K"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index(jsonb[])', 40),
  ('optional_list_index_int', '_[_]', false,
   '[{"kind": "opaque", "name": "optional_type", "params":
      [{"kind": "list", "params": [{"kind": "param",
        "name": "V"}]}]},
     {"kind": "int"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index_strict(jsonb[])', 30),
  ('optional_map_index_value', '_[_]', false,
   '[{"kind": "opaque", "name": "optional_type", "params":
      [{"kind": "map", "params": [{"kind": "param", "name": "K"},
        {"kind": "param", "name": "V"}]}]},
     {"kind": "param", "name": "K"}]',
   '{"kind": "opaque", "name": "optional_type",
     "params": [{"kind": "param", "name": "V"}]}',
   'cel._f_opt_index_strict(jsonb[])', 40)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('optionals', 'overload', 'optional_or_optional'),
  ('optionals', 'overload', 'optional_orValue_value'),
  ('optionals', 'overload', 'select_optional_field'),
  ('optionals', 'overload', 'list_optindex_optional_int'),
  ('optionals', 'overload', 'optional_list_optindex_optional_int'),
  ('optionals', 'overload', 'map_optindex_optional_value'),
  ('optionals', 'overload', 'optional_map_optindex_optional_value'),
  ('optionals', 'overload', 'optional_list_index_int'),
  ('optionals', 'overload', 'optional_map_index_value'),
  ('optionals', 'macro', 'optMap/2/1'),
  ('optionals', 'macro', 'optFlatMap/2/1')
ON CONFLICT DO NOTHING;

COMMIT;

-- ---- sql/120_ext_strings.sql ----

-- The strings extension (cel-go ext/strings.go at the pinned
-- v0.32.0, latest library version): charAt, indexOf, lastIndexOf,
-- lowerAscii, upperAscii, replace, split, substring, trim, join,
-- reverse, strings.quote and string.format. Registered under the
-- 'strings' env.
--
-- All index arithmetic is in code points; Postgres text functions
-- are character-based under UTF8, which lines up. One deliberate
-- divergence from cel-go: indexOf/lastIndexOf with an out-of-range
-- offset error instead of returning -1 -- the corpus and cel-java
-- agree against cel-go v0.32.0 there.

BEGIN;

CREATE OR REPLACE FUNCTION cel._str_val(s text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v', s);
$$;

CREATE OR REPLACE FUNCTION cel._f_char_at(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s text := args[1] ->> 'v';
  i numeric := (args[2] ->> 'v')::numeric;
BEGIN
  IF i < 0 OR i > length(s) THEN
    RETURN cel._err(format('index out of range: %s', i));
  END IF;
  RETURN cel._str_val(substr(s, i::int + 1, 1));
END;
$$;

-- Shared scan for indexOf / lastIndexOf. The empty-substring case
-- returns the clamped offset before the bounds check (matching both
-- cel-go and cel-java); a non-empty search with an out-of-range
-- offset errors (corpus + cel-java adjudication).
CREATE OR REPLACE FUNCTION cel._str_index(
  s text, sub text, off numeric, backwards boolean
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  l  int := length(s);
  ls int := length(sub);
  i  int;
BEGIN
  IF off < 0 THEN
    RETURN cel._err(format('index out of range: %s', off));
  END IF;
  IF sub = '' THEN
    RETURN cel._int_val(least(off, l::numeric));
  END IF;
  IF off >= l THEN
    RETURN cel._err(format('index out of range: %s', off));
  END IF;
  IF backwards THEN
    i := least(off::int, l - ls);
    WHILE i >= 0 LOOP
      IF substr(s, i + 1, ls) = sub THEN
        RETURN cel._int_val(i);
      END IF;
      i := i - 1;
    END LOOP;
  ELSE
    i := off::int;
    WHILE i <= l - ls LOOP
      IF substr(s, i + 1, ls) = sub THEN
        RETURN cel._int_val(i);
      END IF;
      i := i + 1;
    END LOOP;
  END IF;
  RETURN cel._int_val(-1);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_index_of(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._str_index(args[1] ->> 'v', args[2] ->> 'v',
    CASE WHEN cardinality(args) > 2
         THEN (args[3] ->> 'v')::numeric ELSE 0 END,
    false);
$$;

CREATE OR REPLACE FUNCTION cel._f_last_index_of(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s   text := args[1] ->> 'v';
  sub text := args[2] ->> 'v';
BEGIN
  IF cardinality(args) > 2 THEN
    RETURN cel._str_index(s, sub, (args[3] ->> 'v')::numeric, true);
  END IF;
  -- The 2-argument form never errors: it searches from the end.
  IF sub = '' THEN
    RETURN cel._int_val(length(s));
  END IF;
  IF length(s) < length(sub) THEN
    RETURN cel._int_val(-1);
  END IF;
  RETURN cel._str_index(s, sub, (length(s) - 1)::numeric, true);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_lower_ascii(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._str_val(translate(args[1] ->> 'v',
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'));
$$;

CREATE OR REPLACE FUNCTION cel._f_upper_ascii(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._str_val(translate(args[1] ->> 'v',
    'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'));
$$;

-- Go strings.Replace semantics: n < 0 replaces all, n = 0 none.
CREATE OR REPLACE FUNCTION cel._f_replace(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s   text := args[1] ->> 'v';
  old text := args[2] ->> 'v';
  new text := args[3] ->> 'v';
  n   numeric := CASE WHEN cardinality(args) > 3
                      THEN (args[4] ->> 'v')::numeric ELSE -1 END;
  res text := '';
  p   int;
BEGIN
  IF n < 0 THEN
    IF old = '' THEN
      -- Go inserts new between every rune and at both ends.
      res := new;
      FOR p IN 1 .. length(s) LOOP
        res := res || substr(s, p, 1) || new;
      END LOOP;
      RETURN cel._str_val(res);
    END IF;
    RETURN cel._str_val(replace(s, old, new));
  END IF;
  WHILE n > 0 LOOP
    IF old = '' THEN
      res := res || new;
      IF s = '' THEN
        EXIT;
      END IF;
      res := res || substr(s, 1, 1);
      s := substr(s, 2);
    ELSE
      p := strpos(s, old);
      EXIT WHEN p = 0;
      res := res || substr(s, 1, p - 1) || new;
      s := substr(s, p + length(old));
    END IF;
    n := n - 1;
  END LOOP;
  RETURN cel._str_val(res || s);
END;
$$;

-- Go strings.SplitN semantics, in code points; sep = '' splits into
-- characters.
CREATE OR REPLACE FUNCTION cel._f_split(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s   text := args[1] ->> 'v';
  sep text := args[2] ->> 'v';
  n   numeric := CASE WHEN cardinality(args) > 2
                      THEN (args[3] ->> 'v')::numeric ELSE -1 END;
  parts jsonb := '[]'::jsonb;
  p   int;
  cnt int := 0;
BEGIN
  IF n = 0 THEN
    RETURN jsonb_build_object('@t', 'list', 'v', '[]'::jsonb);
  END IF;
  IF sep = '' THEN
    FOR p IN 1 .. length(s) LOOP
      EXIT WHEN n > 0 AND cnt = n - 1;
      parts := parts || jsonb_build_array(
        cel._str_val(substr(s, p, 1)));
      cnt := cnt + 1;
    END LOOP;
    IF n > 0 AND length(s) > cnt THEN
      parts := parts || jsonb_build_array(
        cel._str_val(substr(s, cnt + 1)));
    END IF;
    RETURN jsonb_build_object('@t', 'list', 'v', parts);
  END IF;
  LOOP
    EXIT WHEN n > 0 AND cnt = n - 1;
    p := strpos(s, sep);
    EXIT WHEN p = 0;
    parts := parts || jsonb_build_array(
      cel._str_val(substr(s, 1, p - 1)));
    s := substr(s, p + length(sep));
    cnt := cnt + 1;
  END LOOP;
  parts := parts || jsonb_build_array(cel._str_val(s));
  RETURN jsonb_build_object('@t', 'list', 'v', parts);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_substring(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s text := args[1] ->> 'v';
  a numeric := (args[2] ->> 'v')::numeric;
  b numeric;
  l int := length(s);
BEGIN
  IF cardinality(args) = 2 THEN
    IF a < 0 OR a > l THEN
      RETURN cel._err(format('index out of range: %s', a));
    END IF;
    RETURN cel._str_val(substr(s, a::int + 1));
  END IF;
  b := (args[3] ->> 'v')::numeric;
  IF a > b THEN
    RETURN cel._err(format(
      'invalid substring range. start: %s, end: %s', a, b));
  END IF;
  IF a < 0 OR a > l THEN
    RETURN cel._err(format('index out of range: %s', a));
  END IF;
  IF b < 0 OR b > l THEN
    RETURN cel._err(format('index out of range: %s', b));
  END IF;
  RETURN cel._str_val(substr(s, a::int + 1, (b - a)::int));
END;
$$;

-- Go strings.TrimSpace: the Unicode white-space set.
CREATE OR REPLACE FUNCTION cel._f_trim(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._str_val(btrim(args[1] ->> 'v',
    E' \t\n\f\r' || chr(11) || chr(133) || chr(160) || chr(5760)
    || chr(8192) || chr(8193) || chr(8194) || chr(8195)
    || chr(8196) || chr(8197) || chr(8198) || chr(8199)
    || chr(8200) || chr(8201) || chr(8202) || chr(8232)
    || chr(8233) || chr(8239) || chr(8287) || chr(12288)));
$$;

CREATE OR REPLACE FUNCTION cel._f_str_reverse(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._str_val(reverse(args[1] ->> 'v'));
$$;

CREATE OR REPLACE FUNCTION cel._f_join(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  sep text := CASE WHEN cardinality(args) > 1
                   THEN args[2] ->> 'v' ELSE '' END;
  res text := '';
  i   int;
  e   jsonb;
BEGIN
  FOR i IN 0 .. jsonb_array_length(args[1] -> 'v') - 1 LOOP
    e := args[1] -> 'v' -> i;
    IF e ->> '@t' <> 'string' THEN
      RETURN cel._err(format('join: invalid input: %s', e ->> 'v'));
    END IF;
    IF i > 0 THEN
      res := res || sep;
    END IF;
    res := res || (e ->> 'v');
  END LOOP;
  RETURN cel._str_val(res);
END;
$$;

-- strings.quote: CEL escape sequences, double-quoted.
CREATE OR REPLACE FUNCTION cel._f_quote(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s   text := args[1] ->> 'v';
  res text := '';
  c   text;
  i   int;
BEGIN
  FOR i IN 1 .. length(s) LOOP
    c := substr(s, i, 1);
    res := res || CASE c
      WHEN chr(7)  THEN '\a'
      WHEN chr(8)  THEN '\b'
      WHEN chr(12) THEN '\f'
      WHEN chr(10) THEN '\n'
      WHEN chr(13) THEN '\r'
      WHEN chr(9)  THEN '\t'
      WHEN chr(11) THEN '\v'
      WHEN '\'     THEN '\\'
      WHEN '"'     THEN '\"'
      ELSE c
    END;
  END LOOP;
  RETURN cel._str_val('"' || res || '"');
END;
$$;

COMMIT;

BEGIN;

-- string.format ------------------------------------------------------

-- Round-half-even of an exact numeric at scale p, returned as a
-- numeric of exactly scale p (multiplication by the exact decimal
-- 1e-p preserves exactness; numeric division would not).
CREATE OR REPLACE FUNCTION cel._fmt_round_even(x numeric, p int)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a numeric := abs(x) * (10::numeric ^ p);
  i numeric := trunc(a);
  f numeric := a - i;
BEGIN
  IF f > 0.5 OR (f = 0.5 AND mod(i, 2) = 1) THEN
    i := i + 1;
  END IF;
  RETURN sign(x) * i * ('1e-' || p)::numeric;
END;
$$;

-- The %s formatter (formatting_v2.go formatStringV2): recursive over
-- lists and maps, map entries sorted by their formatted key.
CREATE OR REPLACE FUNCTION cel._fmt_s(v jsonb, OUT o text, OUT err text)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k text := v ->> '@t';
  i int;
  r record;
  parts text[];
  ents  text[];
  kv    record;
BEGIN
  CASE k
    WHEN 'string' THEN o := v ->> 'v';
    WHEN 'bool' THEN o := CASE WHEN (v ->> 'v')::boolean
                              THEN 'true' ELSE 'false' END;
    WHEN 'int', 'uint' THEN o := v ->> 'v';
    WHEN 'double' THEN
      o := CASE v ->> 'v'
        WHEN 'NaN' THEN 'NaN'
        WHEN 'Infinity' THEN 'Infinity'
        WHEN '-Infinity' THEN '-Infinity'
        ELSE cel._sci_to_plain(
          cel._double_text((v ->> 'v')::float8))
      END;
    WHEN 'bytes' THEN
      o := convert_from(decode(v ->> 'v', 'base64'), 'UTF8');
    WHEN 'null' THEN o := 'null';
    WHEN 'type' THEN o := v ->> 'v';
    WHEN 'duration' THEN
      o := cel._f_duration_to_string(ARRAY[v]) ->> 'v';
    WHEN 'timestamp' THEN
      -- Formatting renders in UTC regardless of the value's offset.
      o := cel._f_timestamp_to_string(ARRAY[
        jsonb_set(v, '{v,tz}', '0'::jsonb)]) ->> 'v';
    WHEN 'list' THEN
      parts := '{}';
      FOR i IN 0 .. jsonb_array_length(v -> 'v') - 1 LOOP
        SELECT * INTO r FROM cel._fmt_s(v -> 'v' -> i);
        IF r.err IS NOT NULL THEN
          err := r.err;
          RETURN;
        END IF;
        parts := parts || r.o;
      END LOOP;
      o := '[' || array_to_string(parts, ', ') || ']';
    WHEN 'map' THEN
      ents := '{}';
      FOR i IN 0 .. jsonb_array_length(v -> 'v') - 1 LOOP
        SELECT * INTO r FROM cel._fmt_s(v -> 'v' -> i -> 'k');
        IF r.err IS NOT NULL THEN
          err := r.err;
          RETURN;
        END IF;
        ents := ents || (r.o || chr(1));
        SELECT * INTO r FROM cel._fmt_s(v -> 'v' -> i -> 'v');
        IF r.err IS NOT NULL THEN
          err := r.err;
          RETURN;
        END IF;
        ents[cardinality(ents)] := ents[cardinality(ents)] || r.o;
      END LOOP;
      SELECT array_agg(e ORDER BY split_part(e, chr(1), 1)
                                  COLLATE "C")
      INTO ents FROM unnest(ents) e;
      o := '{' || coalesce((
        SELECT string_agg(replace(e, chr(1), ': '), ', ')
        FROM unnest(ents) e), '') || '}';
    ELSE
      err := format('string clause can only be used on strings, '
        || 'bools, bytes, ints, doubles, maps, lists, types, '
        || 'durations, and timestamps, was given %s',
        CASE WHEN k = 'opaque' THEN v ->> 'type' ELSE k END);
  END CASE;
END;
$$;

-- Integer rendering in bases 2, 8 and 16 (sign + digits of the
-- absolute value, matching Go strconv.FormatInt).
CREATE OR REPLACE FUNCTION cel._fmt_base(n numeric, b int, up boolean)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a numeric := abs(n);
  digits text := '0123456789abcdef';
  o text := '';
  d int;
BEGIN
  IF a = 0 THEN
    o := '0';
  END IF;
  WHILE a > 0 LOOP
    d := mod(a, b)::int;
    o := substr(digits, d + 1, 1) || o;
    a := div(a, b);
  END LOOP;
  IF up THEN
    o := upper(o);
  END IF;
  RETURN CASE WHEN n < 0 THEN '-' || o ELSE o END;
END;
$$;

-- Fixed-point (%f) and scientific (%e) rendering over the exact
-- decimal expansion of the double (cel._f2n), rounded half-even the
-- way Go's correctly-rounded formatter behaves.
CREATE OR REPLACE FUNCTION cel._fmt_fixed(f float8, p int)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  r numeric := cel._fmt_round_even(cel._f2n(f), p);
  neg boolean := f < 0 OR (f = 0 AND f::text = '-0');
BEGIN
  RETURN CASE WHEN neg AND r >= 0 THEN '-' ELSE '' END || r::text;
END;
$$;

CREATE OR REPLACE FUNCTION cel._fmt_sci(f float8, p int)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  m numeric := cel._f2n(f);
  e int := 0;
  am numeric;
  es text;
BEGIN
  am := abs(m);
  IF am <> 0 THEN
    WHILE am >= 10 LOOP
      am := am * 0.1;
      e := e + 1;
    END LOOP;
    WHILE am < 1 LOOP
      am := am * 10;
      e := e - 1;
    END LOOP;
  END IF;
  am := cel._fmt_round_even(am, p);
  IF am >= 10 THEN
    am := am * 0.1;
    e := e + 1;
    am := cel._fmt_round_even(am, p);
  END IF;
  es := lpad(abs(e)::text, 2, '0');
  RETURN CASE WHEN m < 0 OR (f = 0 AND f::text = '-0')
              THEN '-' ELSE '' END
      || am::text || 'e'
      || CASE WHEN e < 0 THEN '-' ELSE '+' END || es;
END;
$$;

-- One formatting clause applied to one argument. kinds follow
-- formatting_v2.go's per-clause type admission exactly.
CREATE OR REPLACE FUNCTION cel._fmt_clause(
  c text, p int, v jsonb, OUT o text, OUT err text
)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k text := v ->> '@t';
  r record;
  tn text := CASE k
    WHEN 'opaque' THEN v ->> 'type'
    WHEN 'timestamp' THEN 'google.protobuf.Timestamp'
    WHEN 'duration' THEN 'google.protobuf.Duration'
    ELSE k END;
BEGIN
  CASE c
    WHEN 's' THEN
      SELECT * INTO r FROM cel._fmt_s(v);
      o := r.o;
      err := r.err;
    WHEN 'd' THEN
      IF k IN ('int', 'uint') THEN
        o := v ->> 'v';
      ELSIF k = 'double'
            AND v ->> 'v' IN ('NaN', 'Infinity', '-Infinity') THEN
        o := v ->> 'v';
      ELSE
        err := format('decimal clause can only be used on '
          || 'integers, was given %s', tn);
      END IF;
    WHEN 'f' THEN
      IF k IN ('int', 'uint', 'double') THEN
        IF k = 'double'
           AND v ->> 'v' IN ('NaN', 'Infinity', '-Infinity') THEN
          o := v ->> 'v';
        ELSE
          o := cel._fmt_fixed((v ->> 'v')::float8, p);
        END IF;
      ELSE
        err := format('fixed-point clause can only be used on '
          || 'numeric types, was given %s', tn);
      END IF;
    WHEN 'e' THEN
      IF k IN ('int', 'uint', 'double') THEN
        IF k = 'double'
           AND v ->> 'v' IN ('NaN', 'Infinity', '-Infinity') THEN
          o := v ->> 'v';
        ELSE
          o := cel._fmt_sci((v ->> 'v')::float8, p);
        END IF;
      ELSE
        err := format('scientific clause can only be used on '
          || 'numeric types, was given %s', tn);
      END IF;
    WHEN 'b' THEN
      IF k IN ('int', 'uint') THEN
        o := cel._fmt_base((v ->> 'v')::numeric, 2, false);
      ELSIF k = 'bool' THEN
        o := CASE WHEN (v ->> 'v')::boolean THEN '1' ELSE '0' END;
      ELSE
        err := format('only integers and bools can be formatted '
          || 'as binary, was given %s', tn);
      END IF;
    WHEN 'x', 'X' THEN
      IF k IN ('int', 'uint') THEN
        o := cel._fmt_base((v ->> 'v')::numeric, 16, c = 'X');
      ELSIF k = 'string' THEN
        o := encode(convert_to(v ->> 'v', 'UTF8'), 'hex');
        IF c = 'X' THEN o := upper(o); END IF;
      ELSIF k = 'bytes' THEN
        o := encode(decode(v ->> 'v', 'base64'), 'hex');
        IF c = 'X' THEN o := upper(o); END IF;
      ELSE
        err := format('only integers, byte buffers, and strings '
          || 'can be formatted as hex, was given %s', tn);
      END IF;
    WHEN 'o' THEN
      IF k IN ('int', 'uint') THEN
        o := cel._fmt_base((v ->> 'v')::numeric, 8, false);
      ELSE
        err := format('octal clause can only be used on integers, '
          || 'was given %s', tn);
      END IF;
    ELSE
      err := NULL;  -- unreachable; clauses validated by the caller
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_format(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s    text := args[1] ->> 'v';
  lst  jsonb := args[2] -> 'v';
  n    int := jsonb_array_length(lst);
  res  text := '';
  i    int := 1;
  ai   int := 0;
  l    int := length(s);
  c    text;
  p    int;
  ptxt text;
  r    record;
BEGIN
  WHILE i <= l LOOP
    c := substr(s, i, 1);
    IF c <> '%' THEN
      res := res || c;
      i := i + 1;
      CONTINUE;
    END IF;
    IF substr(s, i + 1, 1) = '%' THEN
      res := res || '%';
      i := i + 2;
      CONTINUE;
    END IF;
    IF i = l THEN
      RETURN cel._err('unexpected end of string');
    END IF;
    -- precision
    i := i + 1;
    p := 6;
    IF substr(s, i, 1) = '.' THEN
      i := i + 1;
      ptxt := '';
      WHILE i <= l AND substr(s, i, 1) BETWEEN '0' AND '9' LOOP
        ptxt := ptxt || substr(s, i, 1);
        i := i + 1;
      END LOOP;
      IF i > l THEN
        RETURN cel._err('could not parse formatting clause: '
          || 'could not find end of precision specifier');
      END IF;
      IF ptxt = '' THEN
        RETURN cel._err('could not parse formatting clause: error '
          || 'while converting precision to integer');
      END IF;
      p := ptxt::int;
    END IF;
    c := substr(s, i, 1);
    i := i + 1;
    IF c NOT IN ('s', 'd', 'f', 'e', 'b', 'x', 'X', 'o') THEN
      RETURN cel._err(format('could not parse formatting clause: '
        || 'unrecognized formatting clause "%s"', c));
    END IF;
    IF ai >= n THEN
      RETURN cel._err(format('index %s out of range', ai));
    END IF;
    SELECT * INTO r FROM cel._fmt_clause(c, p, lst -> ai);
    IF r.err IS NOT NULL THEN
      RETURN cel._err('error during formatting: ' || r.err);
    END IF;
    res := res || r.o;
    ai := ai + 1;
  END LOOP;
  RETURN cel._str_val(res);
END;
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('string_char_at_int', 'charAt', true,
   '[{"kind": "string"}, {"kind": "int"}]', '{"kind": "string"}',
   'cel._f_char_at(jsonb[])', 10),
  ('string_index_of_string', 'indexOf', true,
   '[{"kind": "string"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_index_of(jsonb[])', 10),
  ('string_index_of_string_int', 'indexOf', true,
   '[{"kind": "string"}, {"kind": "string"}, {"kind": "int"}]',
   '{"kind": "int"}', 'cel._f_index_of(jsonb[])', 20),
  ('string_last_index_of_string', 'lastIndexOf', true,
   '[{"kind": "string"}, {"kind": "string"}]', '{"kind": "int"}',
   'cel._f_last_index_of(jsonb[])', 10),
  ('string_last_index_of_string_int', 'lastIndexOf', true,
   '[{"kind": "string"}, {"kind": "string"}, {"kind": "int"}]',
   '{"kind": "int"}', 'cel._f_last_index_of(jsonb[])', 20),
  ('string_lower_ascii', 'lowerAscii', true,
   '[{"kind": "string"}]', '{"kind": "string"}',
   'cel._f_lower_ascii(jsonb[])', 10),
  ('string_upper_ascii', 'upperAscii', true,
   '[{"kind": "string"}]', '{"kind": "string"}',
   'cel._f_upper_ascii(jsonb[])', 10),
  ('string_replace_string_string', 'replace', true,
   '[{"kind": "string"}, {"kind": "string"}, {"kind": "string"}]',
   '{"kind": "string"}', 'cel._f_replace(jsonb[])', 10),
  ('string_replace_string_string_int', 'replace', true,
   '[{"kind": "string"}, {"kind": "string"}, {"kind": "string"},
     {"kind": "int"}]',
   '{"kind": "string"}', 'cel._f_replace(jsonb[])', 20),
  ('string_split_string', 'split', true,
   '[{"kind": "string"}, {"kind": "string"}]',
   '{"kind": "list", "params": [{"kind": "string"}]}',
   'cel._f_split(jsonb[])', 10),
  ('string_split_string_int', 'split', true,
   '[{"kind": "string"}, {"kind": "string"}, {"kind": "int"}]',
   '{"kind": "list", "params": [{"kind": "string"}]}',
   'cel._f_split(jsonb[])', 20),
  ('string_substring_int', 'substring', true,
   '[{"kind": "string"}, {"kind": "int"}]', '{"kind": "string"}',
   'cel._f_substring(jsonb[])', 10),
  ('string_substring_int_int', 'substring', true,
   '[{"kind": "string"}, {"kind": "int"}, {"kind": "int"}]',
   '{"kind": "string"}', 'cel._f_substring(jsonb[])', 20),
  ('string_trim', 'trim', true,
   '[{"kind": "string"}]', '{"kind": "string"}',
   'cel._f_trim(jsonb[])', 10),
  ('string_reverse', 'reverse', true,
   '[{"kind": "string"}]', '{"kind": "string"}',
   'cel._f_str_reverse(jsonb[])', 10),
  ('list_join', 'join', true,
   '[{"kind": "list", "params": [{"kind": "string"}]}]',
   '{"kind": "string"}', 'cel._f_join(jsonb[])', 10),
  ('list_join_string', 'join', true,
   '[{"kind": "list", "params": [{"kind": "string"}]},
     {"kind": "string"}]',
   '{"kind": "string"}', 'cel._f_join(jsonb[])', 20),
  ('strings_quote', 'strings.quote', false,
   '[{"kind": "string"}]', '{"kind": "string"}',
   'cel._f_quote(jsonb[])', 10),
  ('string_format', 'format', true,
   '[{"kind": "string"},
     {"kind": "list", "params": [{"kind": "dyn"}]}]',
   '{"kind": "string"}', 'cel._f_format(jsonb[])', 10)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'strings', 'overload', id FROM cel.overload
WHERE id IN (
  'string_char_at_int', 'string_index_of_string',
  'string_index_of_string_int', 'string_last_index_of_string',
  'string_last_index_of_string_int', 'string_lower_ascii',
  'string_upper_ascii', 'string_replace_string_string',
  'string_replace_string_string_int', 'string_split_string',
  'string_split_string_int', 'string_substring_int',
  'string_substring_int_int', 'string_trim', 'string_reverse',
  'list_join', 'list_join_string', 'strings_quote',
  'string_format')
ON CONFLICT DO NOTHING;

COMMIT;

-- ---- sql/130_ext_math.sql ----

-- The math extension (cel-go ext/math.go at the pinned v0.32.0,
-- latest library version): the math.greatest / math.least macros over
-- math.@max / math.@min, ceil/floor/round/trunc, isInf/isNaN/
-- isFinite, abs/sign/sqrt, and the 64-bit bit operations. Registered
-- under the 'math' env.
--
-- Bit operations run in numeric two's-complement arithmetic (div /
-- mod by exact powers of two) because Postgres bigint shifts take
-- the count mod 64, and uint64 values do not fit bigint.

BEGIN;

CREATE OR REPLACE FUNCTION cel._math_ident(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT args[1];
$$;

-- minPair/maxPair (math.go:684): compare, propagate NaN's
-- unorderable error.
CREATE OR REPLACE FUNCTION cel._math_pair(a jsonb, b jsonb, mx boolean)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  c    jsonb := cel._compare(a, b);
  take int := CASE WHEN mx THEN -1 ELSE 1 END;
BEGIN
  IF cel._is_error(c) THEN
    RETURN c;
  END IF;
  IF (c ->> 'v')::int = take THEN
    RETURN b;
  END IF;
  RETURN a;
END;
$$;

CREATE OR REPLACE FUNCTION cel._math_minmax(args jsonb[], mx boolean)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  acc jsonb;
  i   int;
BEGIN
  IF cardinality(args) = 2 THEN
    RETURN cel._math_pair(args[1], args[2], mx);
  END IF;
  -- Single list argument.
  IF jsonb_array_length(args[1] -> 'v') = 0 THEN
    RETURN cel._err(format('math.@%s(list) argument must not be '
      || 'empty', CASE WHEN mx THEN 'max' ELSE 'min' END));
  END IF;
  acc := args[1] -> 'v' -> 0;
  FOR i IN 1 .. jsonb_array_length(args[1] -> 'v') - 1 LOOP
    acc := cel._math_pair(acc, args[1] -> 'v' -> i, mx);
    IF cel._is_error(acc) THEN
      RETURN acc;
    END IF;
  END LOOP;
  IF acc ->> '@t' NOT IN ('int', 'uint', 'double', 'unknown') THEN
    RETURN cel._err(format('no such overload: math.@%s',
      CASE WHEN mx THEN 'max' ELSE 'min' END));
  END IF;
  RETURN acc;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_min(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._math_minmax(args, false) $$;

CREATE OR REPLACE FUNCTION cel._f_math_max(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._math_minmax(args, true) $$;

CREATE OR REPLACE FUNCTION cel._f_math_ceil(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dbl_val(ceil((args[1] ->> 'v')::float8));
$$;

CREATE OR REPLACE FUNCTION cel._f_math_floor(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._dbl_val(floor((args[1] ->> 'v')::float8));
$$;

-- math.Round: half away from zero; NaN and infinities pass through.
CREATE OR REPLACE FUNCTION cel._f_math_round(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  f float8 := (args[1] ->> 'v')::float8;
BEGIN
  IF args[1] ->> 'v' IN ('NaN', 'Infinity', '-Infinity') THEN
    RETURN args[1];
  END IF;
  RETURN cel._dbl_val(CASE WHEN f < 0 THEN -floor(-f + 0.5)
                           ELSE floor(f + 0.5) END);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_trunc(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE
    WHEN args[1] ->> 'v' IN ('NaN', 'Infinity', '-Infinity')
      THEN args[1]
    ELSE cel._dbl_val(trunc((args[1] ->> 'v')::float8::numeric)
                        ::float8)
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_isinf(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    args[1] ->> 'v' IN ('Infinity', '-Infinity'));
$$;

CREATE OR REPLACE FUNCTION cel._f_math_isnan(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(args[1] ->> 'v' = 'NaN');
$$;

CREATE OR REPLACE FUNCTION cel._f_math_isfinite(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    args[1] ->> 'v' NOT IN ('NaN', 'Infinity', '-Infinity'));
$$;

CREATE OR REPLACE FUNCTION cel._f_math_abs(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k text := args[1] ->> '@t';
BEGIN
  CASE k
    WHEN 'double' THEN
      IF args[1] ->> 'v' = 'NaN' THEN
        RETURN args[1];
      END IF;
      RETURN cel._dbl_val(abs((args[1] ->> 'v')::float8));
    WHEN 'int' THEN
      IF (args[1] ->> 'v')::numeric = -9223372036854775808 THEN
        RETURN cel._err('integer overflow');
      END IF;
      RETURN cel._int_val(abs((args[1] ->> 'v')::numeric));
    ELSE
      RETURN args[1];  -- uint
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_sign(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  k text := args[1] ->> '@t';
  n numeric;
BEGIN
  IF k = 'double' THEN
    IF args[1] ->> 'v' = 'NaN' THEN
      RETURN args[1];
    END IF;
    RETURN cel._dbl_val(sign((args[1] ->> 'v')::float8)::float8);
  END IF;
  n := (args[1] ->> 'v')::numeric;
  IF k = 'uint' THEN
    RETURN jsonb_build_object('@t', 'uint', 'v',
      CASE WHEN n = 0 THEN 0 ELSE 1 END);
  END IF;
  RETURN cel._int_val(sign(n));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_sqrt(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  f float8;
BEGIN
  IF args[1] ->> '@t' = 'double'
     AND args[1] ->> 'v' IN ('NaN', '-Infinity') THEN
    RETURN cel._dbl_val('NaN'::float8);
  END IF;
  IF args[1] ->> 'v' = 'Infinity' THEN
    RETURN args[1];
  END IF;
  f := (args[1] ->> 'v')::float8;
  IF f < 0 THEN
    RETURN cel._dbl_val('NaN'::float8);
  END IF;
  RETURN cel._dbl_val(sqrt(f));
END;
$$;

-- Two's-complement helpers over numeric: to64/from64 map an
-- int64-or-uint64 payload onto [0, 2^64) and back.
CREATE OR REPLACE FUNCTION cel._bits_of(v jsonb)
RETURNS numeric
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN (v ->> 'v')::numeric < 0
    THEN (v ->> 'v')::numeric + 18446744073709551616::numeric
    ELSE (v ->> 'v')::numeric END;
$$;

CREATE OR REPLACE FUNCTION cel._bits_val(u numeric, uns boolean)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN uns
    THEN jsonb_build_object('@t', 'uint', 'v', to_jsonb(u))
    ELSE cel._int_val(CASE
      WHEN u >= 9223372036854775808::numeric
        THEN u - 18446744073709551616::numeric
      ELSE u END)
  END;
$$;

-- Bitwise and/or/xor run on bigint after an offset-preserving remap
-- (two's complement is offset-invariant under these operators).
CREATE OR REPLACE FUNCTION cel._f_math_bitop(args jsonb[], op text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  uns boolean := args[1] ->> '@t' = 'uint';
  a bigint := cel._bits_val(cel._bits_of(args[1]), false) ->> 'v';
  b bigint := cel._bits_val(cel._bits_of(args[2]), false) ->> 'v';
  r bigint;
BEGIN
  r := CASE op
    WHEN 'and' THEN a & b
    WHEN 'or'  THEN a | b
    ELSE a # b
  END;
  RETURN cel._bits_val(
    cel._bits_of(cel._int_val(r::numeric)), uns);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_bitand(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._f_math_bitop(args, 'and') $$;
CREATE OR REPLACE FUNCTION cel._f_math_bitor(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._f_math_bitop(args, 'or') $$;
CREATE OR REPLACE FUNCTION cel._f_math_bitxor(args jsonb[])
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$ SELECT cel._f_math_bitop(args, 'xor') $$;

CREATE OR REPLACE FUNCTION cel._f_math_bitnot(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE WHEN args[1] ->> '@t' = 'uint'
    THEN jsonb_build_object('@t', 'uint', 'v', to_jsonb(
      18446744073709551615::numeric - (args[1] ->> 'v')::numeric))
    ELSE cel._int_val(-(args[1] ->> 'v')::numeric - 1)
  END;
$$;

CREATE OR REPLACE FUNCTION cel._f_math_shl(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  uns boolean := args[1] ->> '@t' = 'uint';
  bs  numeric := (args[2] ->> 'v')::numeric;
  u   numeric;
BEGIN
  IF bs < 0 THEN
    RETURN cel._err(format(
      'math.bitShiftLeft() negative offset: %s', bs));
  END IF;
  IF bs >= 64 THEN
    RETURN cel._bits_val(0, uns);
  END IF;
  -- numeric ^ returns a scaled result even for integer powers;
  -- trunc() restores the integer.
  u := trunc(mod(
    cel._bits_of(args[1]) * (2::numeric ^ bs::int),
    18446744073709551616::numeric));
  RETURN cel._bits_val(u, uns);
END;
$$;

-- Right shift is logical for both int and uint (math.go
-- bitShiftRightIntInt reinterprets through uint64).
CREATE OR REPLACE FUNCTION cel._f_math_shr(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  uns boolean := args[1] ->> '@t' = 'uint';
  bs  numeric := (args[2] ->> 'v')::numeric;
BEGIN
  IF bs < 0 THEN
    RETURN cel._err(format(
      'math.bitShiftRight() negative offset: %s', bs));
  END IF;
  IF bs >= 64 THEN
    RETURN cel._bits_val(0, uns);
  END IF;
  RETURN cel._bits_val(
    div(cel._bits_of(args[1]), 2::numeric ^ bs::int), uns);
END;
$$;

-- The greatest/least macros (math.go:617): receiver macros on the
-- 'math' namespace, variadic; literal arguments must be numeric.

CREATE OR REPLACE FUNCTION cel._mx_math_arg_ok(arg jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT CASE arg ->> 'k'
    WHEN 'lit' THEN
      (arg -> 'v' ->> '@t') IN ('int', 'uint', 'double')
    WHEN 'list' THEN false
    WHEN 'map' THEN false
    WHEN 'struct' THEN false
    ELSE true
  END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_math_minmax(
  fn text, disp text, target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  n  int := jsonb_array_length(args);
  cs jsonb := target -> 's';
  ce jsonb := target -> 'e';
  ok boolean;
  i  int;
  lst jsonb;
BEGIN
  next_id_out := next_id;
  -- Decline unless the receiver is the math namespace.
  IF target ->> 'k' <> 'ident'
     OR ltrim(target ->> 'name', '.') <> 'math' THEN
    RETURN;
  END IF;
  IF n = 0 THEN
    err := format('%s() requires at least one argument', disp);
    RETURN;
  END IF;
  IF n = 1 THEN
    ok := CASE args -> 0 ->> 'k'
      WHEN 'list' THEN
        jsonb_array_length(args -> 0 -> 'elems') > 0 AND NOT EXISTS (
          SELECT FROM jsonb_array_elements(args -> 0 -> 'elems') e
          WHERE NOT cel._mx_math_arg_ok(e))
      ELSE cel._mx_math_arg_ok(args -> 0)
    END;
    IF NOT ok THEN
      err := format('%s() invalid single argument value', disp);
      RETURN;
    END IF;
    next_id_out := next_id + 1;
    expr := jsonb_build_object('id', next_id_out, 'k', 'call',
      'fn', fn, 'args', args, 's', cs, 'e', ce);
    RETURN;
  END IF;
  FOR i IN 0 .. n - 1 LOOP
    IF NOT cel._mx_math_arg_ok(args -> i) THEN
      err := format('%s() simple literal arguments must be numeric',
        disp);
      RETURN;
    END IF;
  END LOOP;
  IF n = 2 THEN
    next_id_out := next_id + 1;
    expr := jsonb_build_object('id', next_id_out, 'k', 'call',
      'fn', fn, 'args', args, 's', cs, 'e', ce);
    RETURN;
  END IF;
  next_id_out := next_id + 1;
  lst := jsonb_build_object('id', next_id_out, 'k', 'list',
    'elems', args, 's', cs, 'e', ce);
  next_id_out := next_id_out + 1;
  expr := jsonb_build_object('id', next_id_out, 'k', 'call',
    'fn', fn, 'args', jsonb_build_array(lst), 's', cs, 'e', ce);
END;
$$;

CREATE OR REPLACE FUNCTION cel._mx_math_least(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx_math_minmax(
    'math.@min', 'math.least', target, args, next_id);
$$;

CREATE OR REPLACE FUNCTION cel._mx_math_greatest(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT * FROM cel._mx_math_minmax(
    'math.@max', 'math.greatest', target, args, next_id);
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('least', -1, true,
   'cel._mx_math_least(jsonb,jsonb,bigint)'),
  ('greatest', -1, true,
   'cel._mx_math_greatest(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE
  SET expander = excluded.expander;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
SELECT ('math_@' || mm || suffix), 'math.@' || mm, false,
       arg_types, result_type,
       CASE WHEN mm = 'min' THEN 'cel._f_math_min(jsonb[])'
            ELSE 'cel._f_math_max(jsonb[])' END::regprocedure,
       ordinal
FROM (VALUES
  ('_double', '[{"kind":"double"}]'::jsonb, '{"kind":"double"}'::jsonb, 10),
  ('_int', '[{"kind":"int"}]'::jsonb, '{"kind":"int"}'::jsonb, 20),
  ('_uint', '[{"kind":"uint"}]'::jsonb, '{"kind":"uint"}'::jsonb, 30),
  ('_double_double',
   '[{"kind":"double"},{"kind":"double"}]'::jsonb,
   '{"kind":"double"}'::jsonb, 40),
  ('_int_int', '[{"kind":"int"},{"kind":"int"}]'::jsonb,
   '{"kind":"int"}'::jsonb, 50),
  ('_uint_uint', '[{"kind":"uint"},{"kind":"uint"}]'::jsonb,
   '{"kind":"uint"}'::jsonb, 60),
  ('_int_uint', '[{"kind":"int"},{"kind":"uint"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 70),
  ('_int_double', '[{"kind":"int"},{"kind":"double"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 80),
  ('_double_int', '[{"kind":"double"},{"kind":"int"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 90),
  ('_double_uint', '[{"kind":"double"},{"kind":"uint"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 100),
  ('_uint_int', '[{"kind":"uint"},{"kind":"int"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 110),
  ('_uint_double', '[{"kind":"uint"},{"kind":"double"}]'::jsonb,
   '{"kind":"dyn"}'::jsonb, 120),
  ('_list_double',
   '[{"kind":"list","params":[{"kind":"double"}]}]'::jsonb,
   '{"kind":"double"}'::jsonb, 130),
  ('_list_int',
   '[{"kind":"list","params":[{"kind":"int"}]}]'::jsonb,
   '{"kind":"int"}'::jsonb, 140),
  ('_list_uint',
   '[{"kind":"list","params":[{"kind":"uint"}]}]'::jsonb,
   '{"kind":"uint"}'::jsonb, 150)
) v(suffix, arg_types, result_type, ordinal)
CROSS JOIN (VALUES ('min'), ('max')) m(mm)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

-- Single-argument @min/@max of a scalar are identity.
UPDATE cel.overload
SET impl = 'cel._math_ident(jsonb[])'
WHERE id IN ('math_@min_double', 'math_@min_int', 'math_@min_uint',
             'math_@max_double', 'math_@max_int', 'math_@max_uint');

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('math_ceil_double', 'math.ceil', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_ceil(jsonb[])', 10),
  ('math_floor_double', 'math.floor', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_floor(jsonb[])', 10),
  ('math_round_double', 'math.round', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_round(jsonb[])', 10),
  ('math_trunc_double', 'math.trunc', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_trunc(jsonb[])', 10),
  ('math_isInf_double', 'math.isInf', false,
   '[{"kind": "double"}]', '{"kind": "bool"}',
   'cel._f_math_isinf(jsonb[])', 10),
  ('math_isNaN_double', 'math.isNaN', false,
   '[{"kind": "double"}]', '{"kind": "bool"}',
   'cel._f_math_isnan(jsonb[])', 10),
  ('math_isFinite_double', 'math.isFinite', false,
   '[{"kind": "double"}]', '{"kind": "bool"}',
   'cel._f_math_isfinite(jsonb[])', 10),
  ('math_abs_double', 'math.abs', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_abs(jsonb[])', 10),
  ('math_abs_int', 'math.abs', false,
   '[{"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_abs(jsonb[])', 20),
  ('math_abs_uint', 'math.abs', false,
   '[{"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_abs(jsonb[])', 30),
  ('math_sign_double', 'math.sign', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_sign(jsonb[])', 10),
  ('math_sign_int', 'math.sign', false,
   '[{"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_sign(jsonb[])', 20),
  ('math_sign_uint', 'math.sign', false,
   '[{"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_sign(jsonb[])', 30),
  ('math_sqrt_double', 'math.sqrt', false,
   '[{"kind": "double"}]', '{"kind": "double"}',
   'cel._f_math_sqrt(jsonb[])', 10),
  ('math_sqrt_int', 'math.sqrt', false,
   '[{"kind": "int"}]', '{"kind": "double"}',
   'cel._f_math_sqrt(jsonb[])', 20),
  ('math_sqrt_uint', 'math.sqrt', false,
   '[{"kind": "uint"}]', '{"kind": "double"}',
   'cel._f_math_sqrt(jsonb[])', 30),
  ('math_bitAnd_int_int', 'math.bitAnd', false,
   '[{"kind": "int"}, {"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_bitand(jsonb[])', 10),
  ('math_bitAnd_uint_uint', 'math.bitAnd', false,
   '[{"kind": "uint"}, {"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_bitand(jsonb[])', 20),
  ('math_bitOr_int_int', 'math.bitOr', false,
   '[{"kind": "int"}, {"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_bitor(jsonb[])', 10),
  ('math_bitOr_uint_uint', 'math.bitOr', false,
   '[{"kind": "uint"}, {"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_bitor(jsonb[])', 20),
  ('math_bitXor_int_int', 'math.bitXor', false,
   '[{"kind": "int"}, {"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_bitxor(jsonb[])', 10),
  ('math_bitXor_uint_uint', 'math.bitXor', false,
   '[{"kind": "uint"}, {"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_bitxor(jsonb[])', 20),
  ('math_bitNot_int_int', 'math.bitNot', false,
   '[{"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_bitnot(jsonb[])', 10),
  ('math_bitNot_uint_uint', 'math.bitNot', false,
   '[{"kind": "uint"}]', '{"kind": "uint"}',
   'cel._f_math_bitnot(jsonb[])', 20),
  ('math_bitShiftLeft_int_int', 'math.bitShiftLeft', false,
   '[{"kind": "int"}, {"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_shl(jsonb[])', 10),
  ('math_bitShiftLeft_uint_int', 'math.bitShiftLeft', false,
   '[{"kind": "uint"}, {"kind": "int"}]', '{"kind": "uint"}',
   'cel._f_math_shl(jsonb[])', 20),
  ('math_bitShiftRight_int_int', 'math.bitShiftRight', false,
   '[{"kind": "int"}, {"kind": "int"}]', '{"kind": "int"}',
   'cel._f_math_shr(jsonb[])', 10),
  ('math_bitShiftRight_uint_int', 'math.bitShiftRight', false,
   '[{"kind": "uint"}, {"kind": "int"}]', '{"kind": "uint"}',
   'cel._f_math_shr(jsonb[])', 20)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'math', 'overload', id FROM cel.overload
WHERE function LIKE 'math.%'
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('math', 'macro', 'least/-1/1'),
  ('math', 'macro', 'greatest/-1/1')
ON CONFLICT DO NOTHING;

COMMIT;

-- ---- sql/140_ext_lists.sql ----

-- The lists extension (cel-go ext/lists.go at the pinned v0.32.0):
-- slice, flatten, sort, sortBy (macro over @sortByAssociatedKeys),
-- lists.range, reverse, distinct. Registered under the 'lists' env.

BEGIN;

CREATE OR REPLACE FUNCTION cel._list_val(elems jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'list', 'v', elems);
$$;

CREATE OR REPLACE FUNCTION cel._f_list_slice(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  l jsonb := args[1] -> 'v';
  a numeric := (args[2] ->> 'v')::numeric;
  b numeric := (args[3] ->> 'v')::numeric;
  n int := jsonb_array_length(l);
  o jsonb := '[]'::jsonb;
  i int;
BEGIN
  IF a < 0 OR b < 0 THEN
    RETURN cel._err(format('cannot slice(%s, %s), negative indexes '
      || 'not supported', a, b));
  END IF;
  IF a > b THEN
    RETURN cel._err(format('cannot slice(%s, %s), start index must '
      || 'be less than or equal to end index', a, b));
  END IF;
  IF n < b THEN
    RETURN cel._err(format('cannot slice(%s, %s), list is length %s',
      a, b, n));
  END IF;
  FOR i IN a::int .. b::int - 1 LOOP
    o := o || jsonb_build_array(l -> i);
  END LOOP;
  RETURN cel._list_val(o);
END;
$$;

CREATE OR REPLACE FUNCTION cel._list_flatten(l jsonb, depth numeric)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  o jsonb := '[]'::jsonb;
  e jsonb;
  i int;
BEGIN
  FOR i IN 0 .. jsonb_array_length(l) - 1 LOOP
    e := l -> i;
    IF e ->> '@t' = 'list' AND depth > 0 THEN
      o := o || cel._list_flatten(e -> 'v', depth - 1);
    ELSE
      o := o || jsonb_build_array(e);
    END IF;
  END LOOP;
  RETURN o;
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_list_flatten(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  depth numeric := CASE WHEN cardinality(args) > 1
                        THEN (args[2] ->> 'v')::numeric ELSE 1 END;
BEGIN
  IF depth < 0 THEN
    RETURN cel._err('level must be non-negative');
  END IF;
  RETURN cel._list_val(cel._list_flatten(args[1] -> 'v', depth));
END;
$$;

-- sort()/sortBy() core: reorder list by the sort order of keys,
-- which must share one comparable runtime type (lists.go:539).
CREATE OR REPLACE FUNCTION cel._f_list_sort_by_keys(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  l    jsonb := args[1] -> 'v';
  ks   jsonb := args[2] -> 'v';
  n    int := jsonb_array_length(l);
  kt   text;
  o    jsonb := '[]'::jsonb;
  idx  int[];
  i    int;
  j    int;
  tmp  int;
  c    jsonb;
BEGIN
  IF n <> jsonb_array_length(ks) THEN
    RETURN cel._err(format('@sortByAssociatedKeys() expected a list '
      || 'of the same size as the associated keys list, but got %s '
      || 'and %s elements respectively',
      n, jsonb_array_length(ks)));
  END IF;
  IF n = 0 THEN
    RETURN args[1];
  END IF;
  kt := ks -> 0 ->> '@t';
  IF kt NOT IN ('int', 'uint', 'double', 'bool', 'duration',
                'timestamp', 'string', 'bytes') THEN
    RETURN cel._err('list elements must be comparable');
  END IF;
  idx := '{}';
  FOR i IN 0 .. n - 1 LOOP
    IF (ks -> i ->> '@t') <> kt THEN
      RETURN cel._err('list elements must have the same type');
    END IF;
    idx := idx || i;
  END LOOP;
  -- Insertion sort on indices: stable, and adequate for
  -- conformance-sized lists.
  FOR i IN 2 .. n LOOP
    j := i;
    WHILE j > 1 LOOP
      c := cel._compare(ks -> idx[j], ks -> idx[j - 1]);
      IF cel._is_error(c) THEN
        RETURN c;
      END IF;
      EXIT WHEN (c ->> 'v')::int <> -1;
      tmp := idx[j];
      idx[j] := idx[j - 1];
      idx[j - 1] := tmp;
      j := j - 1;
    END LOOP;
  END LOOP;
  FOR i IN 1 .. n LOOP
    o := o || jsonb_build_array(l -> idx[i]);
  END LOOP;
  RETURN cel._list_val(o);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_list_sort(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._f_list_sort_by_keys(ARRAY[args[1], args[1]]);
$$;

CREATE OR REPLACE FUNCTION cel._f_lists_range(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  n numeric := (args[1] ->> 'v')::numeric;
BEGIN
  IF n < 0 THEN
    RETURN cel._err(format(
      'lists.range: size must be non-negative, got %s', n));
  END IF;
  -- cel-go's conformance default limit.
  IF n > 1000000 THEN
    RETURN cel._err(format(
      'lists.range: size %s exceeds maximum allowed (1000000)', n));
  END IF;
  RETURN cel._list_val(coalesce((
    SELECT jsonb_agg(cel._int_val(i))
    FROM generate_series(0, n::int - 1) i), '[]'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_list_reverse(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._list_val(coalesce((
    SELECT jsonb_agg(e ORDER BY o DESC)
    FROM jsonb_array_elements(args[1] -> 'v')
      WITH ORDINALITY q(e, o)), '[]'::jsonb));
$$;

CREATE OR REPLACE FUNCTION cel._f_list_distinct(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  l jsonb := args[1] -> 'v';
  o jsonb := '[]'::jsonb;
  i int;
  j int;
  seen boolean;
BEGIN
  FOR i IN 0 .. jsonb_array_length(l) - 1 LOOP
    seen := false;
    FOR j IN 0 .. jsonb_array_length(o) - 1 LOOP
      IF cel._equal(l -> i, o -> j) THEN
        seen := true;
        EXIT;
      END IF;
    END LOOP;
    IF NOT seen THEN
      o := o || jsonb_build_array(l -> i);
    END IF;
  END LOOP;
  RETURN cel._list_val(o);
END;
$$;

-- sortBy(e, keyExpr) expands to a bind-style comprehension
-- (lists.go:594): fold the target into @__sortBy_input__, then call
-- @sortByAssociatedKeys with the mapped keys.
CREATE OR REPLACE FUNCTION cel._mx_sort_by(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  cs jsonb := target -> 's';
  ce jsonb := target -> 'e';
  id bigint := next_id;
  vref jsonb;
  mapc record;
  callx jsonb;
  init jsonb;
  cond jsonb;
  itv record;
BEGIN
  IF target ->> 'k' NOT IN
     ('list', 'select', 'ident', 'comp', 'call') THEN
    err := 'sortBy can only be applied to a list, identifier, '
        || 'comprehension, call or select expression';
    RETURN;
  END IF;
  SELECT * INTO itv FROM cel._mx_itervar(args -> 0);
  IF itv.err IS NOT NULL THEN
    err := itv.err;
    RETURN;
  END IF;
  id := id + 1;
  vref := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@__sortBy_input__', 's', cs, 'e', ce);
  SELECT * INTO mapc FROM cel._mx_fold(
    'map', vref, args -> 0 ->> 'name', NULL, args -> 1, id);
  IF mapc.err IS NOT NULL THEN
    err := mapc.err;
    RETURN;
  END IF;
  id := mapc.next_id_out + 1;
  vref := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@__sortBy_input__', 's', cs, 'e', ce);
  id := id + 1;
  callx := jsonb_build_object('id', id, 'k', 'call',
    'fn', '@sortByAssociatedKeys', 'target', vref,
    'args', jsonb_build_array(mapc.expr), 's', cs, 'e', ce);
  id := id + 1;
  init := jsonb_build_object('id', id, 'k', 'list',
    'elems', '[]'::jsonb, 's', cs, 'e', ce);
  id := id + 1;
  cond := jsonb_build_object('id', id, 'k', 'lit',
    'v', jsonb_build_object('@t', 'bool', 'v', false),
    's', cs, 'e', ce);
  id := id + 1;
  vref := jsonb_build_object('id', id, 'k', 'ident',
    'name', '@__sortBy_input__', 's', cs, 'e', ce);
  id := id + 1;
  expr := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', init, 'iter', '#unused', 'iter2', '',
    'accu', '@__sortBy_input__',
    'init', target, 'cond', cond, 'step', vref, 'result', callx,
    's', cs, 'e', ce);
  next_id_out := id;
END;
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('sortBy', 2, true, 'cel._mx_sort_by(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE
  SET expander = excluded.expander;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('list_slice', 'slice', true,
   '[{"kind": "list", "params": [{"kind": "param", "name": "T"}]},
     {"kind": "int"}, {"kind": "int"}]',
   '{"kind": "list", "params": [{"kind": "param", "name": "T"}]}',
   'cel._f_list_slice(jsonb[])', 10),
  ('list_flatten', 'flatten', true,
   '[{"kind": "list", "params": [{"kind": "list",
      "params": [{"kind": "param", "name": "T"}]}]}]',
   '{"kind": "list", "params": [{"kind": "param", "name": "T"}]}',
   'cel._f_list_flatten(jsonb[])', 10),
  ('list_flatten_int', 'flatten', true,
   '[{"kind": "list", "params": [{"kind": "dyn"}]},
     {"kind": "int"}]',
   '{"kind": "list", "params": [{"kind": "dyn"}]}',
   'cel._f_list_flatten(jsonb[])', 20),
  ('lists_range', 'lists.range', false,
   '[{"kind": "int"}]',
   '{"kind": "list", "params": [{"kind": "int"}]}',
   'cel._f_lists_range(jsonb[])', 10),
  ('list_reverse', 'reverse', true,
   '[{"kind": "list", "params": [{"kind": "param", "name": "T"}]}]',
   '{"kind": "list", "params": [{"kind": "param", "name": "T"}]}',
   'cel._f_list_reverse(jsonb[])', 20),
  ('list_distinct', 'distinct', true,
   '[{"kind": "list", "params": [{"kind": "param", "name": "T"}]}]',
   '{"kind": "list", "params": [{"kind": "param", "name": "T"}]}',
   'cel._f_list_distinct(jsonb[])', 10)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

-- sort() and @sortByAssociatedKeys(): one row per comparable element
-- type, sharing an impl (lists.go templatedOverloads).
INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
SELECT 'list_' || tn || '_sort', 'sort', true,
       jsonb_build_array(jsonb_build_object(
         'kind', 'list', 'params', jsonb_build_array(t))),
       jsonb_build_object(
         'kind', 'list', 'params', jsonb_build_array(t)),
       'cel._f_list_sort(jsonb[])', ord
FROM (VALUES
  ('int', '{"kind":"int"}'::jsonb, 10),
  ('uint', '{"kind":"uint"}'::jsonb, 20),
  ('double', '{"kind":"double"}'::jsonb, 30),
  ('bool', '{"kind":"bool"}'::jsonb, 40),
  ('google.protobuf.Duration', '{"kind":"duration"}'::jsonb, 50),
  ('google.protobuf.Timestamp', '{"kind":"timestamp"}'::jsonb, 60),
  ('string', '{"kind":"string"}'::jsonb, 70),
  ('bytes', '{"kind":"bytes"}'::jsonb, 80)
) v(tn, t, ord)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
SELECT 'list_' || tn || '_sortByAssociatedKeys',
       '@sortByAssociatedKeys', true,
       jsonb_build_array(
         '{"kind":"list","params":[{"kind":"param","name":"T"}]}'
           ::jsonb,
         jsonb_build_object(
           'kind', 'list', 'params', jsonb_build_array(t))),
       '{"kind":"list","params":[{"kind":"param","name":"T"}]}'
         ::jsonb,
       'cel._f_list_sort_by_keys(jsonb[])', ord
FROM (VALUES
  ('int', '{"kind":"int"}'::jsonb, 10),
  ('uint', '{"kind":"uint"}'::jsonb, 20),
  ('double', '{"kind":"double"}'::jsonb, 30),
  ('bool', '{"kind":"bool"}'::jsonb, 40),
  ('google.protobuf.Duration', '{"kind":"duration"}'::jsonb, 50),
  ('google.protobuf.Timestamp', '{"kind":"timestamp"}'::jsonb, 60),
  ('string', '{"kind":"string"}'::jsonb, 70),
  ('bytes', '{"kind":"bytes"}'::jsonb, 80)
) v(tn, t, ord)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'lists', 'overload', id FROM cel.overload
WHERE id IN ('list_slice', 'list_flatten', 'list_flatten_int',
             'lists_range', 'list_reverse', 'list_distinct')
   OR id LIKE 'list\_%\_sort'
   OR id LIKE 'list\_%\_sortByAssociatedKeys'
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('lists', 'macro', 'sortBy/2/1')
ON CONFLICT DO NOTHING;

COMMIT;

-- ---- sql/150_ext_encoders.sql ----

-- The encoders extension (cel-go ext/encoders.go at the pinned
-- v0.32.0): base64.encode / base64.decode. Registered under the
-- 'encoders' env.

BEGIN;

-- Go accepts both padded and raw (unpadded) standard base64
-- (encoders.go:143-150); Postgres decode requires padding, so pad
-- first.
CREATE OR REPLACE FUNCTION cel._f_base64_decode(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  s text := args[1] ->> 'v';
BEGIN
  IF length(s) % 4 <> 0 THEN
    s := rpad(s, length(s) + 4 - length(s) % 4, '=');
  END IF;
  RETURN jsonb_build_object('@t', 'bytes', 'v',
    translate(encode(decode(s, 'base64'), 'base64'),
      E'\n', ''));
EXCEPTION WHEN OTHERS THEN
  RETURN cel._err(format('illegal base64 data in %s',
    quote_literal(args[1] ->> 'v')));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_base64_encode(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v',
    translate(encode(decode(args[1] ->> 'v', 'base64'), 'base64'),
      E'\n', ''));
$$;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('base64_decode_string', 'base64.decode', false,
   '[{"kind": "string"}]', '{"kind": "bytes"}',
   'cel._f_base64_decode(jsonb[])', 10),
  ('base64_encode_bytes', 'base64.encode', false,
   '[{"kind": "bytes"}]', '{"kind": "string"}',
   'cel._f_base64_encode(jsonb[])', 10)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('encoders', 'overload', 'base64_decode_string'),
  ('encoders', 'overload', 'base64_encode_bytes')
ON CONFLICT DO NOTHING;

COMMIT;

-- ---- sql/160_ext_bindings.sql ----

-- The bindings extension (cel-go ext/bindings.go at the pinned
-- v0.32.0): the cel.bind(var, init, expr) macro, expanding to the
-- bind-style comprehension (empty range, accumulator = the bound
-- variable). Registered under the 'bindings' env.

BEGIN;

CREATE OR REPLACE FUNCTION cel._mx_cel_bind(
  target jsonb, args jsonb, next_id bigint,
  OUT expr jsonb, OUT next_id_out bigint, OUT err text
)
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  cs jsonb := target -> 's';
  ce jsonb := target -> 'e';
  id bigint := next_id;
  nm text;
  init jsonb;
  cond jsonb;
  step jsonb;
BEGIN
  next_id_out := next_id;
  -- Decline unless the receiver is the cel namespace.
  IF target ->> 'k' <> 'ident'
     OR ltrim(target ->> 'name', '.') <> 'cel' THEN
    RETURN;
  END IF;
  IF args -> 0 ->> 'k' <> 'ident' THEN
    err := 'cel.bind() variable names must be simple identifiers';
    RETURN;
  END IF;
  nm := args -> 0 ->> 'name';
  id := id + 1;
  init := jsonb_build_object('id', id, 'k', 'list',
    'elems', '[]'::jsonb, 's', cs, 'e', ce);
  id := id + 1;
  cond := jsonb_build_object('id', id, 'k', 'lit',
    'v', jsonb_build_object('@t', 'bool', 'v', false),
    's', cs, 'e', ce);
  id := id + 1;
  step := jsonb_build_object('id', id, 'k', 'ident',
    'name', nm, 's', cs, 'e', ce);
  id := id + 1;
  expr := jsonb_build_object(
    'id', id, 'k', 'comp',
    'range', init, 'iter', '#unused', 'iter2', '',
    'accu', nm,
    'init', args -> 1, 'cond', cond, 'step', step,
    'result', args -> 2, 's', cs, 'e', ce);
  next_id_out := id;
END;
$$;

INSERT INTO cel.macro (name, arity, member, expander) VALUES
  ('bind', 3, true, 'cel._mx_cel_bind(jsonb,jsonb,bigint)')
ON CONFLICT (name, arity, member) DO UPDATE
  SET expander = excluded.expander;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('bindings', 'macro', 'bind/3/1')
ON CONFLICT DO NOTHING;

COMMIT;

-- ---- sql/170_ext_network.sql ----

-- The network extension (cel-go ext/network.go at the pinned
-- v0.32.0): net.IP / net.CIDR opaque types over Postgres inet
-- machinery, 21 overloads. Registered under the 'network' env.
--
-- Values store canonical text: net.IP as the canonical address
-- string, net.CIDR as '<canonical addr>/<bits>' with host bits
-- preserved (netip.Prefix keeps them; masked() is explicit).
-- Structural payload identity in cel._equal then matches cel-go's
-- equality.
--
-- Parsing is Go netip's strictness, which Postgres inet does not
-- share: no leading zeros in IPv4 octets, no partial addresses, no
-- zone suffixes, no IPv4-mapped IPv6, and a CIDR requires an
-- explicit /bits.

BEGIN;

-- Strict address parse. Returns the canonical text or NULL when the
-- input is not a valid address under netip.ParseAddr rules.
CREATE OR REPLACE FUNCTION cel._net_parse_ip(s text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v inet;
BEGIN
  IF s ~ '%' THEN
    RETURN NULL;  -- zones are not allowed
  END IF;
  IF position(':' IN s) = 0 THEN
    -- IPv4: exactly four octets, 0-255, no leading zeros.
    IF s !~ '^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$' THEN
      RETURN NULL;
    END IF;
    IF EXISTS (
      SELECT FROM unnest(string_to_array(s, '.')) o
      WHERE o::int > 255) THEN
      RETURN NULL;
    END IF;
    RETURN s;
  END IF;
  BEGIN
    v := s::inet;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
  IF family(v) <> 6 OR masklen(v) <> 128 THEN
    RETURN NULL;
  END IF;
  -- IPv4-mapped IPv6: the dotted text form is rejected, the hex
  -- form parses and unmaps to the IPv4 address (corpus
  -- network_ext/parse_invalid_ipv4_in_ipv6 vs ipv4_equals_ipv6 --
  -- cel-go v0.32.0 rejects both and does not run this file in its
  -- own conformance; the corpus is the authority).
  IF v <<= inet '::ffff:0.0.0.0/96' THEN
    IF position('.' IN s) > 0 THEN
      RETURN NULL;
    END IF;
    RETURN (regexp_match(host(v), '([^:]*)$'))[1];
  END IF;
  RETURN host(v);
END;
$$;

-- Strict prefix parse. Returns canonical '<addr>/<bits>' or NULL.
CREATE OR REPLACE FUNCTION cel._net_parse_cidr(s text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  addr text;
  bits text;
  a    text;
BEGIN
  IF s !~ '^[^/]+/[^/]+$' THEN
    RETURN NULL;
  END IF;
  addr := split_part(s, '/', 1);
  bits := split_part(s, '/', 2);
  a := cel._net_parse_ip(addr);
  IF a IS NULL THEN
    RETURN NULL;
  END IF;
  IF bits !~ '^(0|[1-9]\d{0,2})$' THEN
    RETURN NULL;
  END IF;
  IF position(':' IN a) > 0 THEN
    IF bits::int > 128 THEN
      RETURN NULL;
    END IF;
  ELSIF bits::int > 32 THEN
    RETURN NULL;
  END IF;
  RETURN a || '/' || bits::int;
END;
$$;

CREATE OR REPLACE FUNCTION cel._net_ip_val(t text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'opaque', 'type', 'net.IP',
    'v', t);
$$;

CREATE OR REPLACE FUNCTION cel._net_cidr_val(t text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'opaque', 'type', 'net.CIDR',
    'v', t);
$$;

CREATE OR REPLACE FUNCTION cel._f_net_string_to_ip(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a text := cel._net_parse_ip(args[1] ->> 'v');
BEGIN
  IF a IS NULL THEN
    RETURN cel._err(format(
      'IP Address %s parse error during conversion from string',
      quote_literal(args[1] ->> 'v')));
  END IF;
  RETURN cel._net_ip_val(a);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_net_string_to_cidr(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a text := cel._net_parse_cidr(args[1] ->> 'v');
BEGIN
  IF a IS NULL THEN
    RETURN cel._err(format(
      'CIDR %s parse error during conversion from string',
      quote_literal(args[1] ->> 'v')));
  END IF;
  RETURN cel._net_cidr_val(a);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_net_is_ip(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    cel._net_parse_ip(args[1] ->> 'v') IS NOT NULL);
$$;

CREATE OR REPLACE FUNCTION cel._f_net_is_cidr(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    cel._net_parse_cidr(args[1] ->> 'v') IS NOT NULL);
$$;

-- isCanonical: parses and compares against the canonical rendering
-- (RFC 5952 for IPv6 -- Postgres inet output follows it).
CREATE OR REPLACE FUNCTION cel._f_net_ip_is_canonical(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a text := cel._net_parse_ip(args[1] ->> 'v');
BEGIN
  IF a IS NULL THEN
    RETURN cel._err(format(
      'IP Address %s parse error during conversion from string',
      quote_literal(args[1] ->> 'v')));
  END IF;
  RETURN cel._bool_val(a = (args[1] ->> 'v'));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_net_ip_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v', args[1] ->> 'v');
$$;

CREATE OR REPLACE FUNCTION cel._f_net_cidr_to_string(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'string', 'v', args[1] ->> 'v');
$$;

CREATE OR REPLACE FUNCTION cel._f_net_ip_family(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(family((args[1] ->> 'v')::inet));
$$;

CREATE OR REPLACE FUNCTION cel._f_net_cidr_ip(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._net_ip_val(host((args[1] ->> 'v')::inet));
$$;

CREATE OR REPLACE FUNCTION cel._f_net_cidr_masked(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._net_cidr_val(
    host(network((args[1] ->> 'v')::inet)) || '/'
    || masklen((args[1] ->> 'v')::inet));
$$;

CREATE OR REPLACE FUNCTION cel._f_net_cidr_prefix_length(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._int_val(masklen((args[1] ->> 'v')::inet));
$$;

CREATE OR REPLACE FUNCTION cel._f_net_cidr_is_mask(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    host((args[1] ->> 'v')::inet)
      = host(network((args[1] ->> 'v')::inet)));
$$;

-- Containment: families must match (netip returns false, never an
-- error, on family mismatch), then Postgres's network containment
-- compares the masked prefixes.
CREATE OR REPLACE FUNCTION cel._net_contains(
  parent inet, child inet, cidr_child boolean
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
BEGIN
  IF family(parent) <> family(child) THEN
    RETURN false;
  END IF;
  IF cidr_child AND masklen(child) < masklen(parent) THEN
    RETURN false;
  END IF;
  RETURN network(child) <<= network(parent)
      OR network(child) = network(parent);
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_net_contains_ip(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a text;
BEGIN
  IF args[2] ->> '@t' = 'string' THEN
    a := cel._net_parse_ip(args[2] ->> 'v');
    IF a IS NULL THEN
      RETURN cel._err(format(
        'IP Address %s parse error during conversion from string',
        quote_literal(args[2] ->> 'v')));
    END IF;
  ELSE
    a := args[2] ->> 'v';
  END IF;
  RETURN cel._bool_val(cel._net_contains(
    (args[1] ->> 'v')::inet, a::inet, false));
END;
$$;

CREATE OR REPLACE FUNCTION cel._f_net_contains_cidr(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  a text;
BEGIN
  IF args[2] ->> '@t' = 'string' THEN
    a := cel._net_parse_cidr(args[2] ->> 'v');
    IF a IS NULL THEN
      RETURN cel._err(format(
        'CIDR %s parse error during conversion from string',
        quote_literal(args[2] ->> 'v')));
    END IF;
  ELSE
    a := args[2] ->> 'v';
  END IF;
  RETURN cel._bool_val(cel._net_contains(
    (args[1] ->> 'v')::inet, a::inet, true));
END;
$$;

-- Address classification (Go net/netip semantics).
CREATE OR REPLACE FUNCTION cel._f_net_ip_is_loopback(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    CASE WHEN family((args[1] ->> 'v')::inet) = 4
      THEN (args[1] ->> 'v')::inet <<= inet '127.0.0.0/8'
      ELSE (args[1] ->> 'v')::inet = inet '::1'
    END);
$$;

CREATE OR REPLACE FUNCTION cel._f_net_ip_is_unspecified(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    (args[1] ->> 'v')::inet = inet '0.0.0.0'
    OR (args[1] ->> 'v')::inet = inet '::');
$$;

CREATE OR REPLACE FUNCTION cel._f_net_ip_is_ll_unicast(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    CASE WHEN family((args[1] ->> 'v')::inet) = 4
      THEN (args[1] ->> 'v')::inet <<= inet '169.254.0.0/16'
      ELSE (args[1] ->> 'v')::inet <<= inet 'fe80::/10'
    END);
$$;

-- Link-local multicast: 224.0.0.0/24, or IPv6 ffX2::/16 (first byte
-- 0xff, low nibble of the second byte 0x2 -- the flags nibble is
-- arbitrary, so mask with ff0f::).
CREATE OR REPLACE FUNCTION cel._f_net_ip_is_ll_mcast(args jsonb[])
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
  SELECT cel._bool_val(
    CASE WHEN family((args[1] ->> 'v')::inet) = 4
      THEN (args[1] ->> 'v')::inet <<= inet '224.0.0.0/24'
      ELSE ((args[1] ->> 'v')::inet & inet 'ff0f::')
             = inet 'ff02::'
    END);
$$;

-- Global unicast: everything except unspecified, loopback,
-- multicast, link-local unicast, and the IPv4 broadcast address.
CREATE OR REPLACE FUNCTION cel._f_net_ip_is_global_ucast(args jsonb[])
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = cel, pg_temp
AS $$
DECLARE
  v inet := (args[1] ->> 'v')::inet;
BEGIN
  IF family(v) = 4 THEN
    RETURN cel._bool_val(NOT (
      v = inet '0.0.0.0'
      OR v = inet '255.255.255.255'
      OR v <<= inet '127.0.0.0/8'
      OR v <<= inet '169.254.0.0/16'
      OR v <<= inet '224.0.0.0/4'));
  END IF;
  RETURN cel._bool_val(NOT (
    v = inet '::'
    OR v = inet '::1'
    OR v <<= inet 'fe80::/10'
    OR v <<= inet 'ff00::/8'));
END;
$$;

-- Registry rows --------------------------------------------------------

INSERT INTO cel.type (name, kind) VALUES
  ('net.IP', '{"kind": "opaque", "name": "net.IP"}'),
  ('net.CIDR', '{"kind": "opaque", "name": "net.CIDR"}')
ON CONFLICT (name) DO UPDATE SET kind = excluded.kind;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('string_to_ip', 'ip', false,
   '[{"kind": "string"}]',
   '{"kind": "opaque", "name": "net.IP"}',
   'cel._f_net_string_to_ip(jsonb[])', 10),
  ('cidr_ip', 'ip', true,
   '[{"kind": "opaque", "name": "net.CIDR"}]',
   '{"kind": "opaque", "name": "net.IP"}',
   'cel._f_net_cidr_ip(jsonb[])', 20),
  ('string_to_cidr', 'cidr', false,
   '[{"kind": "string"}]',
   '{"kind": "opaque", "name": "net.CIDR"}',
   'cel._f_net_string_to_cidr(jsonb[])', 10),
  ('ip_to_string', 'string', false,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "string"}',
   'cel._f_net_ip_to_string(jsonb[])', 90),
  ('cidr_to_string', 'string', false,
   '[{"kind": "opaque", "name": "net.CIDR"}]', '{"kind": "string"}',
   'cel._f_net_cidr_to_string(jsonb[])', 100),
  ('ip_family', 'family', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "int"}',
   'cel._f_net_ip_family(jsonb[])', 10),
  ('ip_is_canonical', 'ip.isCanonical', false,
   '[{"kind": "string"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_canonical(jsonb[])', 10),
  ('is_ip', 'isIP', false,
   '[{"kind": "string"}]', '{"kind": "bool"}',
   'cel._f_net_is_ip(jsonb[])', 10),
  ('is_cidr', 'isCIDR', false,
   '[{"kind": "string"}]', '{"kind": "bool"}',
   'cel._f_net_is_cidr(jsonb[])', 10),
  ('cidr_contains_ip_ip', 'containsIP', true,
   '[{"kind": "opaque", "name": "net.CIDR"},
     {"kind": "opaque", "name": "net.IP"}]',
   '{"kind": "bool"}', 'cel._f_net_contains_ip(jsonb[])', 10),
  ('cidr_contains_ip_string', 'containsIP', true,
   '[{"kind": "opaque", "name": "net.CIDR"}, {"kind": "string"}]',
   '{"kind": "bool"}', 'cel._f_net_contains_ip(jsonb[])', 20),
  ('cidr_contains_cidr', 'containsCIDR', true,
   '[{"kind": "opaque", "name": "net.CIDR"},
     {"kind": "opaque", "name": "net.CIDR"}]',
   '{"kind": "bool"}', 'cel._f_net_contains_cidr(jsonb[])', 10),
  ('cidr_contains_cidr_string', 'containsCIDR', true,
   '[{"kind": "opaque", "name": "net.CIDR"}, {"kind": "string"}]',
   '{"kind": "bool"}', 'cel._f_net_contains_cidr(jsonb[])', 20),
  ('ip_is_loopback', 'isLoopback', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_loopback(jsonb[])', 10),
  ('ip_is_unspecified', 'isUnspecified', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_unspecified(jsonb[])', 10),
  ('ip_is_link_local_unicast', 'isLinkLocalUnicast', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_ll_unicast(jsonb[])', 10),
  ('ip_is_link_local_multicast', 'isLinkLocalMulticast', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_ll_mcast(jsonb[])', 10),
  ('ip_is_global_unicast', 'isGlobalUnicast', true,
   '[{"kind": "opaque", "name": "net.IP"}]', '{"kind": "bool"}',
   'cel._f_net_ip_is_global_ucast(jsonb[])', 10),
  ('cidr_masked', 'masked', true,
   '[{"kind": "opaque", "name": "net.CIDR"}]',
   '{"kind": "opaque", "name": "net.CIDR"}',
   'cel._f_net_cidr_masked(jsonb[])', 10),
  ('cidr_prefix_length', 'prefixLength', true,
   '[{"kind": "opaque", "name": "net.CIDR"}]', '{"kind": "int"}',
   'cel._f_net_cidr_prefix_length(jsonb[])', 10),
  ('cidr_is_mask', 'isMask', true,
   '[{"kind": "opaque", "name": "net.CIDR"}]', '{"kind": "bool"}',
   'cel._f_net_cidr_is_mask(jsonb[])', 10)
ON CONFLICT (id) DO UPDATE SET
  function = excluded.function,
  member = excluded.member,
  arg_types = excluded.arg_types,
  result_type = excluded.result_type,
  impl = excluded.impl,
  ordinal = excluded.ordinal;

INSERT INTO cel.env_item (env, kind, ref)
SELECT 'network', 'overload', id FROM cel.overload
WHERE id IN (
  'string_to_ip', 'cidr_ip', 'string_to_cidr', 'ip_to_string',
  'cidr_to_string', 'ip_family', 'ip_is_canonical', 'is_ip',
  'is_cidr', 'cidr_contains_ip_ip', 'cidr_contains_ip_string',
  'cidr_contains_cidr', 'cidr_contains_cidr_string',
  'ip_is_loopback', 'ip_is_unspecified',
  'ip_is_link_local_unicast', 'ip_is_link_local_multicast',
  'ip_is_global_unicast', 'cidr_masked', 'cidr_prefix_length',
  'cidr_is_mask')
ON CONFLICT DO NOTHING;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('network', 'type', 'net.IP'),
  ('network', 'type', 'net.CIDR')
ON CONFLICT DO NOTHING;

COMMIT;

