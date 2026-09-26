-- ============================================================================
-- 01-basics/constraints.sql — the database enforcing your invariants
-- ============================================================================
-- Run:  make sql FILE=01-basics/constraints.sql
--
-- Constraints are how the DATABASE (not application code) guarantees
-- invariants. Every constraint you skip is a future 3am data corruption
-- incident — because some script, migration, or second service WILL
-- eventually bypass your application's checks.
-- ============================================================================

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS m01_constraints CASCADE;
CREATE SCHEMA m01_constraints;
SET search_path TO m01_constraints;

-- Referenced table must exist first — FKs resolve at CREATE time.
CREATE TABLE users (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL
);
CREATE TABLE orders (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id   bigint NOT NULL REFERENCES users (id),
    status    text  NOT NULL,
    amount    numeric(10,2) NOT NULL,
    placed_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Primary key = NOT NULL + UNIQUE + a btree index to enforce it.
-- ---------------------------------------------------------------------------
INSERT INTO users (email) VALUES ('a@x.com'), ('b@x.com');
INSERT INTO orders (user_id, status, amount) VALUES (1, 'paid', 19.99);

-- UNIQUE violation — SQLSTATE 23505, the error your Go code will map to 409:
-- INSERT INTO users (email) VALUES ('a@x.com');
--   ERROR: duplicate key value violates unique constraint "users_email_key"

-- ---------------------------------------------------------------------------
-- CHECK constraints and the NULL trap
-- ---------------------------------------------------------------------------
ALTER TABLE orders ADD CONSTRAINT amount_positive CHECK (amount >= 0);

-- CHECK and NULL: a check passes when it evaluates to TRUE *or NULL*.
-- NULL >= 0 is NULL -> constraint satisfied! But amount is NOT NULL here so
-- we're safe. Where it bites people:
ALTER TABLE orders ADD COLUMN coupon text;
ALTER TABLE orders ADD CONSTRAINT coupon_format
    CHECK (coupon LIKE 'SAVE-%');
-- NULL coupon is FINE (NULL LIKE ... = NULL -> passes). To forbid NULLs
-- entirely you need NOT NULL, not a CHECK.

-- ---------------------------------------------------------------------------
-- NOT NULL, DEFAULT
-- ---------------------------------------------------------------------------
ALTER TABLE orders ALTER COLUMN status SET DEFAULT 'pending';
INSERT INTO orders (user_id, amount) VALUES (2, 5.00) RETURNING status;
-- DEFAULT applies only when the column is absent from the INSERT. It does
-- nothing for UPDATE, and adding DEFAULT later does NOT backfill old rows.

-- ---------------------------------------------------------------------------
-- Foreign keys — ON DELETE actions (memorize these)
-- ---------------------------------------------------------------------------
-- NO ACTION (default): fail if children exist (checked at statement end).
-- RESTRICT:            same, checked immediately (no deferred escape hatch).
-- CASCADE:             delete children too.
-- SET NULL / SET DEFAULT: orphan the children by nulling the FK column.

ALTER TABLE orders DROP CONSTRAINT orders_user_id_fkey;
ALTER TABLE orders ADD CONSTRAINT orders_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

-- Every FK needs an index on the CHILD column to make cascades and parent
-- deletes cheap. Postgres does NOT create it for you — a classic slow
-- DELETE incident. Check:
SELECT indexname FROM pg_indexes WHERE tablename = 'orders';
-- (none on user_id!) Add it:
CREATE INDEX orders_user_id_idx ON orders (user_id);

-- FK also takes a ROW LOCK on the referenced parent row (FOR KEY SHARE) so
-- the child can't outlive a concurrent parent delete — demonstrated in
-- 06-transactions/row_locks.sql.

-- ---------------------------------------------------------------------------
-- UNIQUE + NULL: NULLs are not equal to each other
-- ---------------------------------------------------------------------------
CREATE TABLE invites (email text, accepted_at timestamptz);
ALTER TABLE invites ADD CONSTRAINT one_pending_invite UNIQUE (email, accepted_at);
INSERT INTO invites VALUES ('x@x.com', NULL), ('x@x.com', NULL);
-- BOTH inserted! UNIQUE treats NULL != NULL, so (email, NULL) never collides.
-- PostgreSQL 15+ can close this:
--   ALTER TABLE invites ADD CONSTRAINT ... UNIQUE NULLS NOT DISTINCT (email, accepted_at);

-- ---------------------------------------------------------------------------
-- Deferrable constraints — checked at COMMIT, not per-statement
-- ---------------------------------------------------------------------------
-- Only UNIQUE, FOREIGN KEY and EXCLUSION constraints may be DEFERRABLE
-- (a CHECK or NOT NULL cannot — try it: "CHECK constraints cannot be marked
-- DEFERRABLE"). The classic use case: shifting a sort key where every row
-- transiently duplicates another.
CREATE TABLE positions (id int PRIMARY KEY, sort_key int);
ALTER TABLE positions ADD CONSTRAINT positions_sort_key_uniq
    UNIQUE (sort_key) DEFERRABLE INITIALLY IMMEDIATE;
INSERT INTO positions VALUES (1, 1), (2, 2);

BEGIN;
SET CONSTRAINTS positions_sort_key_uniq DEFERRED;
UPDATE positions SET sort_key = sort_key + 1;
-- Without DEFERRED this fails midway (1 collides with 2). With the check
-- postponed to COMMIT, the FINAL state is valid — that's all Postgres checks.
COMMIT;
SELECT * FROM positions ORDER BY sort_key;

-- TAKEAWAYS
-- * PK/UNIQUE/FK/CHECK/NOT NULL are enforced no matter which client writes.
-- * CHECK (x > 0) does NOT forbid NULL — combine with NOT NULL.
-- * UNIQUE ignores NULL duplicates unless NULLS NOT DISTINCT (PG15+).
-- * Index your FK child columns; Postgres won't do it for you.
-- * DEFERRABLE moves enforcement to COMMIT — for cyclic data, not convenience.
