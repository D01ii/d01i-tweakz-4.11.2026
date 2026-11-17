# Runda 4 audytu — 2026-11-04

**Branch:** `arena/1c72ad7f-d01i-tweakz-4-11-2026` · **HEAD przed zmianami:** `d1adc8f` · **HEAD końcowy:** commit rundy 4 (patrz git log)

## Tabela problemów

| Problem | Przyczyna | Poprawka | Test | Wynik | Ograniczenia |
|---|---|---|---|---|---|
| P0 Windows: SECRET_ENC_KEY 128 znaków | `New-SecureRandomString 64` = 64 bajty = 128 HEX; backend wymaga 64 HEX | Funkcja przemianowana na `New-SecureRandomHex([int]$ByteCount)` (parametr = bajty); `SECRET_ENC_KEY = New-SecureRandomHex 32`; wszystkie wywołania sprawdzone | `secrets.test.js`: statyczna kontrola pliku + walidacja 64-HEX przez config backendu | PASS | Brak `pwsh` w sandboxie — parser PS nieuruchomiony (patrz niżej) |
| P0 SECRET_ENC_KEY vs istniejące dane | Backend nie weryfikował klucza wobec danych; instalatory mogły wygenerować nowy klucz mimo istnienia `enc:v1:`; `|| echo 0` maskował błąd DB | `verifySecretKeyIntegrity()` (realne odszyfrowanie AES-256-GCM wszystkich `enc:v1:` w `admins.totp_secret` i `settings.discord_webhook.url`) przy starcie PO migracjach, PRZED HTTP; błąd = abort, bez modyfikacji danych, bez HTTP. Instalatory: `count_encrypted_rows()` rozróżnia „błąd DB” od „0 rekordów” i „brak tabel”; sprawdzenie zarówno przy istniejącym `.env` bez klucza, jak i przy braku `.env` | `secrets.test.js`: dobry klucz OK, zły lecz poprawny format → odrzucony, dane niezmienione po nieudanej weryfikacji | PASS | — |
| P1 migrator: `done` czytane przed lockiem | `schema_migrations` czytane poza transakcją/lockiem | Cały przebieg w jednej transakcji: `BEGIN` → `pg_advisory_xact_lock` → odczyt `schema_migrations` → migracje → `COMMIT`; błąd = pełny rollback z nazwą pliku | `migrations.test.js` R4: 4 niezależne procesy na **czystej** bazie → wszystkie exit 0, każda migracja raz, schemat kompletny; + idempotentność i błąd bez częściowych zmian | PASS | — |
| P1 Stop-Backend nie fail-closed | wyjątek/brak CIM lub pusty CommandLine przechodziły; kasowano PID przy nieudanej weryfikacji | Wszystkie kontrole obowiązkowe (PID, StartTime, node.exe, `src\index.js`, CommandLine z CIM); każdy błąd/null/pusty = brak `Stop-Process`; plik PID zachowany przy nieudanej weryfikacji; normalizacja cudzysłowów w CommandLine | przegląd statyczny (brak Windows w sandboxie) | kod OK, testy VM niewykonane | **Wymagany test na Windows 11 przed produkcją** |
| P1 aktywacja: fallback 23505 w aborted tx | po błędzie SQL transakcja jest aborted — ponowny SELECT rzucałby 25P02 | `INSERT … ON CONFLICT (license_id, install_id) DO NOTHING RETURNING …`; brak wiersza → SELECT FOR UPDATE istniejącego + HWID_MISMATCH/REACTIVATE; kontrola limitu po insercie zachowana | `license.test.js` R3-P1 wzmocniony: dokładny rozkład — 1×200, 5×409 HWID_MISMATCH, brak 500/429, 1 wiersz urządzenia | PASS | — |

## Rzeczywiste wyniki testów (r arbitrarily 4)
- Komenda: `cd backend && node --test --test-concurrency=1 "test/*.test.js"` (z `ARGON2_MEMORY_COST=19456 ARGON2_TIME_COST=2` tylko dla szybkości testów)
- Środowisko: Node.js **v22.22.3**, PostgreSQL (embedded pgserver, `SHOW server_version` = 15.x), Debian 12 sandbox, 2026-11-04
- Wynik: **53/53 PASS, 0 FAIL** (surowe `# tests 53 / # pass 53 / # fail 0`)
- `bash -n` na wszystkich `deploy/ubuntu/*.sh`: OK
- PowerShell: `pwsh` **niedostępny w sandboxie** — parser PS 5.1/7 nie został uruchomiony; skrypty sprawdzone statycznie (treść, nazewnictwo, kolejność). To jawne ograniczenie.

## Niewykonane testy (nie deklaruję ich jako wykonane)
- Czysta instalacja na Ubuntu Server i Windows 11 Home/Pro (brak VM w sandboxie) — **pozostaje obowiązkowym warunkiem przedprodukcyjnym**, w tym: parser PS, Start/Stop-Backend z obcym procesem na 8080 i reużyciem PID, odczyt kluczy jako `d01i`.
- Testy produkcyjnej bazy — wszystkie testy używają osobnych baz `d01i_test_*` (sprawdzone: żaden test nie łączy się z produkcyjną bazą).

## Pozostałe ryzyka
- Jak w poprzednich rundach: in-memory rate limiting (OK przy 1 instancji), utrata `SECRET_ENC_KEY` blokuje odczyt sekretów (klucz tylko w chronionym `.env` — backupować poza bazą), klient PowerShell modyfikowalny (autoryzacja po stronie serwera).
