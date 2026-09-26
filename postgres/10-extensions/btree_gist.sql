-- ============================================================================
-- 10-extensions/btree_gist.sql — scalars inside GiST (exclusion constraints)
-- ============================================================================
-- Run:  make sql FILE=10-extensions/btree_gist.sql
--
-- Same story as btree_gin, but for GiST — and its killer app: EXCLUSION
-- constraints that combine a RANGE with a SCALAR, e.g.:
--     EXCLUDE USING gist (room WITH =, during WITH &&)
-- Without btree_gist, int4 has no GiST operators, so the constraint is
-- impossible. GiST scalars also support ranges via `<->` distance in KNN.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m10_btgist CASCADE;
CREATE SCHEMA m10_btgist;
SET search_path TO m10_btgist, public;

-- The canonical constraint: no two overlapping bookings per resource:
CREATE TABLE bookings (
    id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room   int NOT NULL,
    during tstzrange NOT NULL,
    EXCLUDE USING gist (room WITH =, during WITH &&)   -- needs btree_gist
);

INSERT INTO bookings (room, during) VALUES
    (1, tstzrange('2026-09-25 09:00+00', '2026-09-25 10:00+00')),
    (1, tstzrange('2026-09-25 10:00+00', '2026-09-25 11:00+00')),  -- abuts OK
    (2, tstzrange('2026-09-25 09:00+00', '2026-09-25 10:00+00'));
--   INSERT INTO bookings (room, during) VALUES
--       (1, tstzrange('2026-09-25 09:30+00', '2026-09-25 10:30+00'));
--   ERROR: conflicting key value violates exclusion constraint

-- More constraint shapes this unlocks:
--   (user_id WITH =, validity daterange WITH &&)           -- one active plan
--   (tenant WITH =, ip inet WITH &&)                        -- overlapping CIDRs
--   (account WITH =, amount_range numrange WITH &&)         -- overlapping fees

-- GiST scalar operators also include ORDER BY distance (<->) — nearest-
-- neighbor queries mixing text/int with geometric columns:
CREATE TABLE stores (id int PRIMARY KEY, loc point NOT NULL, tier int NOT NULL);
INSERT INTO stores
SELECT g, point((g * 37) % 1000, (g * 91) % 1000), 1 + g % 3
FROM generate_series(1, 50000) g;
CREATE INDEX ON stores USING gist (loc, tier);   -- composite GiST
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id, loc <-> point(500,500) AS dist
FROM stores
ORDER BY loc <-> point(500,500) LIMIT 5;
-- (KNN ordering works on the FIRST GiST key; tier rides along as payload
-- key — filterable but not ordered.)

-- btree_gist vs btree_gin in one line each:
--   btree_gin  -> equality inside GIN composites (jsonb/arrays)
--   btree_gist -> equality/range inside GiST composites + EXCLUDE constraints
-- ============================================================================

-- TAKEAWAYS
-- * btree_gist is the enabler for scalar+range exclusion constraints.
-- * "No overlapping X per Y" is now one declarative line — no app locks.
-- * Also enables composite GiST with distance-ordered first keys.
-- * Exclusion constraints use GiST index machinery: same write-amplification
--   economics as any index.
