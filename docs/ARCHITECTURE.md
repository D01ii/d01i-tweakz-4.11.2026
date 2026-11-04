# Architektura D01i Tweakz — Backend

## Przegląd

```
┌────────────────────┐   HTTPS (Caddy/Nginx)   ┌──────────────────────────────┐
│  Aplikacja         │ ───────────────────────▶│  Express (Node.js 20+ LTS)   │
│  PowerShell (klient)│  /api/v1/license/*      │  - rate limiting             │
│                    │  /api/v1/admin/*        │  - walidacja (zod)           │
│                    │ ◀───────────────────────│  - sesje admin (cookie+CSRF) │
└────────────────────┘                         │  - Ed25519 tokeny (≤120 s)   │
                                               └──────────────┬───────────────┘
                                                              │ pg (localhost only)
                                               ┌──────────────▼───────────────┐
                                               │  PostgreSQL (transakcje,     │
                                               │  FOR UPDATE dla limitu       │
                                               │  urządzeń)                   │
                                               └──────────────────────────────┘
```

## Katalogi

```
backend/
  src/
    config/         konfiguracja z env (walidacja sekretów przy starcie)
    db/             pool pg + runner migracji
    migrations/     0001_init.sql (schema)
    utils/          crypto (Ed25519, sha256, pepper), licenseKey
    services/       license, token, admin, audit, abuse, discord, settings
    middleware/     rateLimit, adminAuth (sesja+CSRF), common (błędy, IP)
    routes/v1/      license API (klient)
    routes/admin/   auth, licenses, ops (panel)
    public/admin/   panel WWW (statyczny SPA, ciemny motyw #4B0082→#4B0042)
  test/             testy integracyjne node:test (3 pliki, 29 testów)
deploy/
  ubuntu/           install/uninstall/update/backup/restore (bash)
  windows/          Install/Uninstall/Start/Stop/Update/Check (PowerShell)
  systemd/          d01i-backend.service (hardening)
  caddy/            Caddyfile (TLS, HSTS)
docs/               dokumentacja
```

## Model zaufania

- **Serwer jest jedynym źródłem prawdy** o uprawnieniach PREMIUM. Klient PowerShell
  nigdy nie generuje lokalnie uprawnień; każda walidacja/refresh przechodzi przez backend.
- Tokeny: Ed25519, TTL ≤ 120 s, `jti` trzymane w `license_sessions` (można unieważnić natychmiast).
- Klucze licencyjne: w bazie tylko `sha256(klucz)`; pełny klucz wyświetlany adminowi raz.
- HWID/IP: przechowywane tylko jako `sha256(pepper + wartość)`.
- Limit 2 urządzeń egzekwowany w transakcji `SELECT ... FOR UPDATE`.

## Decyzje projektowe

| Decyzja | Uzasadnienie |
|---|---|
| Brak grace offline (STRICT) | wymóg specyfikacji; PREMIUM tylko online |
| Refresh idempotentny (replay window 60 s) | klient może bezpiecznie powtórzyć żądanie po utracie odpowiedzi |
| Blokady IP tylko czasowe i odwracalne | unikanie bezterminowych banów sieci |
| Discord tylko dane zminimalizowane/pseudonimizowane | RODO + wyciek webhooka nie ujawnia sekretów |
| Brak auto-updatera w wydaniu 1 | architektura gotowa (wersjonowane API, update-*.sh) |
