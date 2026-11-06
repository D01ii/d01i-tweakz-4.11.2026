<#
================================================================================
  d01i tweakz  |  DEMO
================================================================================
  Wersja DEMO: tylko bezpieczne, uniwersalne optymalizacje (profil SAFE).
  Funkcje PREMIUM wymagaja aktywnej licencji (serwerowej walidacji online).
#>
param([switch]$DryRun)

$script:ProductName = 'd01i tweakz DEMO'
$script:Root        = $PSScriptRoot
if (-not $script:Root) { $script:Root = (Get-Location).Path }
$script:LogFile     = Join-Path $script:Root 'd01i_demo_log.txt'
$script:BackupDir   = Join-Path $script:Root 'd01i_backups'
$script:StateFile   = Join-Path $script:Root 'd01i_demo_state.json'
$script:BackupDone  = $false
$script:RebootNeeded = $false
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}
try { $Host.UI.RawUI.WindowTitle = $script:ProductName } catch {}

$script:Logo = @'
 _____   ___  _  _______
|  __ \ / _ \| |(_____  |
| |  | | | | | | |   / /
| |  | | | | | | |  / / 
| |__| | |_| | | | / /__
|_____/ \___/|_|_|/_____|
'@

Import-Module (Join-Path $PSScriptRoot '..\common\D01iLicense.psm1') -Force -ErrorAction Stop

# ====================== STAN / BACKUP ======================
$script:State = [ordered]@{
    Version='1.0'; LastBackupDir=''; RegUndo=@(); PreviousPowerScheme=''
}
function Read-State {
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $j = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $script:State.Keys) { if ($null -ne $j.$p) { $script:State[$p] = $j.$p } }
        } catch {}
    }
    $script:State.RegUndo = @($script:State.RegUndo)
}
function Write-State {
    try { ($script:State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $script:StateFile -Encoding UTF8 -Force } catch {}
}
Read-State

function Write-Log   { param([string]$m,[string]$l='INFO') try { Add-Content -Path $script:LogFile -Value ('{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$l,$m) -Encoding UTF8 } catch {} }
function Write-Ok    { param([string]$m) Write-Host ('   [OK]    ' + $m) -ForegroundColor Green;  Write-Log $m 'OK' }
function Write-Warn  { param([string]$m) Write-Host ('   [UWAGA] ' + $m) -ForegroundColor Yellow; Write-Log $m 'WARN' }
function Write-Err   { param([string]$m) Write-Host ('   [BLAD]  ' + $m) -ForegroundColor Red;    Write-Log $m 'ERROR' }
function Write-Info  { param([string]$m) Write-Host ('   [i]     ' + $m) -ForegroundColor Cyan;   Write-Log $m 'INFO' }
function Write-Step  { param([string]$m) Write-Host ("`n==> " + $m) -ForegroundColor Magenta; Write-Log $m 'STEP' }
function Wait-Enter  { param([string]$t='Nacisnij Enter, aby kontynuowac...') Write-Host ''; Read-Host $t | Out-Null }
function Read-YesNo  { param([string]$p) $r = Read-Host "$p (T/N)"; return ($r -eq 'T' -or $r -eq 't' -or $r -eq 'Y' -or $r -eq 'y') }

function Assert-Backup {
    if ($script:BackupDone) { return }
    Write-Step 'BACKUP: punkt przywracania + eksport rejestru'
    try {
        Enable-ComputerRestore "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer 'd01i tweakz DEMO - przed optymalizacja' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Ok 'Punkt przywracania utworzony.'
    } catch { Write-Warn "Punkt przywracania niedostepny: $($_.Exception.Message)" }
    $stamp = Get-Date -Format yyyyMMdd_HHmmss
    $dir = Join-Path $script:BackupDir "reg_$stamp"
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
    $keys = @(
        'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl',
        'HKCU\Control Panel\Desktop',
        'HKCU\Control Panel\Mouse',
        'HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    )
    $ok = 0
    foreach ($k in $keys) {
        $f = Join-Path $dir (($k -replace '[\\\/:\s]','_') + '.reg')
        & reg.exe export $k $f /y 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok++ } else { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    $script:State.LastBackupDir = $dir; Write-State
    Write-Ok "Eksport rejestru: $ok galezi -> $dir"
    $script:BackupDone = $true
}

function Set-Reg {
    param([string]$Path,[string]$Name,$Value,[ValidateSet('DWord','String')][string]$Type='DWord')
    Assert-Backup
    $had=$false; $old=$null; $oldT='DWord'
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $e = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        $old=$e.$Name; $had=$true; $oldT=$key.GetValueKind($Name).ToString()
    } catch {}
    if (-not ($script:State.RegUndo | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name })) {
        $script:State.RegUndo += [pscustomobject]@{Path=$Path;Name=$Name;HadValue=$had;OldValue=$old;OldType=$oldT}
        Write-State
    }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    } catch { Write-Warn "Nie ustawiono $Path\$Name : $($_.Exception.Message)" }
}
function Restore-RegistryUndo {
    foreach ($entry in @($script:State.RegUndo)) {
        try {
            if ([bool]$entry.HadValue) {
                if (-not (Test-Path -LiteralPath $entry.Path)) { New-Item -Path $entry.Path -Force -ErrorAction Stop | Out-Null }
                New-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.OldValue -PropertyType $entry.OldType -Force -ErrorAction Stop | Out-Null
            } elseif (Test-Path -LiteralPath $entry.Path) {
                Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Force -ErrorAction SilentlyContinue
            }
        } catch { Write-Warn "Nie przywrocono REG $($entry.Path)\$($entry.Name)" }
    }
}

# ====================== DEMO TWEAKI (tylko bezpieczne) ======================
function Set-PowerPlanSafe {
    param([string]$PlanName='High Performance')
    if ($script:DryRun) { Write-Info "[DRY-RUN] powercfg /setactive '$PlanName'"; return }
    Assert-Backup
    $plans = @(& powercfg.exe /list 2>$null)
    $text = ($plans -join "`n")
    $rx = [regex]'(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*\(([^)]*' + [regex]::Escape($PlanName) + '[^)]*)\)'
    $m = [regex]::Match($text, $rx)
    $guid = if ($m.Success) { $m.Groups[1].Value } else { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
    if ($text -notmatch $guid) { Write-Warn "Plan '$PlanName' niedostepny - pomijam."; return }
    if (-not $script:State.PreviousPowerScheme) {
        $active = [regex]::Match($text, '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*\*')
        if ($active.Success) { $script:State.PreviousPowerScheme = $active.Groups[1].Value; Write-State }
    }
    & powercfg.exe /setactive $guid 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok "Plan zasilania: $PlanName" } else { Write-Warn 'powercfg /setactive nieudane.' }
}
function Set-SafeTweaks {
    Write-Step 'DEMO SAFE: bezpieczne tweaki (z backupem)'
    Assert-Backup
    Set-PowerPlanSafe 'High Performance'
    Set-Reg 'HKCU:\Control Panel\Desktop' MenuShowDelay '0' String
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' TaskbarDa 0 DWord
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ShowTaskViewButton 0 DWord
    New-Item 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1 DWord
    Write-Ok 'Profil DEMO SAFE zakonczony. Cofniecie: opcja 6.'
    $script:RebootNeeded = $true
}
function Invoke-SelfTestDemo {
    Write-Step 'SELF-TEST DEMO'
    $ok = 0; $bad = 0
    try { $null = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop; $ok++ } catch { $bad++; Write-Warn 'CIM niedostepny' }
    $active = @(& powercfg.exe /getactivescheme 2>$null) -join ' '
    if ($active -match 'High Performance|Wysoka') { $ok++; Write-Ok 'Plan zasilania: wysoka wydajnosc' } else { Write-Info "Aktywny plan: $active" }
    $msd = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name MenuShowDelay -ErrorAction SilentlyContinue).MenuShowDelay
    if ($msd -eq '0') { $ok++; Write-Ok 'MenuShowDelay=0' } else { Write-Info "MenuShowDelay=$msd" }
    Write-Host ''; Write-Host "  WYNIK: $ok OK, $bad bledow" -ForegroundColor Cyan
}
function Invoke-UndoDemo {
    Write-Step 'COFANIE ZMIAN DEMO'
    if (-not (Read-YesNo 'NA PEWNO cofnac zmiany DEMO?')) { return }
    $fail = 0
    if ($script:State.LastBackupDir -and (Test-Path -LiteralPath $script:State.LastBackupDir)) {
        Get-ChildItem -LiteralPath $script:State.LastBackupDir -Filter *.reg -ErrorAction SilentlyContinue | ForEach-Object {
            & reg.exe import $_.FullName 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $fail++ }
        }
    }
    Restore-RegistryUndo
    if ($script:State.PreviousPowerScheme) { & powercfg.exe /setactive $script:State.PreviousPowerScheme 2>&1 | Out-Null }
    if ($fail -eq 0) {
        $script:State = [ordered]@{ Version='1.0'; LastBackupDir=''; RegUndo=@(); PreviousPowerScheme='' }
        Write-State; $script:BackupDone = $false
        Write-Ok 'Cofanie zakonczone - stan wyczyszczony.'
    } else { Write-Warn 'Czesciowe cofanie - stan zachowany do ponownej proby.' }
    if (Read-YesNo 'Zrestartowac TERAZ?') { Restart-Computer -Force }
}

# ====================== UI ======================
function Show-Banner {
    Clear-Host
    Write-Host $script:Logo -ForegroundColor Cyan
    Write-Host '  d01i tweakz - WERSJA DEMO (tylko bezpieczne optymalizacje)' -ForegroundColor Yellow
    Write-Host '  Pelne profile (BALANCED/ADVANCED/FULL) wymagaja licencji PREMIUM.' -ForegroundColor DarkGray
    Write-Host ''
}
function Show-Hw {
    try {
        $script:Hwid = Get-D01iHwid
        Write-Host "  HWID: $script:Hwid" -ForegroundColor White
    } catch { Write-Warn "HWID niedostepny: $($_.Exception.Message)"; $script:Hwid = '' }
}

Write-Log '========== d01i tweakz DEMO START =========='
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err 'Brak uprawnien Administratora - uruchom ponownie jako Administrator.'
    Wait-Enter; exit 1
}

do {
    Show-Banner; Show-Hw
    Write-Host '  [1] Profil DEMO SAFE (bezpieczne optymalizacje)' -ForegroundColor Green
    Write-Host '  [2] SELF-TEST' -ForegroundColor Magenta
    Write-Host '  [3] Status licencji / aktywacja PREMIUM (online)' -ForegroundColor Cyan
    Write-Host '  [4] Kopiuj HWID do schowka' -ForegroundColor White
    Write-Host '  [6] Cofnij zmiany (UNDO)' -ForegroundColor Yellow
    Write-Host '  [0] Wyjscie' -ForegroundColor White
    Write-Host ''
    $c = (Read-Host '  Wybierz').Trim()
    switch ($c) {
        '1' { Set-SafeTweaks; Wait-Enter }
        '2' { Invoke-SelfTestDemo; Wait-Enter }
        '3' {
            $lic = Test-D01iLicense -AllowTypes @('PREMIUM_30D','PREMIUM_90D','PREMIUM_LIFETIME')
            if ($lic.valid) {
                Write-Ok "Licencja PREMIUM aktywna: $($lic.type) (do $($lic.expires_at)). Uruchom pelna wersje premium.ps1."
            } else {
                Write-Info "Brak aktywnej licencji PREMIUM ($($lic.reason))."
                $k = Read-Host '  Podaj klucz licencyjny (lub Enter = anuluj)'
                if ($k) {
                    $r = Invoke-D01iActivate -Key $k
                    if ($r.ok) { Write-Ok "Aktywowano: $($r.license.type). Uruchom pelna wersje premium.ps1." }
                    else { Write-Err "Aktywacja nieudana: $($r.reason)" }
                }
            }
            Wait-Enter
        }
        '4' { if ($script:Hwid) { Set-Clipboard -Value $script:Hwid; Write-Ok 'HWID skopiowany.' } else { Write-Warn 'Brak HWID.' }; Wait-Enter }
        '6' { Invoke-UndoDemo; Wait-Enter }
        '0' { }
        default { Write-Warn 'Zla opcja.'; Start-Sleep -Milliseconds 500 }
    }
} while ($c -ne '0')

if ($script:RebootNeeded) {
    Write-Warn 'Czesc zmian wymaga RESTARTU!'
    if (Read-YesNo 'Uruchomic ponownie TERAZ?') { Restart-Computer -Force }
}
Write-Log '========== d01i tweakz DEMO STOP =========='
Write-Host "  Do zobaczenia! - $script:ProductName" -ForegroundColor Cyan
