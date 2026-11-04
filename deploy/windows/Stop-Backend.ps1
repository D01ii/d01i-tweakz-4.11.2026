# D01i Tweakz - bezpieczne zatrzymanie backendu (Windows).
# Zatrzymujemy WYLACZNIE proces zweryfikowany przez backend.pid.json:
#   PID + czas startu procesu (ochrona przed ponownym przydzieleniem PID)
#   + sciezka node.exe + pelna sciezka src\index.js z katalogu instalacji.
# NIGDY nie zabijamy procesu na podstawie samego portu 8080 ani samego PID.
# Uwaga: zmienna nazywa sie $backendPid, bo $pid kolidowalaby z automatycznym $PID.
#requires -Version 5.1
param(
    [string]$EnvFile = "$env:ProgramData\D01iTweakz\.env",
    [string]$InstallDir = "$env:ProgramFiles\D01iTweakz"
)
$DataDir = Split-Path $EnvFile
$PidFile = Join-Path $DataDir 'backend.pid.json'

if (-not (Test-Path $PidFile)) {
    Write-Host "Brak pliku PID ($PidFile) - backend nie byl uruchomiony przez Start-Backend.ps1. Nic nie zatrzymuje."
    exit 0
}
try { $meta = Get-Content $PidFile -Raw | ConvertFrom-Json } catch {
    Write-Host "Plik PID uszkodzony - usuwam go i nie zatrzymuje zadnego procesu." -ForegroundColor Yellow
    Remove-Item $PidFile -ErrorAction SilentlyContinue
    exit 1
}
$backendPid = [int]$meta.Pid
$p = Get-Process -Id $backendPid -ErrorAction SilentlyContinue
if (-not $p) {
    Write-Host "Proces PID $backendPid juz nie istnieje - czyszcze nieaktualny plik PID."
    Remove-Item $PidFile -ErrorAction SilentlyContinue
    exit 0
}

# Weryfikacja tozsamosci przed zabiciem:
$verified = $true
if ($p.StartTime -ne [datetime]$meta.StartTime) { $verified = $false }          # PID przejety przez inny proces
if ($p.Path -ne $meta.NodeExe) { $verified = $false }
$expectedScript = Join-Path $InstallDir 'src\index.js'
if ($meta.Script -ne $expectedScript) { $verified = $false }
try {
    $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $backendPid").CommandLine
    if ($cmdLine -and $cmdLine -notmatch [regex]::Escape($expectedScript)) { $verified = $false }
} catch {
    # Nie mozemy odczytac linii polecen - nie ryzykujemy: weryfikujemy tylko na podstawie metadanych.
    Write-Host "Nie udalo sie odczytac linii polecen procesu - weryfikacja tylko po PID+StartTime+sciezce." -ForegroundColor Yellow
}

if (-not $verified) {
    Write-Host "UWAGA: proces PID $backendPid ($($p.Path)) NIE przechodzi weryfikacji tozsamosci - NIE zatrzymuje go." -ForegroundColor Yellow
    Write-Host "Jesli to falszywy alarm, usun recznie: $PidFile"
    exit 1
}
Stop-Process -Id $backendPid -Force
Remove-Item $PidFile -ErrorAction SilentlyContinue
Write-Host "Backend (PID $backendPid) zatrzymany."
