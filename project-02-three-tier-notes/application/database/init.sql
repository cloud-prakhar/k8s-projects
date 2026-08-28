-- application/database/init.sql
-- Seed schema and welcome rows for the Notes Platform.
--
-- HOW THIS RUNS: the official postgres image executes every *.sql file it finds
-- in /docker-entrypoint-initdb.d/ — but ONLY when the data directory is empty,
-- i.e. exactly once, on first initialisation. That is not a quirk to work
-- around; it is the behaviour that makes the storage lesson visible:
--
--   • No volume        → a new empty data dir every restart → this file re-runs
--                        every time and the welcome notes come back, but YOUR
--                        notes do not. Data loss dressed up as "it works".
--   • Persistent volume → the data dir survives → this file never runs again,
--                        and everything you wrote is still there.
--
-- Stage 05 mounts this file from a ConfigMap. Stage 07 gives it a volume.

CREATE TABLE IF NOT EXISTS notes (
    id         SERIAL PRIMARY KEY,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Ordering notes by creation time is the only query the API makes, so the
-- index earns its keep. It is also here to prove the ConfigMap mount worked:
-- if \d notes shows this index, the file was read.
CREATE INDEX IF NOT EXISTS notes_created_at_idx ON notes (created_at);

INSERT INTO notes (body) VALUES
    ('Welcome — this row came from the ConfigMap-mounted init.sql'),
    ('Delete the postgres pod and refresh. Which notes survive?');
