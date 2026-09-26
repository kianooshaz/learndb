-- ============================================================================
-- 11-advanced/row_level_security/basics.sql — tenant isolation in the DB
-- ============================================================================
-- Run:  make sql FILE=11-advanced/row_level_security/basics.sql
--
-- RLS makes every query on a table pass a POLICY — rows failing it simply
-- don't exist for that query. It's the strongest multi-tenant fence you can
-- build: even a forgotten WHERE can't leak another tenant's rows, because
-- the filter lives in the table, not the app.
--
-- Roles drive policies; the app sets the tenant per transaction:
--   SET LOCAL app.tenant_id = '42'      -- with the connection pool!
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m11_rls CASCADE;
CREATE SCHEMA m11_rls;
SET search_path TO m11_rls, public;

CREATE TABLE documents (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id int NOT NULL,
    secret    text NOT NULL
);
INSERT INTO documents (tenant_id, secret)
SELECT g % 10, 'tenant-' || (g % 10) || '-doc-' || g
FROM generate_series(1, 100) g;

-- Enable RLS (note: does NOT create a policy — with no policy the default
-- is DENY-ALL for non-owner roles... but table OWNERS and superusers
-- BYPASS RLS unless FORCE):
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents FORCE ROW LEVEL SECURITY;    -- even owner obeys (demo)

-- USING filters READS; WITH CHECK filters WRITES:
CREATE POLICY tenant_isolation ON documents
    USING (tenant_id = current_setting('app.tenant_id')::int)
    WITH CHECK (tenant_id = current_setting('app.tenant_id')::int);

-- Without the setting, current_setting errors — fail-closed by design:
\set ON_ERROR_STOP off
SELECT count(*) FROM documents;
\set ON_ERROR_STOP on

-- Per-transaction tenant context (the pgxpool-safe form):
BEGIN;
SET LOCAL app.tenant_id = '3';
SELECT count(*), min(secret), max(secret) FROM documents;
INSERT INTO documents (tenant_id, secret) VALUES (3, 'allowed');
-- Writing ANOTHER tenant's row is blocked by WITH CHECK:
\set ON_ERROR_STOP off
INSERT INTO documents (tenant_id, secret) VALUES (9, 'forbidden');
\set ON_ERROR_STOP on
COMMIT;

-- AFTER commit, the setting is gone (SET LOCAL = transaction scope only):
\set ON_ERROR_STOP off
SELECT count(*) FROM documents;
\set ON_ERROR_STOP on

-- UPDATEs can't smuggle rows across tenants (USING + WITH CHECK both fire):
BEGIN;
SET LOCAL app.tenant_id = '3';
\set ON_ERROR_STOP off
UPDATE documents SET tenant_id = 9 WHERE id = 31;   -- exists=3 -> moving to 9
\set ON_ERROR_STOP on
COMMIT;

-- ---------------------------------------------------------------------------
-- How RLS plans (performance reality)
-- ---------------------------------------------------------------------------
BEGIN;
SET LOCAL app.tenant_id = '3';
-- The policy becomes a hidden predicate on every query. It uses indexes
-- exactly like a WHERE clause would:
CREATE INDEX IF NOT EXISTS documents_tenant_idx ON documents (tenant_id);
EXPLAIN (COSTS OFF) SELECT * FROM documents WHERE secret LIKE 'tenant-3-d%';
COMMIT;
-- Index the tenant column — RLS multiplies the importance (every query
-- gains the predicate).

-- Roles and testing (why app roles matter). NOTE: roles are CLUSTER-wide —
-- they outlive the schema drop above, hence IF NOT EXISTS:
-- CREATE ROLE has no IF NOT EXISTS — the standard idempotent guard:
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
        CREATE ROLE app_user LOGIN;
    END IF;
END $$;
GRANT USAGE ON SCHEMA m11_rls TO app_user;
GRANT SELECT, INSERT, UPDATE ON m11_rls.documents TO app_user;
-- Test AS the role (superusers bypass — test with the real role!):
SET ROLE app_user;
BEGIN;
SET LOCAL app.tenant_id = '5';
SELECT count(*) FROM documents;      -- 10 rows, tenant 5 only
COMMIT;
RESET ROLE;

-- The deployment checklist for Go services:
--   * one DB role per service (not superuser! bypassrls kills the fence)
--   * SET LOCAL app.tenant_id inside EVERY transaction (13/transactions)
--   * never bare SET with a pool (it sticks to one pooled connection!)
--   * keep USING and WITH CHECK aligned or you open write holes

-- TAKEAWAYS
-- * ENABLE + FORCE + policy(USING, WITH CHECK) = tenant-proof table.
-- * SET LOCAL + per-tx = pool-safe context; bare SET leaks across users.
-- * Policy = hidden predicate: index your tenant column.
-- * Superusers/owners bypass RLS unless FORCE — test as the app role.
