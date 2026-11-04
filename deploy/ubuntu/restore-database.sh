#!/usr/bin/env bash
# D01i Tweakz - przywracanie bazy z backupu.
# UWAGA: nadpisuje bieżącą bazę! Rób to przy zatrzymanej usłudze.
set -euo pipefail
DB_NAME="${DB_NAME:-d01i_tweakz}"

if [ "$(id -u)" -ne 0 ]; then echo "Uruchom jako root." >&2; exit 1; fi
if [ $# -lt 1 ]; then echo "Użycie: sudo $0 /var/backups/d01i-tweakz/d01i_tweakz-YYYYMMDD-HHMMSS.sql.gz" >&2; exit 1; fi
DUMP="$1"
[ -f "${DUMP}" ] || { echo "Nie ma pliku: ${DUMP}" >&2; exit 1; }

echo "[restore] Zatrzymywanie usługi..."
systemctl stop d01i-backend || true

echo "[restore] Odtwarzanie bazy ${DB_NAME} z ${DUMP}..."
if [[ "${DUMP}" == *.gz ]]; then
  sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${DB_NAME};"
  sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER d01i_app;"
  zcat "${DUMP}" | sudo -u postgres psql -d "${DB_NAME}" -q
else
  sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${DB_NAME};"
  sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER d01i_app;"
  sudo -u postgres psql -d "${DB_NAME}" -q -f "${DUMP}"
fi

echo "[restore] Migracje (idempotentne)..."
sudo -u d01i bash -c "set -a; source /etc/d01i-tweakz/.env; set +a; node /opt/d01i-tweakz/src/db/migrate.js"

systemctl start d01i-backend
echo "[restore] Gotowe. Usługa uruchomiona ponownie."
