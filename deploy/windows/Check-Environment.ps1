# D01i Tweakz - diagnostyka środowiska Windows 11 (tylko odczyt).
#requires -Version 5.1
$ErrorActionPreference = 'Continue'
Write-Host "== D01i Tweakz - Check-Environment ==" -ForegroundColor Cyan
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "OS: $($os.Caption) build $($os.BuildNumber)"
$ps = $PSVersionTable.PSVersion
Write-Host "PowerShell: $ps"
$node = Get-Command node -ErrorAction SilentlyContinue
Write-Host "Node.js: $(if ($node) { node -v } else { 'BRAK' }) (wymagane >= 20)"
Write-Host "npm: $(if (Get-Command npm -ErrorAction SilentlyContinue) { npm -v } else { 'BRAK' })"
$pg = Get-Service 'postgresql*' -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host "PostgreSQL service: $(if ($pg) { "$($pg.Name) [$($pg.Status)]" } else { 'BRAK' })"
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Czy Administrator: $admin"
$fw = Get-NetFirewallProfile | Select-Object Name, Enabled
$fw | ForEach-Object { Write-Host "Firewall: $($_.Name) enabled=$($_.Enabled)" }
try {
    $r = Invoke-RestMethod http://127.0.0.1:8080/api/v1/admin/ops/health -TimeoutSec 3
    Write-Host "Backend health: OK (db=$($r.db))"
} catch { Write-Host "Backend health: NIEDOSTĘPNY na 127.0.0.1:8080" }
