# D01i Tweakz — REST API v1

Bazowy URL: `https://<domena>/api/v1` (lokalnie `http://127.0.0.1:8080/api/v1`).
Wszystkie odpowiedzi JSON. Błędy: `{ "error": "KOD", "message": "..." }`.

## Klient licencyjny (PowerShell)

### POST /license/activate
Aktywacja klucza na urządzeniu. Limit urządzeń egzekwowany serwerowo (transakcja).
```json
{ "key": "D01I-XXXX-XXXX-XXXX-XXXX", "install_id": "uuid-instalacji", "hwid": "odcisk-sprzetu", "label": "optional" }
```
Odpowiedzi: `200 {token, token_expires_at, device_id, license}` · `401 KEY_INVALID` · `403 LICENSE_REVOKED|LICENSE_EXPIRED` · `409 DEVICE_LIMIT_REACHED` · `429` (rate limit / blokada)

### POST /license/validate
`{"token":"..."}` → `200 {valid:true, license, device_id}` lub `401 {valid:false, error}`.

### POST /license/refresh
`{"token":"..."}` → `200 {ok, token, token_expires_at}`. Rotacja tokena; idempotentne
powtórzenie w oknie 60 s zwraca ten sam nowy token (odporność na utratę odpowiedzi).

### POST /license/deactivate
`{"token":"..."}` **lub** `{"key":"...","install_id":"..."}` → zwalnia slot urządzenia.

### POST /license/status
`{"token":"..."}` → `200 {license, key_prefix, device_id, active_devices}`.

### POST /license/devices
`{"token":"..."}` → lista urządzeń licencji (cudze install_id są skracane).

## Panel administracyjny (sesja cookie + CSRF)

Wszystkie poniższe wymagają cookie `d01i_admin_session` i nagłówka `X-CSRF-Token`
(dla metod innych niż GET).

| Metoda | Endpoint | Opis |
|---|---|---|
| POST | /admin/login | `{username,password,totp?}` → cookie + csrfToken |
| POST | /admin/logout | unieważnia sesję |
| GET  | /admin/me | bieżący admin |
| GET  | /admin/csrf | aktualny token CSRF |
| POST | /admin/mfa/setup · /mfa/enable · /mfa/disable | TOTP + kody odzyskiwania |
| GET/POST | /admin/admins, POST /admin/admins/:id/(disable|enable) | zarządzanie adminami (superadmin) |
| POST | /admin/licenses | utwórz klucz `{type, max_devices, notes?}` → klucz pokazany **raz** |
| GET  | /admin/licenses?search=&page= | lista z wyszukiwaniem |
| GET  | /admin/licenses/:id | szczegóły + urządzenia + historia |
| POST | /admin/licenses/:id/revoke `{reason}` | unieważnij (natychmiastowo unieważnia sesje) |
| POST | /admin/licenses/:id/extend `{days}` | przedłuż |
| POST | /admin/licenses/:id/reset-devices | reset urządzeń |
| POST | /admin/licenses/:id/devices/:devId/deactivate | dezaktywacja urządzenia |
| GET  | /admin/licenses/:id/history | historia aktywacji |
| GET  | /admin/ops/health | healthcheck (publiczny) |
| GET  | /admin/ops/stats | statystyki dashboard |
| GET  | /admin/ops/audit?limit=&action= | audit log |
| GET  | /admin/ops/abuse?limit=&kind= | zdarzenia nadużyć |
| GET  | /admin/ops/blocks · POST /admin/ops/blocks/:hash/unblock | blokady IP (superadmin) |
| GET/POST | /admin/ops/settings/webhook | konfiguracja Discord webhooka (URL maskowany) |
| GET  | /admin/ops/settings | ustawienia (sekrety maskowane) |

Typy licencji: `DEMO` (7 dni), `PREMIUM_30D`, `PREMIUM_90D`, `PREMIUM_LIFETIME`.
Maksymalnie 2 aktywne urządzenia na licencję (konfigurowalne 1–10 przy tworzeniu).
