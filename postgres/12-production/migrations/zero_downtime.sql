-- ============================================================================
-- 12-production/migrations/zero_downtime.sql — the safe-change cookbook
-- ============================================================================
-- Run:  make sql FILE=12-production/migrations/zero_downtime.sql
--
-- The rule this file teaches: a migration is not "run once on a copy" —
-- it runs AGAINST A LIVE DATABASE with traffic, locks, and a timeout.
-- Every pattern here avoids blocking reads/writes on big tables. The
-- companion runner (migrator/main.go) shows the operational wrapper:
-- advisory lock, versioning, checksums.
--
-- The zero-downtime doctrine: EXPAND -> MIGRATE (backfill) -> CONTRACT,
-- spread across deploys. Never one big ALTER.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m12_mig CASCADE;
CREATE SCHEMA m12_mig;
SET search_path TO m12_mig, public;

-- Baseline table with live "traffic" (imagine writes during all of this):
CREATE TABLE users_t (id bigint PRIMARY KEY, email text NOT NULL);
INSERT INTO users_t SELECT g, 'u' || g || '@x.com' FROM generate_series(1, 500000) g;

-- ---------------------------------------------------------------------------
-- PATTERN 1: add a NOT NULL column WITHOUT a table lock
-- ---------------------------------------------------------------------------
-- Naive: ALTER TABLE users ADD COLUMN plan text NOT NULL DEFAULT 'free';
-- Pre-PG11 that rewrote the table; PG11+ is metadata-only for constant
-- defaults — but backfilling non-constant values still needs the pattern:
ALTER TABLE users_t ADD COLUMN plan text;                    -- instant, nullable
-- Backfill in BATCHES (locks rows briefly, never the table; resumable —
-- the procedure pattern from 11-advanced/procedures):
CREATE OR REPLACE PROCEDURE backfill_plan(batch int) LANGUAGE plpgsql AS $$
DECLARE affected int;
BEGIN
    LOOP
        UPDATE users_t SET plan = CASE WHEN id % 10 = 0 THEN 'pro' ELSE 'free' END
        WHERE plan IS NULL AND id IN (SELECT id FROM users_t WHERE plan IS NULL
                                      ORDER BY id LIMIT batch);
        GET DIAGNOSTICS affected = ROW_COUNT;
        EXIT WHEN affected = 0;
        COMMIT;                          -- release locks per batch
    END LOOP;
END $$;
CALL backfill_plan(50000);

-- Only NOW enforce NOT NULL — instant because PG12+ proves it via the
-- (already validated) constraint below; without it, SET NOT NULL scans:
ALTER TABLE users_t ADD CONSTRAINT plan_filled
    CHECK (plan IS NOT NULL) NOT VALID;                      -- instant: skips existing rows
ALTER TABLE users_t VALIDATE CONSTRAINT plan_filled;         -- scans, but SHARE UPDATE EXCLUSIVE (non-blocking)
ALTER TABLE users_t ALTER COLUMN plan SET NOT NULL;          -- instant (uses validated constraint)
ALTER TABLE users_t DROP CONSTRAINT plan_filled;

-- ---------------------------------------------------------------------------
-- PATTERN 2: indexes without blocking writes
-- ---------------------------------------------------------------------------
CREATE INDEX CONCURRENTLY users_email_lower_idx ON users_t (lower(email));
-- CONCURRENTLY: two scans + waits; writes continue. Cannot run in a tx.
-- If interrupted it leaves an INVALID index: drop and retry:
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
-- (none here; the check belongs in every migration tool)

-- ---------------------------------------------------------------------------
-- PATTERN 3: the destructive change (rename/drop) — CONTRACT, later
-- ---------------------------------------------------------------------------
-- Rename is instant but DOUBLE-WRITES during transition:
ALTER TABLE users_t RENAME COLUMN email TO email_old;
ALTER TABLE users_t ADD COLUMN email text;
-- App deploys writing BOTH columns (or a trigger backfills the new one) ...
UPDATE users_t SET email = email_old WHERE email IS NULL;  -- batched in prod!
-- ...after the old version is fully retired (weeks later):
--   ALTER TABLE users_t DROP COLUMN email_old;
-- Never drop in the same deploy that stops writing it.

-- ---------------------------------------------------------------------------
-- PATTERN 4: the migration preamble (every tool should set these)
-- ---------------------------------------------------------------------------
SET lock_timeout = '3s';       -- fail fast instead of queueing behind traffic
SET statement_timeout = '30s'; -- migrations must not run for hours silently
SHOW lock_timeout;
RESET lock_timeout; RESET statement_timeout;
-- A migration waiting hours on ACCESS EXCLUSIVE blocks EVERYTHING behind it
-- in the lock queue (06-transactions/locks.sql) — lock_timeout turns that
-- outage into a retryable failure.

-- TAKEAWAYS
-- * Expand/migrate/contract across deploys; batches with COMMIT for backfills.
-- * CHECK NOT VALID -> VALIDATE -> SET NOT NULL = no-lock constraint path.
-- * CREATE INDEX CONCURRENTLY + cleanup for INVALID leftovers.
-- * lock_timeout in every migration: fail fast, retry later.
