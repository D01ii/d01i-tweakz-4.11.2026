# Rotacja sekretów (R7)

Wszystkie sekrety tylko w `/etc/d01i-tweakz/.env` (chmod 600, root) — nigdy w repo.
Generowanie: `openssl rand -hex 32`.

| Sekret | Env | Rotacja | Uwagi |
|---|---|---|---|
| Pepper sesji/IP/HWID | `SECURITY_PEPPER` | restart backendu | unieważnia stare sesje admina i hashe HWID/IP (klient re-aktywuje) |
| Pepper HMAC kluczy licencji | `LICENSE_KEY_PEPPER` | rehash wszystkich `key_hash` w DB | skrypt poniżej; stare licencje muszą działać — dual lookup zostaje do czasu rehash |
| Klucz szyfrowania sekretów w DB | `SECRET_ENC_KEY` | możliwa rotacja z re-enkrypcją | TOTP/webhook zaszyfrowane AES-256-GCM |
| Klucz backupów | `BACKUP_KEY_FILE` | zmień plik + zrób nowy backup | stare backupy zostają starym kluczem (zapisz oba offline) |
| Hasło DB runtime | `DATABASE_URL` | `ALTER ROLE d01i_app PASSWORD ...` + restart | analogicznie `d01i_migrator` |
| Hasło admina | panel / `POST /api/v1/admin/password/change` | dowolnie | unieważnia pozostałe sesje (R7) |
| Sekret TOTP admina | panel (MFA) | wyłącz i włącz ponownie MFA | wymaga hasła (R7) |
| Webhook Discord | panel | dowolnie | zaszyfrowany w DB |

## Rehash kluczy licencji po rotacji LICENSE_KEY_PEPPER

1. Wygeneruj nowy pepper, ustaw w `.env`, zachowaj stary tymczasowo.
2. Dla każdego wiersza `licenses`: `UPDATE licenses SET key_hash = 'v2:' || hmac_sha256(key, NEW_PEPPER)`
   — wymaga pełnych kluczy, których NIE mamy (są tylko hashe!). **Wniosek: rotacja
   LICENSE_KEY_PEPPER wymaga re migracji legacy→v2 tylko dla wierszy, dla których znamy hash
   legacy — praktycznie: NIE rotuj pepera bez planu; dual lookup (v2 OR legacy sha256)
   utrzymuje kompatybilność.** Zalecane: ustaw `LICENSE_KEY_PEPPER` raz przy wdrożeniu i nie zmieniaj.
3. Po pełnym przejściu na v2 można usunąć gałąź legacy (osobna migracja).

## Checklist kwartalny

- [ ] `npm audit` w backend/ — przegląd advisories (znane: zod, patrz SECURITY_AUDIT.md).
- [ ] gitleaks w CI zielony.
- [ ] przegląd aktywnych sesji admina i audit log (panel).
- [ ] test restore backupu na VM.
- [ ] rotacja haseł DB/adminów jeśli podejrzenie wycieku.
