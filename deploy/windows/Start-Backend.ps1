# D01i Tweakz - start backendu (Windows). Zapisuje PID do pliku, zeby Stop-Backend
# mogl zweryfikowac, ze zatrzymuje WLASNY proces (A5 - nigdy obcego na porcie 8080).
#requires -Version 5.1
param(
    [string]$InstallDir = "$env:ProgramFiles\D01iTweakz",
    [string]$EnvFile = "$env:ProgramData\D01iTweakz\.env",
    [int]$Port = 8080
)
$ErrorActionPreference = 'Stop'
$DataDir = Split-Path $EnvFile
if (-not (Test-Path $EnvFile)) { Write-Error "Brak $EnvFile - uruchom najpierw Install-Windows.ps1"; exit 1 }
foreach ($line in (Get-Content $EnvFile)) {
    if ($line -match '^\s*([A-Z_]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
}
$PidFile = Join-Path $DataDir 'backend.pid'
$log = Join-Path $DataDir 'backend.log'
$logErr = Join-Path $DataDir 'backend.err.log'

# Jesli nasz backend juz dziala (PID zweryfikowany), nie startuj drugiego.
if (Test-Path $PidFile) {
    $oldPid = Get-Content $PidFile -ErrorAction SilentlyContinue
    $p = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if ($p -and $p.Path -like "*D01iTweakz*") { Write-Host "Backend już działa (PID $oldPid)."; exit 0 }
    Remove-Item $PidFile -ErrorAction SilentlyContinue
}

Write-Host "Start backendu (log: $log)..."
$proc = Start-Process -FilePath node -ArgumentList "src/index.js" -WorkingDirectory $InstallDir `
    -RedirectStandardOutput $log -RedirectStandardError $logErr -PassThru
"$($proc.Id)" | Out-File $PidFile -Encoding ascii -NoNewline
Write-Host "PID zapisany: $PidFile (PID $($proc.Id))"
Start-Sleep -Seconds 3
try {
    $r = Invoke-RestMethod "http://127.0.0.1:$Port/api/v1/admin/ops/health" -TimeoutSec 5
    Write-Host "OK: backend działa (db=$($r.db))" -ForegroundColor Green
} catch {
    Write-Host "Backend nie odpowiada jeszcze - sprawdź $log" -ForegroundColor Yellow
}
