#!/usr/bin/env bash
# ============================================================
# D01i Tweakz - instalator produkcyjny backendu na Ubuntu Server LTS
# Wymaga: Ubuntu 22.04/24.04 LTS, uruchomienie jako root (sudo).
# Instaluje: Node.js 22 LTS, PostgreSQL, Caddy, UFW, systemd,
#            baze danych z ograniczonym użytkownikiem, klucze Ed25519,
#            sekrety, migracje i usługę d01i-backend.
# Idempotentny: bezpiecznie uruchomić ponownie.
# ============================================================
set -euo pipefail

APP_NAME="d01i-tweakz"
APP_USER="d01i"
APP_DIR="/opt/${APP_NAME}"
ENV_FILE="/etc/${APP_NAME}/.env"
KEYS_DIR="/etc/${APP_NAME}/keys"
DB_NAME="d01i_tweakz"
DB_USER="d01i_app"
LOG_DIR="/var/log/${APP_NAME}"
CADDY_DOMAIN="${CADDY_DOMAIN:-api.example.com}"   # zmień na swoją domenę!
CADDY_EMAIL="${CADDY_EMAIL:-admin@example.com}"    # zmień na swój e-mail!

log()  { echo -e "[install] $*"; }
err()  { echo -e "[install][BŁĄD] $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then err "Uruchom jako root: sudo bash install-ubuntu.sh"; exit 1; fi
}

detect_ubuntu() {
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then err "Ten instalator wymaga Ubuntu Server LTS (wykryto: ${ID:-nieznany})."; exit 1; fi
  case "${VERSION_ID:-}" in 22.04|24.04) log "Wykryto Ubuntu ${VERSION_ID} LTS.";; *) err "Wymagana Ubuntu 22.04 lub 24.04 LTS (wykryto ${VERSION_ID:-?})."; exit 1;; esac
}

install_packages() {
  log "Aktualizacja indeksów i instalacja pakietów..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ca-certificates gnupg ufw postgresql postgresql-contrib nodejs npm caddy jq openssl
  # Node.js przez NodeSource tylko jeśli systemowy jest starszy niż 20
  NODE_MAJOR="$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/' || echo 0)"
  if [ "${NODE_MAJOR}" -lt 20 ]; then
    log "Systemowy Node.js (<20) - instalacja Node.js 22 LTS z NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  fi
  node -v | grep -qE '^v(2[0-9]|[3-9][0-9])' || { err "Node.js >= 20 wymagany."; exit 1; }
}

configure_postgres() {
  log "Konfiguracja PostgreSQL (lokalny tylko, bez dostępu z zewnątrz)..."
  systemctl enable --now postgresql
  # Upewnij się, że PostgreSQL słucha tylko na localhost
  PG_CONF="$(su - postgres -c "psql -tAc 'show config_file'")"
  PG_HBA="$(su - postgres -c "psql -tAc 'show hba_file'")"
  grep -q '^listen_addresses' "$PG_CONF" \
    && sed -i "s/^listen_addresses.*/listen_addresses = 'localhost'/" "$PG_CONF" \
    || echo "listen_addresses = 'localhost'" >> "$PG_CONF"
  systemctl restart postgresql

  if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"" | grep -q 1; then
    DB_PASS="$(openssl rand -hex 24)"
    su - postgres -c "psql -c \"CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';\""
    echo "${DB_PASS}" > "/etc/${APP_NAME}/.db_password"
    chmod 600 "/etc/${APP_NAME}/.db_password"
    log "Utworzono użytkownika bazy ${DB_USER} (hasło zapisane w /etc/${APP_NAME}/.db_password)."
  else
    DB_PASS="$(cat /etc/${APP_NAME}/.db_password 2>/dev/null || true)"
    [ -z "$DB_PASS" ] && { DB_PASS="$(openssl rand -hex 24)"; su - postgres -c "psql -c \"ALTER ROLE ${DB_USER} PASSWORD '${DB_PASS}';\""; echo "${DB_PASS}" > "/etc/${APP_NAME}/.db_password"; chmod 600 "/etc/${APP_NAME}/.db_password"; }
    log "Użytkownik bazy ${DB_USER} już istnieje."
  fi

  if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"" | grep -q 1; then
    su - postgres -c "createdb -O ${DB_USER} ${DB_NAME}"
    log "Utworzono bazę ${DB_NAME} (właściciel: ${DB_USER})."
  else
    log "Baza ${DB_NAME} już istnieje - NIE jest kasowana."
  fi
  # Ograniczenie uprawnień: tylko własna baza, brak superuser
  su - postgres -c "psql -c \"ALTER ROLE ${DB_USER} NOSUPERUSER NOCREATEDB NOCREATEROLE;\"" || true
}

ensure_config_dirs() {
  # A1: /etc/d01i-tweakz musi istnieć przed pierwszym zapisem sekretu (.db_password w configure_postgres).
  if [ ! -d "/etc/${APP_NAME}" ]; then
    install -d -m 700 -o root -g root "/etc/${APP_NAME}"
    log "Utworzono /etc/${APP_NAME} (700, root:root)."
  fi
  install -d -m 700 -o root -g root "/etc/${APP_NAME}/keys" 2>/dev/null || true
  mkdir -p "${LOG_DIR}" && chown "${APP_USER}:${APP_USER}" "${LOG_DIR}" 2>/dev/null || true
}

create_app_user() {
  if ! id "${APP_USER}" >/dev/null 2>&1; then
    useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
    log "Utworzono użytkownika systemowego ${APP_USER} (nologin, bez root)."
  fi
}

deploy_app() {
  log "Kopiowanie aplikacji do ${APP_DIR}..."
  mkdir -p "${APP_DIR}"
  # W produkcji: skopiuj zawartość katalogu backend/ z repozytorium.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SRC_DIR="$(cd "${SCRIPT_DIR}/../../backend" && pwd)"
  cp -r "${SRC_DIR}/src" "${SRC_DIR}/migrations" "${SRC_DIR}/package.json" "${SRC_DIR}/package-lock.json" "${APP_DIR}/" 2>/dev/null || true
  cd "${APP_DIR}"
  npm ci --omit=dev --no-audit --no-fund
  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
}

generate_secrets_and_keys() {
  install -d -m 700 -o root -g root "/etc/${APP_NAME}" "${KEYS_DIR}"
  mkdir -p "${LOG_DIR}"

  if [ ! -f "${KEYS_DIR}/ed25519_private.pem" ]; then
    log "Generowanie pary kluczy Ed25519..."
    openssl genpkey -algorithm ed25519 -out "${KEYS_DIR}/ed25519_private.pem"
    openssl pkey -in "${KEYS_DIR}/ed25519_private.pem" -pubout -out "${KEYS_DIR}/ed25519_public.pem"
  fi
  chmod 640 "${KEYS_DIR}/ed25519_private.pem"  # czytelny dla grupy d01i (usluga), nie dla innych
  chmod 644 "${KEYS_DIR}/ed25519_public.pem"

  PEPPER="$(openssl rand -hex 32)"
  if [ ! -f "${ENV_FILE}" ]; then
    DB_PASS="$(cat /etc/${APP_NAME}/.db_password)"
    cat > "${ENV_FILE}" <<EOF
NODE_ENV=production
PORT=8080
HOST=127.0.0.1
PUBLIC_BASE_URL=https://${CADDY_DOMAIN}
DATABASE_URL=postgres://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}
SECURITY_PEPPER=${PEPPER}
ED25519_PRIVATE_KEY_PATH=${KEYS_DIR}/ed25519_private.pem
ED25519_PUBLIC_KEY_PATH=${KEYS_DIR}/ed25519_public.pem
ADMIN_BOOTSTRAP_ENABLED=true
ADMIN_BOOTSTRAP_USERNAME=admin
ADMIN_BOOTSTRAP_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' )
TOKEN_TTL_SECONDS=120
ADMIN_SESSION_TTL_HOURS=8
MAX_DEVICES_DEFAULT=2
DISCORD_WEBHOOK_ENABLED=false
EOF
    log "Wygenerowano ${ENV_FILE} (sekretny). Zmień hasło bootstrap admina po pierwszym logowaniu!"
  else
    log "Plik ${ENV_FILE} już istnieje - pozostawiam bez zmian."
  fi
  # Klucze i .env czyta tylko aplikacja; katalog zostaje root, pliki root:${APP_USER} 640/600.
  chown -R "root:${APP_USER}" "/etc/${APP_NAME}"
  chmod 640 "${ENV_FILE}" "/etc/${APP_NAME}/.db_password" 2>/dev/null || true
  chmod 640 "${KEYS_DIR}/ed25519_private.pem"  # czytelny dla grupy d01i (usluga), nie dla innych
  chmod 644 "${KEYS_DIR}/ed25519_public.pem"
  chown -R "${APP_USER}:${APP_USER}" "${LOG_DIR}"
}

install_systemd() {
  log "Instalacja usługi systemd..."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cp "${SCRIPT_DIR}/../systemd/d01i-backend.service" /etc/systemd/system/d01i-backend.service
  systemctl daemon-reload
  systemctl enable d01i-backend
  systemctl restart d01i-backend
  sleep 2
  systemctl is-active --quiet d01i-backend && log "Usługa d01i-backend aktywna." || { err "Usługa nie wystartowała - sprawdź: journalctl -u d01i-backend"; exit 1; }
}

configure_caddy() {
  log "Konfiguracja Caddy (reverse proxy + HTTPS)..."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  sed -e "s/__DOMAIN__/${CADDY_DOMAIN}/g" -e "s/__EMAIL__/${CADDY_EMAIL}/g" \
    "${SCRIPT_DIR}/../caddy/Caddyfile" > /etc/caddy/Caddyfile
  systemctl enable --now caddy
  systemctl reload caddy || systemctl restart caddy
}

configure_firewall() {
  log "Konfiguracja UFW (22, 80, 443; PostgreSQL NIE jest wystawiany)..."
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
  ufw status verbose | head -8 || true
}

run_migrations() {
  log "Migracje bazy..."
  cd "${APP_DIR}"
  sudo -u "${APP_USER}" bash -c "set -a; source ${ENV_FILE}; set +a; node src/db/migrate.js"
}

healthcheck() {
  log "Healthcheck lokalny..."
  curl -fsS http://127.0.0.1:8080/api/v1/admin/ops/health && echo || { err "Healthcheck nieudany."; exit 1; }
}

report() {
  cat <<EOF

============================================================
 INSTALACJA D01i Tweakz zakończona
============================================================
 Aplikacja:      ${APP_DIR} (użytkownik: ${APP_USER}, NIE root)
 Konfiguracja:   ${ENV_FILE} (chmod 600)
 Klucze Ed25519: ${KEYS_DIR}
 Baza:           PostgreSQL ${DB_NAME} (tylko localhost, użytkownik ${DB_USER})
 Usługa:         systemctl status d01i-backend  (auto-start po restarcie)
 Panel admina:   https://${CADDY_DOMAIN}/admin
 API health:     https://${CADDY_DOMAIN}/api/v1/admin/ops/health
 Logi:           journalctl -u d01i-backend -f
 Backup:         deploy/ubuntu/backup-database.sh

 PIERWSZE KROKI:
 1. Zaloguj się do panelu (konto bootstrap z ${ENV_FILE}).
 2. Włącz MFA (Konto -> MFA) i zapisz kody odzyskiwania.
 3. Wygeneruj pierwszy klucz licencyjny.
 4. Opcjonalnie ustaw webhook Discord (Ustawienia).
============================================================
EOF
}

main() {
  require_root
  detect_ubuntu
  install_packages
  create_app_user
  ensure_config_dirs
  configure_postgres
  deploy_app
  generate_secrets_and_keys
  run_migrations
  install_systemd
  configure_caddy
  configure_firewall
  healthcheck
  report
}

main "$@"
