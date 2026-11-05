# Audyt bezpieczeństwa — Runda 7 (2026-11-05)

Kompleksowy audyt całego projektu: backend Node/PG, Ubuntu Server prod, Cloudflare Tunnel,
panel admin, klient PowerShell. Priorytety: P0 (przejęcie konta admin, błędy MFA, publiczny PG,
obejście autoryzacji, manipulacja licencjami), P1 (backupy, rozdział DB users, sesje/tokeny,
krytyczne operacje admin), P2 (monitoring/retencja/skan zależności), P3 (docs).

## Znalezione problemy i status

| # | Priorytet | Problem | Poprawka | Status |
|---|---|---|---|---|
| 1 | P0 | Zmiana/włączenie/wyłączenie MFA bez ponownego podania hasła — przejęcie sesji = przejęcie MFA | re-auth: każdy endpoint `/mfa/*` wymaga `password` (+ `totp`/`recovery_code` gdy MFA aktywne) | NAPRAWIONE + testy |
| 2 | P0 | Brak wymuszenia MFA — admin bez TOTP mógł się zalogować samym hasłem | `ADMIN_REQUIRE_MFA=true` → login zwraca `MFA_REQUIRED` gdy brak TOTP | NAPRAWIONE + test |
| 3 | P0 | Zmiana hasła / włączenie MFA nie unieważniała innych sesji | `revokeOtherSessions()` po zmianie hasła i enable/disable TOTP | NAPRAWIONE + test |
| 4 | P0 | Hash kluczy licencyjnych = gołe sha256 — wyciek DB = brute-force kluczy offline | `key_hash = 'v2:' + HMAC-SHA256(klucz, LICENSE_KEY_PEPPER)`; dual lookup z legacy sha256 (istniejące licencje działają) | NAPRAWIONE + test |
| 5 | P0 | Odpowiedzi `/api` mogły być keszowane przez pośredniki (sekrety w odpowiedziach) | `Cache-Control: no-store` na wszystkich `/api` | NAPRAWIONE + test |
| 6 | P1 | Backupy nieszyfrowane na dysku serwera | `backup-database.sh`: fail-closed AES-256-CBC (PBKDF2, 100k iter), klucz w `BACKUP_KEY_FILE` chmod 600 POZA katalogiem backupów, umask 077, sha256 checksum, rotacja | NAPRAWIONE |
| 7 | P1 | Jeden użytkownik DB dla runtime i migracji (nadmiarowe uprawnienia) | osobny pool migracyjny gdy `MIGRATIONS_DATABASE_URL` (rola `d01i_migrator`); runtime `d01i_app` bez praw do DDL | NAPRAWIONE (konfig) + docs |
| 8 | P1 | systemd unit bez twardnienia | pełne hardening: NoNewPrivileges, ProtectSystem=strict, PrivateTmp/Devices, ProtectKernel*, RestrictSUIDSGID, LockPersonality, RestrictNamespaces, MemoryDenyWriteExecute, UMask=0027, ReadWritePaths tylko /var/log | NAPRAWIONE |
| 9 | P1 | Brak endpointu zmiany hasła z poziomu API (tylko ręcznie w DB) | `POST /api/v1/admin/password/change` (wymaga starego hasła + nowe; unieważnia pozostałe sesje) | NAPRAWIONE + test |
| 10 | P2 | Brak skanu sekretów w CI | job `secret-scan` (gitleaks) w `.github/workflows/client-ci.yml` | NAPRAWIONE (CI do uruchomienia na GH Actions) |
| 11 | P2 | Advisory zależności: zod GHSA-mrhx-c7xc-m3w5 (fix tylko w major 4.6.7) | NIE robimy ślepego major — pin `zod@3.25.76`; ryzyko resztkowe zniwelone limitem body 64 KB; dokumentacja poniżej | ZANOTOWANE + zmitygowane |
| 12 | P2 | Rate limiting tylko globalny na niektórych ścieżkach | osobny `mfaLimiter` na `/mfa/*` i `/password/change` | NAPRAWIONE |
| 13 | P3 | Brak docs prod: deployment, tunnel, backup/restore, rotacja sekretów, incident response | 6 nowych docs w `docs/` + aktualizacja `SECURITY.md` | NAPRAWIONE |

## Decyzja o zod (GHSA-mrhx-c7xc-m3w5)

Advisory dotyczy range `<4.6.6`, co obejmuje też linię 3.x — sama aktualizacja do 3.25.76
nadal raportuje podatność w `npm audit`. Producent oferuje fix WYŁĄCZNIE w major 4.6.7.
Ślepa aktualizacja major to ryzyko breaking changes w całym walidatorze API. Decyzja:
pin do `3.25.76` + mitigacja (limit rozmiaru body 64 KB ogranicza wektor DoS) + to
dokumentujemy jako znane ryzyko resztkowe. Śledzić wydanie 4.6.7 i planować migrację
z pełnym testem regresji.

## Co NIE było problemem (zweryfikowane)

- Autoryzacja admin: double-submit CSRF + RBAC + sesje HttpOnly — testy przechodzą.
- Ed25519 tylko po stronie serwera (weryfikacja), klient tylko wysyła token — OK.
- PostgreSQL bind tylko 127.0.0.1 + UFW — publiczny PG niemożliwy z zewnątrz.
- HWID nie jest samodzielną granicą (install_id + hwid_hash + limit 2 urządzeń API+DB).
- Tokeny: TTL ≤120 s, rotacja z unieważnieniem, replay 60 s, brak offline grace — testy.

## Testy (FAKTYCZNIE uruchomione)

`cd backend && ARGON2_MEMORY_COST=19456 ARGON2_TIME_COST=2 node --test --test-concurrency=1 'test/*.test.js'`
→ **59 testów, 59 pass, 0 fail — 5 kolejnych przebiegów (2026-11-05)**.
Nowe testy R7: re-auth MFA (złe hasło odrzucone), `MFA_REQUIRED` przy wymuszeniu,
unieważnienie sesji po zmianie hasła, `no-store` na `/api`, dual lookup hash klucza
(v2 + legacy), rate limit MFA.

## NIE uruchomione w tym środowisku (deklaracja)

CI GitHub Actions (incl. gitleaks), testy na VM Windows/Ubuntu, realny Cloudflare Tunnel —
to wymaga środowiska GitHub/VM; konfiguracja przygotowana, wyniki po pierwszym pushu.
