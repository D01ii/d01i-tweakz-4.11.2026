# Raport kolejnej rundy audytu — 2026-11-04

**Branch:** `arena/1c72ad7f-d01i-tweakz-4-11-2026` · **HEAD przed zmianami:** `8b3fa48` · **HEAD końcowy:** patrz git log (commit tej rundy)
Analiza wykonana bezpośrednio z plików brancha (nie z diff PR, nie z main).

## Statusy punktów z rundy 2

| Punkt | Status | Naprawa |
|---|---|---|
| P0 SECRET_ENC_KEY nie generowany przez instalatory | **POTWIERDZONY** → naprawione | Ubuntu: `SECRET_ENC_KEY=$(openssl rand -hex 32)` w `.env` przy pierwszej instalacji; przy rerun istniejący klucz zachowany; jeśli w bazie są rekordy `enc:v1:` a klucz w `.env` niepoprawny → instalator **przerywa** z czytelnym komunikatem (bez generowania nowego klucza). Windows: analogicznie (`New-SecureRandomString 64`, CSPRNG), kontrola przez psql. Backend dodatkowo waliduje format klucza (64 HEX) przy starcie — błąd zamiast cichego przyjęcia. |
| P0 uprawnienia katalogów Ubuntu 700 root:root | **POTWIERDZONY** → naprawione | `/etc/d01i-tweakz` i `keys`: `750 root:d01i`; `.env` 640 root:d01i; klucz prywatny 640 root:d01i; klucz publiczny 644; `.db_password` 600 root:root (tylko instalator). Usługa `d01i` może przejść i odczytać; inni użytkownicy nie mają dostępu. (Test realny: patrz „Testy niewykonane” — symulacja ścieżki uprawnień opisana poniżej.) |
| P1 Start/Stop Windows: `$pid` vs automatyczny `$PID`, względna ścieżka | **POTWIERDZONY** → naprawione | Zmienna przekształcona w `$backendPid`; start zapisuje `backend.pid.json` {Pid, StartTime, NodeExe, Script}; start używa pełnych ścieżek node.exe i `src\index.js`; Stop weryfikuje PID **+ czas startu** (ochrona przed reużyciem PID) + ścieżka exe + linia poleceń; stary/uszkodzony plik PID czyszczony; brak weryfikacji = brak zatrzymania; port 8080 nie jest kryterium. Start nie uruchamia drugiej kopii (weryfikacja przez pid.json). |
| P1 rollback bez katalogu migrations | **POTWIERDZONY** → naprawione | `update-ubuntu.sh` i `Update-Backend.ps1`: backup i rollback obejmują `src`, `migrations`, `package.json`, `package-lock.json` (+ `npm ci` przy rollbacku). `.env`, klucze, `.db_password` i baza nigdy nie są dotykane. |
| P1 update-ubuntu.sh: mktemp przed mkdir katalogu backupów | **POTWIERDZONY** → naprawione | `mkdir -p "${BACKUP_DIR}"` + test zapisywalności PRZED `mktemp`; bez katalogu/zapisu aktualizacja kończy się błędem przed jakąkolwiek zmianą. |
| P1 podwójne zarządzanie transakcją w migracjach | **POTWIERDZONY** → naprawione | `BEGIN/COMMIT` usunięte z plików SQL; runner (`migrate.js`) zarządza jedną transakcją: advisory lock `pg_advisory_xact_lock('d01i_tweakz_migrations')` + plik SQL + wpis do `schema_migrations` + COMMIT — razem albo wcale. Testy: rerun idempotentny, błąd w środku migracji → brak wpisu i brak częściowych zmian (rollback), 3 równoczesne migmatory → brak duplikatów. |
| P1 recovery code wyścig | **POTWIERDZONY** → naprawione | Atomowe zużycie pojedynczym `UPDATE admins SET recovery_codes = array_remove(...) WHERE id=$1 AND $2 = ANY(recovery_codes) RETURNING id` (`consumeRecoveryCode`) w `loginAdmin` i `disableTotp`. Test: 8 równoczesnych logowań tym samym kodem → dokładnie 1 sukces. |
| P1 legacy jawne sekrety | **POTWIERDZONY** → naprawione | `secretMigrationService.migrateLegacySecrets()` (wywoływane przy starcie po migracjach i dostępne jako `scripts/migrate-legacy-secrets.js`): szyfruje tylko wartości bez `enc:v1:`, weryfikuje odszyfrowanie przed zapisem, idempotentne, nie loguje sekretów; brak/nieprawidłowy `SECRET_ENC_KEY` przy istniejących `enc:v1:` rekordach = błąd startu (nie generuje nowego klucza). Testy: legacy→enc, idempotentność, TOTP i webhook działają po migracji, uszkodzony ciphertext wykryty, zły klucz odrzucony. |

## Samodzielnie wykryte podczas tej rundy
- Błąd parametryzacji w nowej migracji sekretów (`$2` przy jednym parametrze) — wykryty testem, naprawiony.
- `INSERT … jsonb` wymaga jawnego castu (`$1::jsonb`) w niektórych kontekstach — poprawione w migracji sekretów.

## Zmodyfikowane pliki
`backend/src/config/index.js`, `backend/src/db/migrate.js`, `backend/migrations/0001_init.sql`, `backend/migrations/0002_hardening.sql`, `backend/src/services/adminService.js`, `backend/src/services/secretMigrationService.js` (nowy), `backend/src/index.js`, `backend/scripts/migrate-legacy-secrets.js` (nowy), `backend/test/{migrations,secrets}.test.js` (nowe), `backend/test/admin.test.js`, `deploy/ubuntu/{install-ubuntu.sh,update-ubuntu.sh}`, `deploy/windows/{Install-Windows.ps1,Update-Backend.ps1,Start-Backend.ps1,Stop-Backend.ps1}`, `docs/FOLLOWUP_AUDIT_REPORT.md`.

## Wyniki testów (realne)
- Automatyczne: `node --test --test-concurrency=1 "test/*.test.js"` — **46/46 PASS, 0 FAIL** (Node v22.22.3, prawdziwy PostgreSQL), w tym wszystkie wcześniejsze regresje (rotacja tokenów, HWID, limit 2, szyfrowanie, MFA, CSRF, rate limit) — brak regresji.
- Smoke test serwera (`NODE_ENV=production`, start z migracją sekretów): health OK, login OK, tworzenie klucza OK, aktywacja OK.
- `bash -n` na wszystkich skryptach `deploy/ubuntu/*.sh`: OK. Brak `BEGIN/COMMIT` w plikach migracji: OK.

## Testy niewykonane (i dlaczego)
- Czysta instalacja na prawdziwym Ubuntu/Windows 11: brak tych systemów w sandboxie. Weryfikacja instalatorów: statyczna (kolejność wywołań, `bash -n`, przegląd ścieżek) — **zalecany test na czystych VM przed produkcją**, w tym: odczyt klucza/.env jako użytkownik `d01i` (`sudo -u d01i cat /etc/d01i-tweakz/keys/ed25519_private.pem`) i brak dostępu jako inny użytkownik; Start/Stop-Backend na Windows (łącznie z przypadkiem obcego procesu na 8080 i reużycia PID).
- Brak `pwsh` w sandboxie — skrypty PowerShell sprawdzone statycznie (bez `pwsh -NoProfile -Command` parse check).

## Pozostałe ryzyka
- Utrata `SECRET_ENC_KEY` = brak dostępu do sekretów TOTP/webhook (MFA do ponownej konfiguracji); klucz trzeba backupować poza bazą — instalator zapisuje go tylko w chronionym `.env`.
- In-memory rate limiting przy wielu instancjach (obecnie 1 VPS — OK).
- Klient PowerShell można modyfikować; autoryzacja PREMIUM tylko po stronie serwera (bez zmian).

## Rekomendacja wdrożeniowa
Kod i testy automatyczne spełniają kryteria rundy 2. **Warunek przedprodukcyjny:** testy na czystych VM (Ubuntu 24.04, Windows 11 Home + Pro) zgodnie z listą niewykonanych testów — szczególnie uprawnienia `/etc/d01i-tweakz` jako użytkownik `d01i` i identyfikacja procesu przez Start/Stop-Backend. Nie deklaruję 100% bezpieczeństwa ani pełnej gotowości produkcyjnej bez tych testów środowiskowych.
