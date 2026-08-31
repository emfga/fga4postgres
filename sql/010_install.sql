-- fga4postgres: OpenFGA, natively in PostgreSQL.
--
-- 010 is the first fga4postgres script on purpose: in initdb the 000
-- slot is taken by the vendored cel4postgres bundle (see compose.yaml),
-- which must install before anything here runs.

BEGIN;

CREATE SCHEMA IF NOT EXISTS fga;

CREATE TABLE IF NOT EXISTS fga.schema_version (
  version text NOT NULL
);

TRUNCATE fga.schema_version;

-- The version lives here and only here; the release build and the
-- workflows sed it out of this file rather than keeping a copy.
INSERT INTO fga.schema_version
VALUES ('0.1.0');

-- STABLE, not IMMUTABLE: it reads a table.
CREATE OR REPLACE FUNCTION fga.version()
RETURNS text
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
  SELECT version FROM fga.schema_version;
$$;

COMMIT;
