#!/usr/bin/env bash
# Restore a backup made by backup.sh.
# Usage:  DB_USER=root ./restore.sh backups/hospital_db_20261009_021500.sql.gz [target_db]
#   target_db (optional): restore into a DIFFERENT database name, e.g. hospital_db_restored,
#   so you can verify a backup without touching the live database.
# Password: export MYSQL_PWD=... (never put it on the command line).
set -euo pipefail

FILE="${1:-}"
TARGET="${2:-}"
DB_USER="${DB_USER:-root}"
DB_HOST="${DB_HOST:-localhost}"
SOURCE_DB="${DB_NAME:-hospital_db}"

[[ -n "$FILE" && -f "$FILE" ]] || { echo "Usage: $0 <backup.sql.gz> [target_db]" >&2; exit 1; }
gzip -t "$FILE" || { echo "Backup file is corrupt: $FILE" >&2; exit 1; }

if [[ -z "$TARGET" || "$TARGET" == "$SOURCE_DB" ]]; then
  echo "This will OVERWRITE $SOURCE_DB on $DB_HOST."
  if [[ "${3:-}" != "--yes" ]]; then
    read -r -p "Continue? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  fi
  gunzip -c "$FILE" | mysql -u"$DB_USER" -h"$DB_HOST"
  echo "Restored into $SOURCE_DB."
else
  # Rewrite the database name in the dump so the live database is left alone
  mysql -u"$DB_USER" -h"$DB_HOST" -e "DROP DATABASE IF EXISTS \`$TARGET\`; CREATE DATABASE \`$TARGET\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  gunzip -c "$FILE" \
    | sed -e "/^CREATE DATABASE/d" -e "/^USE \`$SOURCE_DB\`;/d" \
    | mysql -u"$DB_USER" -h"$DB_HOST" "$TARGET"
  echo "Restored into $TARGET (live $SOURCE_DB untouched)."
fi
