# Sharding with Citus — the production extension

`02_fdw_sharding.sql` shows the architecture; Citus is that architecture done
for you: distributed planner, colocation, reference tables, parallel
scatter-gather, online rebalancer, distributed DDL.

```bash
make citus        # Citus on port 5436 (first run pulls the image)
make sql-citus FILE=11-advanced/sharding/citus.sql
docker compose exec citus psql -U postgres -d learndb    # interactive
```

> If `make citus` fails with `403 Forbidden` from registry-1.docker.io,
> you're hitting Docker Hub's anonymous pull rate limit (it resets within
> the hour) — retry later or `docker login`. The image tag pinned in
> docker-compose.yml is `citusdata/citus:postgres_16`.

The `citus.sql` lab covers, hands-on:

- `create_distributed_table('events','user_id')` — hash-sharded table; watch
  routed (single-shard) vs scatter-gather plans.
- **Colocation** — tables sharing a distribution column get matching shard
  layouts, so joins on that column execute **locally on workers**; only
  aggregates return to the coordinator.
- **Reference tables** — `create_reference_table()` replicates small
  dimension tables to every shard (the broadcast join done right).
- **Rebalancer** — `SELECT rebalance_table_shards('events')` moves shards
  between nodes online; single-node labs can't show movement, but the
  machinery (shard placement metadata in `citus_shards`) is visible.
- The honest limits: global uniqueness on non-distribution columns still
  needs UUIDs/ranges/tickets; multi-shard writes use 2PC coordination.

## When to choose which level

| Situation | Choice |
|---|---|
| One hot table > RAM/write ceiling, standard queries | partitioning first (11-advanced/partitioning) |
| A few services, natural boundaries | vertical split (own DB per service) |
| Multi-tenant SaaS, `tenant_id` on every query | app-level sharding (`app_router/`) or Citus |
| Need distributed joins, rebalancing, MX (multi-statement) | Citus |
| Planet-scale with custom topologies | bespoke (Vitess-style ideas, app-level) |

Deployment note: real Citus clusters run one coordinator + N workers
(`citusdata/citus` images for each; `SELECT * from citus_add_node(...)`).
The lab's single-node Citus exercises every query-path concept; shard
*placement* is what extra nodes add.
