# Raport — Runda 8: kompleksowa naprawa błędów (2026-11-06)

## Zmienione pliki
- `client/demo/demo.ps1` — odtworzony kompletny klient DEMO (był pusty, 0 bajtów)
- `client/premium/premium.ps1` — here-string logo, `Set-PowerPlan`, gating PREMIUM, UNDO, backupy DNS/NIC/plików, USB suspend przez PowerUndo, self-test 38, rejestr Copilot, DoubleClickSpeed
- `backend/src/config/index.js` — jeden obiekt `db`, fail-closed MFA i LICENSE_KEY_PEPPER w produkcji
- `backend/test/helpers.js` — `testDbUrl()`: TEST_DATABASE_URL → DATABASE_URL → lokalny socket
- `backend/test/config.test.js` — 3 nowe testy konfiguracji (R8)
- `.github/workflows/client-ci.yml` — TEST_DATABASE_URL + LICENSE_KEY_PEPPER w CI, mockowane testy HWID (CIM)
- `README.md`, `docs/TEST_REPORT.md` — rzeczywista liczba testów (62)
- `deploy/ubuntu/backup-database.sh` — czysty ASCII (CI ascii-check)

## Tabela problemów

| Problem | Priorytet | Status | Zmienione pliki | Test |
|---|---|---|---|---|
| Pusty DEMO (0 bajtów) | P0 | NAPRAWIONE | client/demo/demo.ps1 | ASCII+BOM OK; parser PS w CI (nie w sandboxie) |
| Here-string logo w PREMIUM | P0 | NAPRAWIONE | premium.ps1 | `@'` kończy linię; ASCII czysty; parser PS 5.1/7 w CI |
| Set-Power 'HighPerformance' (zła sygnatura) | P0 | NAPRAWIONE | premium.ps1 | nowa `Set-PowerPlan`; 3 wywołania poprawione |
| UNDO gubi backupy przy częściowym błędzie | P0 | NAPRAWIONE | premium.ps1 | `Invoke-Undo` z per-item statusem; stan tylko przy pełnym sukcesie |
| DEMO mógł odblokować PREMIUM (`$script:Licensed`) | P0 | NAPRAWIONE | premium.ps1 | SmartISLC/ProBalance/menu 12 i 20 przez `Assert-Premium` (tylko typy PREMIUM_*) |
| Podwójny klucz `db` w config | P0 | NAPRAWIONE | backend/src/config/index.js | test R8: config.db ma max+timeouts+migrationsUrl |
| CI ignoruje DATABASE_URL w testach | P0 | NAPRAWIONE | test/helpers.js, client-ci.yml | TEST_DATABASE_URL ustawiony w workflow |
| DNS bez backupu + wybór przez ICMP | P1 | NAPRAWIONE | premium.ps1 | backup per interfejs (DnsUndo), pomiar Resolve-DnsName, brak zmiany gdy żaden resolver nie odpowie |
| Set-Network bez backupu RSC/power mgmt | P1 | NAPRAWIONE | premium.ps1 | NetUndo per adapter + Restore-NetUndo |
| NetworkLatency: globalne wyłączanie RSS, bez backupu | P1 | NAPRAWIONE | premium.ps1 | RSS usunięte z listy; backup AdvProps przed zmianą |
| USB suspend poza PowerUndo | P1 | NAPRAWIONE | premium.ps1 | przez `Set-Power` (AC+DC z backupem) |
| Discord JSON bez backupu | P1 | NAPRAWIONE | premium.ps1 | FileUndo (dokładna zawartość) + walidacja JSON przed zapisem |
| Self-Test 42 vs Set-Priority 38 | P1 | NAPRAWIONE | premium.ps1 | test sprawdza 38 (wartość faktycznie ustawiana) |
| Zła ścieżka rejestru Copilot | P1 | NAPRAWIONE | premium.ps1 | `WindowsCopilot` (bez spacji) |
| DoubleClickSpeed=50 | P1 | NAPRAWIONE (usunięte) | premium.ps1 | wartość nie jest ruszana |
| HWID zależny od sprzętu runnera | P1 | NAPRAWIONE | client-ci.yml | mocki CIM: pełne dane / puste seriale (blad) / brak dysku (blad) |
| MFA domyślnie off | P1 | NAPRAWIONE (fail-closed) | config/index.js | produkcja bez ADMIN_REQUIRE_MFA = MFA wymagane; test R8 |
| Fallback LICENSE_KEY_PEPPER→SECURITY_PEPPER | P1 | NAPRAWIONE | config/index.js | w produkcji wymagany osobny pepper; test R8 |
| Niespójna liczba testów w docs | P2 | NAPRAWIONE | README.md, docs/TEST_REPORT.md | 62 (faktycznie) |

## Testy wykonane (faktycznie uruchomione)
Backend: `node --test --test-concurrency=1` → **62/62 PASS × 5 przebiegów** (2026-11-06).
Klient PS: ascii-check lokalnie OK (wszystkie pliki czysty ASCII + BOM); parser PS 5.1/7 +
mockowane testy HWID — w CI na Windows (nie uruchomione w sandboxie, deklaracja).

## Nierozwiązane / ryzyko regresji
- Brak parsera PS w sandboxie — składnia premium.ps1/demo.ps1 weryfikowana przez CI (pierwszy push).
- `Invoke-Undo` w premium: powercfg przywracane do SCHEME_CURRENT; jeśli plan był zmieniony
  międzyczasie ręcznie, przywrócenie parametrów może dotyczyć innego aktywnego planu —
  mitigacja: PreviousPowerScheme przywracany na końcu.
