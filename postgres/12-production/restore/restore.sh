#!/usr/bin/env bash
# ============================================================================
# 12-production/restore/restore.sh — the drill: restore into a scratch db
# ============================================================================
# Usage:
#   ./12-production/restore/restore.sh backups/<your-dump>.dump
#
# The rule this drill enforces: A BACKUP THAT HAS NEVER BEEN RESTORED IS A
# HOPE, NOT A BACKUP. Restore on a schedule, TIME it, compare row counts.
# RTO = how long this took.
# ============================================================================
set -euo pipefail

DUMP="${1:?usage: restore.sh backups/<dump>.dump}"
DB="restore_drill"

echo "==> dropping and recreating scratch db ${DB} (WITH FORCE kicks sessions)"
docker compose exec -T postgres psql -U postgres -d postgres \
    -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE);" \
    -c "CREATE DATABASE ${DB};"

echo "==> restoring ${DUMP} into ${DB}"
START=$(date +%s)
# custom-format dump piped through stdin (pg_restore reads '-' by default):
docker compose exec -T postgres pg_restore \
    -U postgres -d "${DB}" --no-owner --no-privileges < "${DUMP}"
echo "==> restore took $(( $(date +%s) - START ))s"

echo "==> sanity: objects restored"
docker compose exec -T postgres psql -U postgres -d "${DB}" -c "
    SELECT relname, n_live_tup AS approx_rows
    FROM pg_stat_user_tables
    WHERE schemaname NOT IN ('pg_catalog','information_schema')
    ORDER BY relname LIMIT 12;"

echo "==> selective restore demo: list entries for ONE table"
docker compose exec -T postgres pg_restore --list < "${DUMP}" \
    | grep -i 'TABLE.*customers' || echo "(no customers table in this dump)"

# PITR (point-in-time recovery) outline — WAL archiving + base backup:
#   1. postgresql.conf: archive_mode=on, archive_command='cp %p /archive/%f'
#   2. base backup:     pg_basebackup -D /backup/base -X stream -P
#   3. restore:         copy base into PGDATA; postgresql.conf:
#                         restore_command='cp /archive/%f %p'
#                         recovery_target_time='2026-09-25 12:34:56+00'
#                      touch recovery.signal; start; promote when verified.
#   Production wrappers: pgBackRest, Barman, WAL-G — use one; raw PITR is
#   for understanding what they do.
