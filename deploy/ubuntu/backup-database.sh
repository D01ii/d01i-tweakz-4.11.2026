#!/usr/bin/env bash
# D01i Tweakz - backup bazy PostgreSQL (R7: SZYFROWANY, fail-closed, z rotacja i checksum).
# Wymaga klucza szyfrujacego POZA serwerem backupów: BACKUP_KEY_FILE (domyslnie
# /etc/d01i-tweakz/backup.key, 600 root:root, 32 bajty raw lub hex). Bez klucza skrypt
# NIE wykona nieszyfrowanego backupu.
set -euo pipefail
umask 077

BACKUP_DIR="${BACKUP_DIR:-/var/backups/d01i-tweakz}"
KEEP_DAYS="${KEEP_DAYS:-14}"
DB_NAME="${DB_NAME:-d01i_tweakz}"
KEY_FILE="${BACKUP_KEY_FILE:-/etc/d01i-tweakz/backup.key}"

if [ "$(id -u)" -ne 0 ]; then echo "Uruchom jako root." >&2; exit 1; fi
if [ ! -f "${KEY_FILE}" ]; then
  echo "[backup] Brak klucza ${KEY_FILE} - odmawiam nieszyfrowanego backupu." >&2
  echo "[backup] Wygeneruj: openssl rand -hex 32 > ${KEY_FILE} && chmod 600 ${KEY_FILE} && chown root:root ${KEY_FILE}" >&2
  echo "[backup] Klucz przechowuj TAKZE offline (poza serwerem) - bez niego nie odtworzysz backupu." >&2
  exit 1
fi
if [ "$(stat -c %a "${KEY_FILE}")" != "600" ]; then echo "[backup] Klucz musi miec chmod 600." >&2; exit 1; fi

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BACKUP_DIR}/${DB_NAME}-${STAMP}.sql.gz.enc"
TMP="${OUT}.tmp"

sudo -u postgres pg_dump "${DB_NAME}" | gzip | \
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass "file:${KEY_FILE}" -out "${TMP}"
mv "${TMP}" "${OUT}"
chmod 600 "${OUT}"
# checksum do kontroli integralnosci
sha256sum "${OUT}" > "${OUT}.sha256"
chmod 600 "${OUT}.sha256"
echo "[backup] Zapisano zaszyfrowany ${OUT} ($(du -h "${OUT}" | cut -f1)) + sha256"
# Rotacja
find "${BACKUP_DIR}" -name "${DB_NAME}-*.sql.gz.enc" -mtime +"${KEEP_DAYS}" -delete
find "${BACKUP_DIR}" -name "${DB_NAME}-*.sql.gz.enc.sha256" -mtime +"${KEEP_DAYS}" -delete
echo "[backup] Rotacja: kopie z ostatnich ${KEEP_DAYS} dni."
echo "[backup] Odtworzenie: openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass file:${KEY_FILE} -in PLIK.enc | gunzip | sudo -u postgres psql ${DB_NAME}"
