# PostgreSQL Laboratory — learn by running everything

A runnable curriculum for going from PostgreSQL fundamentals to production
engineering, **in Go and SQL**. Nothing here is theory-only: every concept
is a file you execute and observe. Built around [pgx v5](https://github.com/jackc/pgx)
and PostgreSQL 16.

```
make up                      # start the lab database (Docker)
make psql                    # interactive shell
make sql FILE=01-basics/tables.sql       # run one SQL lab
go run ./01-basics/go                    # run one Go lab
```

- **Prereqs**: Docker, Go ≥1.22. Ports: `5432` main lab DB (user/pass
  `postgres`/`postgres`, database `learndb`).
- **Everything is idempotent**: labs drop/recreate their own schemas — rerun
  freely, change numbers, break things, rerun.
- Each file's header comment states exactly how to run it and what to watch.

## Curriculum map (recommended order)

| Module | What you will be able to do afterwards |
|---|---|
| `01-basics/` | databases/schemas/tables, CRUD with RETURNING & upserts, constraints (incl. NULL traps, FK actions, deferrable), transactions & savepoints + the pgx app-side twin |
| `02-data-types/` | every type's storage/perf/indexing/gotchas: numeric vs float for money, `char/varchar/text`, timestamptz truths, three-valued logic, uuid vs bigint keys, json vs jsonb, arrays, enums, ranges + exclusion constraints, composites, domains, inet/geometry |
| `demo/` | shared e-commerce dataset (10k/1k/50k/125k rows, deterministic, skewed on purpose) |
| `03-queries/` | joins (incl. fan-out double-count bug), subqueries vs EXISTS vs NOT IN NULL trap, CTEs (MATERIALIZED), recursive CTEs with cycle guards, window functions & frames & top-N-per-group, LATERAL, aggregates (FILTER, ROLLUP/CUBE), set ops & table-diffing |
| `04-indexes/` | btree/hash/gin/gist/spgist/brin each as experiments; partial, expression, covering (INCLUDE, heap fetches), multicolumn ordering; **"why did Postgres NOT use my index"** answered six ways |
| `05-query-planning/` | reading EXPLAIN trees, ANALYZE+BUFFERS, scan types & when each wins, join algorithms (incl. work_mem spills, Memoize), planner statistics (MCVs, correlation, extended stats, stale-stats demos) |
| `06-transactions/` | MVCC (xmin/xmax/HOT, live), isolation levels & anomalies, lock modes & queues, deadlocks + the ordering fix, FOR UPDATE family & SKIP LOCKED, advisory locks, SERIALIZABLE write-skew (40001) |
| `07-performance/` | slow-query walkthrough (measure→fix→re-measure), index lifecycle (CONCURRENTLY, idx_scan audits), autovacuum tuning, VACUUM/FREEZE/wraparound, ANALYZE mechanics, bloat (incl. long-tx pinning), connection math, prepared-statement generic-plan trap, benchmarks (OFFSET vs keyset!) |
| `08-concurrency/` | Go programs: MVCC live, **deterministic lost-update** + 3 fixes, check-then-act races + atomic claims, optimistic versioning with retry, pessimistic SKIP LOCKED queues + **deadlock reproduced & fixed** |
| `09-json/` | json (verbatim) vs jsonb (operators, editing, @>), jsonpath, building API shapes in SQL, GIN ops vs path_ops vs expression indexes, doc-size/TOAST/update-economics + the generated-column hybrid |
| `10-extensions/` | uuid-ossp v5 determinism, pgcrypto (crypt/gen_salt login query!), pg_trgm (indexed `ILIKE '%x%'`, KNN), citext, btree_gin/gist, pg_stat_statements, pgstattuple/pageinspect tour, PostGIS (opt-in container) |
| `11-advanced/` | partitioning (pruning, retention, PK rule), matviews (CONCURRENTLY), deep recursive patterns, generated columns, triggers (transition tables, soft delete), functions (VOLATILITY trap demo!), procedures (chunked COMMIT backfill), full-text search, row-level security (pool-safe tenant context), postgres_fdw pushdown, logical replication (2-instance lab) |
| `11-advanced/sharding/` | **the sharding curriculum**: shard-key math & skew, modulo vs consistent-hash resharding; postgres_fdw coordinator sharding (routing, pruning, no-global-uniqueness); Go app-level router (scatter-gather top-N); Citus (opt-in container) |
| `12-production/` | zero-downtime migration cookbook + a checksummed advisory-locked migration runner; pg_dump formats + a **verified backup→restore drill**; monitoring query pack + Go probe; PgBouncer (opt-in); physical streaming replica (opt-in); failure scenarios in Go (crash-rollback, timeouts, pool starvation) |
| `13-go-postgres/` | pgx deep-dive: pools vs conns, scan patterns, tx discipline & isolation, statement cache, Batch pipelining, CopyFrom, context cancellation (server-side cancel proof), SQLSTATE→HTTP mapping, retry loop with backoff+jitter, benchmarks |

### The opt-in containers (compose profiles)

| Target | Command | Port | Used by |
|---|---|---|---|
| PostGIS | `make postgis` | 5433 | `10-extensions/postgis/` |
| Logical-replication subscriber | `make logical` | 5435 | `11-advanced/logical_replication/` |
| Citus | `make citus` | 5436 | `11-advanced/sharding/` |
| Streaming replica | `make replica` | 5434 | `12-production/replication/` |
| PgBouncer | `make pgbouncer` | 6432 | `12-production/connection_pooling/` |

> If a profile fails with `403 Forbidden` from docker.io, you've hit Docker
> Hub's anonymous pull rate limit — retry within the hour or `docker login`.

## Conventions

- SQL labs own a schema (`mNN_topic`) and reset it — safe to run in any
  order, any number of times. Files needing `make demo` say so up top.
- Labs that intentionally trigger errors toggle `ON_ERROR_STOP off` around
  them; everything else stops on first error (the honest default).
- Go labs share `internal/dsn` (`DATABASE_URL` override) and `internal/db`
  (connect-with-retry). Read them once: they're deliberately tiny.
- Two-terminal experiments (isolation, locks) are written as precise A/B
  scripts in the SQL files AND automated deterministically in `08-concurrency/`.

## Suggested study loop

1. Run the file, read the output against the file's comments.
2. Change a number (selectivity, work_mem, batch size, worker count) and
   predict the difference before rerunning.
3. Break it on purpose: comment out an index, drop statistics, add a whale
   row — the labs are cheap to reset.
4. For concurrency labs: run two terminals, be session A and B yourself.

## Verified status

Every SQL file and Go program in this repository has been executed against
the compose stack (see `make verify-sql`), with two environment-bound
exceptions: the Citus and PgBouncer profiles couldn't be *pulled* during the
build window due to Docker Hub rate limits — their labs are written and
configured, and will run once the images pull (`make citus` / `make pgbouncer`).
