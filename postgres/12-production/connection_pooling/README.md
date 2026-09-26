# 12-production/connection_pooling — PgBouncer in front of PostgreSQL

Theory: `07-performance/connection_pooling.sql` (connection = process; the
memory math; transaction-mode casualties). This directory runs the real
thing and proves the numbers.

> If `make pgbouncer` fails with `403 Forbidden` from docker.io, you're
> hitting Docker Hub's anonymous pull rate limit (resets within the hour) —
> retry later or `docker login`. Everything else in this README needs the
> container up.

## Start

```bash
make pgbouncer     # PgBouncer on localhost:6432 (transaction pooling mode)
```

Compose wires it: `POOL_MODE=transaction`, `DEFAULT_POOL_SIZE=20`,
`MAX_CLIENT_CONN=200`, pointed at the `postgres` service.

## Experiments

```bash
# 1. Through the pool (6432) vs direct (5432) — same query, same result:
docker compose exec -T pgbouncer psql -h localhost -U postgres -d learndb -c "select 1"
PGPASSWORD=postgres psql -h localhost -p 6432 -U postgres -d learndb -c "select 1"

# 2. The admin console (virtual database "pgbouncer"):
PGPASSWORD=postgres psql -h localhost -p 6432 -U postgres -d pgbouncer \
  -c "SHOW POOLS;" -c "SHOW STATS;"
# cl_active vs sv_active: clients vs actual server connections. Run the Go
# flood below and watch many clients share few backends.

# 3. Scale test: 100 concurrent clients through 20 server connections:
go run ./12-production/connection_pooling/flood
```

## The transaction-mode traps, reproduced

```bash
# a) Session state does NOT stick between transactions:
PGPASSWORD=postgres psql -p 6432 -d learndb -c "SET application_name='oops'" \
  -c "SHOW application_name"
# (may run on different backends -> the SET lands who-knows-where)
# Correct form: SET LOCAL inside a transaction, or per-role settings.

# b) LISTEN/NOTIFY needs a dedicated backend (use port 5432 directly).

# c) SQL-level PREPARE breaks across backends; protocol-level prepared
#    statements work on PgBouncer 1.21+ (this image tracks recent releases).
#    pgx auto-prepare is protocol-level — verify your PgBouncer version
#    before relying on it fleet-wide.
```

## Sizing rules of thumb

- server connections = what PostgreSQL can carry:
  `total = max_connections − admin margin − direct connections`
- clients per server connection: 10–50 for OLTP (bounded by per-transaction
  work), not 1000.
- one PgBouncer can become the bottleneck/outage: run ≥2 behind a VIP/DNS.
