# Testy — D01i Tweakz Backend

## Uruchomienie (wymaga działającego PostgreSQL)

```bash
cd backend
export TEST_DATABASE_URL='postgres://user:pass@127.0.0.1:5432/d01i_test'  # opcjonalnie
npm test
```

Każdy plik testowy używa osobnej bazy (`d01i_test_license`, `d01i_test_admin`,
`d01i_test_security` — nazwa przez `TEST_DB_NAME`), więc mogą działać równolegle;
domyślnie wymuszamy `--test-concurrency=1` dla determinizmu. Testy tworzą schemat
od zera (DROP SCHEMA) przed każdym plikiem.

## Zakres (29 testów, wszystkie zielone — patrz TEST_REPORT.md)

**license.test.js (12):** aktywacja, zły klucz, validate, refresh + idempotentny replay,
limit 2 urządzeń (409 na 3.), dezaktywacja zwalnia slot, 8 równoczesnych aktywacji
(transakcja FOR UPDATE), wygasła licencja, revoke + unieważnienie sesji, fałszowany
podpis + TOKEN_TAMPER, status/devices, walidacja wejścia, health.

**admin.test.js (10):** login (złe/dobre), 401 bez sesji, 403 bez CSRF, CRUD licencji
(klucz tylko raz, tylko hash w bazie), revoke unieważnia sesje klienta, extend + historia,
audit log, brute-force → blokada konta (423), MFA TOTP, logout, webhook (zapis + maskowanie URL).

**security.test.js (7):** wygasły token, nieznana sesja z poprawnym podpisem, burst
błędnych kluczy → alert + czasowa blokada IP (429), rate limiting (osobny proces),
nagłówki CSP/XFO, SQL injection w wyszukiwarce, 404 JSON.

## Uwaga
Testy jednostkowe/integracyjne uruchomiono realnie w tym środowisku (patrz TEST_REPORT.md).
