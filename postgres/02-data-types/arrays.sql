-- ============================================================================
-- 02-data-types/arrays.sql — int[] / text[] and the unnest round trip
-- ============================================================================
-- Run:  make sql FILE=02-data-types/arrays.sql
--
-- Arrays are a legitimate modeling tool for compact multi-value columns
-- (tags, roles) — IF you only ever ask "membership/containment" questions.
-- The moment you need to join, constrain per-element, or aggregate across
-- rows, a proper child table (1NF) beats them.
-- ============================================================================

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS m02_arrays CASCADE;
CREATE SCHEMA m02_arrays;
SET search_path TO m02_arrays;

-- Construction, indexing (1-based!), slices:
SELECT ARRAY[1,2,3]            AS literal,
       (ARRAY[1,2,3,4])[2]     AS second_element,
       (ARRAY[1,2,3,4])[2:3]   AS slice,
       array_dims(ARRAY[1,2,3]) AS dims,
       cardinality(ARRAY[1,2,3]) AS length;

-- NULL vs array NULL: an array can contain NULL elements, and the array
-- itself can be NULL. '{1,2}' vs '{1,NULL}' vs NULL are three states.
SELECT ARRAY[1,NULL,3] AS with_null_elem,
       array_position(ARRAY[1,NULL,3], NULL) AS null_sits_at_position_2,
       array_remove(ARRAY[1,NULL,3], NULL) AS cleaned;

-- The relational bridge: unnest (array -> rows) and array_agg (rows -> array)
CREATE TABLE photos (id int PRIMARY KEY, tags text[]);
INSERT INTO photos VALUES
    (1, ARRAY['sunset','beach']),
    (2, ARRAY['beach','family']),
    (3, ARRAY['city']);

SELECT id, unnest(tags) AS tag FROM photos ORDER BY id, tag;   -- one row per element

SELECT id, array_agg(tag ORDER BY tag) AS sorted_tags
FROM (SELECT id, unnest(tags) AS tag FROM photos) x
GROUP BY id ORDER BY id;

-- Containment / overlap — these are GIN-indexable (see below):
SELECT id FROM photos WHERE tags @> ARRAY['beach'];       -- has ALL of these
SELECT id FROM photos WHERE tags && ARRAY['beach','city']; -- has ANY of these

-- Membership without array literal syntax: value = ANY(array)
SELECT 3 = ANY(ARRAY[1,2,3]) AS is_member, 9 = ANY(ARRAY[1,2,3]) AS is_not;

-- GIN index makes containment queries index scans:
CREATE INDEX photos_tags_gin ON photos USING gin (tags);
SET enable_seqscan = off;   -- DEMO ONLY: force index choice to show it CAN be used
EXPLAIN (COSTS OFF) SELECT id FROM photos WHERE tags @> ARRAY['beach'];
RESET enable_seqscan;

-- ---------------------------------------------------------------------------
-- Arrays vs child table — trade-offs you must be able to argue
-- ---------------------------------------------------------------------------
-- Array column (photos.tags):
--   + one row per entity, no join to read the entity
--   + trivial GIN containment
--   - no per-element constraints (can't FK each tag, can't easily update one
--     element without rewriting the array)
--   - statistics are poor (planner can't estimate tag selectivity well)
-- Child table (photo_tags(photo_id, tag)):
--   + per-row constraints, indexes, joins, accurate stats
--   - join cost, more rows
-- For tags/labels READ via containment: arrays fine. For anything you
-- UPDATE per element or JOIN against: child table.

-- Anti-patterns:
--   * int[] of FK ids (no integrity, no cascades) — use a junction table.
--   * Building CSV strings instead of arrays (then splitting in app).

-- TAKEAWAYS
-- * 1-based indexing; slices; arrays can hold NULLs.
-- * unnest/array_agg are the bridge to relational form.
-- * @>, &&, = ANY() are the query forms; GIN indexes them.
-- * Containment-only -> array; per-element integrity -> child table.
