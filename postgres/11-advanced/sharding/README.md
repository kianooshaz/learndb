# 11-advanced/sharding — distributing one logical database across many

Sharding = splitting a table's rows across independent databases (shards),
each on its own instance, with something that routes queries to the right
shard. PostgreSQL has no built-in "sharding mode" — you build it at one of
three levels, and this module does all three hands-on.

## Why shard (and the ladder you climb first)

Sharding is the LAST rung, not the first. In order:

1. **Indexes + query tuning** (04, 05) — fixes 90% of "slow".
2. **Read replicas** (12-production/replication) — scales reads.
3. **Partitioning** (11-advanced/partitioning) — one instance, huge tables,
   instant retention. NOT sharding: same CPU/RAM/disk pool.
4. **Vertical split** — move services/tables to their own instances.
5. **Sharding** — many instances share one hot table. You only land here
   when a SINGLE table's write volume or working set outgrows one machine.

What sharding buys: write throughput and storage scale horizontally.
What it costs: almost everything else — see "the hard problems" below.

## The three strategies (where the routing decision lives)

| Level | Router | Files here |
|---|---|---|
| Application-level | YOUR Go code picks the shard per query | `app_router/` |
| Coordinator (FDW) | Postgres itself routes via partitioned foreign tables | `02_fdw_sharding.sql` |
| Extension (Citus) | dedicated distributed planner + rebalancer | `citus.md` |

All three make the same core decision: **shard key → shard**.

## Shard keys — the decision you can't take back cheaply

- **Hash(key) % N** — even spread; range queries must scatter. `01_shard_key.sql`.
- **Range(key)** — natural for time/ids; risks hot newest shard.
- **Directory/lookup table** — a mapping service; most flexible, adds an
  indirection and a moving part.

Rules of thumb:
- Shard by the entity your OLTP queries are ABOUT (user_id, tenant_id) so
  single-entity queries hit exactly ONE shard (the whole point).
- Compound the key carefully: shard=(tenant_id) means tenant data colocates;
  shard=(user_id) inside a tenant-heavy app splits tenants across shards.
- Skew kills you: `01_shard_key.sql` measures it. A shard key where one
  value = 30% of rows means one shard does 30% of the work — you built a
  distributed system to recreate your bottleneck.

## The hard problems (what actually hurts)

- **Cross-shard queries**: WHERE without the shard key fans out to every
  shard (scatter-gather) — latency = slowest shard.
- **Global uniqueness**: `id bigint PRIMARY KEY` only guarantees uniqueness
  WITHIN a shard. Options: ranges per shard, UUIDs, or a central sequence —
  `02_fdw_sharding.sql` shows the failure and `app_router/` implements fixes.
- **Cross-shard transactions**: no distributed ACID out of the box. Patterns:
  avoid by design (colocate!), two-phase commit (PREPARE TRANSACTION),
  or sagas/compensations with outboxes.
- **Rebalancing**: adding shard N+1 with `hash % N` moves almost every row.
  Consistent hashing / directory-based mapping shrink the blast radius.
- **Schema changes**: N shards to migrate, coordinated.

## Files

| File | What you run |
|---|---|
| `01_shard_key.sql` | hash distribution, skew measurement, key choice experiments |
| `02_fdw_sharding.sql` | build a 3-shard cluster with postgres_fdw + hash partitions; watch routing, pruning, scatter, and the uniqueness failure |
| `app_router/main.go` | Go router: per-shard pools, deterministic routing, scatter-gather top-N, per-shard vs global ids |
| `citus.md` | the production extension: distributed/colocated/reference tables, rebalancer; compose profile included |

Start with `01_shard_key.sql`; it's pure SQL on the main lab database.
