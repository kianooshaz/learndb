-- ============================================================================
-- 07-performance/connection_pooling.sql — why processes make pooling critical
-- ============================================================================
-- Run:  make sql FILE=07-performance/connection_pooling.sql
--
-- The server model most tutorials skip: every PostgreSQL connection is a
-- forked PROCESS with its own memory (work_mem budgets per sort/hash!),
-- its own snapshot bookkeeping, scheduled by the OS. There is no internal
-- thread pool. Consequences:
--   * connections are EXPENSIVE (fork + ~0.5-1MB minimum + context switch)
--   * max_connections is a cliff, not a dial: at some point EVERYONE gets
--     slow (memory pressure, lock contention) — not just the extra ones
--   * idle connections still hold memory and, if in a transaction, pin
--     the vacuum horizon (bloat.sql)
--
-- Two pooling layers, usually BOTH in production:
--   app-side   (pgxpool)   — per process; goroutines share few conns
--   server-side (PgBouncer) — many app processes share few backend conns
-- ============================================================================

\set ON_ERROR_STOP on
\timing on

-- What one connection costs, from the server's viewpoint:
SHOW max_connections;
SELECT count(*) AS current_backends FROM pg_stat_activity;

-- Memory math every backend brings (per SORT or HASH node, PER QUERY!):
SHOW work_mem;                       -- 4MB default
-- A query with 3 sort/hash nodes uses up to ~3 x work_mem ON ITS BACKEND.
-- 500 connections x a few active sorts = the OOM you didn't plan for.
-- This is why "raise work_mem to fix a slow report" is dangerous with
-- many connections, and why PgBouncer pooling (few backends) and bigger
-- work_mem go TOGETHER.

-- Connection states that matter (idle vs idle IN TRANSACTION):
SELECT state, count(*)
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY state ORDER BY 2 DESC;
-- 'idle in transaction' = holding a snapshot (vacuum blocker!) and locks.
-- The two settings that police it:
SHOW idle_in_transaction_session_timeout;    -- 0 = disabled (set it!)
SHOW idle_session_timeout;                    -- 0 = disabled

-- Practical policy for a Go service fleet:
--   total_conns_across_pods <= max_connections - 10 (admin margin)
--   pgxpool MaxConns per pod = small (4-10); scale pods, not pool size
--   statement_timeout + idle_in_transaction_session_timeout server-side

-- ---------------------------------------------------------------------------
-- PgBouncer: the server-side pooling layer (compose profile included)
-- ---------------------------------------------------------------------------
--   make pgbouncer        # starts on localhost:6432, transaction pooling
-- Modes and what each costs you:
--   session    — a backend is tied to one client until disconnect
--   transaction— backend assigned per TRANSACTION (the default choice)
--   statement  — per statement (no multi-statement transactions at all)
--
-- Transaction mode's famous casualties (memorize):
--   * session GUCs via SET           (use SET LOCAL inside a tx)
--   * prepared statements (PgBouncer 1.21+ tracks protocol-level ones;
--     SQL-level PREPARE/EXECUTE still break)
--   * advisory session locks (pg_advisory_xact_lock still fine)
--   * LISTEN/NOTIFY (needs a dedicated backend)
--   * WITH HOLD cursors across tx boundaries
--
-- Prove the pool exists, then compare a connect-through-pgbouncer query:
--   PGPASSWORD=postgres psql -h localhost -p 6432 -U postgres learndb
--   -c "SELECT 1"     # through PgBouncer (port 6432 vs direct 5432)
-- And admin console:
--   psql -p 6432 pgbouncer -U postgres -c "SHOW POOLS"
--
-- When you need PgBouncer: hundreds/thousands of clients, serverless, many
-- pods. When you don't: a few services with well-sized pgxpool can connect
-- directly and keep session features.

-- TAKEAWAYS
-- * Connections are processes; max_connections is a cliff (memory math!).
-- * work_mem x sort-nodes x connections = the real memory budget.
-- * Two layers, both fine: pgxpool per process, PgBouncer fleet-wide.
-- * Transaction pooling trades session state for backend sharing — know
--   exactly which features you lose before enabling it.
