# Raport niezależnego audytu backendu — 2026-11-04

Audytor: niezależny przegląd gałęzi `arena/1c72ad7f-d01i-tweakz-4-11-2026` (kod + instalatory + testy, uruchomione realnie w sandboxie z prawdziwym PostgreSQL).

## 1. Podsumowanie architektury
Express (Node 22) + PostgreSQL; API v1 dla klienta PowerShell (aktywacja/validate/refresh/deactivate/status/devices) i API admina (sesje cookie+CSRF, RBAC admin/superadmin, MFA TOTP); tokeny Ed25519 ≤120 s z `jti` w tabeli `license_sessions`; klucze licencji tylko jako sha256 w bazie; panel WWW pod `/admin`; instalatory Ubuntu (systemd/Caddy/UFW) i Windows (natywne PS).

## 2. Status wcześniejszych ustaleń audytowych

| Punkt | Status | Uzasadnienie |
|---|---|---|
| A1 Ubuntu: zapis `.db_password` przed `mkdir /etc/d01i-tweakz` | **POTWIERDZONY** → naprawione | `install-ubuntu.sh`: `configure_postgres()` (zapis do `/etc/d01i-tweakz/.db_password`) wykonywane przed `generate_secrets_and_keys()` (mkdir). Na czystym systemie `set -e` przerwałoby instalację. Dodano `ensure_config_dirs()` przed konfiguracją PG + poprawne uprawnienia (root:d01i 640/700). |
| A2 Windows: zapis `.db_password` przed utworzeniem katalogu ProgramData | **POTWIERDZONY** → naprawione | `Install-Windows.ps1`: `Configure-Database` (Out-File do `ProgramData\D01iTweakz\.db_password`) przed `New-SecretsAndKeys` (New-Item). Katalog tworzony teraz na początku main; idempotentnie. |
| A3 Windows: wywołanie niezdefiniowanej funkcji `Start-Backend` | **POTWIERDZONY** → naprawione | `Install-Windows.ps1` wywoływał `Start-Backend -InstallDir …` jak funkcję, ale to osobny plik — błąd „not recognized”. Teraz `& (Join-Path $PSScriptRoot 'Start-Backend.ps1') …`. |
| A4 Windows: zależność od `openssl` | **POTWIERDZONY** → naprawione | Czysty Windows 11 nie gwarantuje openssl w PATH. Generowanie kluczy Ed25519 przeniesione do `node crypto` (Node jest wymagany i instalowany wcześniej). Sekrety przez .NET CSPRNG (`RNGCryptoServiceProvider`), nie `Get-Random`. |
| A5 Windows: Stop-Backend zabija dowolny proces na porcie 8080 | **POTWIERDZONY** → naprawione | Stary kod: `Get-NetTCPConnection -LocalPort 8080` → `Stop-Process`. Nowy kod: tylko PID z `backend.pid`, weryfikacja ścieżki/CommandLine pod kątem D01iTweakz przed zabiciem; brak pliku PID = „nic nie zatrzymuję”. Port 8080 nie jest już kryterium. |
| B1 Rotacja tokenów: stary token nie był unieważniany | **POTWIERDZONY** → naprawione | `tokenService.refreshSession` tylko ustawiał `replaced_by`; `verifySessionToken` akceptował stary token. Teraz rotacja atomowo ustawia `revoked, reason='rotated'`; replay w oknie 60 s zwraca ten sam następca; po oknie `TOKEN_ROTATED`; równoczesne odświeżenia serializuje `FOR UPDATE`. Testy zaktualizowane (stary token → 401, 6 równoczesnych refreshów → 1 token, replay po oknie → 401). |
| B2 Cicha podmiana HWID | **POTWIERDZONY** → naprawione | `licenseService.activate` nadpisywał `hwid_hash` przy istniejącym install_id. Teraz niezgodność → `409 HWID_MISMATCH` + `DEVICE_HWID_MISMATCH` + audit; admin reset czyści `hwid_hash` (migracja 0002: kolumna nullable), po czym możliwe kontrolowane ponowne związanie. |
| B3 Limit urządzeń 1–10 konfigurowalny | **POTWIERDZONY** → naprawione | API przyjmowało do 10. Teraz API 1–2, CHECK w schemacie (migracja 0002 niedestrukcyjnie obcina >2), panel max 2. |
| B4 Sekrety TOTP/webhook jawne w bazie | **POTWIERDZONY** → naprawione | Dodano AES-256-GCM (`enc:v1:…`) z kluczem `SECRET_ENC_KEY` z env; szyfrowane: `admins.totp_secret`, `settings.discord_webhook.url`; API nigdy nie zwraca pełnych wartości. Test: w bazie nie ma plaintextu. |
| B5 Brak recovery code w formularzu panelu | **POTWIERDZONY** → naprawione | `app.js`: pole MFA wysyła `totp` (6 cyfr) albo `recovery_code`; backend rozróżnia `TOTP_REQUIRED` vs `MFA_INVALID`. Test: recovery code jednorazowy. |
| B6 Panel woła `/admin/admins` jako zwykły admin → 403 | **POTWIERDZONY** → naprawione | `app.js` pobiera `/admin/me` i renderuje sekcje adminów/webhook-zapis tylko dla superadmina. Test: zwykły admin → 403 na `/admin/admins`, 200 na `/ops/stats`. |
| B7 Audit log mógł cicho zgasnąć | **CZĘŚCIOWO POTWIERDZONY** → naprawione | `logAudit` łapał błąd (OK dla diagnostyki), ale krytyczne operacje teraz używają `logAuditTx` w tej samej transakcji: activate ok/limit/hwid_mismatch, deactivate, revoke, reset-devices. |
| B8 Rate limiting w pamięci | **NIEPOTWIERDZONY jako problem** (decyzja udokumentowana) | Pojedynczy VPS/jedna instancja — in-memory wystarcza; blokady kont w DB; Redis możliwy później bez zmiany API. Uzasadnienie w SECURITY.md. |
| C1 Ubuntu update: rollback tylko `src`, migracja przed healthcheckiem | **POTWIERDZONY** → naprawione | `update-ubuntu.sh` przepisany: backup dumpu bazy + backup kodu/manifestu, `trap … ERR` rollback kodu **i** `npm ci`, jawna informacja że schemat bazy nie jest cofany automatycznie (restore-database.sh). |
| C2 Windows update: bez rollbacku, backend mógł zostać zatrzymany | **POTWIERDZONY** → naprawione | `Update-Backend.ps1` przepisany: 6 kroków z try/catch, rollback kodu+deps i ponowny start, `.env`/klucze nietknięte, jasny raport krytyczny gdy rollback też się nie uda. |
| D1 Brak walidacji TTL tokena | **POTWIERDZONY** → naprawione | `config`: zakres 30–120 s, poza zakresem start kończy się czytelnym błędem. Test (osobny proces): TTL=9999 → błąd startu. |
| D2 Wyłączenie MFA tylko hasłem | **CZĘŚCIOWO POTWIERDZONY** → naprawione | Teraz wymagane hasło **oraz** TOTP lub jednorazowy recovery code. Test dodany. |
| D3 Trust proxy / fałszowanie IP | **FAŁSZYWY ALARM** (z zabezpieczeniem) | Aplikacja binduje 127.0.0.1, Caddy nadpisuje X-Forwarded-For; bezpośredni dostęp z zewnątrz niemożliwy. Udokumentowane w SECURITY.md. |
| D4 Dane do Discorda | **NIEPOTWIERDZONY jako problem** | Już tylko dane zminimalizowane/pseudonimizowane; dodatkowo URL webhooka szyfrowany w bazie (B4). |

## 3. Problemy wykryte samodzielnie podczas tego audytu
- **Błąd w `secretCrypto.decryptSecret`** (off-by-one przy split `:`) — wykryty testem, naprawiony.
- **Defens-in-depth potwierdzony:** gdy API na chwilę przyjęło `max_devices>2`, CHECK w bazie odrzucił zapis (23514) — po naprawie API zwraca 400.
- **Skrypty PowerShell DEMO/PREMIUM nie były w repo** (tylko w załącznikach) — zweryfikowane i dodane: `client/demo/{starter.bat,demo.ps1}`, `client/premium/{starter.bat,premium.ps1}`.

## 4. Zmienione pliki
`backend/migrations/0002_hardening.sql` (nowy), `backend/src/config/index.js`, `backend/src/utils/secretCrypto.js` (nowy), `backend/src/services/{tokenService,licenseService,adminService,auditService,discordService}.js`, `backend/src/routes/v1/license.js`, `backend/src/routes/admin/{licenses,ops,auth}.js`, `backend/src/public/admin/app.js`, `backend/.env.example`, `backend/test/{license,admin,security}.test.js`, `backend/test/refresh-window-child.mjs` (nowy), `backend/test/helpers.js`, `deploy/ubuntu/{install-ubuntu.sh,update-ubuntu.sh}`, `deploy/windows/{Install-Windows.ps1,Start-Backend.ps1,Stop-Backend.ps1,Update-Backend.ps1}`, `docs/{API,SECURITY,TEST_REPORT}.md`, `docs/AUDIT_REPORT.md` (ten plik), `client/…` (nowe).

## 5. Wykonane testy (realne wyniki)
- **Automatyczne:** `node --test --test-concurrency=1 "test/*.test.js"` w `backend/` na Node v22.22.3 + PostgreSQL: **39/39 PASS, 0 FAIL** (2026-11-04). Obejmują: rotację tokenów (stary odrzucony, replay w oknie, 6 równoczesnych refreshów → 1 token, replay po oknie → 401), HWID mismatch 409 + reset admina, limit 2 (409 na 3., API odrzuca >2), licencje (zły/wygasły/revokowany klucz), MFA (TOTP, recovery jednorazowy, disable wymaga hasła+TOTP), szyfrowanie sekretów w bazie, brute-force 423, CSRF 403, SQLi, CSP, rate limit, TTL config 30–120.
- **Smoke test serwera produkcyjnego** (`NODE_ENV=production`, migracje 0001+0002 na istniejącej bazie): health OK, login OK, utworzenie klucza OK, aktywacja OK, refresh OK, **stary token po rotacji → 401**, **HWID mismatch → 409**, **max_devices=5 → 400**.
- **Skrypty bash:** `bash -n` (składnia) — OK dla wszystkich skryptów ubuntu.

## 6. Testy, których NIE wykonano (i dlaczego)
- Czysta instalacja na prawdziwym Ubuntu Server / Windows 11 Home/Pro — sandbox nie ma tych systemów; weryfikacja była statyczna + `bash -n` + przegląd kolejności operacji. **Zalecane przed produkcją:** test na czystych VM.
- Testy panelu WWW w przeglądarce — brak przeglądarki w sandboxie; logika panelu testowana przez API (403/200 dla ról).

## 7. Pozostałe ryzyka
- In-memory rate limiting nie działa między instancjami (nie dotyczy obecnej architektury 1×VPS).
- HWID nie jest odporny na podrobienie przez zaawansowanego użytkownika — celowo: utrudniamy nadużycia (mismatch + limit + reset admina), nie blokujemy uczciwych.
- Utrata `SECRET_ENC_KEY` = utrata możliwości odczytu sekretów TOTP/webhook (MFA trzeba skonfigurować od nowa) — klucz trzeba backupować poza bazą.
- Klient PowerShell nadal można zmodyfikować — autoryzacja PREMIUM pozostaje po stronie serwera.

## 8. Ocena gotowości
Backend spełnia kryteria akceptacji **po stronie kodu i testów automatycznych**. Warunek przedprodukcyjny: instalacja na czystych VM (Ubuntu 24.04, Windows 11 Home i Pro) — patrz sekcja 6.
