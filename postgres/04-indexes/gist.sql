-- ============================================================================
-- 04-indexes/gist.sql — GiST: ranges, geometry, trigrams, exclusion
-- ============================================================================
-- Run:  make sql FILE=04-indexes/gist.sql
--
-- GiST = Generalized Search Tree: a toolkit for building balanced trees over
-- ANY "sortable-ish" datatype — things with no natural total order (a point?
-- a range?). Nodes partition SPACE (bounding boxes, interval containment)
-- instead of sorting keys. Lossiness is allowed: the index may return
-- candidates that the recheck step then verifies exactly.
-- Built-in users: ranges, geometric types, tsvector, text (via pg_trgm),
-- inet — plus EXCLUSION constraints (02-data-types/ranges.sql).
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m04_gist CASCADE;
CREATE SCHEMA m04_gist;
SET search_path TO m04_gist, public;

-- ---------------------------------------------------------------------------
-- Range columns: overlap queries at scale (bookings)
-- ---------------------------------------------------------------------------
CREATE TABLE bookings (
    id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room   int NOT NULL,
    during tstzrange NOT NULL
);
-- Constraint FIRST (a table-level guarantee every insert must respect), then
-- load data that respects it: room r gets 90-minute slots starting at hour
-- r + 100*k — same-room slots are 100h apart, so nothing overlaps.
ALTER TABLE bookings ADD CONSTRAINT no_room_double_booking
    EXCLUDE USING gist (room WITH =, during WITH &&);
INSERT INTO bookings (room, during)
SELECT 1 + (g % 50),
       tstzrange(
           now() + (((g % 50) + 100 * (g / 50)) || ' hours')::interval,
           now() + (((g % 50) + 100 * (g / 50)) || ' hours')::interval + interval '90 minutes')
FROM generate_series(1, 200000) g;

CREATE INDEX bookings_during_gist ON bookings USING gist (during);
ANALYZE bookings;

-- "Show my conflicts if I want this slot" — one lookup instead of a scan.
-- (Hour 101..102.5 is exactly room 2's booking at hour 101 — the window
-- below sits inside a booked slot, so the count is small but nonzero:)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM bookings
WHERE during && tstzrange(now() + interval '101 hours',
                          now() + interval '102 hours');
-- GiST Index Scan. Without it, && over tstzrange means checking every row.

-- ---------------------------------------------------------------------------
-- Geometry: points + nearest-neighbor (<-> KNN) — "10 closest stores"
-- ---------------------------------------------------------------------------
CREATE TABLE stores (id int PRIMARY KEY, name text, loc point NOT NULL);
INSERT INTO stores
SELECT g, 'store' || g, point((g * 37 % 1000)::float, (g * 91 % 1000)::float)
FROM generate_series(1, 20000) g;

CREATE INDEX stores_loc_gist ON stores USING gist (loc);
ANALYZE stores;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id, name, loc <-> point(500, 500) AS dist
FROM stores
ORDER BY loc <-> point(500, 500)          -- KNN: ordered by the index itself
LIMIT 10;
-- No sort node at all: the tree walks outward in distance order and STOPS
-- after 10. This is the pattern behind "nearby X" features.

-- Bounding-box containment for boxes/circles/polygons:
EXPLAIN (COSTS OFF)
SELECT id FROM stores WHERE loc <@ box(point(100,100), point(200,200));

-- ---------------------------------------------------------------------------
-- pg_trgm's GiST: similarity AND substring search
-- ---------------------------------------------------------------------------
CREATE TABLE names (id int PRIMARY KEY, name text NOT NULL);
INSERT INTO names
SELECT g, (ARRAY['Kianoosh','Postgre','Backand','Databse','Queery'])[1 + g % 5] || g
FROM generate_series(1, 50000) g;

-- Note: pg_trgm ships BOTH gin_trgm_ops and gist_trgm_ops opclasses:
CREATE INDEX names_trgm_gist ON names USING gist (name gist_trgm_ops);
ANALYZE names;

-- Similarity search with INDEX-ORDERED results (GiST's superpower vs GIN):
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT name, similarity(name, 'Databse') AS sim
FROM names
WHERE name % 'Databse'                    -- similarity above pg_trgm.similarity_threshold
ORDER BY name <-> 'Databse'               -- distance order from the index
LIMIT 5;
-- GIN can answer % too, but NOT the <-> ordering; GiST does both.

-- LOSSINESS demo: GiST geometric tests are approximate (bbox), so plans show
-- "Recheck" when the index can't prove the predicate — look for it in the
-- KNN plan above (loc is exact so no recheck fires there, but boxes/polygons
-- usually recheck).

-- ---------------------------------------------------------------------------
-- Why exclusion constraints NEED GiST (recap of 02-data-types/ranges.sql):
-- the constraint above is "GiST with a twist": an index that REJECTS entries
-- conflicting with existing ones on (=, &&). Mixing in a scalar column
-- (room WITH =) needs btree_gist, which gives int its GiST operators.
-- ============================================================================

-- TAKEAWAYS
-- * GiST partitions space, not order: ranges/geo/trigram/fts + KNN.
-- * <-> ORDER BY ... LIMIT = index-ordered nearest neighbors, no sort.
-- * GiST may be lossy -> Recheck in plans; correctness is preserved.
-- * EXCLUDE constraints run on GiST (btree_gist unlocks scalar columns).
