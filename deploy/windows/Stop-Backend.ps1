# D01i Tweakz - bezpieczne zatrzymanie backendu (Windows).
# A5: NIGDY nie zabijamy obcego procesu tylko dlatego, ze nasluchuje na porcie 8080.
# Zatrzymujemy wylacznie proces, ktorego PID mamy w pliku backend.pid I ktorego
# sciezka/komenda jednoznacznie wskazuje na katalog instalacji D01iTweakz.
#requires -Version 5.1
param(
    [string]$EnvFile = "$env:ProgramData\D01iTweakz\.env",
    [string]$InstallDir = "$env:ProgramFiles\D01iTweakz"
)
$DataDir = Split-Path $EnvFile
$PidFile = Join-Path $DataDir 'backend.pid'

if (-not (Test-Path $PidFile)) {
    Write-Host "Brak pliku PID ($PidFile) - backend nie byl uruchomiony przez Start-Backend.ps1. Nic nie zatrzymuję."
    exit 0
}
$pid = (Get-Content $PidFile).Trim()
$p = Get-Process -Id $pid -ErrorAction SilentlyContinue
if (-not $p) {
    Write-Host "Proces PID $pid już nie istnieje. Usuwam plik PID."
    Remove-Item $PidFile -ErrorAction SilentlyContinue
    exit 0
}
# Weryfikacja: proces musi nalezec do D01iTweakz (sciezka exe lub katalog roboczy/linia polecen).
$cmdLine = $null
try { $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $pid").CommandLine } catch {}
$verified = ($p.Path -like "*D01iTweakz*") -or ($cmdLine -like "*D01iTweakz*") -or ($cmdLine -match [regex]::Escape($InstallDir))
if (-not $verified) {
    Write-Host "UWAGA: proces PID $pid ($($p.Path)) NIE wyglada na backend D01iTweakz - NIE zatrzymuje go." -ForegroundColor Yellow
    Write-Host "Usun plik $PidFile recznie, jesli to falszywy alarm."
    exit 1
}
Stop-Process -Id $pid -Force
Remove-Item $PidFile -ErrorAction SilentlyContinue
Write-Host "Backend (PID $pid) zatrzymany."
