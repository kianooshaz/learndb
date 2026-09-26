-- ============================================================================
-- 11-advanced/triggers/basics.sql — server-side reactions to data changes
-- ============================================================================
-- Run:  make sql FILE=11-advanced/triggers/basics.sql
--
-- A trigger = WHEN (event) THEN run function. The function (plpgsql) sees
-- the changing row as NEW/OLD. BEFORE can modify/cancel; AFTER reacts;
-- INSTEAD OF makes views writable. Transition tables give statement-level
-- access to ALL changed rows (perfect for audit).
--
-- Engineering stance: triggers are powerful and DANGEROUS — logic hides
-- from code review, multiplies per row, and bites during bulk loads.
-- Use for invariants the DB must own (audit, updated_at); keep business
-- logic in application code.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m11_trg CASCADE;
CREATE SCHEMA m11_trg;
SET search_path TO m11_trg, public;

CREATE TABLE posts (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title      text NOT NULL,
    body       text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted    boolean NOT NULL DEFAULT false
);
CREATE TABLE posts_audit (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    post_id   bigint NOT NULL,
    action    text NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT now(),
    old_row   jsonb, new_row jsonb
);

-- ---------------------------------------------------------------------------
-- 1. BEFORE UPDATE: the updated_at auto-touch
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();          -- mutate the row before it's written
    RETURN NEW;                       -- RETURN NULL would skip the write!
END $$;

CREATE TRIGGER posts_touch BEFORE UPDATE ON posts
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ---------------------------------------------------------------------------
-- 2. BEFORE DELETE: soft-delete interception
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION soft_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE posts SET deleted = true WHERE id = OLD.id;
    RETURN NULL;                      -- cancels the physical DELETE
END $$;

CREATE TRIGGER posts_softdel BEFORE DELETE ON posts
    FOR EACH ROW EXECUTE FUNCTION soft_delete();

-- ---------------------------------------------------------------------------
-- 3. AFTER ... FOR EACH STATEMENT + transition tables: set-based audit
-- ---------------------------------------------------------------------------
-- REFERENCING NEW TABLE/OLD TABLE exposes the whole changed set — one
-- invocation per STATEMENT, not per row (the sane way to audit bulk ops):
CREATE OR REPLACE FUNCTION audit_posts() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO posts_audit (post_id, action, old_row, new_row)
    SELECT id, TG_OP, NULL, to_jsonb(n) FROM new_table   -- transition table
    WHERE TG_OP IN ('INSERT','UPDATE');
    RETURN NULL;                                        -- AFTER: ignored
END $$;

-- (REFERENCING comes BEFORE FOR EACH in the grammar — easy to misorder)
CREATE TRIGGER posts_audit AFTER INSERT OR UPDATE ON posts
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION audit_posts();

-- ---------------------------------------------------------------------------
-- Watch them work
-- ---------------------------------------------------------------------------
INSERT INTO posts (title, body) VALUES
    ('MVCC', 'readers never block'),
    ('Vacuum', 'the garbage truck');
SELECT pg_sleep(0.01);
UPDATE posts SET body = body || '!' WHERE title = 'MVCC';
DELETE FROM posts WHERE title = 'Vacuum';      -- soft-deleted, not gone

SELECT id, title, updated_at < now() AS touched, deleted FROM posts ORDER BY id;
SELECT post_id, action, new_row ->> 'title' AS title FROM posts_audit ORDER BY id;

-- Fair warning on costs: FOR EACH ROW triggers fire per row; a 1M-row
-- UPDATE with a per-row trigger = 1M function calls. Transition tables
-- (statement-level) are the fix for set-based needs. And beware trigger
-- order: same-event triggers fire in NAME alphabetical order (rename to
-- control: a_..., b_...). Check what exists:
SELECT tgname, tgtiming, tgevent FROM pg_trigger
WHERE tgrelid = 'm11_trg.posts'::regclass AND NOT tgisinternal;

-- INSTEAD OF triggers (making views writable) and WHEN clauses:
--   CREATE TRIGGER ... INSTEAD OF INSERT ON my_view ...
--   CREATE TRIGGER ... AFTER UPDATE ON t FOR EACH ROW
--     WHEN (OLD.status IS DISTINCT FROM NEW.status) ...   -- fire condition

-- TAKEAWAYS
-- * BEFORE=modify/cancel, AFTER=react, INSTEAD OF=writable views.
-- * Transition tables make auditing SET-BASED — use them for bulk paths.
-- * Per-row triggers multiply; bulk loads should DISABLE them knowingly.
-- * Triggers own data invariants; business logic stays in the application.
