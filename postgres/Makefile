# PostgreSQL Laboratory — Makefile
#
# Common flows:
#   make up                      start the lab database
#   make psql                    interactive SQL shell
#   make sql FILE=01-basics/tables.sql        run one SQL lab file
#   go run ./01-basics/go                     run one Go lab program
#   make reset                   destroy + recreate the database (fresh state)

COMPOSE := docker compose
PSQL    := $(COMPOSE) exec -T postgres psql -v ON_ERROR_STOP=1 -U postgres -d learndb

# Go lab programs read this. Override with: make sql ... DSN=postgres://...
DSN ?= postgres://postgres:postgres@localhost:5432/learndb
export DATABASE_URL := $(DSN)

.PHONY: up down reset psql logs sql sql-postgis postgis pgbouncer replica demo go-build go-vet verify-sql

up:
	$(COMPOSE) up -d --wait postgres

down:
	$(COMPOSE) down

reset:            ## nuke data volume and start fresh
	$(COMPOSE) down -v
	$(COMPOSE) up -d --wait postgres

psql:             ## interactive shell
	$(COMPOSE) exec postgres psql -U postgres -d learndb

logs:
	$(COMPOSE) logs -f postgres

sql:              ## usage: make sql FILE=01-basics/tables.sql
	$(PSQL) -f - < $(FILE)

sql-postgis:      ## usage: make sql-postgis FILE=10-extensions/postgis/basics.sql
	$(COMPOSE) exec -T postgis psql -v ON_ERROR_STOP=1 -U postgres -d learndb -f - < $(FILE)

postgis:          ## opt-in PostGIS container on port 5433
	$(COMPOSE) --profile postgis up -d --wait postgis

pgbouncer:        ## opt-in PgBouncer on port 6432
	$(COMPOSE) --profile pgbouncer up -d --wait pgbouncer

replica:          ## opt-in streaming replica on port 5434
	$(COMPOSE) --profile replica up -d --wait replica

logical:          ## opt-in subscriber instance on port 5435 (logical replication lab)
	$(COMPOSE) --profile logical up -d --wait shopdb

citus:            ## opt-in Citus (sharding) on port 5436
	$(COMPOSE) --profile citus up -d --wait citus

sql-citus:        ## usage: make sql-citus FILE=11-advanced/sharding/citus.sql
	$(COMPOSE) exec -T citus psql -v ON_ERROR_STOP=1 -U postgres -d learndb -f - < $(FILE)

demo:             ## seed the shared e-commerce dataset used by modules 03-05
	$(PSQL) -f - < demo/setup.sql

go-build:
	go build ./...

go-vet:
	go vet ./...

# Runs every lab SQL file in order (against the MAIN database). Files that
# need OTHER containers are excluded: 10-extensions/postgis/* (make postgis),
# 11-advanced/sharding/citus.sql (make citus). Everything else is idempotent;
# module 06's two-session protocols are additionally automated by the Go
# programs in 08-concurrency/.
verify-sql:
	@for f in $(sort $(wildcard */*.sql) $(wildcard */*/*.sql) demo/*.sql); do \
		case "$$f" in \
			10-extensions/postgis/*|11-advanced/sharding/citus.sql) \
				echo "=== $$f: SKIPPED (needs its own container — see file header)" ;; \
			*) echo "=== $$f"; \
			   $(PSQL) -q -f - < $$f >/dev/null || { echo "FAILED: $$f"; exit 1; } ;; \
		esac; \
	done; echo "ALL SQL FILES OK"
