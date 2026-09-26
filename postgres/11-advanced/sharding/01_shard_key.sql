-- ============================================================================
-- 11-advanced/sharding/01_shard_key.sql — the routing math, before hardware
-- ============================================================================
-- Run:  make sql FILE=11-advanced/sharding/01_shard_key.sql
--
-- Sharding is 90% a DATA MODELING decision: pick the shard key and the
-- distribution follows. This file runs the actual math you'd do on paper —
-- hash spread, skew, and resharding cost — on real data, no second server
-- needed. Every number here is a number you'll defend in a design review.
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
DROP SCHEMA IF EXISTS m11_shard CASCADE;
CREATE SCHEMA m11_shard;
SET search_path TO m11_shard, public;

-- A realistic user base: 200k events across 20k users with a whale (user 7
-- generates 10% of all events — every real dataset has one):
CREATE TABLE events (id bigint, user_id int, bytes int);
INSERT INTO events
SELECT g, (g % 20000) + 1, 1 + (g * 37) % 1000
FROM generate_series(1, 180000) g;
INSERT INTO events  -- the whale:
SELECT 1000000 + g, 7, 1000 FROM generate_series(1, 20000) g;

-- ---------------------------------------------------------------------------
-- 1. The routing function: hash(key) % N
-- ---------------------------------------------------------------------------
-- PostgreSQL's hash() is stable per value for the cluster's lifetime — good
-- enough to SIMULATE routing (production routers use CRC32/FNV/Murmur of
-- the key IN THE APP, so the math must live in one shared library):
CREATE FUNCTION shard_of(user_id int, shards int)
RETURNS int LANGUAGE sql IMMUTABLE
RETURN abs(hashtext(user_id::text)) % shards;

-- Distribution across 4 shards with user_id as the key:
SELECT shard_of(user_id, 4) AS shard,
       count(*)             AS events,
       count(DISTINCT user_id) AS users,
       sum(bytes)           AS bytes
FROM events
GROUP BY 1 ORDER BY 1;
-- Users spread evenly; the whale's 20k events all land in ONE shard. Skew!

-- The skew, precisely (max shard / mean shard — "1.0" = perfect):
WITH per_shard AS (
    SELECT shard_of(user_id, 4) AS shard, sum(bytes) AS bytes
    FROM events GROUP BY 1
)
SELECT round(max(bytes) / avg(bytes), 2) AS skew_factor FROM per_shard;
-- >1.2 deserves a hard look at the key; >2 is a design change.

-- ---------------------------------------------------------------------------
-- 2. Same data, different key — routing shape changes completely
-- ---------------------------------------------------------------------------
-- By event id (near-sequential): range-friendly but every hot "recent"
-- window piles into one shard:
SELECT (id - 1) / 50000 AS range_shard, count(*) FROM events
GROUP BY 1 ORDER BY 1;

-- The cardinal question: how often do queries carry the shard key?
-- "Activity for user 42" with user_id sharding -> 1 shard (perfect).
-- "All events > 1000 bytes" (no key) -> ALL shards (scatter-gather):
SELECT count(*) FROM events WHERE bytes > 999 AND user_id = 42;    -- routed
SELECT count(*) FROM events WHERE bytes > 999;                     -- scattered

-- ---------------------------------------------------------------------------
-- 3. Resharding math: % N is a liar when N changes
-- ---------------------------------------------------------------------------
-- From 4 to 5 shards with plain modulo moves nearly EVERY row:
WITH users AS (SELECT DISTINCT user_id FROM events)
SELECT
    count(*) FILTER (WHERE shard_of(user_id, 4) = shard_of(user_id, 5)) AS stay_put,
    count(*) FILTER (WHERE shard_of(user_id, 4) <> shard_of(user_id, 5)) AS must_move,
    round(100.0 * count(*) FILTER (WHERE shard_of(user_id, 4) <> shard_of(user_id, 5))
          / count(*), 1) AS pct_moved
FROM users;
-- ~80-95% moved! Plain modulo gives you a full-data migration per scale-out.

-- Consistent hashing fixes most of that: map keys AND shards onto a ring,
-- move only the keys between the new shard and its neighbor. The lab
-- router (app_router/main.go) implements jump/consistent-style mapping and
-- shows the moved-row count collapsing.

-- ---------------------------------------------------------------------------
-- 4. What must be true about the key (the checklist)
-- ---------------------------------------------------------------------------
--  * high cardinality (user_id: yes; country_code: max ~200 shards, forever)
--  * even spread (measured above; beware whales)
--  * present on your hot queries (else scatter)
--  * stable (emails change; ids don't)
--  * colocates what joins: shard users & their events by the SAME key, and
--    joins become local. Shard them differently, and every join scatters.

-- Colocation check — same key => same shard, always:
SELECT count(*) FILTER (WHERE shard_of(user_id, 4) IS DISTINCT FROM shard_of(user_id, 4)) AS violations
FROM events;

-- TAKEAWAYS
-- * Choose the key by QUERY shape, then verify spread/skew with real data.
-- * Modulo resharding moves ~everything; consistent hashing moves ~1/N.
-- * Colocate join partners on the same key or accept scatter joins.
-- * Measure skew_factor before provisioning a single server.
