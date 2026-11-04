# ============================================================
# D01i Tweakz - instalator deweloperski backendu na Windows 11 (Home/Pro)
# Wymaga: Windows 11, PowerShell 5.1+, uruchomienie jako Administrator.
# Instaluje NATYWNIE (bez WSL/Dockera): Node.js LTS, PostgreSQL,
# bazę + użytkownika, sekrety, klucze Ed25519, migracje, usługę (lub start ręczny).
# Idempotentny - bezpiecznie uruchomić ponownie. NIE usuwa istniejących danych.
# ============================================================
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramFiles\D01iTweakz",
    [string]$EnvFile = "$env:ProgramData\D01iTweakz\.env",
    [string]$KeysDir = "$env:ProgramData\D01iTweakz\keys",
    [string]$DbName = "d01i_tweakz",
    [string]$DbUser = "d01i_app",
    [int]$Port = 8080,
    [string]$PublicBaseUrl = "http://localhost:8080",
    [switch]$NoService   # nie rejestruj zadania/usługi, tylko przygotuj środowisko
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'


function New-SecureRandomHex([int]$ByteCount = 32) {
    # Kryptograficznie bezpieczny generator (CSPRNG), niezalezny od openssl.
    # Parametr to LICZBA BAJTOW; zwracamy HEX (2 znaki na bajt).
    # 32 bajty -> 64 znaki HEX (wymagane dla SECRET_ENC_KEY / AES-256).
    $bytes = New-Object byte[] $ByteCount
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter.ToString($bytes)).Replace('-', '').ToLowerInvariant()
}

function Write-Info($m) { Write-Host "[install] $m" -ForegroundColor Cyan }
function Write-Warn2($m) { Write-Host "[install][UWAGA] $m" -ForegroundColor Yellow }
function Write-Err2($m) { Write-Host "[install][BŁĄD] $m" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsVersionInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{ Caption = $os.Caption; Version = $os.Version; Build = $os.BuildNumber }
}

function Test-Windows11 {
    $v = Get-WindowsVersionInfo
    if ($v.Caption -notmatch 'Windows 11') { return $false }
    return [int]$v.Build -ge 22000
}

function Install-NodeIfMissing {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $ver = (node -v) -replace 'v', ''
        $major = [int]($ver.Split('.')[0])
        if ($major -ge 20) { Write-Info "Node.js wykryty: v$ver"; return }
    }
    Write-Info "Pobieranie Node.js 22 LTS (msi)..."
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $url = "https://nodejs.org/dist/v22.14.0/node-v22.14.0-$arch.msi"
    $msi = "$env:TEMP\nodejs-lts.msi"
    Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
    Write-Info "Instalacja Node.js (wymaga zamknięcia tego okna po zakończeniu MSI)..."
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Warn2 "Node.js może wymagać restartu systemu. Po restarcie uruchom ponownie Install-Windows.ps1."
        exit 0
    }
    Write-Info "Node.js zainstalowany: $(node -v)"
}

function Install-PostgresIfMissing {
    $pg = Get-Service -Name 'postgresql*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pg) { Write-Info "PostgreSQL wykryty (usługa: $($pg.Name))."; return }
    # Chocolatey jako wygodna ścieżka; fallback: ręczny instalator EDB
    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if ($choco) {
        Write-Info "Instalacja PostgreSQL przez Chocolatey..."
        choco install postgresql -y --params "/Password:postgres"
    } else {
        Write-Warn2 "Brak Chocolatey - pobieram instalator PostgreSQL EDB..."
        $url = "https://get.enterprisedb.com/postgresql/postgresql-16.4-1-windows-x64.exe"
        $exe = "$env:TEMP\postgresql.exe"
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
        Write-Info "Uruchamiam instalator PostgreSQL (tryb cichy)..."
        Start-Process $exe -ArgumentList "--mode unattended --superpassword postgres --servicepassword postgres --prefix `"C:\Program Files\PostgreSQL\16`"" -Wait
    }
    Start-Sleep -Seconds 3
    $pg = Get-Service -Name 'postgresql*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pg) { Set-Service $pg.Name -StartupType Automatic; Start-Service $pg.Name -ErrorAction SilentlyContinue; Write-Info "Usługa $($pg.Name) uruchomiona." }
}

function Get-PsqlPath {
    $candidates = @(
        "C:\Program Files\PostgreSQL\17\bin\psql.exe",
        "C:\Program Files\PostgreSQL\16\bin\psql.exe",
        "C:\Program Files\PostgreSQL\15\bin\psql.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $p = Get-Command psql -ErrorAction SilentlyContinue
    if ($p) { return $p.Source }
    throw "Nie znaleziono psql.exe - sprawdź instalację PostgreSQL."
}

function Invoke-Psql($sql) {
    $psql = Get-PsqlPath
    & $psql -U postgres -h 127.0.0.1 -p 5432 -d postgres -tAc $sql
}

function Configure-Database {
    Write-Info "Konfiguracja bazy ${DbName} i użytkownika ${DbUser}..."
    $exists = Invoke-Psql "SELECT 1 FROM pg_roles WHERE rolname='$DbUser'"
    $dbPassFile = "$env:ProgramData\D01iTweakz\.db_password"
    if ($exists -ne '1') {
        $dbPass = New-SecureRandomHex 48      # haslo DB: 48 bajtow
        Invoke-Psql "CREATE ROLE $DbUser LOGIN PASSWORD '$dbPass' NOSUPERUSER NOCREATEDB NOCREATEROLE" | Out-Null
        $dbPass | Out-File -FilePath $dbPassFile -Encoding ascii -NoNewline
        Write-Info "Utworzono użytkownika bazy $DbUser."
    } else {
        Write-Info "Użytkownik bazy już istnieje."
        $dbPass = Get-Content $dbPassFile -ErrorAction SilentlyContinue
        if (-not $dbPass) {
            $dbPass = New-SecureRandomHex 48   # haslo DB: 48 bajtow
            Invoke-Psql "ALTER ROLE $DbUser PASSWORD '$dbPass'" | Out-Null
            $dbPass | Out-File $dbPassFile -Encoding ascii -NoNewline
        }
    }
    $dbExists = Invoke-Psql "SELECT 1 FROM pg_database WHERE datname='$DbName'"
    if ($dbExists -ne '1') {
        Invoke-Psql "CREATE DATABASE $DbName OWNER $DbUser" | Out-Null
        Write-Info "Utworzono bazę $DbName."
    } else {
        Write-Warn2 "Baza $DbName już istnieje - NIE jest kasowana ani modyfikowana."
    }
    return $dbPass
}

function New-SecretsAndKeys($dbPass) {
    New-Item -ItemType Directory -Force -Path (Split-Path $EnvFile), $KeysDir | Out-Null  # A2: idempotentnie, nawet jesli main juz utworzyl
    if (-not (Test-Path "$KeysDir\ed25519_private.pem")) {
        Write-Info "Generowanie kluczy Ed25519 przez Node.js crypto (bez openssl)..."
        # A4: czysty Windows 11 nie gwarantuje openssl w PATH - uzywamy wbudowanego crypto Node.
        $keyScript = "const{ generateKeyPairSync }=require('crypto');const fs=require('fs');const{ privateKey, publicKey }=generateKeyPairSync('ed25519');fs.writeFileSync(process.argv[1], privateKey.export({ type: 'pkcs8', format: 'pem' }));fs.writeFileSync(process.argv[2], publicKey.export({ type: 'spki', format: 'pem' }));"
        & node -e $keyScript "$KeysDir\ed25519_private.pem" "$KeysDir\ed25519_public.pem"
        if (-not (Test-Path "$KeysDir\ed25519_private.pem")) { throw "Generowanie kluczy Ed25519 nieudane." }
    }
    if (-not (Test-Path $EnvFile)) {
        # R4: brak .env + zaszyfrowane rekordy w bazie = brak oryginalnego klucza -> STOP.
        $psql = Get-PsqlPath
        $encRows = & $psql -U postgres -h 127.0.0.1 -d $DbName -tAc "SELECT (SELECT count(*) FROM admins WHERE totp_secret LIKE 'enc:v1:%') + (SELECT count(*) FROM settings WHERE key='discord_webhook' AND value::text LIKE '%enc:v1:%')" 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Err2 "Nie mozna polaczyc z baza $DbName - nie generuje nowego SECRET_ENC_KEY (blad DB != 0 rekordow)."; exit 1 }
        if ([int]($encRows | Select-Object -First 1) -gt 0) {
            Write-Err2 "Baza zawiera zaszyfrowane sekrety (enc:v1:), ale brak pliku .env z SECRET_ENC_KEY."
            Write-Err2 "Przywroc oryginalny klucz (64 znaki HEX) do $EnvFile - nowy klucz uniemozliwi odczyt danych."
            exit 1
        }
        $pepper = New-SecureRandomHex 64      # SECURITY_PEPPER: 64 bajty
        $encKey = New-SecureRandomHex 32      # SECRET_ENC_KEY: 32 bajty = 64 znaki HEX (AES-256-GCM)
        $bootstrapPass = New-SecureRandomHex 32  # haslo bootstrap admina
        @"
NODE_ENV=development
PORT=$Port
HOST=127.0.0.1
PUBLIC_BASE_URL=$PublicBaseUrl
DATABASE_URL=postgres://${DbUser}:$dbPass@127.0.0.1:5432/$DbName
SECURITY_PEPPER=$pepper
SECRET_ENC_KEY=$encKey
ED25519_PRIVATE_KEY_PATH=$KeysDir\ed25519_private.pem
ED25519_PUBLIC_KEY_PATH=$KeysDir\ed25519_public.pem
ADMIN_BOOTSTRAP_ENABLED=true
ADMIN_BOOTSTRAP_USERNAME=admin
ADMIN_BOOTSTRAP_PASSWORD=$bootstrapPass
TOKEN_TTL_SECONDS=120
ADMIN_SESSION_TTL_HOURS=8
MAX_DEVICES_DEFAULT=2
DISCORD_WEBHOOK_ENABLED=false
"@ | Out-File -FilePath $EnvFile -Encoding ascii
        Write-Info "Wygenerowano $EnvFile (bootstrap admin: admin / hasło w pliku .env)."
    } else {
        Write-Info "Plik .env już istnieje - bez zmian."
        # Rerun: jesli .env nie ma poprawnego SECRET_ENC_KEY, a w bazie sa zaszyfrowane
        # sekrety - NIE generuj nowego klucza (stracilibysmy dostep do danych).
        $hasKey = Select-String -Path $EnvFile -Pattern '^SECRET_ENC_KEY=[0-9a-f]{64}$' -Quiet
        if (-not $hasKey) {
            $psql = Get-PsqlPath
            $encRows = & $psql -U $DbUser -h 127.0.0.1 -d $DbName -tAc "SELECT (SELECT count(*) FROM admins WHERE totp_secret LIKE 'enc:v1:%') + (SELECT count(*) FROM settings WHERE key='discord_webhook' AND value::text LIKE '%enc:v1:%')" 2>$null
            if ([int]($encRows | Select-Object -First 1) -gt 0) {
                Write-Err2 "W bazie sa zaszyfrowane sekrety, ale .env nie ma poprawnego SECRET_ENC_KEY."
                Write-Err2 "Przywroc oryginalny klucz (64 znaki HEX) do $EnvFile - nowy klucz uniemozliwi odczyt danych."
                exit 1
            }
            $encKey = New-SecureRandomHex 32      # SECRET_ENC_KEY: 32 bajty = 64 znaki HEX
            Add-Content -Path $EnvFile -Value "SECRET_ENC_KEY=$encKey"
            Write-Info "Dodano SECRET_ENC_KEY do istniejacego .env (w bazie nie bylo zaszyfrowanych sekretow)."
        }
    }
}

function Install-DependenciesAndMigrate {
    Write-Info "Instalacja zależności npm i migracje..."
    Push-Location $InstallDir
    npm ci --omit=dev --no-audit --no-fund
    $envContent = Get-Content $EnvFile -Raw
    foreach ($line in (Get-Content $EnvFile)) {
        if ($line -match '^\s*([A-Z_]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
    }
    node src/db/migrate.js
    Pop-Location
}

function Test-Health {
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/v1/admin/ops/health" -TimeoutSec 5
        if ($r.ok -and $r.db) { Write-Info "Healthcheck OK."; return $true }
    } catch { Write-Warn2 "Healthcheck nieudany: $($_.Exception.Message)" }
    return $false
}

# ----------------------------- main -----------------------------
if (-not (Test-Admin)) { Write-Err2 "Uruchom PowerShell jako Administrator."; exit 1 }

# A2: katalog danych aplikacji musi istnieć przed pierwszym zapisem sekretu (.db_password).
New-Item -ItemType Directory -Force -Path "$env:ProgramData\D01iTweakz", $KeysDir | Out-Null
Write-Info "Katalog danych: $env:ProgramData\D01iTweakz"

$v = Get-WindowsVersionInfo
Write-Info "Windows: $($v.Caption) (build $($v.Build))"
if (-not (Test-Windows11)) { Write-Warn2 "Wykryto inny system niż Windows 11 - kontynuuję mimo to." }

Install-NodeIfMissing
Install-PostgresIfMissing

Write-Info "Przygotowanie katalogów..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$src = Join-Path $PSScriptRoot '..\..\backend'
if (Test-Path (Join-Path $src 'src')) {
    Copy-Item (Join-Path $src 'src'), (Join-Path $src 'migrations'), (Join-Path $src 'package.json'), (Join-Path $src 'package-lock.json') -Destination $InstallDir -Recurse -Force
} else {
    Write-Warn2 "Nie znaleziono backend/ obok deploy/windows - skopiuj ręcznie zawartość backend/ do $InstallDir"
}

$dbPass = Configure-Database
New-SecretsAndKeys $dbPass
Set-Location $InstallDir
Install-DependenciesAndMigrate

if (-not $NoService) {
    Write-Info "Start backendu..."
    # A3: Start-Backend.ps1 to osobny plik - wywolanie przez operator &, z parametrami.
    & (Join-Path $PSScriptRoot 'Start-Backend.ps1') -InstallDir $InstallDir -EnvFile $EnvFile -Port $Port
}

if (Test-Health) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " INSTALACJA ZAKOŃCZONA POMYŚLNIE" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " Panel admina:  http://localhost:$Port/admin"
    Write-Host " API health:    http://localhost:$Port/api/v1/admin/ops/health"
    Write-Host " Dane logowania admina (bootstrap): patrz $EnvFile"
    Write-Host " Użyj Start-Backend.ps1 / Stop-Backend.ps1 do zarządzania."
} else {
    Write-Warn2 "Serwer nie odpowiedział na healthcheck - uruchom: Start-Backend.ps1 i sprawdź logi."
}
