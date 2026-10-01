-- streamed_list_objects: list_objects without the result cap, one
-- row per object, mirroring upstream's StreamedListObjects (which
-- ignores the server's max-results setting).
--
-- Each row has the shape of upstream's stream message,
-- {"object": "document:<id>"}. Request shape, validation order and
-- error codes are list_objects' own: both run fga._list_objects.
-- The rows are not streamed as they are found. A PL/pgSQL search
-- produces its whole answer before the first row reaches the
-- caller, so this is "uncapped", not "incremental"; a condition
-- error therefore fails the call where upstream may have streamed
-- some objects first.

CREATE OR REPLACE FUNCTION fga.streamed_list_objects(
  store_id uuid,
  request jsonb
)
RETURNS SETOF jsonb
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT jsonb_build_object('object', o)
  FROM unnest(fga._list_objects(store_id, request, 0)) AS o;
$$;
