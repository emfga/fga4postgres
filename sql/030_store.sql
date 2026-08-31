-- Stores: the conformance-isolation and namespacing unit.
--
-- A store exists so every conformance test can run in a fresh
-- namespace and so one install can serve several callers. It is not
-- multi-tenancy machinery (CLAUDE.md scope).
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
-- idempotent DeleteStore. Dependent rows (models, tuples) do not
-- exist yet; the cascade mechanism -- FKs with ON DELETE CASCADE vs
-- explicit deletes -- is decided in plan phase 1, when t.Cleanup
-- makes its cost visible to the suite.
CREATE OR REPLACE FUNCTION fga.delete_store(store_id uuid)
RETURNS void
LANGUAGE sql
VOLATILE
SET search_path = fga, pg_temp
AS $$
  DELETE FROM fga.store WHERE store.id = store_id;
$$;

COMMIT;
