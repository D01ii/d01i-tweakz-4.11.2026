# D01i Tweakz - zatrzymanie backendu (Windows).
#requires -Version 5.1
Get-Process -Name node -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -match 'D01iTweakz' -or $_.CommandLine -match 'd01i' } catch { $false }
} | Stop-Process -Force
# Awaryjnie: proces nasłuchujący na porcie 8080
$conn = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
if ($conn) { Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue }
Write-Host "Backend zatrzymany."
