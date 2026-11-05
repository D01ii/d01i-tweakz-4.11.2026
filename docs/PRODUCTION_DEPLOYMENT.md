# Wdrożenie produkcyjne — Ubuntu Server (R7)

Produkcja = Ubuntu Server + PostgreSQL + Caddy (TLS) + Cloudflare Tunnel. Windows = tylko testy.

## Wymagania wstępne

- Ubuntu 22.04/24.04 LTS, domena w Cloudflare, VPS z publicznym IP (dostęp tylko przez tunnel/SSH).
- Sekrety generowane na serwerze, NIGDY nie w repo:
  - `SECURITY_PEPPER` / `LICENSE_KEY_PEPPER`: `openssl rand -hex 32` (inne wartości!)
  - `SECRET_ENC_KEY`: `openssl rand -hex 32`
  - `BACKUP_KEY_FILE`: `openssl rand -hex 32 > /etc/d01i-tweakz/backup.key; chmod 600` — klucz POZA katalogiem backupów
  - hasło DB i admina: menedżer haseł

## Kroki

1. `sudo bash deploy/ubuntu/install-ubuntu.sh` — instaluje Node 22, PostgreSQL, Caddy, UFW,
   tworzy role `d01i_app` (runtime) i opcjonalnie `d01i_migrator` (migracje), konfiguruje UFW
   (tylko SSH + 443), systemd unit z pełnym hardeningiem.
2. Wypełnij `/etc/d01i-tweakz/.env` (patrz `backend/.env.example`): DATABASE_URL,
   `MIGRATIONS_DATABASE_URL` (zalecane), `LICENSE_KEY_PEPPER`, `ADMIN_REQUIRE_MFA=true`,
   `NODE_ENV=production`, `TRUST_PROXY=1`.
3. Migracje: `sudo -u d01i bash -c "set -a; source /etc/d01i-tweakz/.env; set +a; node /opt/d01i-tweakz/src/db/migrate.js"`
4. `sudo systemctl enable --now d01i-backend` i `sudo systemctl status d01i-backend`.
5. Health: `curl -s http://127.0.0.1:8080/api/v1/admin/ops/health` (z serwera).
6. Cloudflare Tunnel — patrz `CLOUDFLARE_TUNNEL.md`.
7. Backupy: cron `0 3 * * * root /opt/d01i-tweakz/deploy/ubuntu/backup-database.sh` — patrz `BACKUP_RESTORE.md`.
8. Aktualizacje: `sudo bash deploy/ubuntu/update-ubuntu.sh` (robi backup przed zmianą, rollback w razie błędu).

## Twardnienie systemd (deploy/systemd/d01i-backend.service)

NoNewPrivileges, ProtectSystem=strict, ProtectHome, PrivateTmp, PrivateDevices,
ProtectKernelTunables/Modules/Logs, ProtectControlGroups, ProtectClock, ProtectHostname,
RestrictSUIDSGID, LockPersonality, RestrictNamespaces, RestrictRealtime, MemoryDenyWriteExecute,
CapabilityBoundingSet= (pusty), UMask=0027, ReadWritePaths=/var/log/d01i-tweakz tylko.

## Rozdzielenie użytkowników DB

- `d01i_app` — runtime (tylko DML na schemacie, bez DDL).
- `d01i_migrator` — tylko migracje (`MIGRATIONS_DATABASE_URL`). Bez tej zmiennej migracje
  używają DATABASE_URL (działa, mniej bezpieczne).
- Nadanie praw (przykład): `GRANT CONNECT ON DATABASE d01i_tweakz TO d01i_app;`
  `GRANT USAGE ON SCHEMA public TO d01i_app; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO d01i_app;`

## Rollback

`update-ubuntu.sh` trzyma backup w `/opt/d01i-tweakz/.rollback/` — w razie problemu:
przywróć pliki z backupu, `systemctl restart d01i-backend`, ewentualnie restore DB z zaszyfrowanego backupu (BACKUP_RESTORE.md).
