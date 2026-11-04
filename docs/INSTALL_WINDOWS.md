# Instalacja deweloperska — Windows 11 Home / Pro

Wymagania: Windows 11 (build ≥ 22000), PowerShell 5.1+, **PowerShell jako Administrator**.
Instalacja jest natywna — **nie wymaga WSL ani Dockera** (Docker pozostaje opcją dodatkową).

## Kroki

```powershell
# jako Administrator:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\deploy\windows\Install-Windows.ps1
```

Instalator:
1. Sprawdza wersję Windows 11 i uprawnienia administratora.
2. Wykrywa/instaluje Node.js ≥ 20 LTS (NodeSource MSI 22.x) — przy braku może wymagać restartu;
   po restarcie uruchom instalator ponownie (jest idempotentny).
3. Wykrywa/instaluje PostgreSQL (usługa `postgresql-*`, start automatyczny).
4. Tworzy bazę `d01i_tweakz` i użytkownika `d01i_app` (istniejące dane **nie** są kasowane).
5. Generuje sekrety, klucze Ed25519 (`%ProgramData%\D01iTweakz\keys`) i `.env`.
6. `npm ci --omit=dev`, migracje, start backendu, healthcheck, raport.

## Skrypty
| Skrypt | Cel |
|---|---|
| `Check-Environment.ps1` | diagnostyka (OS, Node, PostgreSQL, firewall, health) — tylko odczyt |
| `Start-Backend.ps1` / `Stop-Backend.ps1` | start/stop procesu node |
| `Update-Backend.ps1` | backup kodu → podmiana → migracje → restart (baza nietknięta) |
| `Uninstall-Windows.ps1` | czysta dezinstalacja (baza tylko po potwierdzeniu) |

## Dostęp
- Panel admina: `http://localhost:8080/admin`
- API health: `http://localhost:8080/api/v1/admin/ops/health`
- Dane bootstrap admina: `%ProgramData%\D01iTweakz\.env`
