# D01i Tweakz - start backendu (Windows, bez usługi systemowej).
#requires -Version 5.1
param(
    [string]$InstallDir = "$env:ProgramFiles\D01iTweakz",
    [string]$EnvFile = "$env:ProgramData\D01iTweakz\.env",
    [int]$Port = 8080
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $EnvFile)) { Write-Error "Brak $EnvFile - uruchom najpierw Install-Windows.ps1"; exit 1 }
foreach ($line in (Get-Content $EnvFile)) {
    if ($line -match '^\s*([A-Z_]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
}
$log = "$env:ProgramData\D01iTweakz\backend.log"
Write-Host "Start backendu (log: $log)..."
Start-Process -FilePath node -ArgumentList "src/index.js" -WorkingDirectory $InstallDir `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err" -NoNewWindow
Start-Sleep -Seconds 3
try {
    $r = Invoke-RestMethod "http://127.0.0.1:$Port/api/v1/admin/ops/health" -TimeoutSec 5
    Write-Host "OK: backend działa (db=$($r.db))" -ForegroundColor Green
} catch {
    Write-Host "Backend nie odpowiada jeszcze - sprawdź $log" -ForegroundColor Yellow
}
