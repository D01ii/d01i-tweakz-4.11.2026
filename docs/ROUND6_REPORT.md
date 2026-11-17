# Runda 6 — stabilizacja klienta Windows, licencjonowania i backup/restore — 2026-11-04

**Branch:** `arena/1c72ad7f-d01i-tweakz-4-11-2026` · **HEAD przed:** `9ba768f` · **HEAD po:** commit rundy 6 (git log)

## ETAP 1 — PowerShell 5.1
- Usunięto wszystkie operatory PS7-only z klienta: 4× ternary `? :` w `D01iLicense.psm1` zastąpione klasycznym if/else; skan `??`, `&&`, `||`, `?.` w `client/**` — czysty (pozostało tylko wspomnienie w komentarzu).
- **NIE wykonano:** prawdziwego parsowania przez Windows PowerShell 5.1 / PowerShell 7 — binary `pwsh` niedostępne w sandboxie (host z release'ami GitHub zablokowany, apt blokowany). Wymagany Windows CI (runner Windows + pwsh 7) przed wydaniem klienta. Deklaracja zgodności oparta na analizie statycznej — wyraźnie oznaczona.

## ETAP 2 — adres API klienta
- Usunięto domyślną przykładową domenę `https://api.twojadomena.pl` z `Get-D01iApiBase`. Adres tylko z `D01I_API_BASE` lub `%ProgramData%\D01iTweakz\config.json` (`api_base`).
- `Test-D01iApiBase`: brak konfiguracji → `CONFIG_MISSING` + blokada aktywacji z komunikatem; walidacja URL; **HTTPS wymagane**, HTTP tylko dla localhost/127.0.0.1 z `D01I_ALLOW_HTTP=1`. Brak sekretów backendu w kliencie.
- `docs/MANUAL_INSTALLATION_GUIDE.md` — nowa sekcja F (jak użytkownik ustawia własną domenę).

## ETAP 3 — bezpieczne przechowywanie licencji i cykl życia tokenów
- Klucz licencyjny zapisywany wyłącznie jako **DPAPI blob** (`ProtectedData`, CurrentUser) w `license.json`; ACL katalogu/pliku tylko SYSTEM (S-1-5-18) + lokalni Administratorzy (S-1-5-32-544) przez SID-y; błędy ACL **nie są ignorowane** (rzucamy wyjątek); zapis atomowy (temp + move); brak logowania kluczy/tokenów/HWID.
- Cykl życia: walidacja ważnego tokena → refresh przy <30 s do wygaśnięcia → po wygaśnięciu **automatyczna ponowna aktywacja** kluczem z DPAPI (`Invoke-D01iReauth`) — użytkownik nie wpisuje klucza ponownie. Revoke/expiry/HWID_MISMATCH/offline → blokada PREMIUM, bez grace period. Dezaktywacja działa także po wygaśnięciu tokena (key + install_id) — zwalnia slot licencji.
- HWID: brak `HWID-ERR00000000` fallback — brak ProcessorId/SerialNumber/dysk → jawny błąd, aktywacja odmówiona; nazwa komputera usunięta z HWID; install_id = hash(MachineGuid), brak MachineGuid → błąd (bez losowego fallbacku).

## ETAP 4 — backup/restore (DEMO + PREMIUM)
- **demo.ps1:** `Restore-ServicesDefault` przywraca tylko zapisane stany (StartupType + DelayedAutoStart + czy istniał + Running), bez fallbacku do `ServiceDefaults` (usunięty); `Restore-D01Tasks` włącza tylko zadania wyłączone przez D01i z poprzednim stanem Enabled; hibernacja z zapisem stanu (`Restore-Hibernation`); plany zasilania: zapis poprzedniego aktywnego GUID (`Restore-D01PowerScheme`), usuwanie tylko własnego planu Ultimate; powercfg AC/DC: każda zmiana najpierw zapisuje starą wartość (`PowerUndo`), restore przywraca tylko zapisane; NIC (PnPCapabilities) i MTU z pełnym backupem per karta — jeśli stanu nie można odczytać, zmiana jest **odmawiana**; `Invoke-RestoreDefaults` daje raport i nie kasuje stanu przy błędach.
- **premium.ps1:** BCD — `Set-BcdSetting` zapisuje istnienie + wartość każdego wpisu, `Restore-Bcd` przywraca oryginał lub usuwa tylko wartości utworzone przez D01i; `Set-Power` zapisuje AC/DC przed zmianą (`PowerUndo` + `Restore-PowerUndo`); `Invoke-Undo` — szczegółowy raport (przywrócone/pominięte/nieudane), stan nieudanych zachowany, punkt przywracania i backup rejestru nigdy nie kasowane.

## ETAP 5 — ponowny audyt tweaków
- Z uniwersalnego DEMO usunięto globalne CPU min 100% i wyłączanie parkowania rdzeni (zostały tylko PCIe ASPM off + USB suspend off, odwracalne). Ultimate Performance zostało z ostrzeżeniem o poborze energii/temperatur. Pozostałe tweaki mają uzasadnienie + backup + restore; brak obietnic FPS bez pomiaru.

## ETAP 6 — spójność DEMO/PREMIUM
- Reguła (zapisana w przewodniku sekcja F): DEMO = bezpłatny, bez licencji, bezpieczny podzbiór; PREMIUM = licencja `PREMIUM_*`, walidacja online per operacja. `Assert-D01iPremium` akceptuje tylko typy PREMIUM — DEMO nigdy nie dostaje PREMIUM.

## ETAP 7 — testy (5+ przebiegów)
- Backend: znaleziono i naprawiono **flaky test** R4 (wyścig `CREATE TABLE schema_migrations` poza advisory lockiem → duplicate key w pg_type przy 4 równoległych procesach). Poprawka: tabela tworzona wewnątrz transakcji z lockiem (`migrate.js`). Po poprawce: **10/10 przebiegów × 53/53 PASS, 0 FAIL** (Node v22.22.3, PostgreSQL 16.2; przed poprawką flaky ~40% przebiegów).
- PowerShell: tylko analiza statyczna (brak pwsh w sandboxie) — patrz Etap 1. Testy backup/restore na żywym Windows: **niewykonane** (brak VM; nie ryzykowano głównego systemu).

## Zmienione pliki
`client/common/D01iLicense.psm1` (przepisany), `client/premium/premium.ps1`, `client/demo/demo.ps1`, `backend/src/db/migrate.js`, `docs/MANUAL_INSTALLATION_GUIDE.md`, `docs/TEST_REPORT.md`, `docs/ROUND6_REPORT.md`.

## Gotowość klienta Windows
Kod zgodny statycznie z PS 5.1, licencjonowanie online fail-closed, backup/restore tylko ze stanu rzeczywistego. **Warunek wydania:** test parsera PS 5.1 + PS7, import modułu, pełny cykl licencji i backup/restore na Windows CI / VM Windows 11 — w tym środowisku niewykonalne.
