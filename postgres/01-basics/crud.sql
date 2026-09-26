-- ============================================================================
-- 01-basics/crud.sql — INSERT / SELECT / UPDATE / DELETE done properly
-- ============================================================================
-- Run:  make sql FILE=01-basics/crud.sql
--
-- Covers the statement forms a backend engineer actually uses daily:
-- RETURNING (eliminating the second round trip), upserts (ON CONFLICT),
-- multi-row DML, and TRUNCATE vs DELETE.
-- ============================================================================

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS m01_crud CASCADE;
CREATE SCHEMA m01_crud;
SET search_path TO m01_crud;

CREATE TABLE users (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       text NOT NULL UNIQUE,
    plan        text NOT NULL DEFAULT 'free',
    login_count int  NOT NULL DEFAULT 0,
    last_seen   timestamptz
);

-- ---------------------------------------------------------------------------
-- INSERT
-- ---------------------------------------------------------------------------

-- Multi-row VALUES: one statement, one round trip. In Go you will instead
-- parameterize this (see 13-go-postgres) — but the SQL shape is the same.
INSERT INTO users (email, plan) VALUES
    ('ada@example.com',   'pro'),
    ('grace@example.com', 'free'),
    ('linus@example.com', 'free');

-- RETURNING: DML statements can give back rows. Without it, an app needs
-- INSERT then SELECT id WHERE email=... — two round trips and a race.
INSERT INTO users (email) VALUES ('edi@example.com') RETURNING id, plan;

-- UPDATE/DELETE support RETURNING too — e.g. "claim exactly one job":
UPDATE users SET login_count = login_count + 1
WHERE email = 'ada@example.com'
RETURNING login_count;

-- ---------------------------------------------------------------------------
-- UPSERT — ON CONFLICT
-- ---------------------------------------------------------------------------
-- "Insert, but if the UNIQUE constraint fires, do this instead."
-- The conflict target MUST be a unique index/constraint.

-- DO UPDATE (= real upsert). `excluded` = the row we TRIED to insert.
INSERT INTO users (email, plan) VALUES
    ('ada@example.com', 'enterprise'),
    ('new@example.com', 'pro')
ON CONFLICT (email) DO UPDATE
SET plan = excluded.plan          -- take the new value...
WHERE users.plan <> excluded.plan -- ...but skip no-op writes (dead tuples!)
RETURNING id, email, plan;
-- Watch the output: ada is updated, new@example.com inserted. WHERE false
-- rows are simply not written — and on conflicts matched but not updated,
-- xmax=0 (no dead tuple), keeping the table lean under churn.

-- DO NOTHING — swallow the conflict, insert the rest:
INSERT INTO users (email) VALUES ('ada@example.com'), ('zed@example.com')
ON CONFLICT (email) DO NOTHING RETURNING id, email;

-- Common mistake: ON CONFLICT without target works only when ANY unique
-- violation should trigger it, and then DO UPDATE is not allowed:
--   INSERT ... ON CONFLICT DO NOTHING;              -- legal
--   INSERT ... ON CONFLICT DO UPDATE SET ...;       -- ERROR: target required

-- ---------------------------------------------------------------------------
-- UPDATE — beware the missing WHERE
-- ---------------------------------------------------------------------------
UPDATE users SET last_seen = now() WHERE email = 'grace@example.com' RETURNING last_seen;

-- UPDATE ... FROM: set-modify join (like UPDATE + JOIN in other dialects):
CREATE TABLE plan_changes (email text, new_plan text);
INSERT INTO plan_changes VALUES ('linus@example.com', 'pro');

UPDATE users u
SET plan = c.new_plan
FROM plan_changes c
WHERE u.email = c.email
RETURNING u.id, u.plan;

-- FORGETTING WHERE updates EVERY row. In psql you'd see "UPDATE 4". Habits
-- that save careers: BEGIN; UPDATE ...; check row count; COMMIT only if sane.
BEGIN;
UPDATE users SET plan = 'free';
ROLLBACK;   -- mercy

-- ---------------------------------------------------------------------------
-- DELETE and TRUNCATE
-- ---------------------------------------------------------------------------
DELETE FROM plan_changes WHERE email = 'linus@example.com' RETURNING *;

-- TRUNCATE vs DELETE:
--   DELETE    = row-by-row DML; fires triggers; keeps dead tuples for vacuum;
--              can have WHERE; MVCC-safe with concurrent readers.
--   TRUNCATE  = deallocates whole pages in one move; no WHERE; requires
--              ACCESS EXCLUSIVE lock (blocks everything); can't run if other
--              transactions hold row locks; still transactional (rollback-able)!
TRUNCATE plan_changes;

-- TAKEAWAYS
-- * RETURNING removes read-after-write round trips (and races).
-- * ON CONFLICT DO UPDATE ... WHERE guards against useless rewrite churn.
-- * UPDATE ... FROM is the join-update; there is no UPDATE ... JOIN syntax.
-- * TRUNCATE is metadata-fast but lock-heavy; DELETE is DML and MVCC-legal.
