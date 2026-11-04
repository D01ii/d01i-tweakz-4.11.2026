#!/usr/bin/env bash
# D01i Tweakz - dezinstalacja (Ubuntu). NIE usuwa bazy danych ani kluczy
# bez jawnego potwierdzenia.
set -euo pipefail
APP_NAME="d01i-tweakz"

if [ "$(id -u)" -ne 0 ]; then echo "Uruchom jako root." >&2; exit 1; fi

echo "Zatrzymywanie i wylaczanie uslugi..."
systemctl stop d01i-backend 2>/dev/null || true
systemctl disable d01i-backend 2>/dev/null || true
rm -f /etc/systemd/system/d01i-backend.service
systemctl daemon-reload

read -rp "Usunac aplikacje z /opt/${APP_NAME}? [y/N] " r1
if [ "${r1:-N}" = "y" ]; then rm -rf "/opt/${APP_NAME}"; echo "Usunieto /opt/${APP_NAME}."; fi

read -rp "Usunac konfiguracje i klucze z /etc/${APP_NAME}? [y/N] " r2
if [ "${r2:-N}" = "y" ]; then rm -rf "/etc/${APP_NAME}"; echo "Usunieto /etc/${APP_NAME} (w tym klucze Ed25519 i sekrety)."; fi

read -rp "Usunac baze danych i uzytkownika PostgreSQL? [y/N] " r3
if [ "${r3:-N}" = "y" ]; then
  su - postgres -c "psql -c 'DROP DATABASE IF EXISTS d01i_tweakz;'"
  su - postgres -c "psql -c 'DROP ROLE IF EXISTS d01i_app;'"
  echo "Usunieto baze i uzytkownika bazy."
else
  echo "Baza danych ZOSTALA na serwerze."
fi

read -rp "Usunac uzytkownika systemowego d01i? [y/N] " r4
if [ "${r4:-N}" = "y" ]; then userdel "${APP_NAME}" 2>/dev/null || true; fi

echo "Dezinstalacja zakonczona."
