-- ============================================================================
-- 02-data-types/enums.sql — enumerated types: cheap, rigid, migration-heavy
-- ============================================================================
-- Run:  make sql FILE=02-data-types/enums.sql
--
-- An enum is a static ordered set of labels stored in 4 bytes. Fast compares,
-- meaningful ORDER BY. The price: adding values is a schema change (fine),
-- removing/reordering needs a rewrite, and you cannot insert a value that
-- doesn't exist yet.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_enum CASCADE;
CREATE SCHEMA m02_enum;
SET search_path TO m02_enum;

DROP TYPE IF EXISTS order_status CASCADE;
CREATE TYPE order_status AS ENUM
    ('draft', 'pending', 'paid', 'shipped', 'delivered', 'cancelled');

CREATE TABLE orders (
    id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    status order_status NOT NULL DEFAULT 'draft'
);

-- Type safety: unknown labels are rejected at parse time —
--   INSERT INTO orders (status) VALUES ('payed');
--   ERROR: invalid input value for enum order_status: "payed"
INSERT INTO orders (status) VALUES ('pending'), ('shipped');

-- Ordering follows DECLARATION order, not alphabetical — surprisingly useful:
SELECT enum_range(NULL::order_status) AS lifecycle_order;
SELECT status FROM orders ORDER BY status DESC;
-- and comparable: WHERE status >= 'paid' means paid..delivered per the list.

-- Growing an enum: cheap catalog update, no table rewrite:
ALTER TYPE order_status ADD VALUE IF NOT EXISTS 'returned' AFTER 'delivered';
SELECT enum_range(NULL::order_status);
-- (Values cannot be dropped or renamed cheaply; removing requires a chain of
-- steps or a new type + column swap.)

-- Casting gotchas: text -> enum is not implicit in all positions; be explicit:
INSERT INTO orders (status) VALUES ('paid'::order_status);
SELECT 'paid'::order_status = 'paid' AS enum_text_compare;  -- literal auto-cast

-- enum vs text + CHECK vs lookup table:
--   enum        — ordered, compact, typo-proof; value changes = migration.
--   text + CHECK— flexible (rename = UPDATE), no ordering; slightly bigger.
--   lookup table— FK integrity, metadata per state (labels, sort), joins;
--                 the choice when states carry data or change often.
-- Sizing rule: closed, ordered, stable vocabulary (lifecycle states) -> enum.
-- Open vocabulary (categories, user-defined) -> lookup table.

-- What enums quietly break:
--   * Adding values in a transaction: allowed only if the type itself was
--     created in the same transaction (details in the docs).
--   * pg_dump/restore ordering: types must be restored before tables.
--   * ORMs and admin tools sometimes render enums as plain text.

-- TAKEAWAYS
-- * 4 bytes, ordered by declaration, invalid values rejected.
-- * ADD VALUE is cheap; removal/reorder is not.
-- * Closed lifecycle -> enum; open or data-carrying sets -> lookup table.
