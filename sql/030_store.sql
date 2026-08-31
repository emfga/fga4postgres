-- Stores: the conformance-isolation and namespacing unit.
--
-- A store exists so every conformance test can run in a fresh
-- namespace and so one install can serve several callers. It is not
-- multi-tenancy machinery (deliberately out of scope).
--
-- Ids are uuidv7() -- time-ordered like upstream's ULIDs, so
-- "latest" queries stay index-backed. PostgreSQL 18 is the version
-- floor precisely because uuidv7() is used natively, with no shim.

BEGIN;

CREATE TABLE IF NOT EXISTS fga.store (
  id uuid NOT NULL DEFAULT uuidv7(),
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id)
);

-- The store name is a label, not an identifier: upstream allows
-- duplicate names and resolves everything by id, so no uniqueness
-- here either.
CREATE OR REPLACE FUNCTION fga.create_store(store_name text)
RETURNS TABLE (id uuid, name text, created_at timestamptz)
LANGUAGE sql
VOLATILE
SET search_path = fga, pg_temp
AS $$
  INSERT INTO fga.store AS s (name)
  VALUES (store_name)
  RETURNING s.id, s.name, s.created_at;
$$;

-- Deleting a missing store is a no-op, matching upstream's
-- idempotent DeleteStore (measured against the pinned oracle).
--
-- Dependent rows go by explicit deletes, not FK cascades: the
-- tuple insert path stays free of
-- FK-check overhead, at the price of naming every dependent table
-- here. The tables live in later install files — fine, because
-- PL/pgSQL resolves them at call time, after the full install.
CREATE OR REPLACE FUNCTION fga.delete_store(store_id uuid)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SET search_path = fga, pg_temp
AS $$
BEGIN
  DELETE FROM fga.tuple WHERE store = store_id;
  DELETE FROM fga.model_reachable WHERE store = store_id;
  DELETE FROM fga.model_computed WHERE store = store_id;
  DELETE FROM fga.model_condition WHERE store = store_id;
  DELETE FROM fga.model_ttu WHERE store = store_id;
  DELETE FROM fga.model_type_restriction WHERE store = store_id;
  DELETE FROM fga.model_relation WHERE store = store_id;
  DELETE FROM fga.model_type WHERE store = store_id;
  DELETE FROM fga.model WHERE store = store_id;
  DELETE FROM fga.store WHERE id = store_id;
END;
$$;

COMMIT;
