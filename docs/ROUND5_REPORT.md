# Runda 5 — dokumentacja instalacji + integracja licencjonowania klienta + audyt tweaków — 2026-11-04

**Branch:** `arena/1c72ad7f-d01i-tweakz-4-11-2026` · **HEAD przed:** `99c17eb` · **HEAD po:** commit rundy 5 (git log)

## 1. Instrukcja ręcznej instalacji — `docs/MANUAL_INSTALLATION_GUIDE.md`
- Pełna procedura PL krok-po-kroku: pobranie (git/ZIP + weryfikacja HEAD), Ubuntu Server 24.04 (Node 22, PostgreSQL 16, user `d01i`, `.env` 600, klucze Ed25519, `SECURITY_PEPPER`/`SECRET_ENC_KEY` = `openssl rand -hex 32`, migracje, systemd, Caddy+HTTPS, ufw, healthcheck `/api/v1/admin/ops/health`, backup/rollback), Windows 11 dev (bez Dockera/WSL), zasady sekretów i odtwarzania po awarii.
- **Każda komenda/zmienna zweryfikowana z kodem:** `backend/package.json`, `.env.example`, `src/config/index.js`, `src/index.js`, `src/app.js` (HEAD `99c17eb`).
- Instalatory automatyczne (`deploy/`) — **nie są dalej rozwijane** zgodnie z decyzją; pozostają w repo jako legacy.

## 2. Licencjonowanie klienta — serwer jako jedyne źródło prawdy
- **Nowy moduł `client/common/D01iLicense.psm1`:** HWID (SHA-256), stabilny `install_id` (MachineGuid), `Invoke-D01iApi`, aktywacja `POST /api/v1/license/activate`, walidacja `/validate`, odświeżanie `/refresh` (TTL 120 s), `/status`, `/devices`, `/deactivate`. Token w `%ProgramData%\D01iTweakz\license.json` z ACL (SYSTEM/Administrators).
- **`premium.ps1`:** usunięto lokalny sekret HMAC (`$script:Secret`), `Get-KeyForHwid`, `Get-DebugKeyInfo` i lokalną walidację klucza. Aktywacja/walidacja wyłącznie online; bramka `Assert-Premium` (per operacja, online) blokuje funkcje PREMIUM przy braku internetu, revoke, expiry, HWID_MISMATCH. **Brak obejścia offline.** Klient nie zawiera żadnych sekretów kryptograficznych.
- **`demo.ps1`:** wariant DEMO = tylko bezpieczne, uniwersalne optymalizacje (profil zasilania, MMCSS, wizualne, QoS, HAGS), bez wymagania licencji.

## 3. Audyt tweaków — usunięte zakazane/ryzykowne (premium.ps1: 19 funkcji, demo.ps1: 6)
Usunięte m.in.: wyłączanie VBS/HVCI, Spectre/Meltdown, stała blokada Windows Update, sterowników WU, wyłączanie Windows Search, SysMain/defrag "na SSD", czyszczenie cache shaderów, „RAM cleaner" (ClearStandby), wymuszony timer 0.5 ms (NtSetTimerResolution), globalne 100% CPU (MaxPerf/CState), wyłączanie kompresji pamięci, HPET, szerokie wyjątki Defendera, edycja hosts (telemetria), agresywne wyłączanie usług bazowych, tryb „agresywny”. Zostały tylko odwracalne, uzasadnione tweaki; każda zmiana nadal przez `Ensure-Backup` + listy undo.

## 4. Backup/restore i diagnostyka
- Backup: punkt przywracania + eksport gałęzi rejestru + zapis rzeczywistych wartości (RegUndo/ServiceUndo/TaskUndo) — przywracanie tylko zapisanych wartości (bez „przywracania” hardkodowanych). Zweryfikowane: `Ensure-Backup`, `Invoke-Undo`, `Restore-*`.
- Diagnostyka (`New-Diag` premium, `Show-StatusScreen` demo): OS/build, CPU, RAM, GPU, dysk, aktywny plan zasilania + **status licencji online**. Brak obietnic konkretnych FPS bez pomiaru.

## 5. Panel administratora
- SPA (`backend/src/public/admin/`) pokrywa wszystkie endpointy: login/logout/me/CSRF, MFA setup/enable, admini (superadmin), licencje (create/list/revoke/extend/reset-devices/deactivate/history), ops (health/stats/audit/abuse/blocks/webhook). Uprawnienia wymuszane po stronie serwera (`requireRole('superadmin')`); webhook — tylko zminimalizowane dane (weryfikowane w rundach 1–4).

## 6. Testy — 5 przebiegów pełnego zestawu (wymagane minimum 5×)
Komenda: `cd backend && ARGON2_MEMORY_COST=19456 ARGON2_TIME_COST=2 node --test --test-concurrency=1 "test/*.test.js"`
Środowisko: Node v22.22.3, PostgreSQL 16.2 (embedded), Debian 12, 2026-11-04.

| Przebieg | tests | pass | fail |
|---|---|---|---|
| 1 | 53 | 53 | 0 |
| 2 | 53 | 53 | 0 |
| 3 | 53 | 53 | 0 |
| 4 | 53 | 53 | 0 |
| 5 | 53 | 53 | 0 |

**5/5 × 53/53 PASS, 0 FAIL.** Testy współbieżności/licencji/rotacji/revoke (R3-P1/P2/P3, race migratora, recovery-code) zawarte w zestawie — wszystkie zielone we wszystkich 5 przebiegach. Brak flaky tests.

## 7. Niewykonane (nie deklarowane jako wykonane)
- **PowerShell 5.1/7: `pwsh` niedostępny w sandboxie** — klient (`premium.ps1`, `demo.ps1`, `D01iLicense.psm1`) zweryfikowany statycznie (usunięte referencje do skasowanych funkcji, bramki licencji, balans bloków); wymagany test uruchomieniowy na Windows 11 przed wydaniem klienta.
- Czyste instalacje na VM Ubuntu 24.04 / Windows 11 — nadal **warunek przedprodukcyjny** (instrukcja w `MANUAL_INSTALLATION_GUIDE.md`).
- Testy tweaków na żywym systemie Windows — celowo NIE wykonywane (ryzyko dla systemu); logika backup/undo pokryta przeglądem kodu.

## 8. Pozostałe ryzyka
- Klient PowerShell jest modyfikowalny przez użytkownika — dlatego autoryzacja wyłącznie po stronie serwera (zaimplementowane).
- Utrata `SECRET_ENC_KEY` = utrata zaszyfrowanych sekretów w bazie (fail-closed przy starcie; backup klucza offline obowiązkowy — opisane w przewodniku).
