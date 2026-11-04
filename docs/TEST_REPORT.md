# Raport testów — D01i Tweakz Backend (wydanie 1.0.0)

**Data uruchomienia:** 2026-11-04 (po dwóch rundach audytu) · **Środowisko:** Node.js v22.22.3, PostgreSQL (instancja testowa), Debian sandbox
**Polecenie:** `node --test --test-concurrency=1 "test/*.test.js"` (w `backend/`)

## Wynik: 49 / 49 PASS, 0 FAIL (po trzech rundach audytu)

```
# tests 46
# pass 46
# fail 0
```

Nowe testy regresyjne z audytu: stary token po rotacji → 401; 6 równoczesnych refreshów → dokładnie 1 nowy token; replay po oknie idempotencji → 401 TOKEN_ROTATED (osobny proces); HWID mismatch → 409 + zdarzenie; reset admina czyści HWID i pozwala na ponowne związanie; API odrzuca max_devices>2; sekrety TOTP/webhook zaszyfrowane w bazie; recovery code jednorazowy; wyłączenie MFA wymaga hasła+TOTP; zwykły admin → 403 na /admin/admins; TOKEN_TTL_SECONDS poza 30–120 → odmowa startu.

## Lista testów (wszystkie wykonane realnie, wszystkie zielone)

| # | Test | Plik |
|---|---|---|
| 1 | logowanie admina: złe hasło → 401, dobre → cookie + CSRF | admin |
| 2 | dostęp do API admin bez sesji → 401 | admin |
| 3 | POST bez tokena CSRF → 403 | admin |
| 4 | CRUD licencji: klucz pokazany tylko raz, tylko hash w bazie, revoke unieważnia sesje klienta, reset urządzeń | admin |
| 5 | przedłużanie licencji + historia aktywacji | admin |
| 6 | audit log rejestruje akcje admina | admin |
| 7 | brute-force logowania → blokada konta (423) | admin |
| 8 | MFA: TOTP setup/enable, logowanie wymaga kodu | admin |
| 9 | logout unieważnia sesję | admin |
| 10 | webhook: zapis ustawień + maskowanie URL w odpowiedziach | admin |
| 11 | poprawna aktywacja → token + dane licencji | license |
| 12 | niepoprawny klucz → 401 KEY_INVALID | license |
| 13 | validate + refresh z rotacją; idempotentny replay po utracie odpowiedzi | license |
| 14 | limit 2 urządzeń: 3. aktywacja → 409 | license |
| 15 | dezaktywacja zwalnia slot → ponowna aktywacja OK | license |
| 16 | 8 równoczesnych aktywacji 3. urządzenia → 0 sukcesów (FOR UPDATE) | license |
| 17 | wygasła licencja → LICENSE_EXPIRED | license |
| 18 | revoke → LICENSE_REVOKED + sesje unieważnione natychmiast | license |
| 19 | sfałszowany podpis → 401 + zdarzenie TOKEN_TAMPER | license |
| 20 | status + lista urządzeń | license |
| 21 | błędne dane wejściowe → 400 VALIDATION_ERROR | license |
| 22 | health endpoint (DB ok) | license |
| 23 | wygasły token (TTL) → TOKEN_EXPIRED | security |
| 24 | poprawny podpis, nieznana sesja → SESSION_UNKNOWN + alert | security |
| 25 | burst 6 błędnych kluczy → FAILED_KEY_BURST + czasowa blokada IP (429) | security |
| 26 | rate limiting aktywacji (limit 3/okno → 429) | security |
| 27 | nagłówki CSP/XFO/nosniff ustawione | security |
| 28 | SQL injection w wyszukiwarce — tabela licencji nietknięta | security |
| 29 | nieznana trasa API → 404 JSON | security |

## Dodatkowy smoke test (ręczny, serwer produkcyjny w trybie `NODE_ENV=production`)
- migracje startowe OK, bootstrap admina OK
- `POST /admin/login` → cookie + CSRF
- `POST /admin/licenses` → klucz `D01I-....` pokazany raz
- `POST /license/activate` → token Ed25519; `validate` → valid; `refresh` → nowy token
- `GET /admin/ops/stats` → poprawne statystyki
- panel `/admin/` serwuje HTML/CSS/JS z poprawnymi typami MIME

## Znane ograniczenia testów
- Testy używają osobnych baz `d01i_test_*`; produkcyjna baza nie jest dotykana.
- Argon2 w testach ma obniżony koszt pamięci (zmienne `ARGON2_MEMORY_COST/ARGON2_TIME_COST`);
  produkcja używa domyślnych 64 MB / 3 iteracje (Argon2id).

### Runda 2 (FOLLOWUP_AUDIT): migracje (idempotentność, błąd=brak częściowych zmian, advisory lock przy równoczesności), migracja legacy sekretów, atomowe zużycie recovery code (8 równoczesnych prób → 1 sukces), walidacja SECRET_ENC_KEY.
