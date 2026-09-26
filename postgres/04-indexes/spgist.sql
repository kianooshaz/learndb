-- ============================================================================
-- 04-indexes/spgist.sql — space-partitioned trees (SP-GiST)
-- ============================================================================
-- Run:  make sql FILE=04-indexes/spgisg.sql   (typo guard: file is spgist.sql)
--
-- SP-GiST = Space-Partitioned GiST. Regular GiST/btree trees are BALANCED:
-- every leaf at the same depth, nodes overlap if they must. SP-GiST instead
-- PARTITIONS the key space into non-overlapping regions — like a radix tree
-- / k-d tree / quad tree. Winner when keys cluster along structure:
--   * long strings with shared prefixes (URLs, SKUs, emails' domains)
--   * points in 2D (quad trees) — geo without PostGIS
--   * inet/cidr (network prefixes)
-- Trade-off: unbalanced depth possible (data-dependent), no ordering support.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m04_spgist CASCADE;
CREATE SCHEMA m04_spgist;
SET search_path TO m04_spgist, public;

-- ---------------------------------------------------------------------------
-- Prefix-heavy data: URL paths
-- ---------------------------------------------------------------------------
CREATE TABLE urls (id bigint PRIMARY KEY, url text NOT NULL);
INSERT INTO urls
SELECT g, '/api/v2/users/' || g || '/settings/notifications'
FROM generate_series(1, 300000) g
UNION ALL
SELECT 1000000 + g, '/api/v2/orders/' || g || '/items'
FROM generate_series(1, 300000) g
UNION ALL
SELECT 2000000 + g, '/static/assets/img/icon-' || g || '.png'
FROM generate_series(1, 300000) g;

CREATE INDEX urls_btree  ON urls USING btree  (url);
CREATE INDEX urls_spgist ON urls USING spgist (url);   -- radix-tree opclass
ANALYZE urls;

-- Equality: both serve it; compare sizes and lookups:
SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class WHERE relname IN ('urls_btree','urls_spgist');

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM urls WHERE url = '/api/v2/orders/1234/items';

BEGIN;
SET LOCAL enable_indexscan = off;   -- force the spgist path for comparison
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM urls WHERE url = '/api/v2/orders/1234/items';
ROLLBACK;

-- Prefix searches: SP-GiST text_ops supports ^@ (starts-with) — btree
-- cannot answer this without text_pattern_ops:
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM urls WHERE url ^@ '/api/v2/users/';   -- same as starts_with()
-- The radix tree walks the shared prefix once — ideal here.

-- ---------------------------------------------------------------------------
-- Points: kd_point_ops — a k-d tree over 2D points
-- ---------------------------------------------------------------------------
CREATE TABLE pings (id bigint PRIMARY KEY, loc point NOT NULL);
INSERT INTO pings
SELECT g, point((g * 37 % 100000)::float, (g * 91 % 100000)::float)
FROM generate_series(1, 400000) g;

CREATE INDEX pings_kd ON pings USING spgist (loc kd_point_ops);
ANALYZE pings;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id, loc <-> point(50000, 50000) AS d
FROM pings
ORDER BY loc <-> point(50000, 50000)
LIMIT 5;
-- KNN over a k-d tree — compare with the GiST quad-tree version by creating
-- a second index (quad_point_ops) and re-running; both are legit, data decides.

--/inet prefixes: same story with network types:
CREATE TABLE subnets (id int PRIMARY KEY, net cidr NOT NULL);
INSERT INTO subnets VALUES (1, '10.1.0.0/24'), (2, '10.1.16.0/24'),
                            (3, '192.168.0.0/16'), (4, '10.0.0.0/8');
CREATE INDEX subnets_spgist ON subnets USING spgist (net inet_ops);
EXPLAIN (COSTS OFF) SELECT * FROM subnets WHERE net >> '10.1.2.3'::inet;

-- ---------------------------------------------------------------------------
-- Decision guidance (SP-GiST vs the world):
--   * URLs / long keys with common prefixes -> spgist text_ops often smaller
--     and faster than btree; <<=# prefix matching is unique to it.
--   * points -> kd_point_ops / quad_point_ops: competitive KNN.
--   * need ORDER BY or ranges from the index -> btree only.
--   * overlapping regions / containment semantics -> GiST, not SP-GiST.
-- ============================================================================

-- TAKEAWAYS
-- * SP-GiST = non-overlapping partitions (radix/k-d/quad), can be lopsided.
-- * Best on structured/prefix-heavy keys and 2D points; no ordering support.
-- * Always bench against btree/GiST on your real data — that's the tiebreak.
