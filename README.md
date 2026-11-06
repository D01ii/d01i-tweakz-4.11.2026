# D01i Tweakz 4.11.2026

Ekosystem optymalizacji Windows z licencjonowanym dostępem PREMIUM.

## Struktura
- `backend/` — Node.js 20+ LTS + Express + PostgreSQL, REST API v1, Ed25519, panel admina WWW
- `deploy/ubuntu/` — instalator produkcyjny Ubuntu Server LTS (systemd, Caddy, UFW, backupy)
- `deploy/windows/` — instalator deweloperski Windows 11 Home/Pro (natywny, bez WSL/Dockera)
- `docs/` — architektura, API, instalacja, bezpieczeństwo, testy, panel

## Szybki start (backend)
```bash
cd backend
cp .env.example .env   # uzupełnij sekrety i klucze
npm ci
npm run migrate
npm start              # http://127.0.0.1:8080  (panel: /admin)
npm test               # 62 testy integracyjne (wymaga PostgreSQL)
```

Szczegóły: `docs/INSTALL_UBUNTU.md`, `docs/INSTALL_WINDOWS.md`, `docs/API.md`.
