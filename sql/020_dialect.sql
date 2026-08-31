-- The OpenFGA CEL dialect, as a cel4postgres extension:
-- the `ipaddress` opaque type with its
-- constructor and `in_cidr`, registered through the cel registry
-- tables exactly as cel4postgres's own extensions register —
-- never a fork. Conditions evaluate under the 'openfga' env,
-- which composes 'standard' plus these rows.
--
-- Also here: the typed-parameter conversion layer implementing
-- upstream's converter grammar for declared condition parameters
-- (internal/condition/types at the pin), and the condition
-- evaluator the read paths call. Context merge precedence is
-- measured against the pinned oracle (re-verified by
-- conformance/probe_conditions_test.go): the tuple's condition
-- context wins over the request context per key; a parameter
-- absent from the merged context only errors if the expression
-- actually references it — which matches upstream's
-- partial-evaluation behaviour without needing UNKNOWN support.

BEGIN;

INSERT INTO cel.env (name) VALUES ('openfga')
ON CONFLICT DO NOTHING;

INSERT INTO cel.type (name, kind) VALUES
  ('ipaddress', '{"kind": "opaque", "name": "ipaddress"}')
ON CONFLICT (name) DO UPDATE SET kind = excluded.kind;

CREATE OR REPLACE FUNCTION fga._cel_ipaddress_val(t text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT jsonb_build_object('@t', 'opaque', 'type', 'ipaddress',
    'v', t);
$$;

-- Constructor: ipaddress(string). Parsing reuses cel4postgres's
-- netip-strict address parser so the accepted grammar matches the
-- Go side upstream uses.
CREATE OR REPLACE FUNCTION fga._cel_string_to_ipaddress(
  args jsonb[]
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  a text := cel._net_parse_ip(args[1] ->> 'v');
BEGIN
  IF a IS NULL THEN
    RETURN cel._err(format('invalid IP address %s',
      quote_literal(args[1] ->> 'v')));
  END IF;
  RETURN fga._cel_ipaddress_val(a);
END;
$$;

-- (ipaddress).in_cidr(string). The CIDR argument follows
-- net.ParseCIDR leniency: host bits are allowed and masked away.
CREATE OR REPLACE FUNCTION fga._cel_ipaddress_in_cidr(
  args jsonb[]
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  ip inet;
  net cidr;
BEGIN
  BEGIN
    ip := (args[1] ->> 'v')::inet;
    IF position('/' IN args[2] ->> 'v') = 0 THEN
      RAISE EXCEPTION 'missing prefix';
    END IF;
    net := network((args[2] ->> 'v')::inet);
  EXCEPTION WHEN OTHERS THEN
    RETURN cel._err(format('invalid CIDR %s',
      quote_literal(args[2] ->> 'v')));
  END;
  RETURN jsonb_build_object('@t', 'bool', 'v', ip <<= net);
END;
$$;

INSERT INTO cel.overload
  (id, function, member, arg_types, result_type, impl, ordinal)
VALUES
  ('openfga_string_to_ipaddress', 'ipaddress', false,
   '[{"kind": "string"}]',
   '{"kind": "opaque", "name": "ipaddress"}',
   'fga._cel_string_to_ipaddress(jsonb[])'::regprocedure, 10),
  ('openfga_ipaddress_in_cidr', 'in_cidr', true,
   '[{"kind": "opaque", "name": "ipaddress"},
     {"kind": "string"}]',
   '{"kind": "bool"}',
   'fga._cel_ipaddress_in_cidr(jsonb[])'::regprocedure, 10)
ON CONFLICT (id) DO UPDATE
  SET arg_types = excluded.arg_types,
      result_type = excluded.result_type,
      impl = excluded.impl;

INSERT INTO cel.env_item (env, kind, ref) VALUES
  ('openfga', 'env', 'standard'),
  ('openfga', 'type', 'ipaddress'),
  ('openfga', 'overload', 'openfga_string_to_ipaddress'),
  ('openfga', 'overload', 'openfga_ipaddress_in_cidr')
ON CONFLICT DO NOTHING;

-- Dyn conversion for untyped values: google.protobuf.Struct
-- semantics, so every JSON number is a double.
CREATE OR REPLACE FUNCTION fga._json_to_cel(val jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
BEGIN
  RETURN CASE jsonb_typeof(val)
    WHEN 'string' THEN
      jsonb_build_object('@t', 'string', 'v', val)
    WHEN 'number' THEN
      jsonb_build_object('@t', 'double', 'v', val)
    WHEN 'boolean' THEN
      jsonb_build_object('@t', 'bool', 'v', val)
    WHEN 'null' THEN
      jsonb_build_object('@t', 'null', 'v', NULL)
    WHEN 'array' THEN
      jsonb_build_object('@t', 'list', 'v', coalesce(
        (SELECT jsonb_agg(fga._json_to_cel(e))
         FROM jsonb_array_elements(val) e), '[]'::jsonb))
    ELSE
      jsonb_build_object('@t', 'map', 'v', coalesce(
        (SELECT jsonb_agg(jsonb_build_object(
           'k', jsonb_build_object('@t', 'string', 'v',
                                   to_jsonb(kv.key)),
           'v', fga._json_to_cel(kv.value)))
         FROM jsonb_each(val) kv), '[]'::jsonb))
  END;
END;
$$;

-- One declared parameter's conversion (upstream's converter
-- grammar): numbers parse with integral checks for
-- int/uint, strings parse for numerics, timestamps and durations
-- are string-only, ipaddress goes through the strict parser.
-- Refusals raise in the YF class; the evaluator catches them into
-- condition-error scoping.
CREATE OR REPLACE FUNCTION fga._param_value(
  decl jsonb,
  val jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  tn text := coalesce(decl ->> 'type_name', 'TYPE_NAME_ANY');
  n numeric;
  ts timestamptz;
  frac numeric;
  total numeric := 0;
  m text[];
  rest text;
BEGIN
  CASE tn
  WHEN 'TYPE_NAME_INT' THEN
    IF jsonb_typeof(val) = 'number' THEN
      n := (val #>> '{}')::numeric;
    ELSIF jsonb_typeof(val) = 'string' THEN
      n := (val #>> '{}')::numeric;
    ELSE
      RAISE EXCEPTION 'expected an int value'
        USING ERRCODE = 'YF100';
    END IF;
    IF n <> trunc(n) OR n < -9223372036854775808
       OR n > 9223372036854775807 THEN
      RAISE EXCEPTION 'value % is not an int64', n
        USING ERRCODE = 'YF100';
    END IF;
    RETURN jsonb_build_object('@t', 'int', 'v', n);
  WHEN 'TYPE_NAME_UINT' THEN
    n := (val #>> '{}')::numeric;
    IF n <> trunc(n) OR n < 0
       OR n > 9223372036854775807 THEN
      RAISE EXCEPTION 'value % is not a uint64', n
        USING ERRCODE = 'YF100';
    END IF;
    RETURN jsonb_build_object('@t', 'uint', 'v', n);
  WHEN 'TYPE_NAME_DOUBLE' THEN
    IF jsonb_typeof(val) NOT IN ('number', 'string') THEN
      RAISE EXCEPTION 'expected a double value'
        USING ERRCODE = 'YF100';
    END IF;
    BEGIN
      RETURN jsonb_build_object('@t', 'double', 'v',
        to_jsonb(((val #>> '{}')::double precision)));
    EXCEPTION WHEN numeric_value_out_of_range
             OR invalid_text_representation THEN
      RAISE EXCEPTION 'value % is out of range for a double',
        val USING ERRCODE = 'YF100';
    END;
  WHEN 'TYPE_NAME_STRING' THEN
    IF jsonb_typeof(val) <> 'string' THEN
      RAISE EXCEPTION 'expected a string value'
        USING ERRCODE = 'YF100';
    END IF;
    RETURN jsonb_build_object('@t', 'string', 'v', val);
  WHEN 'TYPE_NAME_BOOL' THEN
    IF jsonb_typeof(val) = 'boolean' THEN
      RETURN jsonb_build_object('@t', 'bool', 'v', val);
    ELSIF val #>> '{}' IN ('true', 'false') THEN
      RETURN jsonb_build_object('@t', 'bool', 'v',
        to_jsonb((val #>> '{}')::boolean));
    END IF;
    RAISE EXCEPTION 'expected a bool value'
      USING ERRCODE = 'YF100';
  WHEN 'TYPE_NAME_TIMESTAMP' THEN
    IF jsonb_typeof(val) <> 'string' THEN
      RAISE EXCEPTION 'timestamps convert from strings only'
        USING ERRCODE = 'YF100';
    END IF;
    BEGIN
      ts := (val #>> '{}')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'invalid timestamp %', val
        USING ERRCODE = 'YF100';
    END;
    frac := extract(epoch FROM ts)::numeric;
    RETURN jsonb_build_object('@t', 'timestamp', 'v',
      jsonb_build_object(
        's', trunc(frac),
        'n', round((frac - trunc(frac)) * 1e9),
        'tz', 0));
  WHEN 'TYPE_NAME_DURATION' THEN
    IF jsonb_typeof(val) <> 'string' THEN
      RAISE EXCEPTION 'durations convert from strings only'
        USING ERRCODE = 'YF100';
    END IF;
    -- Go duration grammar: decimal numbers with ns/us/ms/s/m/h
    -- units, concatenated.
    rest := val #>> '{}';
    IF rest ~ '^-' THEN
      RAISE EXCEPTION 'invalid duration %', val
        USING ERRCODE = 'YF100';
    END IF;
    WHILE rest <> '' LOOP
      m := regexp_match(rest,
        '^(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)');
      IF m IS NULL THEN
        RAISE EXCEPTION 'invalid duration %', val
          USING ERRCODE = 'YF100';
      END IF;
      total := total + m[1]::numeric * CASE m[2]
        WHEN 'ns' THEN 1
        WHEN 'us' THEN 1e3 WHEN 'µs' THEN 1e3
        WHEN 'ms' THEN 1e6
        WHEN 's' THEN 1e9
        WHEN 'm' THEN 6e10
        ELSE 3.6e12 END;
      rest := substr(rest, length(m[1] || m[2]) + 1);
    END LOOP;
    RETURN jsonb_build_object('@t', 'duration', 'v',
      trunc(total));
  WHEN 'TYPE_NAME_IPADDRESS' THEN
    IF jsonb_typeof(val) <> 'string'
       OR cel._net_parse_ip(val #>> '{}') IS NULL THEN
      RAISE EXCEPTION 'invalid ipaddress %', val
        USING ERRCODE = 'YF100';
    END IF;
    RETURN fga._cel_ipaddress_val(
      cel._net_parse_ip(val #>> '{}'));
  WHEN 'TYPE_NAME_LIST' THEN
    IF jsonb_typeof(val) <> 'array' THEN
      RAISE EXCEPTION 'expected a list value'
        USING ERRCODE = 'YF100';
    END IF;
    RETURN jsonb_build_object('@t', 'list', 'v', coalesce(
      (SELECT jsonb_agg(fga._param_value(
         coalesce(decl -> 'generic_types' -> 0,
                  '{"type_name":"TYPE_NAME_ANY"}'), e))
       FROM jsonb_array_elements(val) e), '[]'::jsonb));
  WHEN 'TYPE_NAME_MAP' THEN
    IF jsonb_typeof(val) <> 'object' THEN
      RAISE EXCEPTION 'expected a map value'
        USING ERRCODE = 'YF100';
    END IF;
    RETURN jsonb_build_object('@t', 'map', 'v', coalesce(
      (SELECT jsonb_agg(jsonb_build_object(
         'k', jsonb_build_object('@t', 'string', 'v',
                                 to_jsonb(kv.key)),
         'v', fga._param_value(
           coalesce(decl -> 'generic_types' -> 0,
                    '{"type_name":"TYPE_NAME_ANY"}'), kv.value)))
       FROM jsonb_each(val) kv), '[]'::jsonb));
  ELSE
    RETURN fga._json_to_cel(val);
  END CASE;
END;
$$;

-- Evaluates one named condition under merged context. Never
-- raises: the caller decides what a condition error means at its
-- read site (held per read, dropped if a sibling row grants —
-- the measured scoping, re-verified by
-- conformance/probe_conditions_test.go).
CREATE OR REPLACE FUNCTION fga._eval_condition(
  store_id uuid,
  model_id uuid,
  cond_name text,
  tuple_ctx jsonb,
  req_ctx jsonb
)
RETURNS TABLE (met boolean, err text)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  cond record;
  merged jsonb;
  activation jsonb := '{}';
  p record;
  result jsonb;
  msg text;
BEGIN
  SELECT c.parameters, c.compiled_ast INTO cond
  FROM fga.model_condition c
  WHERE c.store = store_id AND c.model_id = _eval_condition.model_id
    AND c.name = cond_name;
  IF NOT FOUND OR cond.compiled_ast IS NULL THEN
    RETURN QUERY SELECT false,
      format('undefined condition ''%s''', cond_name);
    RETURN;
  END IF;

  -- Tuple context wins over request context per key (measured).
  merged := coalesce(req_ctx, '{}'::jsonb)
         || coalesce(tuple_ctx, '{}'::jsonb);

  -- Pre-scan (measured against the corpus): a declared parameter
  -- the expression references but the merged context lacks is a
  -- missing-parameters error BEFORE evaluation — upstream does
  -- not let CEL's || short-circuit around a missing operand.
  DECLARE
    missing text[] := '{}';
  BEGIN
    FOR p IN
      SELECT * FROM jsonb_each(coalesce(cond.parameters,
                                        '{}'::jsonb))
    LOOP
      IF merged ? p.key THEN
        activation := activation || jsonb_build_object(
          p.key, fga._param_value(p.value, merged -> p.key));
      ELSIF jsonb_path_exists(cond.compiled_ast,
        '$.** ? (@.k == "ident" && @.name == $n)',
        jsonb_build_object('n', p.key))
      THEN
        missing := missing || p.key;
      END IF;
    END LOOP;
    IF array_length(missing, 1) > 0 THEN
      RETURN QUERY SELECT false, format(
        'failed to evaluate relationship condition: ''%s'' - '
        'context is missing parameters ''%s''',
        cond_name, missing::text);
      RETURN;
    END IF;
  EXCEPTION WHEN SQLSTATE 'YF000' THEN
    GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT;
    RETURN QUERY SELECT false, format(
      'failed to convert context to typed parameters: %s', msg);
    RETURN;
  END;

  result := cel.eval(cond.compiled_ast, activation, 'openfga');
  IF result ->> '@t' = 'bool' THEN
    RETURN QUERY SELECT (result -> 'v')::boolean, NULL::text;
  ELSIF result ->> '@t' = 'error' THEN
    msg := result -> 'v' ->> 'msg';
    IF msg LIKE 'no such attribute%' THEN
      RETURN QUERY SELECT false, format(
        'failed to evaluate relationship condition: ''%s'' - '
        'context is missing parameters ''[%s]''',
        cond_name, substr(msg, 20));
    ELSE
      RETURN QUERY SELECT false, format(
        'failed to evaluate relationship condition: ''%s'' - %s',
        cond_name, msg);
    END IF;
  ELSE
    RETURN QUERY SELECT false, format(
      'condition ''%s'' did not evaluate to a bool', cond_name);
  END IF;
END;
$$;

COMMIT;
