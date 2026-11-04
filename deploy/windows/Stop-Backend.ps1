# D01i Tweakz - bezpieczne zatrzymanie backendu (Windows), FAIL-CLOSED (Runda 4).
# Zatrzymujemy WYLACZNIE proces zweryfikowany przez backend.pid.json:
#   PID + StartTime + dokladna sciezka node.exe + oczekiwany skrypt src\index.js
#   + ODCZYTANA linia polecen (CommandLine) z Win32_Process.
# Kazdy blad/brak/null/pusty CommandLine = NIEUDANA weryfikacja = NIE zatrzymujemy procesu.
# Nie kasujemy pliku PID przy nieudanej weryfikacji (zostaje do recznej diagnostyki).
# Uwaga: zmienna to $backendPid - $pid kolidowaloby z automatyczna zmienna $PID.
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
    Write-Host "Plik PID uszkodzony - nie zatrzymuje zadnego procesu (zostawiam plik do diagnostyki)." -ForegroundColor Yellow
    exit 1
}
$backendPid = [int]$meta.Pid
$p = Get-Process -Id $backendPid -ErrorAction SilentlyContinue
if (-not $p) {
    Write-Host "Proces PID $backendPid juz nie istnieje - czyszcze nieaktualny plik PID."
    Remove-Item $PidFile -ErrorAction SilentlyContinue
    exit 0
}

# --- fail-closed: wszystkie kontrole musza przejsc ---
$reasons = @()
if ($p.StartTime -ne [datetime]$meta.StartTime) { $reasons += "StartTime mismatch (PID mogl byc ponownie przydzielony)" }
if ($p.Path -ne $meta.NodeExe) { $reasons += "sciezka exe inna niz zapisana ($($p.Path))" }
$expectedScript = Join-Path $InstallDir 'src\index.js'
if ($meta.Script -ne $expectedScript) { $reasons += "zapisana sciezka skryptu niezgodna z instalacja" }

# CommandLine jest OBOWIĄZKOWY: wyjatek / brak obiektu / null / pusty = nieudana weryfikacja.
$cmdLine = $null
$cimOk = $true
try {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $backendPid" -ErrorAction Stop
    if (-not $cim) { $cimOk = $false; $reasons += "brak obiektu CIM dla PID $backendPid" }
    else { $cmdLine = $cim.CommandLine }
} catch {
    $cimOk = $false
    $reasons += "wyjatek przy odczycie CommandLine: $($_.Exception.Message)"
}
if ($cimOk -and ([string]::IsNullOrWhiteSpace($cmdLine))) { $reasons += "pusty/null CommandLine" }
if ($cmdLine) {
    # normalizacja cudzyslowow i wielkosci liter przy porownaniu sciezki skryptu
    $norm = $cmdLine -replace '"', ''
    if ($norm -notmatch [regex]::Escape($expectedScript)) { $reasons += "CommandLine nie zawiera oczekiwanego skryptu ($expectedScript)" }
}

if ($reasons.Count -gt 0) {
    Write-Host "Weryfikacja tozsamosci NIEUDANA - NIE zatrzymuje procesu PID ${backendPid}:" -ForegroundColor Yellow
    $reasons | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "Plik PID zostaje ($PidFile) do recznej diagnostyki."
    exit 1
}
Stop-Process -Id $backendPid -Force
Remove-Item $PidFile -ErrorAction SilentlyContinue
Write-Host "Backend (PID $backendPid) zatrzymany."
