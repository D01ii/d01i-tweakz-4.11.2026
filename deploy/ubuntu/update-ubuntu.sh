#!/usr/bin/env bash
# D01i Tweakz - aktualizacja backendu na Ubuntu (bez utraty danych:
# baza, klucze i .env zostają). Procedura: backup -> podmiana kodu ->
# migracje -> restart -> healthcheck -> w razie problemu rollback.
set -euo pipefail
APP_NAME="d01i-tweakz"
APP_DIR="/opt/${APP_NAME}"
BACKUP_DIR="/var/backups/${APP_NAME}"

if [ "$(id -u)" -ne 0 ]; then echo "Uruchom jako root." >&2; exit 1; fi

SRC_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../backend" && pwd)}"
[ -d "${SRC_DIR}/src" ] || { echo "Nie znaleziono kodu źródłowego: ${SRC_DIR}" >&2; exit 1; }

echo "[update] Backup bazy danych..."
mkdir -p "${BACKUP_DIR}"
sudo -u postgres pg_dump d01i_tweakz | gzip > "${BACKUP_DIR}/pre-update-$(date +%Y%m%d-%H%M%S).sql.gz"

echo "[update] Backup kodu..."
TMP_BACKUP="$(mktemp -d)"
cp -r "${APP_DIR}/src" "${APP_DIR}/package.json" "${TMP_BACKUP}/" 2>/dev/null || true

echo "[update] Podmiana kodu..."
cp -r "${SRC_DIR}/src" "${SRC_DIR}/migrations" "${SRC_DIR}/package.json" "${SRC_DIR}/package-lock.json" "${APP_DIR}/"
cd "${APP_DIR}"
npm ci --omit=dev --no-audit --no-fund
chown -R "${APP_NAME}:${APP_NAME}" "${APP_DIR}"

echo "[update] Migracje..."
sudo -u "${APP_NAME}" bash -c "set -a; source /etc/${APP_NAME}/.env; set +a; node src/db/migrate.js"

echo "[update] Restart usługi..."
systemctl restart d01i-backend
sleep 3

if curl -fsS http://127.0.0.1:8080/api/v1/admin/ops/health >/dev/null 2>&1; then
  echo "[update] OK - healthcheck przeszedł."
  rm -rf "${TMP_BACKUP}"
else
  echo "[update][BŁĄD] healthcheck nieudany - ROLLBACK kodu..." >&2
  cp -r "${TMP_BACKUP}/src" "${APP_DIR}/src" 2>/dev/null || true
  systemctl restart d01i-backend
  echo "[update] Przywrócono poprzedni kod. Baza NIE była ruszana. Sprawdź: journalctl -u d01i-backend" >&2
  exit 1
fi
