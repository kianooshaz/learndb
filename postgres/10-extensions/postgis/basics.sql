-- ============================================================================
-- 10-extensions/postgis/basics.sql — real geospatial: geometry, geography
-- ============================================================================
-- Run:
--   make postgis                                   # start the 5433 container
--   make sql-postgis FILE=10-extensions/postgis/basics.sql
--
-- PostGIS is a full spatial database: SRIDs, projections, spheroid math,
-- spatial indexes. Two column flavors:
--   geometry — flat coordinate math (fast; pick an SRID/planar projection)
--   geography— on-the-spheroid (WGS84; meters natively; slower)
-- Built-in geometric types (02-data-types/network_geometric.sql) are toys
-- next to this — no SRIDs, no polygons-on-Earth.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP TABLE IF EXISTS stores CASCADE;
DROP TABLE IF EXISTS users_geo CASCADE;

CREATE EXTENSION IF NOT EXISTS postgis;

-- geometry(point, 4326): lon/lat points with an explicit SRID (WGS84):
CREATE TABLE stores (
    id   int PRIMARY KEY,
    name text NOT NULL,
    loc  geometry(Point, 4326) NOT NULL
);
CREATE TABLE users_geo (
    id  int PRIMARY KEY,
    loc geometry(Point, 4326) NOT NULL
);

-- SF is at -122.42, 37.77; NYC at -74.00, 40.71 (lon FIRST, always):
INSERT INTO stores VALUES
 (1, 'SF',    ST_SetSRID(ST_MakePoint(-122.42, 37.77), 4326)),
 (2, 'NYC',   ST_SetSRID(ST_MakePoint(-74.00,  40.71), 4326)),
 (3, 'Berlin',ST_SetSRID(ST_MakePoint(13.40,   52.52), 4326));

INSERT INTO users_geo
SELECT g, ST_SetSRID(ST_MakePoint(-122.4 + (g % 100) * 0.001, 37.7 + (g % 90) * 0.001), 4326)
FROM generate_series(1, 50000) g;

-- ---------------------------------------------------------------------------
-- 1. Distance: geometry (degrees — meaningless raw) vs geography (meters)
-- ---------------------------------------------------------------------------
-- Flat math on lon/lat returns DEGREES — a trap:
SELECT round(ST_Distance(
    (SELECT loc FROM stores WHERE id = 1),
    (SELECT loc FROM users_geo WHERE id = 1))::numeric, 6) AS degrees_naive;

-- Cast to geography: spheroid math, real meters:
SELECT round(ST_Distance(
    (SELECT loc FROM stores WHERE id = 1)::geography,
    (SELECT loc FROM users_geo WHERE id = 1))::numeric, 1) AS meters_true;

-- Two correct workflows:
--   A) geography columns (ST_Distance in meters natively)
--   B) geometry in a LOCAL PROJECTED SRID (e.g. 26910 = UTM zone 10N for SF):
SELECT round(ST_Distance(
    ST_Transform((SELECT loc FROM stores WHERE id = 1), 26910),
    ST_Transform((SELECT loc FROM users_geo WHERE id = 1), 26910))::numeric, 1)
    AS meters_projected;

-- ---------------------------------------------------------------------------
-- 2. The spatial index: GiST over bounding boxes
-- ---------------------------------------------------------------------------
CREATE INDEX stores_loc_gix ON stores USING gist (loc);
CREATE INDEX users_geo_loc_gix ON users_geo USING gist (loc);

-- ST_DWithin(range in meters for geography) is the operator that uses it:
\timing on
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM users_geo
WHERE ST_DWithin(loc::geography, (SELECT loc FROM stores WHERE name='SF')::geography, 500);
-- Bitmap Index Scan -> recheck: index checks BBOXes, exact geometry after.

-- KNN ordering straight off the GiST index:
SELECT s.name,
       round(ST_Distance(s.loc::geography, u.loc::geography)::numeric) AS meters
FROM stores s, users_geo u
WHERE u.id = 1
ORDER BY s.loc <-> u.loc
LIMIT 2;

-- ---------------------------------------------------------------------------
-- 3. Areas and containment (the features toys can't do)
-- ---------------------------------------------------------------------------
SELECT ST_Area(ST_Transform(
    ST_MakeEnvelope(-122.45, 37.74, -122.39, 37.80, 4326), 26910)) AS neighborhood_sqm;

SELECT name FROM stores
WHERE ST_Contains(
    ST_MakeEnvelope(-125, 35, -120, 42, 4326),  -- a bbox over California
    loc);

-- Mixing SRIDs errors loudly (a FEATURE — silent misprojection is worse):
--   SELECT ST_Distance(ST_SetSRID(ST_MakePoint(0,0), 4326),
--                      ST_SetSRID(ST_MakePoint(1,1), 26910));
--   ERROR: ST_Distance: Operation on mixed SRID geometries (4326, 26910)

-- Operational notes:
--  * PostGIS functions are IMMUTABLE where they must be — indexable (04).
--  * Write geometry, serve geography views when you need meters everywhere.
--  * Bulk-load then CREATE INDEX (same as every AM); ANALYZE for stats.
-- ============================================================================

-- TAKEAWAYS
-- * geometry(planar, fast) vs geography(spheroid, meters) — choose once.
-- * lon/lat order; SRIDs are explicit and checked.
-- * GiST + ST_DWithin <-> = the standard "nearby" backend.
-- * Bounding-box index + exact recheck is PostGIS's whole game.
