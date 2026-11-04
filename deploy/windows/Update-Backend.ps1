# D01i Tweakz - aktualizacja backendu na Windows (backup kodu, podmiana, migracje, restart).
# Baza danych i .env NIE są modyfikowane.
#requires -Version 5.1
param(
    [string]$InstallDir = "$env:ProgramFiles\D01iTweakz",
    [string]$SourceDir = (Join-Path $PSScriptRoot '..\..\backend')
)
$ErrorActionPreference = 'Stop'
Write-Host "[update] Zatrzymywanie backendu..."
& (Join-Path $PSScriptRoot 'Stop-Backend.ps1')
$backup = "$env:TEMP\d01i-backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item "$InstallDir\src" -Destination $backup -Recurse -Force
Write-Host "[update] Backup kodu: $backup"
Copy-Item (Join-Path $SourceDir 'src'), (Join-Path $SourceDir 'migrations'), (Join-Path $SourceDir 'package.json'), (Join-Path $SourceDir 'package-lock.json') -Destination $InstallDir -Recurse -Force
Push-Location $InstallDir
npm ci --omit=dev --no-audit --no-fund
$envFile = "$env:ProgramData\D01iTweakz\.env"
foreach ($line in (Get-Content $envFile)) { if ($line -match '^\s*([A-Z_]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') } }
node src/db/migrate.js
Pop-Location
& (Join-Path $PSScriptRoot 'Start-Backend.ps1')
Write-Host "[update] Aktualizacja zakończona."
