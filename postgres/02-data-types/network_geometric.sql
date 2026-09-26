-- ============================================================================
-- 02-data-types/network_geometric.sql — inet/cidr/macaddr + geometry basics
-- ============================================================================
-- Run:  make sql FILE=02-data-types/network_geometric.sql
--
-- Network types power real features: IP allow/deny lists, geo by subnet,
-- CIDR capacity math. Geometric types (point/box/circle/path) give you
-- "within radius" queries WITHOUT PostGIS — fine for in-memory-scale data.
-- For real GIS (SRIDs, polygons on a spheroid): PostGIS (10-extensions).
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_net CASCADE;
CREATE SCHEMA m02_net;
SET search_path TO m02_net;

-- ---------------------------------------------------------------------------
-- inet (one host or network) vs cidr (network, enforced)
-- ---------------------------------------------------------------------------
SELECT '192.168.1.5'::inet AS host,
       '192.168.1.0/24'::inet AS inet_allows_host_bits,
       '192.168.1.0/24'::cidr AS cidr_network;
--   SELECT '192.168.1.5/24'::cidr;  -- ERROR: invalid cidr value (masked bits)

-- Operators that make ACL checks one predicate (all btree/GiST-indexable
-- with the built-in opclasses):
SELECT '192.168.1.5'::inet << '192.168.1.0/24'::inet AS contained_in_subnet,
       '192.168.1.0/24'::inet && '192.168.0.0/16'::inet AS subnets_overlap,
       '10.0.0.1'::inet <<= '10.0.0.1'::inet AS equal_or_contained,
       family('::1'::inet) AS ip_version_6;

-- Realistic: rate-limit / audit table keyed by client IP
CREATE TABLE login_audit (
    at     timestamptz NOT NULL DEFAULT now(),
    src_ip inet NOT NULL,
    ok     boolean NOT NULL
);
CREATE INDEX ON login_audit (src_ip);
INSERT INTO login_audit (src_ip, ok) VALUES
    ('203.0.113.7',  true), ('203.0.113.99', false), ('198.51.100.4', true);

-- "All logins from the attacker's subnet in the last day":
SELECT count(*) FROM login_audit
WHERE src_ip << '203.0.113.0/24' AND at > now() - interval '1 day';

-- Subnet math: how many usable hosts in a prefix?
SELECT broadcast('192.168.1.0/24'::cidr) AS broadcast,
       netmask('192.168.1.0/24'::cidr) AS netmask,
       masklen('192.168.1.0/24'::cidr) AS prefix_bits,
       power(2, 32 - masklen('192.168.1.0/24'::cidr)) - 2 AS usable_hosts;

-- macaddr(8) too — SELECT '08:00:2b:01:02:03'::macaddr; and macaddr8 for EUI-64.

-- ---------------------------------------------------------------------------
-- Geometric types — enough for simple radius/bounding-box queries
-- ---------------------------------------------------------------------------
-- point, box, circle, path, polygon; operators && (overlap), @> (contains),
-- <-> (distance, for KNN with GiST — 04-indexes/gist.sql).
SELECT point(1,1) <@ circle(point(0,0), 5) AS point_inside_circle,
       box(point(0,0), point(2,2)) @> point(1,1) AS box_contains_point,
       point(3,4) <-> point(0,0) AS euclidean_distance;

-- Practical mini-geo without PostGIS: delivery radius
CREATE TABLE stores (id int PRIMARY KEY, name text, loc point, radius float);
CREATE TABLE customers_geo (id int PRIMARY KEY, name text, loc point);
INSERT INTO stores VALUES (1, 'SOMA', point(0,0), 5), (2, 'Marina', point(8,8), 3);
INSERT INTO customers_geo VALUES (1, 'Ada', point(1,1)), (2, 'Bob', point(9,9));

-- Who can be served by which store (circle containment, sequential scan is
-- fine at this size; GiST on circle makes it scale — see 04-indexes/gist.sql):
SELECT s.name AS store, c.name AS customer
FROM stores s JOIN customers_geo c ON c.loc <@ circle(s.loc, s.radius)
ORDER BY 1, 2;

-- Nearest store regardless of radius (KNN — index-accelerated with GiST):
SELECT name FROM stores ORDER BY loc <-> point(4,4) LIMIT 1;

-- Honest limits of built-ins: flat-earth geometry (no SRIDs, no great
-- circles, degrees vs meters ambiguity). For anything map-shaped, use
-- PostGIS geometry/geography (10-extensions/postgis/).

-- TAKEAWAYS
-- * inet vs cidr: host+netmask vs strict network; << tests membership.
-- * IP allowlists / abuse queries are one operator away — and indexable.
-- * Geometric types + GiST cover radius/nearest/bounding-box needs.
-- * Real GIS (SRIDs, spheroid distance) => PostGIS.
