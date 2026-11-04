# D01i Tweakz - start backendu (Windows). Bezpieczna identyfikacja wlasnego procesu:
# zapisujemy PID + czas startu + pelna sciezke skryptu, zeby Stop-Backend mogl
# zweryfikowac tozsamosc procesu (takze po ponownym przydzieleniu PID).
# Uwaga: NIE uzywamy tu zmiennej $pid - koliduje z automatyczna zmienna $PID.
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
$PidFile = Join-Path $DataDir 'backend.pid.json'
$log = Join-Path $DataDir 'backend.log'
$logErr = Join-Path $DataDir 'backend.err.log'
$EntryScript = Join-Path $InstallDir 'src\index.js'   # PELNA sciezka, nie wzgledna
if (-not (Test-Path $EntryScript)) { Write-Error "Brak $EntryScript - zainstaluj backend najpierw."; exit 1 }
$NodeExe = (Get-Command node).Source                  # PELNA sciezka do node.exe

function Test-OurBackendRunning {
    if (-not (Test-Path $PidFile)) { return $null }
    try {
        $meta = Get-Content $PidFile -Raw | ConvertFrom-Json
        $p = Get-Process -Id $meta.Pid -ErrorAction SilentlyContinue
        if (-not $p) { return $null }
        # Weryfikacja: PID + czas startu (ochrona przed ponownym uzyciem PID) + sciezka exe/args
        if ($p.StartTime -ne [datetime]$meta.StartTime) { return $null }
        if ($p.Path -ne $NodeExe) { return $null }
        return $p
    } catch { return $null }
}

$running = Test-OurBackendRunning
if ($running) { Write-Host "Backend juz dziala (PID $($running.Id), start $($running.StartTime))."; exit 0 }
if (Test-Path $PidFile) { Remove-Item $PidFile -ErrorAction SilentlyContinue }  # stary/nieaktualny plik PID

Write-Host "Start backendu: $NodeExe $EntryScript (log: $log)..."
$proc = Start-Process -FilePath $NodeExe -ArgumentList "`"$EntryScript`"" -WorkingDirectory $InstallDir `
    -RedirectStandardOutput $log -RedirectStandardError $logErr -PassThru
$meta = [ordered]@{
    Pid       = $proc.Id
    StartTime = $proc.StartTime.ToString('o')
    NodeExe   = $NodeExe
    Script    = $EntryScript
    StartedAt = (Get-Date -Format 'o')
}
$meta | ConvertTo-Json | Out-File $PidFile -Encoding utf8
Write-Host "Zapisano $PidFile (PID $($proc.Id))"
Start-Sleep -Seconds 3
try {
    $r = Invoke-RestMethod "http://127.0.0.1:$Port/api/v1/admin/ops/health" -TimeoutSec 5
    Write-Host "OK: backend dziala (db=$($r.db))" -ForegroundColor Green
} catch {
    Write-Host "Backend nie odpowiada jeszcze - sprawdz $logErr" -ForegroundColor Yellow
}
