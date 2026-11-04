#!/usr/bin/env bash
# D01i Tweakz - backup bazy PostgreSQL (dump + gzip), z rotacją (domyślnie 14 dni).
set -euo pipefail
BACKUP_DIR="${BACKUP_DIR:-/var/backups/d01i-tweakz}"
KEEP_DAYS="${KEEP_DAYS:-14}"
DB_NAME="${DB_NAME:-d01i_tweakz}"

if [ "$(id -u)" -ne 0 ]; then echo "Uruchom jako root." >&2; exit 1; fi
mkdir -p "${BACKUP_DIR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BACKUP_DIR}/${DB_NAME}-${STAMP}.sql.gz"
sudo -u postgres pg_dump "${DB_NAME}" | gzip > "${OUT}"
chmod 600 "${OUT}"
echo "[backup] Zapisano ${OUT} ($(du -h "${OUT}" | cut -f1))"
# Rotacja: kasuj starsze niż KEEP_DAYS
find "${BACKUP_DIR}" -name "${DB_NAME}-*.sql.gz" -mtime +"${KEEP_DAYS}" -delete
echo "[backup] Rotacja: pozostawiono kopie z ostatnich ${KEEP_DAYS} dni."
