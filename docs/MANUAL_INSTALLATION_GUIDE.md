# D01i Tweakz — Instrukcja ręcznej instalacji i uruchomienia

Wersja: 2026-11-04 · Gałąź: `arena/1c72ad7f-d01i-tweakz-4-11-2026` · Zweryfikowana względem kodu backendu (`backend/`, HEAD `99c17eb`)

> Uwaga: automatyczne instalatory (`deploy/ubuntu/install-ubuntu.sh`, `deploy/windows/Install-Windows.ps1`) nie są dalej rozwijane. Ten dokument prowadzi do działającego backendu krok po kroku.

---

## 0. Co jest potrzebne

| Element | Wymaganie |
|---|---|
| Serwer (produkcja) | Ubuntu Server 24.04 LTS, min. 1 vCPU / 1 GB RAM, publiczny adres IP lub domena |
| Windows (dewelopersko) | Windows 11 Home/Pro, PowerShell 5.1 (wbudowany) |
| Node.js | 20 LTS lub nowszy (`node -v` → `v20.x` lub wyżej; backend testowany na v22) |
| PostgreSQL | 15/16, nasłuchujący lokalnie (127.0.0.1), **nie** wystawiony publicznie |
| Domena (produkcja) | rekord A wskazujący na serwer, np. `api.twojadomena.pl` |

Struktura repozytorium (istotne ścieżki):

```
backend/                 ← cały backend (tu pracujemy)
  package.json           ← skrypty: start, migrate, test
  .env.example           ← wzór pliku .env (NIGDY nie commituj prawdziwego .env)
  src/index.js           ← punkt startu (migracje + start HTTP)
  src/db/migrate.js      ← migrator schematu (uruchamiany też przez npm run migrate)
  src/public/admin/      ← panel administratora (SPA, serwowany przez backend pod /admin)
  test/                  ← testy (node --test)
client/demo/demo.ps1     ← klient DEMO
client/premium/premium.ps1 ← klient PREMIUM
deploy/ubuntu, deploy/windows ← stare instalatory (nierozwijane, patrz nagłówek)
docs/                    ← dokumentacja
```

Z **katalogu `backend/`** wykonuje się wszystkie polecenia `npm`/`node` opisane poniżej.

---

## A. Pobranie projektu z GitHub

### A1. Przez Git (zalecane)

```bash
# Ubuntu
sudo apt update && sudo apt install -y git
# Windows (PowerShell 5.1, jako Administrator)
# Git for Windows: https://git-scm.com/download/win — po instalacji zamknij i otwórz PowerShell

git clone https://github.com/D01ii/d01i-tweakz-4.11.2026.git
cd d01i-tweakz-4.11.2026
git switch arena/1c72ad7f-d01i-tweakz-4-11-2026
```

### A2. Archiwum ZIP (bez Gita)

1. Wejdź na https://github.com/D01ii/d01i-tweakz-4.11.2026
2. Kliknij zielony **Code** → **Download ZIP** (wybierz gałąź `arena/1c72ad7f-d01i-tweakz-4-11-2026`, jeśli GitHub na to pozwala; inaczej pobierz ZIP `main` i dopisz w dokumencie różnice — lub użyj Gita jak w A1).
3. Rozpakuj, np. do `C:\d01i-tweakz` (Windows) lub `~/d01i-tweakz` (Ubuntu).

### A3. Sprawdzenie aktualności

```bash
cd d01i-tweakz-4.11.2026
git log --oneline -3          # ostatnie commity
git status                     # "working tree clean" = pliki zgodne z gałęzią
git rev-parse HEAD             # SHA — porównaj z SHA w docs/ROUND5_REPORT.md
```

---

## B. Instalacja produkcyjna na Ubuntu Server 24.04

Wszystkie kroki jako `root` (lub przez `sudo`). Zakładamy domenę `api.twojadomena.pl`.

### B1. Przygotowanie systemu

```bash
apt update && apt upgrade -y
apt install -y curl ca-certificates gnupg ufw openssl
# Node.js 22 LTS (NodeSource)
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs
node -v    # v22.x
npm -v
# PostgreSQL 16
apt install -y postgresql postgresql-contrib
systemctl enable --now postgresql
```

### B2. Użytkownik i baza PostgreSQL

```bash
sudo -u postgres psql <<'SQL'
CREATE ROLE d01i_app LOGIN PASSWORD 'GENEROWANE_HASLO_ponizej';
CREATE DATABASE d01i_tweakz OWNER d01i_app;
SQL
# Hasło bazy wygeneruj bezpiecznie:
DB_PASS="$(openssl rand -base64 32 | tr -d '/+=' )"
# i użyj go w CREATE ROLE powyżej (podmień GENEROWANE_HASLO_ponizej).
```

Zabezpiecz nasłuch: PostgreSQL domyślnie słucha na localhost — **nie zmieniaj** `listen_addresses` na `'*'`.

### B3. Użytkownik systemowy aplikacji

```bash
useradd --system --home /opt/d01i-tweakz --shell /usr/sbin/nologin d01i
mkdir -p /opt/d01i-tweakz /etc/d01i-tweakz/keys
chown -R d01i:d01i /opt/d01i-tweakz
chown root:d01i /etc/d01i-tweakz /etc/d01i-tweakz/keys
chmod 750 /etc/d01i-tweakz /etc/d01i-tweakz/keys
```

### B4. Skopiowanie backendu i zależności

```bash
# jako użytkownik z dostępem do repo (lokalnie sklonowanego jak w A1):
rsync -a --exclude .git --exclude node_modules ~/d01i-tweakz-4.11.2026/backend/ /opt/d01i-tweakz/
sudo -u d01i bash -c 'cd /opt/d01i-tweakz && npm ci --omit=dev'
```

### B5. Sekrety — generowanie (wszystkie komendy wykonaj jako `root`)

```bash
cd /etc/d01i-tweakz
# 1) SECURITY_PEPPER — 32 bajty HEX
openssl rand -hex 32 > pepper.hex
# 2) SECRET_ENC_KEY — DOKŁADNIE 32 bajty = 64 znaki HEX (AES-256-GCM)
openssl rand -hex 32 > enc_key.hex
# 3) Para kluczy Ed25519 do podpisu tokenów licencyjnych
openssl genpkey -algorithm ED25519 -out keys/ed25519_private.pem
openssl pkey -in keys/ed25519_private.pem -pubout -out keys/ed25519_public.pem
chmod 640 pepper.hex enc_key.hex keys/*
chown root:d01i pepper.hex enc_key.hex keys/*
```

> **KRYTYCZNE:** `SECURITY_PEPPER`, `SECRET_ENC_KEY` i klucz prywatny Ed25519 to sekrety produkcyjne. Skopiuj je w bezpieczne miejsce (menedżer haseł / sejf offline, poza serwerem i poza repo). Utrata `SECRET_ENC_KEY` = **trwała utrata zaszyfrowanych sekretów w bazie** (TOTP adminów, webhook) — backend celowo odmówi startu, jeśli klucz nie odszyfruje istniejących rekordów.

### B6. Plik `.env`

```bash
sudo -u d01i cp /opt/d01i-tweakz/.env.example /opt/d01i-tweakz/.env
sudo -u d01i nano /opt/d01i-tweakz/.env
```

Uzupełnij (zgodnie z `backend/.env.example` i `backend/src/config/index.js`):

```dotenv
NODE_ENV=production
PORT=8080
HOST=127.0.0.1
PUBLIC_BASE_URL=https://api.twojadomena.pl
DATABASE_URL=postgres://d01i_app:TWOJE_HASLO_DB@127.0.0.1:5432/d01i_tweakz
SECURITY_PEPPER=<zawartosc /etc/d01i-tweakz/pepper.hex>
SECRET_ENC_KEY=<zawartosc /etc/d01i-tweakz/enc_key.hex>   # 64 znaki HEX
ED25519_PRIVATE_KEY_PATH=/etc/d01i-tweakz/keys/ed25519_private.pem
ED25519_PUBLIC_KEY_PATH=/etc/d01i-tweakz/keys/ed25519_public.pem
TOKEN_TTL_SECONDS=120            # dozwolone 30-120; poza zakresem backend odmawia startu
REFRESH_REPLAY_WINDOW_SECONDS=60
ADMIN_SESSION_TTL_HOURS=8
MAX_DEVICES_DEFAULT=2
ADMIN_BOOTSTRAP_ENABLED=true     # TYLKO przy pierwszej instalacji
ADMIN_BOOTSTRAP_USERNAME=admin
ADMIN_BOOTSTRAP_PASSWORD=<losowe min. 12 znakow: openssl rand -base64 18>
# DISCORD_WEBHOOK_ENABLED=false (lub ustaw webhook w panelu admina)
```

```bash
chown d01i:d01i /opt/d01i-tweakz/.env
chmod 600 /opt/d01i-tweakz/.env
```

### B7. Migracje i pierwszy start (ręczna kontrola)

```bash
sudo -u d01i bash -c 'cd /opt/d01i-tweakz && npm run migrate'   # node src/db/migrate.js
sudo -u d01i bash -c 'cd /opt/d01i-tweakz && timeout 15 npm start'
# Oczekiwany log m.in.:
#   [d01i] zweryfikowano SECRET_ENC_KEY wobec 0 zaszyfrowanych rekordow
#   [d01i] PostgreSQL OK
#   [d01i] nasluchuje na http://127.0.0.1:8080
# Ctrl+C po sprawdzeniu. Przy starcie backend SAM wykonuje migracje i weryfikację klucza
# (src/index.js) — jeśli klucz nie pasuje do danych, proces kończy się PRZED startem HTTP.
```

Healthcheck:

```bash
curl -s http://127.0.0.1:8080/api/v1/admin/ops/health
# {"ok":true,...}
curl -s http://127.0.0.1:8080/api/v1/config
# {"ok":true,"config":{"env":"production","tokenTtlSeconds":120,"maxDevicesDefault":2,"licenseTypes":["DEMO","PREMIUM_30D","PREMIUM_90D","PREMIUM_LIFETIME"]}}
curl -s http://127.0.0.1:8080/     # {"ok":true,"product":"D01i Tweakz Backend",...,"adminPanel":"/admin"}
```

### B8. Usługa systemd

```bash
cat > /etc/systemd/system/d01i-tweakz.service <<'EOF'
[Unit]
Description=D01i Tweakz Backend
After=network.target postgresql.service

[Service]
Type=simple
User=d01i
Group=d01i
WorkingDirectory=/opt/d01i-tweakz
EnvironmentFile=/opt/d01i-tweakz/.env
ExecStart=/usr/bin/node src/index.js
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/opt/d01i-tweakz

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now d01i-tweakz
systemctl status d01i-tweakz --no-pager
journalctl -u d01i-tweakz -n 50 --no-pager
```

> Uwaga: `EnvironmentFile` ładuje `.env` — plik ma prawa `600 d01i:d01i`, więc tylko aplikacja go czyta.

### B9. Reverse proxy Caddy + HTTPS

```bash
apt install -y caddy
cat > /etc/caddy/Caddyfile <<'EOF'
api.twojadomena.pl {
    reverse_proxy 127.0.0.1:8080
}
EOF
systemctl reload caddy
# Caddy automatycznie wystawi certyfikat Let's Encrypt (wymaga otwartych portów 80/443 i rekordu A).
curl -s https://api.twojadomena.pl/api/v1/admin/ops/health
```

### B10. Firewall

```bash
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny 5432/tcp     # PostgreSQL tylko lokalnie
ufw deny 8080/tcp     # backend tylko przez Caddy (lokalnie)
ufw enable
ufw status
```

### B11. Pierwszy admin i panel

1. Otwórz `https://api.twojadomena.pl/admin` — zaloguj się loginem/hasłem z `ADMIN_BOOTSTRAP_*`.
2. **Natychmiast** ustaw MFA (TOTP): POST `/api/v1/admin/mfa/setup` → zeskanuj QR → `/mfa/enable`.
3. W panelu ustaw `ADMIN_BOOTSTRAP_ENABLED=false` w `.env` i `systemctl restart d01i-tweakz`.
4. Utwórz licencje: POST `/api/v1/admin/licenses` (typy: `DEMO`, `PREMIUM_30D`, `PREMIUM_90D`, `PREMIUM_LIFETIME`).

### B12. Logi, backup, aktualizacja

```bash
# Logi
journalctl -u d01i-tweakz -f
# Backup bazy (codziennie przez cron)
sudo -u postgres pg_dump d01i_tweakz | gzip > /var/backups/d01i/d01i_tweakz_$(date +%F).sql.gz
# Backup sekretów (RĘCZNIE, offline, poza serwerem):
#   /etc/d01i-tweakz/pepper.hex, enc_key.hex, keys/ed25519_private.pem
# Aktualizacja (bez utraty danych):
#   1) backup bazy (powyżej) + backup .env i /etc/d01i-tweakz
#   2) rsync nowej wersji backend/ do /opt/d01i-tweakz (NIE nadpisuj .env!)
#   3) sudo -u d01i npm ci --omit=dev
#   4) systemctl restart d01i-tweakz  (migracje wykonają się przy starcie, atomowo)
# Rollback: przywróć backup bazy (pg_restore/psql) i poprzednią wersję kodu, restart usługi.
```

---

## C. Instalacja deweloperska na Windows 11 (bez Dockera/WSL)

PowerShell 5.1 jako Administrator:

```powershell
# 1) Node.js 22 LTS: https://nodejs.org (instalator MSI) — zaznacz "Add to PATH"
node -v
# 2) PostgreSQL 16: https://www.postgresql.org/download/windows/ (instalator EDB, port 5432, hasło dla postgres)
# 3) Git for Windows: https://git-scm.com/download/win
git clone https://github.com/D01ii/d01i-tweakz-4.11.2026.git
cd d01i-tweakz-4.11.2026
git switch arena/1c72ad7f-d01i-tweakz-4-11-2026
cd backend
npm ci
# 4) Sekrety (PowerShell 5.1, CSPRNG):
$rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
function New-RandomHex([int]$ByteCount) { $b = New-Object byte[] $ByteCount; $rng.GetBytes($b); ([BitConverter.ToString($b)).Replace('-','').ToLower() }
$pepper  = New-RandomHex 32   # SECURITY_PEPPER
$encKey  = New-RandomHex 32   # SECRET_ENC_KEY — 32 bajty = 64 znaki HEX
# Klucze Ed25519 (przez openssl z Git Bash lub WSL-free: użyj "C:\Program Files\Git\usr\bin\openssl.exe"):
& "C:\Program Files\Git\usr\bin\openssl.exe" genpkey -algorithm ED25519 -out ..\keys\ed25519_private.pem
& "C:\Program Files\Git\usr\bin\openssl.exe" pkey -in ..\keys\ed25519_private.pem -pubout -out ..\keys\ed25519_public.pem
# 5) .env — skopiuj .env.example do .env i uzupełnij (NODE_ENV=development,
#    DATABASE_URL=postgres://postgres:HASLO@127.0.0.1:5432/d01i_tweakz,
#    ED25519_PRIVATE_KEY_PATH / ED25519_PUBLIC_KEY_PATH na wygenerowane pliki,
#    lub lokalnie ALLOW_EPHEMERAL_KEYS=true — wtedy NIE ustawiaj pepper/encKey recznie)
# 6) Baza:
& "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U postgres -c "CREATE DATABASE d01i_tweakz;"
# 7) Migracje i start:
npm run migrate
npm start          # http://127.0.0.1:8080  →  panel: http://127.0.0.1:8080/admin
# 8) Testy (wymagają lokalnego PostgreSQL):
$env:ARGON2_MEMORY_COST=19456; $env:ARGON2_TIME_COST=2; npm test
```

Diagnostyka typowych błędów startu (wszystkie komunikaty pochodzą z `backend/src/config/index.js`):

| Komunikat | Przyczyna |
|---|---|
| `SECRET_ENC_KEY musi byc 64-znakowa wartoscia HEX` | klucz ma inną długość niż 32 bajty — wygeneruj `openssl rand -hex 32` |
| `SECRET_ENC_KEY nie odszyfrowuje istniejącego...` | zły klucz względem danych w bazie — przywróć oryginalny klucz, NIE generuj nowego |
| `TOKEN_TTL_SECONDS=... poza dozwolonym zakresem 30-120 s` | popraw wartość w `.env` |
| `Brak kluczy Ed25519...` | ustaw ścieżki PEM lub `ALLOW_EPHEMERAL_KEYS=true` (tylko lokalnie) |
| `Brak SECURITY_PEPPER` / `Brak SECRET_ENC_KEY` | uzupełnij `.env` |

---

## D. Konfiguracja i bezpieczeństwo — zasady

**Sekrety (nigdy w repo, nigdy w kliencie, nigdy w logach):**
- `SECRET_ENC_KEY` (64 HEX) — szyfruje sekrety w bazie (TOTP, webhook). **Utrata = nieodwracalna utrata tych danych**; backend odmówi startu przy niezgodnym kluczu (fail-closed).
- `SECURITY_PEPPER` — hashowanie IP/HWID.
- klucz prywatny Ed25519 — podpisuje tokeny licencyjne. Klient zawiera tylko klucz publiczny (lub żaden — weryfikacja jest po stronie serwera).
- hasło bazy, hasła adminów (Argon2id), sesje admina.

**Przechowywanie:** `.env` z prawami `600` (Linux) / ACL tylko dla konta usługi (Windows); kopia zapasowa sekretów offline (sejf/menedżer haseł), poza serwerem.

**Nigdy nie commituj:** `.env`, `*.pem`, `pepper.hex`, `enc_key.hex`, `*.key`, backupy rejestru zawierające dane użytkownika. `.gitignore` repo to blokuje.

**Odtworzenie po awarii:** 1) nowy serwer + PostgreSQL, 2) `pg_restore` z backupu bazy, 3) przywróć `.env` i `/etc/d01i-tweakz` (oryginalne sekrety!), 4) `npm ci`, 5) `systemctl start` — backend zweryfikuje klucz przed startem HTTP; jeśli się nie zgadza, nie startuje (ochrona danych).

---

## E. Weryfikacja i ograniczenia

- Wszystkie komendy i zmienne powyżej odpowiadają plikom: `backend/package.json`, `backend/.env.example`, `backend/src/config/index.js`, `backend/src/index.js`, `backend/src/app.js` (weryfikacja 2026-11-04, HEAD `99c17eb`).
- **NIE wykonano w tym środowisku:** instalacji na czystych VM Ubuntu 24.04 / Windows 11 (brak VM) — przed produkcją należy przejść tę instrukcję na czystych maszynach. Testy jednostkowe/integracyjne backendu (53/53) wykonano na prawdziwym PostgreSQL — patrz `docs/TEST_REPORT.md`.

---

## F. Konfiguracja klienta Windows (adres API)

Klient (`client/premium/premium.ps1`, `client/demo/demo.ps1` + `client/common/D01iLicense.psm1`) **nie ma wbudowanej przykładowej domeny**. Adres backendu ustawiasz lokalnie na komputerze użytkownika:

```powershell
# trwale dla użytkownika (setx) lub dla bieżącej sesji:
setx D01I_API_BASE "https://api.twojadomena.pl"     # <- TWOJA domena z sekcji B9
# lub plik konfiguracyjny: %ProgramData%\D01iTweakz\config.json
# { "api_base": "https://api.twojadomena.pl" }
```

Zasady (wymuszane przez `Test-D01iApiBase` w `D01iLicense.psm1`):

- bez ustawionego adresu aktywacja jest **zablokowana z czytelnym komunikatem** (`CONFIG_MISSING`);
- wymagany prawidłowy URL i **HTTPS**; HTTP dopuszczalne tylko dla `localhost`/`127.0.0.1` z `D01I_ALLOW_HTTP=1` (środowisko deweloperskie);
- klient nie zawiera żadnych sekretów backendu (klucz prywatny Ed25519 i `SECRET_ENC_KEY` zostają wyłącznie na serwerze);
- klucz licencyjny przechowywany lokalnie jest chroniony **DPAPI** (`license.json` w `%ProgramData%\D01iTweakz`, ACL tylko SYSTEM + Administratorzy via SID), token sesji ma TTL 120 s i jest odświeżany online; po wygaśnięciu tokena klient sam ponawia aktywację zapamiętanym kluczem — bez trybu offline.

**Reguła produktu DEMO/PREMIUM (spójna w backendzie, panelu, kliencie i dokumentacji):** DEMO = bezpłatny klient z bezpiecznym podzbiorem funkcji, **bez wymagania licencji**; PREMIUM = pełne funkcje, wymagana licencja `PREMIUM_*` walidowana online przy każdej operacji (revoke/expiry/HWID mismatch/blokada IP natychmiast blokują; brak internetu = brak PREMIUM). Typ licencji `DEMO` w backendzie służy tylko do ewidencji aktywacji demo i **nie daje uprawnień PREMIUM** (`Assert-D01iPremium` akceptuje wyłącznie `PREMIUM_30D/90D/LIFETIME`).
