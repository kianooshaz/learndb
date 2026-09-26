-- ============================================================================
-- 06-transactions/serialization_failures.sql — SERIALIZABLE and write skew
-- ============================================================================
-- Run:  make sql FILE=06-transactions/serialization_failures.sql
--       (+ two-terminal protocol below — the anomaly needs real sessions)
--
-- The anomaly SERIALIZABLE exists for: WRITE SKEW. Two transactions read
-- overlapping data, make disjoint writes, and together break an invariant
-- that neither write alone violates. Neither row conflicted, so lower
-- isolation levels let both commit silently.
--
-- Classic: two on-call doctors both go off-call after each sees "the other
-- is still on" — the schedule ends up EMPTY. (Or: two bank accounts with a
-- "sum >= 0" rule, each withdraws against the sum.)
--
-- SERIALIZABLE (SSI) detects such dangerous overlap retroactively and
-- aborts one transaction: SQLSTATE 40001. Your job: RETRY.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m06_ser CASCADE;
CREATE SCHEMA m06_ser;
SET search_path TO m06_ser, public;

CREATE TABLE doctors (id int PRIMARY KEY, name text, on_call bool NOT NULL);
INSERT INTO doctors VALUES (1, 'Ada', true), (2, 'Grace', true);

-- The invariant: at least one doctor on call at all times.

-- ---------------------------------------------------------------------------
-- THE WRITE-SKEW PROTOCOL (two terminals)
-- ---------------------------------------------------------------------------
-- Both A and B:   BEGIN ISOLATION LEVEL SERIALIZABLE;
-- A:  SELECT count(*) FROM m06_ser.doctors WHERE on_call;    -- sees 2
-- B:  SELECT count(*) FROM m06_ser.doctors WHERE on_call;    -- sees 2
-- A:  UPDATE m06_ser.doctors SET on_call = false WHERE id = 1;
-- B:  UPDATE m06_ser.doctors SET on_call = false WHERE id = 2;
-- A:  COMMIT;      -- succeeds
-- B:  COMMIT;      -- ERROR: could not serialize access due to read/write
--                  -- dependencies among transactions  (SQLSTATE 40001)
-- Check: SELECT * FROM m06_ser.doctors;  -- exactly one went off-call.
--
-- Repeat with both at REPEATABLE READ instead: BOTH commits succeed and the
-- invariant is VIOLATED (nobody on call) — no error, just a corrupted
-- schedule. THAT silent case is what SERIALIZABLE sells you.

UPDATE doctors SET on_call = true;   -- reset for replays

-- ---------------------------------------------------------------------------
-- Single-session: what SSI tracking looks like from pg_locks
-- ---------------------------------------------------------------------------
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM doctors WHERE on_call;
SELECT locktype, mode, count(*) FROM pg_locks
WHERE locktype IN ('transactionid','tuple')
  AND mode LIKE 'SIRead%'
GROUP BY 1, 2;         -- predicate (SIRead) locks: what SSI "remembers"
ROLLBACK;
-- These are not blocking locks — they're READ FOOTPRINTS used at commit to
-- detect dependencies. A false positive costs a retry; a missed true
-- positive would cost correctness — SSI errs toward aborting.

-- ---------------------------------------------------------------------------
-- The retry loop shape (the Go implementation: 13-go-postgres/retries)
-- ---------------------------------------------------------------------------
-- for attempt := 1; ; attempt++ {
--     tx, _ := pool.Begin(ctx)                  // SERIALIZABLE
--     ...read predicate, write decision...
--     err := tx.Commit(ctx)
--     var pgErr *pgconn.PgError
--     if errors.As(err, &pgErr) && pgErr.Code == "40001" {
--         backoff(attempt)                      // exponential + jitter
--         continue                              // safe: tx rolled back
--     }
--     break
-- }
-- Requirements for correctness: the transaction must be a pure function of
-- its reads (no external side effects mid-tx — send the email AFTER commit).

-- When to pay SERIALIZABLE's price (aborts + predicate tracking):
--   * invariants SPANNING rows that you can't easily lock ("sum >= 0",
--     "exactly one active", "no overlapping ranges" — though ranges have
--     exclusion constraints, which are cheaper and stricter)
--   * low/moderate contention — under heavy contention retry storms hurt;
--     consider explicit locking instead (08/pessimistic_locking)
--   * never mix levels on the same data in one app flow

-- TAKEAWAYS
-- * Write skew = disjoint writes from overlapping reads break an invariant;
--   invisible to RR and below.
-- * SERIALIZABLE aborts with 40001; retry loops are MANDATORY, not optional.
-- * SIRead locks are bookkeeping, not blocking.
-- * Alternatives per use case: exclusion constraints (ranges), FOR UPDATE,
--   optimistic version columns — pick the cheapest correct tool.
