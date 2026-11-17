# Runda 3 audytu — 2026-11-04

**Branch:** `arena/1c72ad7f-d01i-tweakz-4-11-2026` · **HEAD przed zmianami:** `5cb7fad` · **HEAD końcowy:** commit rundy 3

## Statusy trzech problemów

### Problem 1 — współbieżność aktywacji (install_id + różne HWID)
**CZĘŚCIOWO POTWIERDZONY → wzmocnione.**
Weryfikacja kodu: tabela `devices` ma `UNIQUE (license_id, install_id)` (migracja 0001), a aktywacja zaczyna się od `SELECT … FROM licenses WHERE key_hash=$1 FOR UPDATE` — blokada wiersza licencji serializuje wszystkie aktywacje tej licencji, więc podwójne wstawienie tego samego install_id **nie mogło** się zdarzyć, a limit liczony przed insertem był chroniony tym samym lockiem. Realny pozostały problem: ewentualne naruszenie UNIQUE (23505) kończyłoby się 500 zamiast kontrolowanej odpowiedzi, i nie było ponownej kontroli limitu po insercie.
Naprawa (`licenseService.activate`): blokada `23505` na insercie urządzenia → ponowny odczyt `FOR UPDATE` i obsługa jak istniejące urządzenie (w tym `HWID_MISMATCH` przy innym HWID); po insercie ponowne policzenie aktywnych urządzeń — przekroczenie limitu → krytyczne zdarzenie `DEVICE_LIMIT_EXCEEDED` i błąd (rollback transakcji).
Test `R3-P1`: 6 równoczesnych aktywacji, ten sam install_id, różne HWID → brak 500, maks. 1×200, reszta 409 HWID_MISMATCH, dokładnie 1 wiersz urządzenia. **PASS.**

### Problem 2 — rotacja tokenów
**NIEPOTWIERDZONY jako aktualny problem (naprawiony w rundzie 1) → zweryfikowany testem.**
`refreshSession` unieważnia stary token atomowo (`revoked, reason='rotated'`) w transakcji z `FOR UPDATE`; replay w oknie 60 s zwraca tego samego następcę; po oknie `TOKEN_ROTATED`; wszystkie endpointy odrzucają rotowany token. Nowy test `R3-P2`: 3 replaye starego tokena zwracają ten sam token, liczba sesji nie rośnie (2 = stara + następca, 1 aktywna), `/validate` i `/status` na starym tokenie → 401. **PASS.**

### Problem 3 — unieważnione sesje admina
**FAŁSZYWY ALARM w aktualnym kodzie → zweryfikowany testem.**
`verifyAdminSession` odrzuca sesje `revoked`, wygasłe i konta nieaktywne (`return null` → 401 w `requireAdmin`); `logoutAdmin` i `setAdminActive` revokują sesje. Nowy test `R3-P3`: revoked w bazie → 401; expired → 401; konto wyłączone → 401 (stary cookie bezużyteczny). **PASS.**

## Wyniki testów (realne)
- `node --test --test-concurrency=1 "test/*.test.js"` — **49/49 PASS, 0 FAIL** (Node v22.22.3, prawdziwy PostgreSQL), bez regresji wcześniejszych rund.

## Zmodyfikowane pliki
`backend/src/services/licenseService.js` (obsługa 23505 + kontrola limitu po insercie), `backend/test/license.test.js` (R3-P1, R3-P2), `backend/test/admin.test.js` (R3-P3), `docs/ROUND3_REPORT.md`, `docs/TEST_REPORT.md`.

## Pozostałe ryzyka (bez zmian)
- Rate limiting in-memory (OK przy 1 instancji), utrata `SECRET_ENC_KEY` blokuje odczyt sekretów (klucz poza bazą, backupować), klient PowerShell modyfikowalny (autoryzacja po stronie serwera).
- Testy czysto-systemowe (Ubuntu/Windows VM) nadal niewykonane w sandboxie — warunek przedprodukcyjny z poprzednich rund.
