#!/bin/bash
# Entry point for the lab's physical streaming replica (12-production/replication).
#
# The official postgres image normally initializes a *fresh, empty* cluster.
# For replication we instead want a byte-for-byte copy of the primary, so on
# first boot we seed the data directory with pg_basebackup before handing
# control back to the standard entrypoint. -R writes standby.signal and
# primary_conninfo into postgresql.auto.conf, which turns this node into a
# hot standby that streams WAL from `postgres`.
set -e

if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
  echo "replica: data dir empty -> pg_basebackup from postgres:5432"
  until pg_isready -h postgres -p 5432 -U postgres; do
    echo "replica: waiting for primary..."
    sleep 1
  done
  PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup \
    -h postgres -p 5432 -U postgres \
    -D "$PGDATA" -R -Fp -Xs -P
  chmod 700 "$PGDATA"
fi

exec docker-entrypoint.sh "$@"
