# Raport testów — D01i Tweakz Backend

**Ostatnie uruchomienie:** 2026-11-04, runda 5 — 5 kolejnych przebiegów, wszystkie 53/53 PASS
**Środowisko:** Node.js v22.22.3 · PostgreSQL 16.2 (embedded, pgserver) · Debian 12 sandbox · 2 CPU
**Dokładna komenda:**
```bash
cd backend
ARGON2_MEMORY_COST=19456 ARGON2_TIME_COST=2 node --test --test-concurrency=1 "test/*.test.js"
```
(ARGON2_* tylko skraca testy; produkcja używa 64 MB/3 — Argon2id.)

## Wynik (Runda 6, 2026-11-04): 10 przebiegów × 53/53 PASS, 0 FAIL (po naprawie flaky migratora)

Runda 6 wykryła flaky test współbieżności migratora (R4, ~40% przebiegów): `CREATE TABLE schema_migrations`
wykonywane było poza advisory lockiem → wyścig o katalogi pg_type. Poprawka w `src/db/migrate.js`
(tabela tworzona wewnątrz transakcji z lockiem). Po poprawce 10 kolejnych przebiegów bez FAIL.

| Przebieg (R6) | # tests | # pass | # fail |
|---|---|---|---|
| 1–10 | 53 | 53 | 0 |

## Wynik (Runda 5, 2026-11-04): 5 przebiegów × 53/53 PASS, 0 FAIL

Każdy przebieg osobno (stdout `node --test`):

| Przebieg | # tests | # pass | # fail |
|---|---|---|---|
| 1 | 53 | 53 | 0 |
| 2 | 53 | 53 | 0 |
| 3 | 53 | 53 | 0 |
| 4 | 53 | 53 | 0 |
| 5 | 53 | 53 | 0 |

Surowy wynik pojedynczego przebiegu:
```
# tests 53
# pass 53
# fail 0
```

## Zakres
- **license.test.js:** aktywacja, zły/wygasły/revokowany klucz, limit 2 urządzeń (409 na 3.), równoczesne aktywacje (FOR UPDATE + ON CONFLICT), R3-P1 (6×równoczesny ten sam install_id: dokładnie 1×200 + 5×409 HWID_MISMATCH, brak 500/429, 1 wiersz), HWID mismatch + reset admina, tokeny (walidacja, rotacja z unieważnieniem, replay w oknie, R3-P2: replay nie mintuje sesji, stary token → 401 wszędzie), R3-P3 sesje admina (revoked/expired/wyłączone → 401), błędne wejście, health.
- **admin.test.js:** login, 401 bez sesji, 403 bez CSRF, CRUD licencji (klucz raz, tylko hash w bazie), revoke unieważnia sesje, extend/historia, audit, brute-force 423, MFA TOTP, **recovery code atomowy (8 równoczesnych → 1 sukces)**, wyłączenie MFA wymaga hasła+TOTP, max_devices>2 → 400, zwykły admin → 403 na /admin/admins, webhook maskowany.
- **security.test.js:** wygasły/nieznany/fałszowany token, burst błędnych kluczy → blokada IP 429, rate limit (proces-dziecko), CSP/XFO, SQLi, 404, TTL poza zakresem → odmowa startu, replay po oknie → TOKEN_ROTATED.
- **migrations.test.js:** idempotentność, błąd migracji = rollback bez wpisu i bez częściowych zmian, **R4: 4 niezależne procesy na czystej bazie → wszystkie OK, każda migracja raz, schemat kompletny**.
- **secrets.test.js:** migracja legacy sekretów (idempotentna, TOTP/webhook działają po migracji), uszkodzony ciphertext, zły klucz odrzucony, **R4: verifySecretKeyIntegrity (dobry/zły klucz, dane niezmienione po błędzie)**, walidacja SECRET_ENC_KEY 64-HEX, statyczna kontrola instalatora Windows (32 bajty).

## Testy NIE wykonane (nie deklarowane jako wykonane)
- Czysta instalacja na Ubuntu Server / Windows 11 Home/Pro (brak VM w sandboxie) — warunek przedprodukcyjny.
- Parser PowerShell (`pwsh` niedostępny w sandboxie) — skrypty PS sprawdzone statycznie.
- Testy przeglądarki panelu WWW (brak przeglądarki) — logika panelu przez API.
- Produkcyjna baza nie jest dotykana przez testy (osobne bazy `d01i_test_*`).
