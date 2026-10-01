-- Settings: database-wide engine configuration, the counterpart of
-- upstream's server config (one install, one configuration, every
-- store).
--
--   list_objects_max_results  cap on fga.list_objects answers
--   list_users_max_results    cap on fga.list_users answers
--
-- Both default to 1000, upstream's DefaultListObjectsMaxResults and
-- DefaultListUsersMaxResults; 0 means unlimited, as it does
-- upstream. fga.streamed_list_objects is never capped, matching
-- upstream's StreamedListObjects. Change a value with a plain
-- UPDATE:
--
--   UPDATE fga.setting SET value = 0
--   WHERE name = 'list_objects_max_results';
--
-- Re-running this script (the upgrade path) inserts missing rows and
-- never resets a value already set.

CREATE TABLE IF NOT EXISTS fga.setting (
  name text NOT NULL,
  value integer NOT NULL CHECK (value >= 0),
  PRIMARY KEY (name)
);

INSERT INTO fga.setting (name, value)
VALUES ('list_objects_max_results', 1000),
       ('list_users_max_results', 1000)
ON CONFLICT (name) DO NOTHING;

-- A missing row is an install defect, not a default: refusing it
-- keeps a deleted row from silently lifting a cap.
CREATE OR REPLACE FUNCTION fga._setting_int(setting_name text)
RETURNS integer
LANGUAGE plpgsql
STABLE PARALLEL SAFE
SET search_path = fga, pg_temp
AS $$
DECLARE
  v integer;
BEGIN
  SELECT s.value INTO v FROM fga.setting s
  WHERE s.name = setting_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fga4postgres: setting ''%'' is missing',
      setting_name
      USING HINT = 'Re-run the installer to restore the defaults.';
  END IF;
  RETURN v;
END;
$$;
