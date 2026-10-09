#!/usr/bin/env bash
# Logical backup of hospital_db: tables, data, stored procedures, views and triggers.
# Usage:  DB_USER=root ./backup.sh            -> backups/hospital_db_YYYYmmdd_HHMMSS.sql.gz
# Password: export MYSQL_PWD=... (never put it on the command line).
# Schedule it with cron, e.g. nightly at 02:00:   0 2 * * * /path/to/backup.sh
set -euo pipefail
cd "$(dirname "$0")"

DB_NAME="${DB_NAME:-hospital_db}"
DB_USER="${DB_USER:-root}"
DB_HOST="${DB_HOST:-localhost}"
KEEP_DAYS="${KEEP_DAYS:-14}"
OUT_DIR="backups"
mkdir -p "$OUT_DIR"

# mysqldump (MySQL) or mariadb-dump (MariaDB)
DUMP="$(command -v mysqldump || command -v mariadb-dump)" || { echo "mysqldump not found" >&2; exit 1; }

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$OUT_DIR/${DB_NAME}_${STAMP}.sql.gz"

# --single-transaction: consistent snapshot without locking InnoDB tables
"$DUMP" -u"$DB_USER" -h"$DB_HOST" \
  --single-transaction --routines --triggers --events \
  --databases "$DB_NAME" | gzip > "$OUT"

# Refuse to call it a success if the file is empty or not valid gzip
gzip -t "$OUT"
[[ -s "$OUT" ]] || { echo "Backup file is empty" >&2; exit 1; }

# Delete backups older than KEEP_DAYS
find "$OUT_DIR" -name "${DB_NAME}_*.sql.gz" -mtime +"$KEEP_DAYS" -delete

echo "Backup OK: $OUT ($(du -h "$OUT" | cut -f1))"
