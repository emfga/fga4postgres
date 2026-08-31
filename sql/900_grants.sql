-- Consumer privilege template (workspace decision 8, design doc
-- 13): two conventional NOLOGIN group roles the consumer grants
-- to their actual users.
--
--   CREATE ROLE fga_reader NOLOGIN;
--   CREATE ROLE fga_writer NOLOGIN;
--   GRANT fga_reader TO <app_query_user>;
--   GRANT fga_writer TO <app_admin_user>;
--
-- No role is created here (CREATE ROLE needs CREATEROLE, which
-- the zero-dependency claim forbids requiring); every grant sits
-- behind an existence check, so this script is a silent no-op
-- until the roles exist and re-running it is the upgrade path
-- like every other numbered script. Entry points run with
-- CALLER rights — no SECURITY DEFINER — so table privileges are
-- part of the reader surface, not a bypass of it.

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_roles WHERE rolname = 'fga_reader'
  ) THEN
    RETURN;
  END IF;

  GRANT USAGE ON SCHEMA fga TO fga_reader;
  GRANT USAGE ON SCHEMA cel TO fga_reader;

  -- Query entry points, plus every internal helper they reach
  -- (the privilege boundary is table DML, which honest
  -- volatility labels already separate — CLAUDE.md decision 9).
  GRANT EXECUTE ON FUNCTION
    fga.check(uuid, jsonb),
    fga.batch_check(uuid, jsonb),
    fga.list_objects(uuid, jsonb),
    fga.list_users(uuid, jsonb),
    fga.expand(uuid, jsonb),
    fga.read(uuid, jsonb),
    fga.version()
    TO fga_reader;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA cel TO fga_reader;

  DECLARE
    helper record;
  BEGIN
    FOR helper IN
      SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'fga' AND p.proname LIKE E'\\_%'
    LOOP
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION %s TO fga_reader',
        helper.sig);
    END LOOP;
  END;

  GRANT SELECT ON ALL TABLES IN SCHEMA fga TO fga_reader;
  GRANT SELECT ON ALL TABLES IN SCHEMA cel TO fga_reader;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_roles WHERE rolname = 'fga_writer'
  ) THEN
    RETURN;
  END IF;
  IF EXISTS (
    SELECT FROM pg_roles WHERE rolname = 'fga_reader'
  ) THEN
    GRANT fga_reader TO fga_writer;
  END IF;

  GRANT USAGE ON SCHEMA fga TO fga_writer;
  GRANT USAGE ON SCHEMA cel TO fga_writer;
  GRANT EXECUTE ON FUNCTION
    fga.write(uuid, jsonb),
    fga.write_authorization_model(uuid, jsonb),
    fga.create_store(text),
    fga.delete_store(uuid)
    TO fga_writer;
  GRANT INSERT, UPDATE, DELETE
    ON ALL TABLES IN SCHEMA fga TO fga_writer;
END;
$$;

COMMIT;
