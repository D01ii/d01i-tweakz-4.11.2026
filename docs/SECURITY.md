# Raport bezpieczeństwa — D01i Tweakz Backend

## Model zagrożeń (wybrane scenariusze i zabezpieczenia)

| Zagrożenie | Scenariusz | Zabezpieczenie | Test |
|---|---|---|---|
| Brute-force logowania admina | wiele prób z hasłem | rate limit 5/okno + licznik w DB + blokada konta 15 min (423) | `blokada po brute-force` |
| Brute-force kluczy | skrypt podaje losowe klucze | rate limit aktywacji + `FAILED_KEY_BURST` (critical) → czasowa blokada IP + alert Discord | `burst blednych kluczy` |
| Manipulacja tokenem | zmiana payloadu/podpisu | Ed25519 verify + struktura + `jti` w bazie; tamper → `TOKEN_TAMPER` | `sfałszowany token` |
| Replay tokenu | użycie starego tokenu | TTL ≤ 120 s + natychmiastowe unieważnienie sesji (revoke/reset) | `wygasły token`, `unieważniona licencja` |
| Utrata odpowiedzi przy refresh | klient powtarza refresh | idempotentny replay (60 s) zwraca ten sam nowy token | `refresh rotuje token` |
| Wyścig aktywacji (3. urządzenie) | 8 równoczesnych żądań | transakcja + `SELECT ... FOR UPDATE` na licencji i urządzeniu | `równoczesne aktywacje` |
| SQL injection | `'; DROP TABLE...` w wyszukiwarce | zapytania parametryzowane (pg) | `SQL injection w wyszukiwarce` |
| XSS | skrypt w polach panelu | helmet CSP `default-src 'self'`, escapowanie w SPA, `X-Content-Type-Options` | `nagłówki bezpieczeństwa` |
| CSRF | spreparowane żądanie z innej strony | double-submit cookie + nagłówek, `SameSite=Strict`, weryfikacja przy każdym POST | `CSRF przy POST` |
| Session hijacking admina | kradzież cookie | HttpOnly, Secure (prod), 8 h TTL, unieważnienie sesji przy logout/disable | `wylogowanie unieważnia sesje` |
| Kradzież klucza z bazy | wyciek dumpu bazy | przechowywany tylko sha256(klucz); pełny klucz tylko raz przy tworzeniu | `CRUD licencji` |
| Nadużycie HWID | ponowne użycie HWID na wielu instalacjach | HWID tylko jako peppered hash; tożsamość urządzenia = install_id + hwid_hash; limit 2 aktywne | `limit urządzeń` |
| SSRF (webhook) | admin podaje URL internalny | walidacja schematu `https://discord.com/api/webhooks/...` | kod: discordService |
| Wyciek sekretów do Discorda | alert z danymi | tylko zminimalizowane, pseudonimizowane pola; pełne IP/HWID/klucze nigdy | kod: discordService |
| Brak połączenia / awaria DB | klient offline, DB padło | STRICT offline (brak grace), healthcheck 503, transakcje rollback | `health endpoint` |
| Kompromitacja VPS | dostęp do dysku | app nie jako root, ProtectSystem=strict, sekrety poza repo, PostgreSQL tylko localhost, UFW | konfiguracja systemd/UFW |

## RODO (środki techniczne i organizacyjne zaimplementowane w kodzie)
- Minimalizacja danych: brak pełnych kluczy, tokenów, haseł, surowych HWID i pełnych IP w bazie/logach/Discordzie.
- Pseudonimizacja: IP/HWID jako sha256 z pepperem serwera.
- Ograniczenie przechowywania: blokady czasowe, rotacja backupów (14 dni); retencja audit/abuse konfigurowalna przez admina (usuwanie przez SQL/panel).
- Kontrola dostępu: RBAC (admin/superadmin), MFA, sesje z TTL, audit log każdej akcji.
- Procedura usuwania danych: dezaktywacja urządzenia/licencji + `reset-devices`; pełne usunięcie przez admina (SQL) zgodnie z procedurą.
- Przekazywanie danych zewnętrznym dostawcom: tylko opcjonalny webhook Discord, wyłączalny, z danymi zminimalizowanymi.

**Uwaga:** zgodność z RODO to proces (podstawa prawna, klauzule informacyjne, rejestr czynności),
nie wyłącznie kod. Kod implementuje środki techniczne; dokumenty prawne leżą po stronie administratora.

## Oświadczenie o kliencie
Klient PowerShell **można zmodyfikować** (użytkownik ma kontrolę nad komputerem).
Dlatego autoryzacja PREMIUM zawsze pochodzi z backendu; klient nie jest źródłem prawdy.

## Decyzje z audytu (2026-11-04)

- **Sekrety w bazie (B4):** sekret TOTP i URL webhooka Discord są szyfrowane w spoczynku
  AES-256-GCM (`enc:v1:…`), klucz `SECRET_ENC_KEY` (32 bajty) tylko w env/poza bazą.
  Stare wartości plaintext są czytane legacy tylko do migracji. Hasła adminów: Argon2id (hash, bez odczytu).
- **Rotacja tokenów (B1):** stary token jest unieważniany atomowo przy pierwszym refresh
  (`revoked, reason='rotated'`); replay w oknie 60 s zwraca ten sam następca; równoczesne
  odświeżenia serializuje `FOR UPDATE` (dokładnie jeden następca). Po oknie → `TOKEN_ROTATED`.
- **HWID (B2):** brak cichej podmiany — niezgodność HWID przy istniejącym install_id →
  `409 HWID_MISMATCH` + zdarzenie `DEVICE_HWID_MISMATCH` + audit. Zmiana sprzętu = reset
  urządzenia przez admina (czyści `hwid_hash`), potem kontrolowane ponowne związanie.
- **Limit urządzeń (B3):** maks. 2 jako reguła produktu — API (1–2), CHECK w schemacie,
  migracja 0002 obcina ewentualne istniejące wartości >2 niedestrukcyjnie.
- **Rate limiting (B8):** w pamięci procesu — wystarczające przy jednym VPS/jednej
  instancji (udokumentowana architektura); liczniki nieudanych logowań dodatkowo w DB
  (blokada konta). Przy wielu instancjach można dodać Redis bez zmiany API.
- **Trust proxy (D3):** aplikacja binduje `127.0.0.1`; w produkcji `trust proxy=1`,
  a Caddy **nadpisuje** `X-Forwarded-For` własną wartością (`header_up`), więc klient
  nie może sfabrykować IP. Bezpośredni dostęp z zewnątrz jest niemożliwy (UFW + bind).
- **Discord (D4):** tylko zdarzenia i pola zminimalizowane (skrócony hash IP, brak pełnych
  kluczy/tokenów/HWID); webhook wyłączalny w panelu; URL zaszyfrowany w bazie i maskowany w API.
- **TTL tokenów (D1):** 120 s (zakres dozwolony 30–120, poza zakresem backend odmawia startu).
  Uzasadnienie: klient odświeża co ~60 s, więc 120 s daje margines na 1 utraconą odpowiedź.
