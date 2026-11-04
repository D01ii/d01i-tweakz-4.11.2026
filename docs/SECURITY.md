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
