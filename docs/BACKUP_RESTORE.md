# Backup i restore bazy — szyfrowane (R7)

## Backup (`deploy/ubuntu/backup-database.sh`)

- Dump `pg_dump` → gzip → **AES-256-CBC** (`openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt`)
  kluczem z `BACKUP_KEY_FILE` (domyślnie `/etc/d01i-tweakz/backup.key`).
- Fail-closed: brak klucza lub zły chmod (musi być `600`) = backup NIE powstaje, exit 1.
- Klucz trzymany POZA katalogiem backupów — kradzież samych backupów nie wystarczy do odczytu.
- `umask 077`, katalog backupów `chmod 700`, pliki `600`, do każdego backupu `.sha256`.
- Rotacja: `KEEP_DAYS` (domyślnie 14) — starsze pliki `*.sql.gz.enc` są usuwane.
- Cron: `0 3 * * * root BACKUP_KEY_FILE=/etc/d01i-tweakz/backup.key /opt/d01i-tweakz/deploy/ubuntu/backup-database.sh >> /var/log/d01i-tweakz/backup.log 2>&1`

Wygenerowanie klucza (raz, na serwerze, wynik zapisz też w menedżerze haseł offline):
`openssl rand -hex 32 > /etc/d01i-tweakz/backup.key && chmod 600 /etc/d01i-tweakz/backup.key && chown root:root /etc/d01i-tweakz/backup.key`

## Restore (`deploy/ubuntu/restore-database.sh`)

1. Zatrzymaj backend: `systemctl stop d01i-backend`.
2. `BACKUP_KEY_FILE=/etc/d01i-tweakz/backup.key bash restore-database.sh /var/backups/d01i-tweakz/d01i_tweakz-YYYYMMDD-HHMMSS.sql.gz.enc`
3. Skrypt: weryfikuje sha256 (jeśli plik `.sha256` obok), deszyfruje do tmp (600), ładuje przez `psql`.
4. Uruchom ponownie: `systemctl start d01i-backend`.
5. Sprawdź: `curl -s http://127.0.0.1:8080/api/v1/admin/ops/health`.

## Test restore (zalecane raz na kwartał)

Na osobnej VM: wgraj backup + klucz, przeprowadź restore, zweryfikuj liczbę licencji i health.
Backup bez przetestowanego restore nie istnieje.
