-- ============================================================================
-- demo/setup.sql — shared e-commerce dataset for modules 03 / 04 / 05
-- ============================================================================
-- Run:  make demo        (or: make sql FILE=demo/setup.sql)
--
-- A small but realistic shop: customers, products, orders, order_items.
-- Sizes are chosen so the planner makes non-trivial decisions (~10k/1k/50k/
-- 150k rows) while setup stays a few seconds. Data is RANDOM but DETERMINIS-
-- TIC (fixed seed) so outputs are reproducible across resets.
--
-- Conventions used by every module that builds on this:
--   * indexes are NOT pre-created on most columns — modules 04/05 create
--     them deliberately and measure the difference;
--   * after bulk loading we run ANALYZE so the planner has fresh statistics
--     (see 07-performance/analyze.sql for why that matters).
-- ============================================================================

\set ON_ERROR_STOP on
\timing on

DROP SCHEMA IF EXISTS demo CASCADE;
CREATE SCHEMA demo;

CREATE TABLE demo.customers (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       text NOT NULL UNIQUE,
    name        text NOT NULL,
    country     char(2) NOT NULL,
    is_pro      boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL
);

CREATE TABLE demo.products (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         text NOT NULL UNIQUE,
    name        text NOT NULL,
    category    text NOT NULL,          -- 8 categories, deliberately skewed
    price       numeric(10,2) NOT NULL CHECK (price >= 0),
    in_stock    boolean NOT NULL DEFAULT true,
    tags        text[] NOT NULL DEFAULT '{}',
    attrs       jsonb NOT NULL DEFAULT '{}'
);

-- status is deliberately a text column here so modules can show enum vs
-- text trade-offs; the 11-advanced/partitioning lab builds its own enums.
CREATE TABLE demo.orders (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES demo.customers (id),
    status      text NOT NULL,          -- placed|paid|shipped|delivered|cancelled
    placed_at   timestamptz NOT NULL
);

CREATE TABLE demo.order_items (
    order_id    bigint NOT NULL REFERENCES demo.orders (id) ON DELETE CASCADE,
    product_id  bigint NOT NULL REFERENCES demo.products (id),
    qty         int NOT NULL CHECK (qty > 0),
    unit_price  numeric(10,2) NOT NULL,
    PRIMARY KEY (order_id, product_id)
);

-- ---------------------------------------------------------------------------
-- Deterministic data: every choice derives from g via modular arithmetic, so
-- every reset produces byte-identical tables (and planner behavior you can
-- reproduce in a GitHub issue).
-- ---------------------------------------------------------------------------

-- 10,000 customers across 12 countries, skewed: US dominates (realistic and
-- useful later — skew is what breaks planner estimates). Categorical values
-- come from modular arithmetic on g, NOT random() array indexing — that
-- idiom can index out of bounds and produce silent NULLs.
INSERT INTO demo.customers (email, name, country, is_pro, created_at)
SELECT
    'customer' || g || '@example.com',
    (ARRAY['Ada','Grace','Linus','Edsger','Barbara','Alan','Margaret','Donald'])[1 + (g * 7919) % 8]
        || ' ' ||
      (ARRAY['Lovelace','Hopper','Torvalds','Dijkstra','Liskov','Turing','Hamilton','Knuth'])[1 + (g * 104729) % 8],
    (ARRAY['US','US','US','US','US','US','DE','GB','FR','CA','JP','BR'])[1 + (g * 7) % 12],
    (g % 7) = 0,
    now() - ((g % 730) || ' days')::interval
FROM generate_series(1, 10000) g;

-- 1,000 products; category skew via modular assignment (electronics ~3x the
-- tail categories).
INSERT INTO demo.products (sku, name, category, price, in_stock, tags, attrs)
SELECT
    'SKU-' || lpad(g::text, 4, '0'),
    (ARRAY['Keyboard','Monitor','Cable','Laptop','Mouse','Webcam','SSD','Hub'])[1 + (g * 31) % 8]
        || ' ' || g,
    (ARRAY['electronics','electronics','electronics','electronics','electronics','electronics',
           'accessories','accessories','accessories','office','office','gaming','gaming','audio'])[1 + (g * 17) % 14],
    round(((g * 37 % 480) + 19.99)::numeric, 2),
    (g % 10) <> 0,
    CASE WHEN g % 2 = 0 THEN ARRAY['sale'] ELSE ARRAY[]::text[] END,
    jsonb_build_object(
        'color', (ARRAY['black','white','silver'])[1 + (g * 13) % 3],
        'weight_g', 100 + (g * 61) % 2000,
        'warranty_months', (ARRAY[12, 24, 36])[1 + (g * 7) % 3]
    )
FROM generate_series(1, 1000) g;

-- 50,000 orders over the past 24 months, status weighted to recent activity.
INSERT INTO demo.orders (customer_id, status, placed_at)
SELECT
    1 + (g * 37) % 10000,        -- customers are loaded first, so the FK holds
    (ARRAY['placed','placed','paid','paid','paid','shipped','shipped','shipped',
           'delivered','delivered','delivered','delivered','cancelled'])[1 + (g * 11) % 13],
    now() - ((g % 730) || ' hours')::interval
FROM generate_series(1, 50000) g;

-- ~150,000 order items: 1–4 products per order, deterministic spread.
INSERT INTO demo.order_items (order_id, product_id, qty, unit_price)
SELECT o.id,
       p.id,
       1 + ((o.id + n) % 3),
       p.price
FROM demo.orders o
CROSS JOIN LATERAL generate_series(1, 1 + (o.id * 7) % 4) AS n
JOIN demo.products p ON p.id = 1 + ((o.id * 13 + n * 101) % 1000);

-- Fresh statistics for the planner (this exact step is taught in 07).
ANALYZE demo.customers;
ANALYZE demo.products;
ANALYZE demo.orders;
ANALYZE demo.order_items;

-- Sanity report:
SELECT 'customers' AS table_, count(*) FROM demo.customers
UNION ALL SELECT 'products', count(*) FROM demo.products
UNION ALL SELECT 'orders', count(*) FROM demo.orders
UNION ALL SELECT 'order_items', count(*) FROM demo.order_items;

SELECT category, count(*) AS products FROM demo.products GROUP BY 1 ORDER BY 2 DESC;
SELECT country, count(*) AS customers FROM demo.customers GROUP BY 1 ORDER BY 2 DESC LIMIT 5;
