# D01i Tweakz — rozwiązywanie problemów (zebranie z rzeczywistych zgłoszeń, 2026-11-04)

## Backend

| Objaw | Przyczyna | Rozwiązanie |
|---|---|---|
| `npm error ENOENT ... package.json` | `npm start` w złym katalogu | `cd backend` — tam jest `package.json` |
| `Error: listen EADDRINUSE 127.0.0.1:8080` | stary backend już działa | `Get-NetTCPConnection -LocalPort 8080 -State Listen` → `Stop-Process -Id <pid>`, potem `npm start` |
| `SECRET_ENC_KEY musi byc 64-znakowa...` | zła długość klucza | `openssl rand -hex 32` (32 bajty = 64 znaki HEX) |
| `SECRET_ENC_KEY nie odszyfrowuje istniejącego...` | zły klucz względem danych w bazie | przywróć ORYGINALNY klucz z backupu; NIE generuj nowego |
| `TOKEN_TTL_SECONDS poza zakresem 30-120` | zła wartość w `.env` | popraw zakres 30-120 |

## Panel admina (`/admin`)

| Objaw | Przyczyna | Rozwiązanie |
|---|---|---|
| Czarna pusta strona, w Network `admin/` czerwone | przeglądarka weszła na `https://localhost:8080` (backend lokalnie = HTTP) | wpisz `http://localhost:8080/admin/`; w Brave/Chrome wyłącz „Always use secure connections” albo używaj http |
| Czarna strona, w Console `SyntaxError` w `app.js` | stary/błędny `app.js` z cache albo stary kod | `git pull` (min. commit z fixem app.js), zabij stary proces node, `npm start`, **Ctrl+Shift+R** |
| `404 favicon.ico` | brak ikony | nieszkodliwe; naprawione w kodzie (`data:` icon) |

## Klient PowerShell (`client\premium`, `client\demo`)

| Objaw | Przyczyna | Rozwiązanie |
|---|---|---|
| `'starter.bat' is not recognized` | uruchomione spoza folderu (PATH) | `cd client\premium` i `.\starter.bat` albo pełna ścieżka |
| Błędy parsera (`InvalidVariableReferenceWithDrive`, `Unexpected token`) | stare: `$zmienna:` w stringu / UTF-8 bez BOM / osierocone klamry | `git pull` (min. `2e45e93`/`ac8a166`); skrypty są teraz czystym ASCII + BOM |
| Logo pokazuje `???` | stary plik przed konwersją ASCII | `git pull` (commit `ac8a166`) |
| `NIE SKONFIGUROWANY (ustaw D01I_API_BASE...)` / `CONFIG_MISSING` | brak adresu API w tej sesji | `setx D01I_API_BASE "http://localhost:8080"` + `setx D01I_ALLOW_HTTP "1"` (lokalnie HTTP), zamknij i otwórz PowerShell; weryfikacja: `echo $env:D01I_API_BASE`; alternatywa: `%ProgramData%\D01iTweakz\config.json` |
| Aktywacja `KEY_INVALID` | klucz nie istnieje na TYM backendzie | utwórz licencję w panelu `http://localhost:8080/admin` (login z `ADMIN_BOOTSTRAP_*`) |
| `HTTP_NOT_ALLOWED` | HTTP na adresie innym niż localhost | użyj HTTPS (produkcja) albo localhost + `D01I_ALLOW_HTTP=1` |

## Licencja

- `LICENSE_REVOKED` / `LICENSE_EXPIRED` / `HWID_MISMATCH` / limit 2 urządzeń → zarządzaj w panelu admina (revoke, extend, reset urządzeń).
- Dezaktywacja działa także z wygasłym tokenem (menu `[3]`) — zwalnia slot.
- Brak internetu = brak funkcji PREMIUM (STRICT ONLINE, bez obejścia) — tak ma być.
