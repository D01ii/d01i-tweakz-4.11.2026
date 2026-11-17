# Incident response — D01i Tweakz (R7)

## Wykrywanie

- Alerty Discord (zminimalizowane): `FAILED_KEY_BURST`, `TOKEN_TAMPER`, `DEVICE_HWID_MISMATCH`, blokady kont.
- Audit log admina w panelu (`/admin/`): każda akcja z czasem i IP (hash).
- `journalctl -u d01i-backend -f` i `/var/log/d01i-tweakz/`.

## Scenariusze i reakcja

### 1. Podejrzenie przejęcia konta admina
1. Panel (z innego, zaufanego urządzenia): zmień hasło (`POST /api/v1/admin/password/change`) — R7 unieważnia wszystkie pozostałe sesje.
2. Wyłącz i włącz MFA ponownie (wymaga hasła — R7).
3. Przejrzyj sesje i audit log; w razie wątpliwości `UPDATE admin_sessions SET revoked = true`.
4. Zrotuj `SECRET_ENC_KEY` tylko z planem re-enkrypcji; zrotuj `SECURITY_PEPPER` (unieważni wszystkie sesje).

### 2. Wyciek bazy danych (dump)
1. Klucze licencji są tylko jako HMAC (v2) / sha256 — bez pepera brute-force offline jest niepraktyczny (R7).
2. Zrotuj `LICENSE_KEY_PEPPER` zgodnie z SECRET_ROTATION.md (uwaga: wymaga planu migracji).
3. Zrotuj hasła DB, wymuś zmianę haseł adminów, przejrzyj audit log.

### 3. Wyciek sekretów z repo / CI
1. Unieważnij sekret natychmiast (zmień wszędzie), nie licz na „nikt nie widział”.
2. gitleaks w CI blokuje przyszłe wycieki; przeglądnij historię git (`git log -p` + gitleaks lokalnie).
3. Zrotuj wszystkie sekrety z listy SECRET_ROTATION.md.

### 4. Nadużycie / atak na licencje (burst kluczy)
1. Backend sam blokuje IP czasowo (`FAILED_KEY_BURST`) i alertuje na Discord.
2. Sprawdź `abuse_events`; zablokuj IP na poziomie Cloudflare (WAF) lub UFW.
3. W razie masowej próby: rozważ Cloudflare Turnstile na endpoincie aktywacji (przyszłe rozszerzenie).

### 5. Awaria / kompromitacja VPS
1. Odłącz od sieci (panel VPS), zrób snapshot dysku jako dowód.
2. Wdróż na nowym VPS z czystych źródeł + restore z zaszyfrowanego backupu (BACKUP_RESTORE.md).
3. Zrotuj WSZYSTKIE sekrety (SECURITY_PEPPER, LICENSE_KEY_PEPPER, SECRET_ENC_KEY, hasła DB/adminów, klucz backupów, tokeny Cloudflare).
4. Przeanalizuj wektor wejścia (journalctl, audit log, Cloudflare logs).

## Kontakt i eskalacja

- Właściciel projektu → admin techniczny → (opcjonalnie) Cloudflare Support / producent VPS.
- RODO: jeśli incydent dotyczy danych osobowych — obowiązek zgłoszenia do UODO w 72 h (decyzja właściciela).

## Po incydencie

- Post-mortem: co się stało, jaka luka, jaka poprawka w kodzie/konfiguracji, aktualizacja SECURITY_AUDIT.md.
- Weryfikacja: testy regresji (`node --test`, 5 przebiegów) przed ponownym wdrożeniem.
