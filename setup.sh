#!/usr/bin/env bash
# Builds the whole hospital_db from scratch (DESTRUCTIVE: drops and recreates hospital_db).
# Usage:  DB_USER=root DB_HOST=localhost ./setup.sh
# Password: export MYSQL_PWD=... (never put it on the command line).
set -euo pipefail
cd "$(dirname "$0")"

DB_USER="${DB_USER:-root}"
DB_HOST="${DB_HOST:-localhost}"
MYSQL=(mysql -u"$DB_USER" -h"$DB_HOST")

echo "This will DROP and recreate hospital_db on $DB_HOST as $DB_USER."
if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

for f in schema.sql procedures.sql views_and_roles.sql sample_data.sql indexes.sql; do
  echo "-> $f"
  "${MYSQL[@]}" < "$f"
done
echo "Done. Row counts:"
"${MYSQL[@]}" hospital_db -e "SELECT 'patients' AS tbl, COUNT(*) AS n FROM patients
  UNION ALL SELECT 'doctors', COUNT(*) FROM doctors
  UNION ALL SELECT 'appointments', COUNT(*) FROM appointments
  UNION ALL SELECT 'invoices', COUNT(*) FROM invoices;"
