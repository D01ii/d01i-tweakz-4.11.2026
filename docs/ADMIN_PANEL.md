# Panel administratora WWW

Dostęp: `https://<domena>/admin` (lokalnie `http://localhost:8080/admin`).

## Wygląd
Czarne tło, ciemnoszare panele, akcent fioletowy `#4B0042`, responsywny, minimalistyczny.

## Zakładki
- **Dashboard** — statystyki: aktywne/unieważnione licencje, urządzenia, sesje, aktywacje 24 h, nadużycia 24 h, liczba adminów.
- **Licencje** — lista z wyszukiwaniem (prefix klucza/typ/status), tworzenie klucza
  (typ DEMO/PREMIUM 30D/90D/LIFETIME, limit urządzeń 1–10; pełny klucz pokazany **raz**),
  szczegóły: urządzenia (z dezaktywacją), historia aktywacji, unieważnij / przedłuż / reset urządzeń.
- **Audit** — log wszystkich akcji (kto, co, kiedy, poziom zagrożenia).
- **Nadużycia** — zdarzenia bezpieczeństwa + blokady IP (z możliwością cofnięcia blokady przez superadmina).
- **Ustawienia** — webhook Discord (włącz/wyłącz, URL; wysyłane tylko dane zminimalizowane),
  zarządzanie administratorami (tworzenie, wyłączanie — superadmin).
- **Konto** — konfiguracja MFA (TOTP) + kody odzyskiwania.

## Zabezpieczenia panelu
Sesje w bazie (8 h TTL, unieważnialne), cookie HttpOnly + Secure (prod) + SameSite=Strict,
CSRF double-submit, Argon2id dla haseł, MFA (TOTP) z kodami odzyskiwania,
blokada konta po 5 błędnych próbach (15 min), rate limiting, RBAC, pełny audit log,
helmet (CSP, XFO: DENY), maskowanie sekretów w odpowiedziach API.
