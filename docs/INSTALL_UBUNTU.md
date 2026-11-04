# Instalacja produkcyjna — Ubuntu Server LTS (22.04 / 24.04)

## Wymagania
- Ubuntu Server 22.04 lub 24.04 LTS, dostęp root (sudo), domena wskazująca na VPS.
- Porty 22/80/443 otwarte; PostgreSQL **nie** jest wystawiany publicznie.

## Kroki

```bash
sudo bash deploy/ubuntu/install-ubuntu.sh
```

Instalator (idempotentny):
1. Wykrywa wersję Ubuntu i wymaga roota.
2. Instaluje Node.js ≥ 20 (NodeSource 22 LTS jeśli systemowy jest starszy), PostgreSQL, Caddy, UFW.
3. Tworzy użytkownika systemowego `d01i` (nologin) — aplikacja **nie** działa jako root.
4. Konfiguruje PostgreSQL tylko na `localhost`, tworzy bazę `d01i_tweakz` i użytkownika
   `d01i_app` z ograniczonymi uprawnieniami (NOSUPERUSER/NOCREATEDB/NOCREATEROLE).
5. Kopiuje kod do `/opt/d01i-tweakz`, `npm ci --omit=dev`.
6. Generuje sekrety (`SECURITY_PEPPER`, hasło DB) i parę kluczy **Ed25519** w `/etc/d01i-tweakz/keys`.
7. Tworzy `/etc/d01i-tweakz/.env` (chmod 600) z bootstrap adminem.
8. Uruchamia migracje, instaluje `systemd/d01i-backend.service` (auto-start, hardening:
   NoNewPrivileges, ProtectSystem=strict), konfiguruje Caddy (TLS + HSTS) i UFW.
9. Wykonuje healthcheck i wyświetla raport.

### Zmienne przed instalacją
```bash
export CADDY_DOMAIN=api.twojadomena.pl
export CADDY_EMAIL=admin@twojadomena.pl
```

## Administracja
- Logi: `journalctl -u d01i-backend -f`
- Status: `systemctl status d01i-backend`
- Backup: `sudo bash deploy/ubuntu/backup-database.sh` (rotacja 14 dni, `/var/backups/d01i-tweakz`)
- Restore: `sudo bash deploy/ubuntu/restore-database.sh <plik.sql.gz>`
- Aktualizacja: `sudo bash deploy/ubuntu/update-ubuntu.sh` (backup → podmiana → migracje → healthcheck → rollback przy błędzie)
- Dezinstalacja: `sudo bash deploy/ubuntu/uninstall-ubuntu.sh` (nie usuwa bazy bez potwierdzenia)

## Pierwsze logowanie
1. Wejdź na `https://<domena>/admin`, zaloguj się kontem bootstrap z `/etc/d01i-tweakz/.env`.
2. Włącz MFA (Konto → MFA), zapisz kody odzyskiwania.
3. Wygeneruj klucze licencyjne (zakładka Licencje).
4. Opcjonalnie skonfiguruj webhook Discord (Ustawienia).

## Ręczne generowanie kluczy Ed25519 (alternatywa)
```bash
sudo mkdir -p /etc/d01i-tweakz/keys && sudo chmod 700 /etc/d01i-tweakz/keys
sudo openssl genpkey -algorithm ed25519 -out /etc/d01i-tweakz/keys/ed25519_private.pem
sudo openssl pkey -in /etc/d01i-tweakz/keys/ed25519_private.pem -pubout -out /etc/d01i-tweakz/keys/ed25519_public.pem
sudo chmod 600 /etc/d01i-tweakz/keys/ed25519_private.pem
```
