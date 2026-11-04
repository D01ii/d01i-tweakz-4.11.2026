#!/usr/bin/env bash
# D01i Tweakz - aktualizacja backendu na Ubuntu.
# Strategia (C1):
#   1. backup bazy (dump) - na wypadek, gdyby migracja byla nieodwracalna;
#   2. backup KODU i manifestu zaleznosci (src, package.json, package-lock.json);
#   3. podmiana kodu + npm ci + migracje (expand/contract - stary kod dziala z nowym schematem);
#   4. restart + healthcheck;
#   5. przy bledzie: rollback KODU i zaleznosci (nie dotykamy bazy automatycznie -
#      dane mogly powstac po aktualizacji; przywrocenie bazy robimy recznie przez
#      restore-database.sh z backupu z kroku 1).
set -euo pipefail
APP_NAME="d01i-tweakz"
APP_DIR="/opt/${APP_NAME}"
BACKUP_DIR="/var/backups/${APP_NAME}"

if [ "$(id -u)" -ne 0 ]; then echo "Uruchom jako root." >&2; exit 1; fi

SRC_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../backend" && pwd)}"
[ -d "${SRC_DIR}/src" ] || { echo "Nie znaleziono kodu źródłowego: ${SRC_DIR}" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"

# Katalog backupow musi istniec PRZED mktemp; nie kontynuujemy bez mozliwosci zapisu.
mkdir -p "${BACKUP_DIR}" || { echo "[update][BŁĄD] nie mozna utworzyc ${BACKUP_DIR}" >&2; exit 1; }
[ -w "${BACKUP_DIR}" ] || { echo "[update][BŁĄD] ${BACKUP_DIR} nie jest zapisywalny" >&2; exit 1; }
TMP_BACKUP="$(mktemp -d "${BACKUP_DIR}/code-${STAMP}-XXXX")"

echo "[update] 1/6 Backup bazy danych..."
sudo -u postgres pg_dump d01i_tweakz | gzip > "${BACKUP_DIR}/pre-update-${STAMP}.sql.gz"
chmod 600 "${BACKUP_DIR}/pre-update-${STAMP}.sql.gz"
echo "[update]    zapisano ${BACKUP_DIR}/pre-update-${STAMP}.sql.gz"

echo "[update] 2/6 Backup kodu, migracji i manifestu..."
cp -a "${APP_DIR}/src" "${APP_DIR}/migrations" "${APP_DIR}/package.json" "${APP_DIR}/package-lock.json" "${TMP_BACKUP}/"
echo "[update]    backup kodu: ${TMP_BACKUP}"

rollback() {
  echo "[update][BŁĄD] Rollback kodu i zależności do stanu sprzed aktualizacji..." >&2
  systemctl stop d01i-backend 2>/dev/null || true
  rm -rf "${APP_DIR}/src" "${APP_DIR}/migrations"
  cp -a "${TMP_BACKUP}/src" "${TMP_BACKUP}/migrations" "${TMP_BACKUP}/package.json" "${TMP_BACKUP}/package-lock.json" "${APP_DIR}/"
  (cd "${APP_DIR}" && npm ci --omit=dev --no-audit --no-fund) || echo "[update] npm ci podczas rollbacku nieudane - sprawdź ręcznie" >&2
  chown -R "${APP_NAME}:${APP_USER:-${APP_NAME}}" "${APP_DIR}" 2>/dev/null || chown -R "${APP_NAME}:${APP_NAME}" "${APP_DIR}"
  systemctl start d01i-backend || true
  echo "[update] UWAGA: schemat bazy NIE jest automatycznie cofany. Jeśli migracja była nieodwracalna," >&2
  echo "[update] przywróć bazę ręcznie: sudo bash deploy/ubuntu/restore-database.sh ${BACKUP_DIR}/pre-update-${STAMP}.sql.gz" >&2
  exit 1
}
trap rollback ERR

echo "[update] 3/6 Podmiana kodu..."
rm -rf "${APP_DIR}/src"
cp -a "${SRC_DIR}/src" "${SRC_DIR}/migrations" "${SRC_DIR}/package.json" "${SRC_DIR}/package-lock.json" "${APP_DIR}/"
cd "${APP_DIR}"
npm ci --omit=dev --no-audit --no-fund
chown -R "${APP_NAME}:${APP_NAME}" "${APP_DIR}"

echo "[update] 4/6 Migracje (idempotentne)..."
sudo -u "${APP_NAME}" bash -c "set -a; source /etc/${APP_NAME}/.env; set +a; node src/db/migrate.js"

echo "[update] 5/6 Restart + healthcheck..."
systemctl restart d01i-backend
sleep 3
if curl -fsS http://127.0.0.1:8080/api/v1/admin/ops/health >/dev/null 2>&1; then
  trap - ERR
  echo "[update] 6/6 OK - healthcheck przeszedł. Aktualizacja zakończona."
  echo "[update] Backup kodu zachowany w ${TMP_BACKUP} (można usunąć ręcznie)."
  find "${BACKUP_DIR}" -name 'pre-update-*.sql.gz' -mtime +14 -delete
else
  echo "[update] healthcheck nieudany" >&2
  rollback
fi
