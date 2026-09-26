#!/bin/bash
# Runs on FIRST container boot (docker-entrypoint-initdb.d).
# Physical streaming replication (12-production/replication) needs an
# explicit pg_hba entry for replication connections — the stock image only
# adds `host all all all`. Allow it from anywhere on the compose network
# with password auth (POSTGRES_PASSWORD).
set -e
HBA="${PGDATA}/pg_hba.conf"
if ! grep -q "replication all all" "$HBA"; then
    echo "host replication all all scram-sha-256" >> "$HBA"
    echo "03-replication-hba: added replication pg_hba entry"
fi
