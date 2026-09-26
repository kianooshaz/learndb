# 12-production/replication — physical streaming replication, live

Logical replication (per-table, cross-version) is covered in
`11-advanced/logical_replication/`. This directory builds the OTHER kind:
physical streaming replication — the byte-level replica that powers HA.

## Start the replica

```bash
make replica        # boots learndb-replica on port 5434
```

The entrypoint (`scripts/replica-entrypoint.sh`) seeds the data directory
with `pg_basebackup -R` from the primary on first boot: a byte-for-byte
copy plus `standby.signal`, which turns the node into a hot standby that
streams WAL. In production you'd also set `primary_conninfo` passwords via
`.pgpass`, replication slots (`-C -S slotname`) so the primary retains WAL
for a down replica, and Patroni/pg_auto_failover for automated failover.

## The demo flow

```bash
# 1. On the PRIMARY (5432): write something + check the stream:
docker compose exec postgres psql -U postgres -d learndb \
  -c "CREATE TABLE IF NOT EXISTS m12_repl (id int, note text); \
      INSERT INTO m12_repl VALUES (1, 'streamed');"

docker compose exec postgres psql -U postgres -d learndb -c "
  SELECT application_name, state, sync_state,
         pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
  FROM pg_stat_replication;"

# 2. On the REPLICA (5434): read it (usually <50ms later), and notice it's read-only:
docker compose exec replica psql -U postgres -d learndb \
  -c "TABLE m12_repl;" \
  -c "INSERT INTO m12_repl VALUES (2, 'nope');"
#   ERROR: cannot execute INSERT in a read-only transaction

# 3. Watch the catch-up lag live (monitoring.sql section 6):
go run ./12-production/monitoring/probe -interval 1s
# then write a burst on the primary and watch replicas=N lag=... spike and drain.
```

## What to internalize

- **async by default**: `synchronous_commit=on` waits for LOCAL disk only;
  the replica may lag milliseconds-to-seconds. Transactions acknowledged
  before the replica has them can be lost on primary death (set
  `synchronous_standby_names` for RPO=0, at commit-latency cost).
- **replication lag** is THE metric: bytes (`pg_stat_replication.replay_lsn`
  delta) and time (`replay_lag`). Alert on both.
- **failover** = promote (`pg_promote()` on the replica / trigger file),
  repoint clients (DNS/hosts), and never let the old primary come back as
  primary without `pg_rewind` — split brain is the classic outage.
- **read scaling**: point reports at 5434; but a replica is eventually
  consistent — your "read your own write" flows must read the primary.
- hot_standby_feedback=on removes cancel-on-conflict pain at a vacuum cost.

## Cleanup

```bash
docker compose --profile replica stop replica   # or: make down
```
