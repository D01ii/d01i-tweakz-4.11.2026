# D01i Tweakz - aktualizacja backendu na Windows 11 z pelna sciezka bledu i rollbackiem (C2).
# NIGDY nie dotyka .env, kluczy Ed25519 ani .db_password (konfiguracja i sekrety zostaja).
#requires -Version 5.1
param(
    [string]$InstallDir = "$env:ProgramFiles\D01iTweakz",
    [string]$SourceDir = (Join-Path $PSScriptRoot '..\..\backend'),
    [string]$EnvFile = "$env:ProgramData\D01iTweakz\.env",
    [int]$Port = 8080
)
$ErrorActionPreference = 'Continue'
$DataDir = Split-Path $EnvFile
$Backup = Join-Path $env:TEMP ("d01i-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$failed = $false

try {
    Write-Host "[update] 1/6 Sprawdzanie aktualizacji..."
    if (-not (Test-Path (Join-Path $SourceDir 'src'))) { throw "Brak kodu zrodlowego w $SourceDir" }
    if (-not (Test-Path $EnvFile)) { throw "Brak $EnvFile - backend nie byl instalowany?" }

    Write-Host "[update] 2/6 Zatrzymywanie backendu (weryfikacja PID)..."
    & (Join-Path $PSScriptRoot 'Stop-Backend.ps1') -EnvFile $EnvFile -InstallDir $InstallDir

    Write-Host "[update] 3/6 Backup kodu i manifestu ($Backup)..."
    New-Item -ItemType Directory -Force -Path $Backup | Out-Null
    Copy-Item "$InstallDir\src", "$InstallDir\migrations" -Destination $Backup -Recurse -Force
    Copy-Item "$InstallDir\package.json", "$InstallDir\package-lock.json" -Destination $Backup -Force -ErrorAction SilentlyContinue

    Write-Host "[update] 4/6 Podmiana kodu + npm ci + migracje..."
    Remove-Item "$InstallDir\src" -Recurse -Force
    Copy-Item (Join-Path $SourceDir 'src'), (Join-Path $SourceDir 'migrations') -Destination $InstallDir -Recurse -Force
    Copy-Item (Join-Path $SourceDir 'package.json'), (Join-Path $SourceDir 'package-lock.json') -Destination $InstallDir -Force
    Push-Location $InstallDir
    foreach ($line in (Get-Content $EnvFile)) { if ($line -match '^\s*([A-Z_]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') } }
    npm ci --omit=dev --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw "npm ci nieudane (kod $LASTEXITCODE)" }
    node src/db/migrate.js
    if ($LASTEXITCODE -ne 0) { throw "Migracje nieudane (kod $LASTEXITCODE)" }
    Pop-Location

    Write-Host "[update] 5/6 Start backendu..."
    & (Join-Path $PSScriptRoot 'Start-Backend.ps1') -InstallDir $InstallDir -EnvFile $EnvFile -Port $Port

    Write-Host "[update] 6/6 Healthcheck..."
    Start-Sleep -Seconds 2
    $ok = $false
    try { $r = Invoke-RestMethod "http://127.0.0.1:$Port/api/v1/admin/ops/health" -TimeoutSec 5; $ok = ($r.ok -and $r.db) } catch {}
    if (-not $ok) { throw "Healthcheck nieudany po aktualizacji" }

    Write-Host "[update] OK - aktualizacja zakonczona pomyslnie. Backup: $Backup" -ForegroundColor Green
} catch {
    $failed = $true
    Write-Host "[update][BLAD] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[update] Rollback do poprzedniej wersji..." -ForegroundColor Yellow
    try {
        & (Join-Path $PSScriptRoot 'Stop-Backend.ps1') -EnvFile $EnvFile -InstallDir $InstallDir
        if (Test-Path "$Backup\src") {
            Remove-Item "$InstallDir\src" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$InstallDir\migrations" -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item "$Backup\src", "$Backup\migrations" -Destination $InstallDir -Recurse -Force
            Copy-Item "$Backup\package.json", "$Backup\package-lock.json" -Destination $InstallDir -Force -ErrorAction SilentlyContinue
        }
        Push-Location $InstallDir
        npm ci --omit=dev --no-audit --no-fund
        Pop-Location
        & (Join-Path $PSScriptRoot 'Start-Backend.ps1') -InstallDir $InstallDir -EnvFile $EnvFile -Port $Port
        Write-Host "[update] Rollback zakonczony - poprzednia wersja probuje wystartowac. Sprawdz logi." -ForegroundColor Yellow
        Write-Host "[update] UWAGA: schemat bazy nie jest cofany automatycznie; w razie potrzeby przywroc baze recznie." -ForegroundColor Yellow
    } catch {
        Write-Host "[update][KRYTYCZNY] Rollback tez sie nie powiodl: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[update] Backend moze byc zatrzymany. Uruchom recznie: Start-Backend.ps1 i sprawdz $env:ProgramData\D01iTweakz\backend.err.log" -ForegroundColor Red
    }
    exit 1
}
