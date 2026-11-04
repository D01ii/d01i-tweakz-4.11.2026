<#
================================================================================
  d01i tweakz  |  p v2.5 BITSUM
================================================================================
#>
param([switch]$Demo,[switch]$AutoRun)

# ====================== KONFIGURACJA (ZMIEN SEKRET PRZED SPRZEDAZA!) ======================
$script:ProductName  = 'd01i tweakz'
$script:Edition      = 'p v2.5 BITSUM'
$script:Author       = '(c) 2026 d01i'
$script:Secret       = 'D01I-GAMING-PRO-2026-XYZ-CHANGE-ME'
$script:Root         = $PSScriptRoot
if (-not $script:Root) { $script:Root = (Get-Location).Path }
$script:LogFile      = Join-Path $script:Root 'd01i_log.txt'
$script:BackupDir    = Join-Path $script:Root 'd01i_backups'
$script:StateFile    = Join-Path $script:Root 'd01i_state.json'
$script:LicenseFile  = Join-Path $script:Root 'd01i_license.key'
$script:AutoRunTaskName = 'd01i tweakz p AutoRun'
$script:BackupDone   = $false
$script:RebootNeeded = $false
$script:Licensed     = $false
$script:LicenseExpires = [datetime]::MinValue
$script:Hwid         = ''
$script:Hw           = $null
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}
try { $Host.UI.RawUI.WindowTitle = $script:ProductName } catch {}

# ====================== LOGO (design z darmowej) ======================
$script:Logo = @'
░███████     ░████     ░██   ░██      ░██                                            ░██
░██   ░██   ░██ ░██  ░████            ░██                                            ░██
░██    ░██ ░██ ░████   ░██   ░██   ░████████ ░██    ░██    ░██  ░███████   ░██████   ░██    ░██░█████████
░██    ░██ ░██░██░██   ░██   ░██      ░██    ░██    ░██    ░██ ░██    ░██       ░██  ░██   ░██      ░███
░██    ░██ ░████ ░██   ░██   ░██      ░██     ░██  ░████  ░██  ░█████████  ░███████  ░███████     ░███
░██   ░██   ░██ ░██    ░██   ░██      ░██      ░██░██ ░██░██   ░██        ░██   ░██  ░██   ░██  ░███
░███████     ░████   ░██████ ░██       ░████    ░███   ░███     ░███████   ░█████░██ ░██    ░██░█████████
'@

# ====================== LICENCJA ======================
function Get-Hwid {
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $mb  = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        $cpuId = if ($cpu.ProcessorId) { [string]$cpu.ProcessorId } else { 'NO-CPU' }
        $mbSn  = if ($mb.SerialNumber) { [string]$mb.SerialNumber } else { 'NO-MB' }
        $raw = "$cpuId|$mbSn|$($env:COMPUTERNAME)"
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
        return ((($h | ForEach-Object { $_.ToString('X2') }) -join '').Substring(0, 16).ToUpper())
    } catch { return 'HWID-ERR00000000' }
}

function Get-KeyForHwid {
    param([string]$Hwid,[string]$Expire='9999-12-31')
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($script:Secret))
    $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("D01IPRO|$Hwid|$Expire"))
    $alph = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $sb = New-Object System.Text.StringBuilder
    $bits = 0
    $val = 0
    foreach ($b in $hash[0..12]) {
        $val = ($val -shl 8) -bor [int]$b
        $bits += 8
        while ($bits -ge 5) {
            $bits -= 5
            $shift = $bits
            $idx = (($val -shr $shift) -band 31)
            [void]$sb.Append($alph[$idx])
            $val = $val -band ((1 -shl $shift) - 1)
        }
    }
    return $sb.ToString().Substring(0, 20)
}

function Get-DebugKeyInfo {
    # Zwraca tabelke z obliczonymi kluczami dla roznych soli - do diagnostyki
    $out = @()
    foreach ($exp in @('9999-12-31','2026')) {
        $k = Get-KeyForHwid $script:Hwid $exp
        $fmt = ($k -replace '(.{5})','$1-').TrimEnd('-')
        $out += "$exp  =>  $fmt"
    }
    return $out -join "`n"
}

function Test-License {
    param([string]$RawKey)
    if ([string]::IsNullOrWhiteSpace($RawKey)) { return $false }
    # Sanityzacja wejscia
    $s = $RawKey.Trim().ToUpper()
    $s = $s -replace '\s+',''
    $s = $s -replace '[!]','|'
    # Dziel po kresce pionowej
    $parts = $s.Split('|')
    $k = ($parts[0] -replace '[^A-Z0-9]','')
    if ($k.Length -ne 20) { return $false }
    $expFromInput = ''
    if ($parts.Count -ge 2 -and $parts[1] -match '^(\d{4}-\d{2}-\d{2})') { $expFromInput = $matches[1] }

    # Lista dat do sprawdzenia w kolejnosci:
    $candidates = New-Object System.Collections.ArrayList
    if ($expFromInput) { [void]$candidates.Add($expFromInput) }
    [void]$candidates.Add('9999-12-31')
    [void]$candidates.Add('2026')

    foreach ($cand in $candidates) {
        $expected = Get-KeyForHwid $script:Hwid $cand
        if ($k -ceq $expected) {
            try {
                if ($cand -eq '2026') {
                    $script:LicenseExpires = [datetime]::MaxValue
                } else {
                    $script:LicenseExpires = [datetime]::ParseExact($cand,'yyyy-MM-dd',$null)
                }
                return $true
            } catch { return $false }
        }
    }
    return $false
}

function Test-StoredLicense {
    [CmdletBinding()]
    param([switch]$Quiet)

    if (-not $script:Hwid) { $script:Hwid = Get-Hwid }
    if (-not (Test-Path -LiteralPath $script:LicenseFile)) { return $false }

    try {
        $raw = ([string](Get-Content -LiteralPath $script:LicenseFile -Raw -Encoding UTF8 -ErrorAction Stop)).Trim()
        if (-not (Test-License $raw)) {
            if (-not $Quiet) { Write-Warn 'Plik licencji jest uszkodzony lub nieprawidlowy.' }
            return $false
        }
        if ($script:LicenseExpires -ge (Get-Date).Date) { return $true }
        if (-not $Quiet) {
            Write-Warn "Licencja WYGASLA dnia $($script:LicenseExpires.ToString('yyyy-MM-dd'))!"
            Write-Host '   Kup nowy klucz lub uruchom w trybie DEMO.' -ForegroundColor Yellow
            Write-Host ''
        }
    } catch {
        if (-not $Quiet) { Write-Warn 'Nie mozna odczytac pliku licencji.' }
    }
    return $false
}

function Invoke-License {
    $script:Hwid = Get-Hwid
    if ($Demo) { return $false }
    if (Test-StoredLicense) { return $true }
    do {
        Show-Banner
        Show-Section 'AKTYWACJA LICENCJI'
        Write-Host '   Twoj HWID : ' -NoNewline -ForegroundColor White
        Write-Host $script:Hwid -ForegroundColor Yellow
        Write-Host ''
        Write-Host '   Wyslij ten HWID sprzedawcy, otrzymasz klucz.' -ForegroundColor Cyan
        Write-Host '   Wklej CALA linijke aktywacyjna (z data po | ), jesli masz licencje czasowa.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   [1] Wprowadz klucz aktywacyjny' -ForegroundColor White
        Write-Host '   [2] Tryb DEMO (tylko plan zasilania)' -ForegroundColor DarkGray
        Write-Host '   [3] Diagnostyka (pokaz klucz dla tego HWID)' -ForegroundColor DarkGray
        Write-Host '   [0] Wyjscie' -ForegroundColor White
        $c = Read-Host '   Wybierz'
        switch ($c) {
            '1' {
                Write-Host '   Skopiuj caly aktywator z wiadomosci (ten z |9999-12-31 na koncu) i wklej tutaj.' -ForegroundColor DarkGray
                Write-Host '   (W PowerShell wkleja sie PRAWYM przyciskiem myszy, nie Ctrl+V)' -ForegroundColor DarkGray
                Write-Host ''
                $k = Read-Host '   Aktywator'
                # Od razu pokaz co zostalo odczytane, zeby widziec literowke
                $kSan = ($k.Trim().ToUpper() -replace '\s+','' -replace '[!]','|')
                $kClean = ($kSan -split '\|')[0] -replace '[^A-Z0-9]',''
                Write-Host "   Odczytany klucz: $kClean" -ForegroundColor DarkGray
                if (Test-License $k) {
                    if ($script:LicenseExpires -lt (Get-Date).Date) {
                        Write-Err "Klucz wygasl $($script:LicenseExpires.ToString('yyyy-MM-dd'))!"
                        Start-Sleep 2
                    } else {
                        # Zapis w formacie KEY|EXPIRE - zapisujemy tylko 20-znakowy klucz,
                        # bez daty i separatorow z wklejonej linii aktywacyjnej.
                        if ($script:LicenseExpires -eq [datetime]::MaxValue) {
                            $expStr = '9999-12-31'
                        } else {
                            $expStr = $script:LicenseExpires.ToString('yyyy-MM-dd')
                        }
                        $line = "$kClean|$expStr"
                        $line | Set-Content $script:LicenseFile -Encoding UTF8 -Force
                        Write-Host ''
                        Write-Ok 'Licencja aktywowana!'
                        Start-Sleep 1
                        return $true
                    }
                } else {
                    Write-Err 'Nieprawidlowy klucz.'
                    Write-Host ''
                    Write-Host '   DEBUG (skopiuj to i wyslij sprzedawcy):' -ForegroundColor DarkYellow
                    Write-Host "   HWID: $script:Hwid" -ForegroundColor DarkYellow
                    $kP = Get-KeyForHwid $script:Hwid '9999-12-31'
                    $kPFmt = ($kP -replace '(.{5})','$1-').TrimEnd('-')
                    Write-Host "   Klucz permanentny obliczony przez skrypt: $kPFmt" -ForegroundColor DarkYellow
                    Write-Host "   Wpisany klucz                              : $kClean" -ForegroundColor DarkYellow
                    Write-Host ''
                    Start-Sleep 5
                }
            }
            '3' {
                Write-Host ''
                Write-Host '   === DIAGNOSTYKA LICENCJI ===' -ForegroundColor Cyan
                Write-Host "   HWID   : $script:Hwid" -ForegroundColor White
                foreach ($exp in @('9999-12-31','2026')) {
                    $k = Get-KeyForHwid $script:Hwid $exp
                    $f = ($k -replace '(.{5})','$1-').TrimEnd('-')
                    Write-Host "   $exp : $f" -ForegroundColor White
                }
                Write-Host ''
                Write-Host '   Aktywator permanent: ' -NoNewline -ForegroundColor DarkGray
                $kPerm = Get-KeyForHwid $script:Hwid '9999-12-31'
                Write-Host "$kPerm|9999-12-31" -ForegroundColor Green
                Write-Host ''
                Wait-Enter
            }
            '2' { return $false }
            '0' { exit 0 }
            default { Write-Warn 'Zly wybor.'; Start-Sleep -Milliseconds 500 }
        }
    } while ($true)
}

# ====================== STAN ======================
$script:State = [ordered]@{
    Version='2.5'; LastBackupDir=''; RegUndo=@(); ServiceUndo=@(); DisabledTasks=@()
    VbsDisabled=$false; CreatedUltimate=$false; UltimateSchemeGuid=''; PreviousPowerScheme=''
    HibernationWasEnabled=$null; MemoryCompressionWasEnabled=$null; Applied=@(); MsiTouched=@(); DefenderExclusions=@(); HostsBackupFile=''; CreatedRegistryKeys=@()
}
function Load-State {
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $j = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $script:State.Keys) {
                if ($null -ne $j.$p) { $script:State[$p] = $j.$p }
            }
        } catch {}
    }
    foreach ($p in @('RegUndo','ServiceUndo','DisabledTasks','Applied','MsiTouched','DefenderExclusions','CreatedRegistryKeys')) {
        $script:State[$p] = @($script:State[$p])
    }
}
function Save-State {
    try { ($script:State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $script:StateFile -Encoding UTF8 -Force } catch {}
}

# ====================== LOGOWANIE + DESIGN (z darmowej) ======================
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
}
function Write-Ok   { param([string]$m) Write-Host ('   [OK]    ' + $m) -ForegroundColor Green;    Write-Log $m 'OK'    }
function Write-Warn { param([string]$m) Write-Host ('   [UWAGA] ' + $m) -ForegroundColor Yellow;   Write-Log $m 'WARN'  }
function Write-Err  { param([string]$m) Write-Host ('   [BŁĄD]  ' + $m) -ForegroundColor Red;      Write-Log $m 'ERROR' }
function Write-Info { param([string]$m) Write-Host ('   [i]     ' + $m) -ForegroundColor Cyan;     Write-Log $m 'INFO'  }
function Write-Step { param([string]$m) Write-Host ("`n==> " + $m)      -ForegroundColor Magenta;  Write-Log $m 'STEP'  }
function Wait-Enter {
    param([string]$Text = 'Nacisnij Enter, aby kontynuowac...')
    Write-Host ''
    Read-Host "  $Text" | Out-Null
}
function Read-YesNo {
    param([string]$Prompt)
    $a = Read-Host "  $Prompt [T/N]"
    return ($a.Trim().ToUpper() -eq 'T' -or $a.Trim().ToUpper() -eq 'Y')
}
function Add-Applied {
    param([string]$Id)
    if ($script:State.Applied -notcontains $Id) { $script:State.Applied += $Id; Save-State }
    Write-Log $Id 'APPLY'
}
function Show-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray
    Write-Host ("  $Title") -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray
}

# ====================== BANNER (design z darmowej) ======================
function Set-ConsoleSize {
    try {
        $w = 100; $h = 45
        $ui = $Host.UI.RawUI
        # Buffer musi byc >= Window
        try {
            $buf = $ui.BufferSize
            $buf.Width = $w
            $buf.Height = 3000
            $ui.BufferSize = $buf
        } catch {}
        try {
            $win = $ui.WindowSize
            $win.Width = $w
            $win.Height = $h
            $ui.WindowSize = $win
        } catch {}
        # Tytul okna
        try { $Host.UI.RawUI.WindowTitle = "$script:ProductName $script:Edition" } catch {}
    } catch {}
}
function Show-Banner {
    try { Clear-Host } catch { }
    Write-Host $script:Logo -ForegroundColor Cyan
    Write-Host ''
    $dateStr = Get-Date -Format 'yyyy-MM-dd'
    Write-Host ("        $script:ProductName  $script:Edition   |   $dateStr   |   ") -NoNewline -ForegroundColor DarkGray
    if ($script:Licensed) {
        if ($script:LicenseExpires -eq [datetime]::MinValue -or $script:LicenseExpires.Year -ge 2099 -or $script:LicenseExpires -eq [datetime]::MaxValue) {
            Write-Host 'LICENCJA PERMANENTNA' -ForegroundColor Green -NoNewline
        } else {
            $daysLeft = ($script:LicenseExpires.Date - (Get-Date).Date).Days
            if ($daysLeft -lt 0) { Write-Host 'LICENCJA WYGASLA' -ForegroundColor Red -NoNewline }
            elseif ($daysLeft -le 7) { Write-Host "wygasa $($script:LicenseExpires.ToString('yyyy-MM-dd')) ($daysLeft dni)" -ForegroundColor Yellow -NoNewline }
            else { Write-Host "wygasa $($script:LicenseExpires.ToString('yyyy-MM-dd'))" -ForegroundColor Green -NoNewline }
        }
    } else { Write-Host 'TRYB DEMO' -ForegroundColor Yellow -NoNewline }
    Write-Host "  |  $script:Author" -ForegroundColor DarkGray
    Write-Host ''
}
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
function Invoke-Preflight {
    if (-not (Test-IsAdmin)) {
        Write-Host ''
        Write-Host '  URUCHOM SKRYPT JAKO ADMINISTRATOR!' -ForegroundColor Red
        if (Read-YesNo 'Uruchomic ponownie z uprawnieniami admina?') {
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        }
        exit 1
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        if ([int]$os.ProductType -ne 1) { Write-Err 'Skrypt dziala TYLKO na Windows 10/11 stacje robocze.'; exit 1 }
    } catch {}
}

# ====================== SPRZET ======================
function Get-Hardware {
    $hw = [pscustomobject][ordered]@{
        CpuName='?'; CpuVendor='?'; GpuName='?'; GpuVendor='?'
        RamGB=0; IsLaptop=$false; Chassis='Desktop'; OsBuild=0; DiskType='?'; IsSSD=$false; NicNames=@()
    }
    try {
        $c = Get-CimInstance Win32_Processor | Select-Object -First 1
        $hw.CpuName = ($c.Name -replace '\s+',' ').Trim()
        if ($hw.CpuName -match 'Ryzen|EPYC|FX|Athlon') { $hw.CpuVendor='AMD' }
        elseif ($hw.CpuName -match 'Intel|Core|Xeon|Pentium|Celeron') { $hw.CpuVendor='Intel' }
    } catch {}
    try {
        $gs = Get-CimInstance Win32_VideoController
        $pick = $null
        foreach ($g in $gs) { if ($g.AdapterCompatibility -match 'NVIDIA|AMD|Advanced Micro|ATI') { $pick=$g; break } }
        if (-not $pick) { $pick = $gs | Select-Object -First 1 }
        if ($pick) {
            $hw.GpuName = ($pick.Name -replace '\s+',' ').Trim()
            if ($pick.AdapterCompatibility -match 'NVIDIA') { $hw.GpuVendor='NVIDIA' }
            elseif ($pick.AdapterCompatibility -match 'AMD|Advanced Micro|ATI') { $hw.GpuVendor='AMD' }
            elseif ($pick.AdapterCompatibility -match 'Intel') { $hw.GpuVendor='Intel' }
        }
    } catch {}
    try { $hw.RamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB) } catch {}
    try {
        $t = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes)
        $lapT = @(8,9,10,11,12,14,18,21,30,31,32)
        foreach ($x in $t) { if ($lapT -contains [int]$x) { $hw.IsLaptop=$true } }
        if (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) { $hw.IsLaptop=$true }
        if ($hw.IsLaptop) { $hw.Chassis='Laptop' }
    } catch {}
    try { $hw.OsBuild=[int](Get-CimInstance Win32_OperatingSystem).BuildNumber } catch {}
    try {
        $sl = ($env:SystemDrive).TrimEnd(':')
        $pt = Get-Partition -DriveLetter $sl -ErrorAction SilentlyContinue
        $d = $null
        if ($pt) { $d = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$($pt.DiskNumber)" } | Select-Object -First 1 }
        if (-not $d) { $d = Get-PhysicalDisk | Select-Object -First 1 }
        if ($d) {
            $hw.DiskType = "$($d.BusType)/$($d.MediaType)"
            if ($d.MediaType -eq 'SSD' -or $d.BusType -eq 'NVMe') { $hw.IsSSD=$true }
        }
    } catch {}
    try { $hw.NicNames = @((Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }).Name) } catch {}
    return $hw
}
function Show-Hw {
    if (-not $script:Hw) { return }
    $h = $script:Hw
    Write-Host ("   CPU : {0}  [{1}]" -f $h.CpuName, $h.CpuVendor) -ForegroundColor White
    Write-Host ("   GPU : {0}  [{1}]" -f $h.GpuName, $h.GpuVendor) -ForegroundColor White
    Write-Host ("   RAM : {0} GB    Dysk: {1}    Obudowa: {2}    Build: {3}" -f $h.RamGB, $h.DiskType, $h.Chassis, $h.OsBuild) -ForegroundColor White
    if ($h.NicNames.Count -gt 0) { Write-Host ("   Siec: {0}" -f ($h.NicNames -join ', ')) -ForegroundColor White }
    Write-Host ("   Log : d01i_log.txt    Zastosowane pakiety: {0}" -f $script:State.Applied.Count) -ForegroundColor DarkGray
    Write-Host ''
}

# ====================== BACKUP ======================
function Ensure-Backup {
    if ($script:BackupDone) { return }
    Write-Step 'BACKUP: punkt przywracania + eksport rejestru'
    try {
        Enable-ComputerRestore "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer 'd01i tweakz p - przed optymalizacja' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Ok 'Punkt przywracania utworzony.'
    } catch { Write-Warn "Punkt przywracania: $($_.Exception.Message)" }
    $stamp = Get-Date -Format yyyyMMdd_HHmmss
    $dir = Join-Path $script:BackupDir "reg_$stamp"
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
    $keys = @(
        'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia',
        'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl',
        'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management',
        'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers',
        'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard',
        'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters',
        'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces',
        'HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR',
        'HKLM\SOFTWARE\Policies\Microsoft\Windows\Psched',
        'HKCU\System\GameConfigStore',
        'HKCU\Control Panel\Mouse',
        'HKCU\Control Panel\Desktop'
    )
    $ok = 0
    foreach ($k in $keys) {
        $f = Join-Path $dir (($k -replace '[\\\/:\s]','_') + '.reg')
        & reg.exe export $k $f /y 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok++ } else { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    $script:State.LastBackupDir = $dir; Save-State
    Write-Ok "Eksport rejestru: $ok galezi -> $dir"
    Write-Ok 'Backup gotowy.'
    $script:BackupDone = $true; Save-State
}

# ====================== GENERIC TWEAK HELPERS ======================
function Set-Reg {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Value,
        [ValidateSet('DWord','QWord','String','ExpandString','Binary')][string]$Type='DWord'
    )
    Ensure-Backup
    $had=$false; $old=$null; $oldT='DWord'
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($Name -eq '(default)') {
            $had = ($key.GetValueNames() -contains '')
            if ($had) {
                $old = $key.GetValue('')
                $oldT = $key.GetValueKind('').ToString()
            }
        } else {
            $e = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
            $old=$e.$Name; $had=$true; $oldT=$key.GetValueKind($Name).ToString()
        }
    } catch {}
    if (-not ($script:State.RegUndo | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name })) {
        $script:State.RegUndo += [pscustomobject]@{Path=$Path;Name=$Name;HadValue=$had;OldValue=$old;OldType=$oldT}
        Save-State
    }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        if ($Name -eq '(default)') {
            Set-Item -LiteralPath $Path -Value $Value -Type $Type -Force -ErrorAction Stop | Out-Null
        } else {
            New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        }
        Write-Ok "REG: $Name = $Value"
    } catch { Write-Err "REG $Path $Name : $($_.Exception.Message)" }
}
function Remove-Reg {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    Ensure-Backup
    $had=$false; $old=$null; $oldT='DWord'
    try {
        $e = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        $old=$e.$Name; $had=$true; $oldT=(Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueKind($Name).ToString()
    } catch {}
    if (-not ($script:State.RegUndo | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name })) {
        $script:State.RegUndo += [pscustomobject]@{Path=$Path;Name=$Name;HadValue=$had;OldValue=$old;OldType=$oldT}
        Save-State
    }
    if (-not $had) { Write-Info "REG: $Name nie istnieje - pomijam."; return }
    try {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop
        Write-Ok "REG: usunieto $Name"
    } catch { Write-Err "REG $Path $Name : $($_.Exception.Message)" }
}
function Set-Svc {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][ValidateSet('Disabled','Manual','Automatic')][string]$Start,[string]$Desc='')
    Ensure-Backup
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Info "Usluga $Name nie istnieje - pomijam."; return }
    $w = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    $oldM = if ($w) { $w.StartMode } elseif ($svc.PSObject.Properties['StartType']) { $svc.StartType.ToString() } else { 'Manual' }
    if (-not ($script:State.ServiceUndo | Where-Object { $_.Name -eq $Name })) {
        $script:State.ServiceUndo += [pscustomobject]@{Name=$Name;OldMode=$oldM;WasRunning=($svc.Status -eq 'Running')}
        Save-State
    }
    try {
        if ($Start -ne 'Automatic') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $Name -StartupType $Start -ErrorAction Stop
        Write-Ok "SVC: $Name : $oldM -> $Start $(if($Desc){' | '+$Desc})"
    } catch { Write-Err "SVC $Name : $($_.Exception.Message)" }
}
function Set-Task {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Full,[Parameter(Mandatory)][ValidateSet('Disable','Enable')][string]$Action)
    Ensure-Backup
    $dir = $Full.Substring(0,$Full.LastIndexOf('\')+1)
    $n = $Full.Substring($Full.LastIndexOf('\')+1)
    try { $t = Get-ScheduledTask -TaskPath $dir -TaskName $n -ErrorAction Stop } catch { Write-Info "Zadanie nie istnieje: $Full"; return }
    if ($Action -eq 'Disable' -and $t.State -eq 'Disabled') { Write-Info "Zadanie juz wylaczone: $n"; return }
    try {
        if ($Action -eq 'Disable') {
            Disable-ScheduledTask -TaskPath $dir -TaskName $n -ErrorAction Stop | Out-Null
            if ($script:State.DisabledTasks -notcontains $Full) { $script:State.DisabledTasks += $Full; Save-State }
            Write-Ok "TASK wylaczone: $n"
        } else {
            Enable-ScheduledTask -TaskPath $dir -TaskName $n -ErrorAction Stop | Out-Null
            $script:State.DisabledTasks = @($script:State.DisabledTasks -ne $Full); Save-State
            Write-Ok "TASK wlaczone: $n"
        }
    } catch { Write-Warn "TASK $n : $($_.Exception.Message)" }
}
function Set-Power {
    [CmdletBinding()]
    param([string]$SubG,[string]$Setting,[string]$Val,[ValidateSet('AC','DC')][string]$AcDc='AC')
    $flag = if ($AcDc -eq 'DC') {'/setdcvalueindex'} else {'/setacvalueindex'}
    & powercfg.exe $flag SCHEME_CURRENT $SubG $Setting $Val 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ====================== C# natywne: RAM + Timer ======================
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace D01i {
    public static class Native {
        [DllImport("ntdll.dll", SetLastError=true)]
        public static extern uint NtSetSystemInformation(int infoClass, ref uint buf, int size);
        [DllImport("ntdll.dll", SetLastError=true)]
        public static extern uint NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);
        public static uint ClearStandby() { uint v = 4; return NtSetSystemInformation(80, ref v, 4); }
        public static void SetTimer05() { uint cur; NtSetTimerResolution(5000, true, out cur); }
    }
}
'@ -ErrorAction SilentlyContinue
function Clear-Ram {
    try {
        $status = [D01i.Native]::ClearStandby()
        if ($status -eq 0) {
            Write-Ok 'RAM Standby List wyczyszczona.'
        } else {
            Write-Warn ('Nie mozna wyczyscic RAM (kod NTSTATUS: 0x{0:X8}).' -f [uint32]$status)
        }
    } catch { Write-Warn "Nie mozna wyczyscic RAM: $($_.Exception.Message)" }
}

# ====================== TWEAKI ======================
function Enable-Ultimate {
    Write-Step 'Plan zasilania: ULTIMATE PERFORMANCE'
    Ensure-Backup

    $templateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $g = [string]$script:State.UltimateSchemeGuid
    if ([string]::IsNullOrWhiteSpace($g)) { $g = $templateGuid }

    if (-not $script:State.PreviousPowerScheme) {
        $active = @(& powercfg.exe /getactivescheme 2>$null)
        $activeMatch = [regex]::Match(($active -join "`n"), '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
        if ($activeMatch.Success) {
            $script:State.PreviousPowerScheme = $activeMatch.Value
            Save-State
        }
    }

    & powercfg.exe /query $g 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $duplicateOutput = @(& powercfg.exe /duplicatescheme $templateGuid 2>&1)
        if ($LASTEXITCODE -ne 0) {
            Write-Err 'Nie udalo sie utworzyc planu Ultimate Performance.'
            return
        }
        $guidMatch = [regex]::Match(($duplicateOutput -join "`n"), '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
        if (-not $guidMatch.Success) {
            Write-Err 'Powercfg nie zwrocil GUID nowego planu Ultimate.'
            return
        }
        $g = $guidMatch.Value
        $script:State.CreatedUltimate = $true
        $script:State.UltimateSchemeGuid = $g
        Save-State
        Write-Ok 'Odblokowano plan Ultimate Performance.'
    }

    & powercfg.exe /setactive $g 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err 'Nie udalo sie aktywowac planu Ultimate Performance.'
        return
    }

    $sets = @(
        [pscustomobject]@{SubGroup='SUB_PROCESSOR'; Setting='PROCTHROTTLEMIN'; Value='100'; AcDc='AC'},
        [pscustomobject]@{SubGroup='SUB_PROCESSOR'; Setting='PROCTHROTTLEMAX'; Value='100'; AcDc='AC'},
        [pscustomobject]@{SubGroup='SUB_PROCESSOR'; Setting='CPMINCORES'; Value='100'; AcDc='AC'},
        [pscustomobject]@{SubGroup='SUB_PROCESSOR'; Setting='CPMAXCORES'; Value='100'; AcDc='AC'},
        [pscustomobject]@{SubGroup='SUB_PCIEXPRESS'; Setting='ASPM'; Value='0'; AcDc='AC'},
        [pscustomobject]@{SubGroup='SUB_PCIEXPRESS'; Setting='ASPM'; Value='0'; AcDc='DC'},
        [pscustomobject]@{SubGroup='2a737441-1930-4402-8d77-b2bebba308a3'; Setting='48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Value='0'; AcDc='AC'}
    )
    $i=0
    foreach ($s in $sets) {
        if (Set-Power -SubG $s.SubGroup -Setting $s.Setting -Val $s.Value -AcDc $s.AcDc) { $i++ }
    }
    & powercfg.exe /setactive $g 2>&1 | Out-Null
    Write-Ok "Plan Ultimate aktywowany ($i ustawien)."
    Add-Applied 'power-ultimate'
}
function Disable-Hibernation {
    Write-Step 'Hibernacja/Fast Startup: WYLACZENIE'
    Ensure-Backup
    if ($null -eq $script:State.HibernationWasEnabled) {
        $script:State.HibernationWasEnabled = Test-Path "$env:SystemDrive\hiberfil.sys"
        Save-State
    }
    & powercfg.exe /hibernate off 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'Hibernacja i Fast Startup wylaczone.'
        Add-Applied 'power-hib'
    } else {
        Write-Warn 'Nie udalo sie wylaczyc hibernacji.'
    }
}
function Set-Mmcss {
    Write-Step 'MMCSS: profil gamingowy'
    $p = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-Reg $p SystemResponsiveness 0 DWord
    Set-Reg $p NetworkThrottlingIndex 0xFFFFFFFF DWord
    Set-Reg $p NoLazyMode 1 DWord
    $g = "$p\Tasks\Games"
    Set-Reg $g 'GPU Priority' 8 DWord
    Set-Reg $g Priority 8 DWord
    Set-Reg $g 'Scheduling Category' High String
    Set-Reg $g 'SFIO Priority' High String
    Write-Ok 'MMCSS Games: High, GPU prio 8, zero throttlingu.'
    Add-Applied 'reg-mmcss'
}
function Set-Priority {
    Write-Step 'Priorytety/GameDVR/Game Mode'
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' Win32PrioritySeparation 38 DWord
    Set-Reg 'HKCU:\System\GameConfigStore' GameDVR_Enabled 0 DWord
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' AllowGameDVR 0 DWord
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' AllowAutoGameMode 1 DWord
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' AutoGameModeEnabled 1 DWord
    Set-Reg 'HKCU:\System\GameConfigStore' GameDVR_FSEBehaviorMode 2 DWord
    Write-Ok 'Priorytety, GameDVR off, FSE fix, Game Mode on.'
    Add-Applied 'reg-prio'
}
function Set-Timer05 {
    Write-Step 'Timer Resolution 0.5ms'
    & bcdedit.exe /set {current} useplatformtick yes | Out-Null
    & bcdedit.exe /set {current} disabledynamictick yes | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' GlobalTimerResolutionRequests 1 DWord
    try {
        [D01i.Native]::SetTimer05()
        Write-Ok 'Timer 0.5ms ustawiony dla biezacego procesu (autostart utrzyma go po restarcie).'
    } catch {
        Write-Warn 'Nie mozna ustawic timer resolution dla biezacego procesu.'
    }
    $script:RebootNeeded=$true; Add-Applied 'reg-timer'
}
function Set-MouseFix {
    Write-Step 'Mouse Fix 1:1 (bez akceleracji)'
    $m = 'HKCU:\Control Panel\Mouse'
    Set-Reg $m MouseSpeed '0' String
    Set-Reg $m MouseThreshold1 '0' String
    Set-Reg $m MouseThreshold2 '0' String
    Set-Reg $m MouseSensitivity '10' String
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Input\Settings\ControllerProcessor' MouseDataQueueSize 20 DWord
    Write-Ok 'Mysz: 1:1, bez akceleracji.'
    Add-Applied 'ui-mouse'
}
function Set-Network {
    Write-Step 'TCP/IP: low-latency'
    $par = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    Set-Reg $par Tcp1323Opts 1 DWord
    Set-Reg $par TcpDelAckTicks 0 DWord
    Set-Reg $par TCPNoDelay 1 DWord
    Set-Reg $par TcpAckFrequency 1 DWord
    Set-Reg $par TCPTimedWaitDelay 30 DWord
    Set-Reg $par MaxUserPort 65534 DWord
    Set-Reg $par DefaultTTL 64 DWord
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' NonBestEffortLimit 0 DWord
    Get-ChildItem "$par\Interfaces" -ErrorAction SilentlyContinue | ForEach-Object {
        Set-Reg $_.PSPath TcpAckFrequency 1 DWord | Out-Null
        Set-Reg $_.PSPath TCPNoDelay 1 DWord | Out-Null
    }
    try {
        Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
            Disable-NetAdapterRsc -Name $_.Name -IPv4 -IPv6 -ErrorAction SilentlyContinue
            Disable-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue
            $did = if ($_.PnPDeviceID) { [string]$_.PnPDeviceID } else { [string]$_.DeviceID }
            $nk = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}' -ErrorAction SilentlyContinue | Where-Object {
                try { (Get-ItemPropertyValue $_.PSPath DeviceInstanceID -ErrorAction SilentlyContinue) -ieq $did } catch { $false }
            } | Select-Object -First 1
            if ($nk) {
                $cur = 0
                try { $cur = [int](Get-ItemPropertyValue $nk.PSPath PnPCapabilities -ErrorAction SilentlyContinue) } catch {}
                Set-Reg -Path $nk.PSPath -Name PnPCapabilities -Value ($cur -bor 24) -Type DWord
            }
        }
    } catch {}
    Write-Ok 'TCP/IP: Nagle off, QoS 0%, NIC power off.'
    $script:RebootNeeded=$true; Add-Applied 'net-tcp'
}
function Set-AutoDns {
    Write-Step 'DNS: automatyczny najszybszy (15 serwerow)'
    $dns = @(
        @{N='Cloudflare';A='1.1.1.1';B='1.0.0.1'},
        @{N='Google';A='8.8.8.8';B='8.8.4.4'},
        @{N='Quad9';A='9.9.9.9';B='149.112.112.112'},
        @{N='OpenDNS';A='208.67.222.222';B='208.67.220.220'},
        @{N='AdGuard';A='94.140.14.14';B='94.140.15.15'},
        @{N='CleanBrowsing';A='185.228.168.9';B='185.228.169.9'},
        @{N='Neustar';A='156.154.70.1';B='156.154.71.1'},
        @{N='Comodo';A='8.26.56.26';B='8.20.247.20'},
        @{N='Yandex';A='77.88.8.8';B='77.88.8.1'},
        @{N='Verisign';A='64.6.64.6';B='64.6.65.6'},
        @{N='Norton';A='199.85.126.10';B='199.85.127.10'},
        @{N='Dyn';A='216.146.35.35';B='216.146.36.36'},
        @{N='UncensoredDNS';A='91.239.100.100';B='89.233.43.71'},
        @{N='Freenom';A='80.80.80.80';B='80.80.81.81'},
        @{N='Mullvad';A='194.242.2.2';B='185.222.222.222'}
    )
    $best=$null; $bestMs=9999
    foreach ($d in $dns) {
        $r = Test-Connection -ComputerName $d.A -Count 2 -ErrorAction SilentlyContinue | Measure-Object ResponseTime -Average
        if ($r -and $r.Average) {
            $ms = [math]::Round($r.Average,1)
            Write-Host "     $($d.N): $ms ms" -ForegroundColor DarkGray
            if ($ms -lt $bestMs) { $bestMs=$ms; $best=$d }
        }
    }
    if (-not $best) { Write-Warn 'Nie mozna sprawdzic DNS.'; return }
    Write-Ok "Najszybszy: $($best.N) ($bestMs ms)"
    Ensure-Backup
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
        Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ($best.A,$best.B) -ErrorAction SilentlyContinue
    }
    Write-Ok "DNS ustawione na $($best.N)."; Add-Applied "net-dns-$($best.N)"
}
function Set-MsiMode {
    Write-Step 'MSI Mode dla GPU/NIC/dyskow (niskie DPC)'
    Ensure-Backup
    $paths = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -Recurse -ErrorAction SilentlyContinue | Where-Object {
        try { Get-ItemProperty $_.PSPath DeviceParameters -ErrorAction Stop; $true } catch { $false }
    }
    $classes = 'Display','Net','SCSIAdapter','SDHost' -split ','
    $n=0
    foreach ($p in $paths) {
        try {
            $c = (Get-ItemProperty $p.PSPath -Name Class -ErrorAction SilentlyContinue).Class
            if (-not $c -or $classes -notcontains $c) { continue }
            $mp = Join-Path $p.PSPath 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
            $cur = Get-ItemProperty $mp MSISupported -ErrorAction SilentlyContinue
            if (-not $cur -or $cur.MSISupported -ne 1) {
                Set-Reg -Path $mp -Name MSISupported -Value 1 -Type DWord
                Set-Reg -Path $mp -Name MessageNumberLimit -Value 8 -Type DWord
                if ($script:State.MsiTouched -notcontains $p.PSPath) { $script:State.MsiTouched += $p.PSPath }
                $n++
            }
        } catch {}
    }
    Save-State
    Write-Ok "MSI Mode wlaczony dla $n urzadzen (restart wymagany)."
    $script:RebootNeeded=$true; Add-Applied 'tweak-msi'
}
function Disable-BaseSvc {
    Write-Step 'Uslugi: telemetria/Xbox OFF (SysMain zostaje - pomaga w ladowaniu SSD)'
    $off = @(
        @{N='DiagTrack';D='Telemetria'},
        @{N='dmwappushservice';D='WAP push'},
        @{N='MapsBroker';D='Mapy offline'},
        @{N='RetailDemo';D='Demo sklepu'},
        @{N='WMPNetworkSvc';D='WMP sharing'},
        @{N='XblAuthManager';D='Xbox Auth'},
        @{N='XblGameSave';D='Xbox Save'},
        @{N='XboxNetApiSvc';D='Xbox Net'},
        @{N='XboxGipSvc';D='Xbox Accessory'},
        @{N='lfsvc';D='Geolokalizacja'},
        @{N=' diagnosticshub.standardcollector.service';D='Diagnostic Hub'},
        @{N='TrkWks';D='Distributed Link Tracking'},
        @{N='WerSvc';D='Error Reporting'},
        @{N='WSearch';D='Windows Search indexer'}
    )
    foreach ($s in $off) { Set-Svc $s.N Disabled $s.D }
    $tasks = @(
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Autochk\Proxy',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
        '\Microsoft\Windows\Maps\MapsUpdateTask',
        '\Microsoft\Windows\Maps\MapsToastTask'
    )
    foreach ($t in $tasks) { Set-Task $t Disable }
    Write-Ok 'Bazowe uslugi i zadania wylaczone.'; Add-Applied 'svc-base'
}
function Pause-WU {
    Write-Step 'Windows Update: wstrzymanie w tle'
    Set-Svc wuauserv Disabled 'Windows Update'
    Set-Task '\Microsoft\Windows\WindowsUpdate\Scheduled Start' Disable
    $pause = (Get-Date).AddDays(30).ToString('yyyy-MM-dd')
    New-Item 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' PauseUpdatesExpiryTime $pause String
    Write-Ok 'Windows Update wstrzymany na 30 dni.'; Add-Applied 'svc-wu'
}

# ====================== MOCNE TWEAKI COMPETITIVE ======================
function Disable-CoreParking {
    Write-Step 'CPU: Core Parking OFF'
    Ensure-Backup
    try {
        foreach ($setting in @('CPMINCORES','CPMAXCORES')) {
            [void](Set-Power -SubG 'SUB_PROCESSOR' -Setting $setting -Val '100' -AcDc AC)
            [void](Set-Power -SubG 'SUB_PROCESSOR' -Setting $setting -Val '100' -AcDc DC)
        }
        & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' PowerThrottlingOff 1 DWord
        Write-Ok 'Core Parking off, Power Throttling off.'
        Add-Applied 'cpu-parking'
    } catch { Write-Warn "Core Parking: $($_.Exception.Message)" }
}
function Disable-MemoryCompression {
    Write-Step 'RAM: Memory Compression OFF (>=16GB)'
    if (-not $script:Hw -or $script:Hw.RamGB -lt 16) { Write-Warn 'Za malo RAM, pomijam.'; return }
    try {
        $mc = Get-MMAgent -ErrorAction SilentlyContinue
        if (-not $mc) { Write-Warn 'Wymaga Win10+ z dostepnymi cmdletami, pomijam.'; return }
        if ($null -eq $script:State.MemoryCompressionWasEnabled) {
            $script:State.MemoryCompressionWasEnabled = [bool]$mc.MemoryCompression
            Save-State
        }
        if ($mc.MemoryCompression) {
            Disable-MMAgent -mc -ErrorAction Stop
            Write-Ok 'Memory Compression wylaczone (restart zalecany).'
        } else { Write-Ok 'Memory Compression juz wylaczone.' }
        Add-Applied 'ram-mc'
    } catch { Write-Warn 'Nie mozna zmienic Memory Compression na tym systemie.' }
}
function Disable-HpetGlobally {
    Write-Step 'HPET off (lepsze latency)'
    Ensure-Backup
    & bcdedit /set useplatformclock no 2>&1 | Out-Null
    & bcdedit /set tscsyncpolicy enhanced 2>&1 | Out-Null
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' SystemResponsiveness 0 DWord
    Write-Ok 'HPET wylaczone (restart wymagany).'
    $script:RebootNeeded=$true; Add-Applied 'adv-hpet'
}
function Set-NetworkLatency {
    Write-Step 'Siec: NDIS latency off (GSO/LSO/RSC/InterruptModeration)'
    Ensure-Backup
    $changed=0
    try {
        $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
        foreach($n in $nics){
            # DeviceID nie odpowiada numerowi klucza 0000/0001 w rejestrze. Uzywamy
            # udokumentowanego cmdletu i tylko wlasciwosci obslugiwanych przez sterownik.
            foreach($name in @('*LsoV2IPv4','*LsoV2IPv6','*TCPUDPChecksumOffloadIPv4','*TCPUDPChecksumOffloadIPv6',
                '*IPChecksumOffloadIPv4','*TCPChecksumOffloadIPv4','*TCPChecksumOffloadIPv6','*UDPChecksumOffloadIPv4',
                '*UDPChecksumOffloadIPv6','*RscIPv4','*RscIPv6','*InterruptModeration','*RSS')){
                try {
                    Set-NetAdapterAdvancedProperty -Name $n.Name -RegistryKeyword $name -RegistryValue '0' -NoRestart -ErrorAction Stop | Out-Null
                    $changed++
                } catch {}
            }
        }
        # Disable Nagle globalnie
        $interfaces = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue
        foreach($i in $interfaces){
            Set-Reg $i.PSPath TcpAckFrequency 1 DWord
            Set-Reg $i.PSPath TcpDelAckTicks 0 DWord
            Set-Reg $i.PSPath TCPNoDelay 1 DWord
        }
    } catch { Write-Warn 'Niektore karty sieciowe mogly nie dac sie ustawic.' }
    if ($changed -gt 0) { $script:RebootNeeded=$true }
    Write-Ok "NDIS latency tweaks zastosowane (wlasciwosci NIC: $changed)."
    Add-Applied 'net-latency'
}
function Disable-FullscreenOpt {
    Write-Step 'Gry: Fullscreen Optimizations OFF globalnie'
    Ensure-Backup
    $root='HKCU:\System\GameConfigStore'
    Set-Reg $root GameDVR_FSEBehaviorMode 2 DWord
    Set-Reg $root GameDVR_FSEBehavior 2 DWord
    Set-Reg $root GameDVR_DXGIHDRMode 1 DWord
    Set-Reg $root GameDVR_Enabled 0 DWord
    # Wylacz priorytet gier w pasku
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' AppCaptureEnabled 0 DWord
    Write-Ok 'Fullscreen Optimizations OFF.'; Add-Applied 'game-fso'
}
function Disable-WidgetsCopilot {
    Write-Step 'UI: Widgety/Copilot/Teams autostart OFF'
    Ensure-Backup
    $policies='HKCU:\SOFTWARE\Policies\Microsoft\Windows'
    New-Item "$policies\Windows Copilot" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Reg "$policies\Windows Copilot" TurnOffWindowsCopilot 1 DWord
    New-Item "$policies\Windows\Explorer" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Reg "$policies\Windows\Explorer" DisableNewsAndInterests 1 DWord
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' TaskbarDa 0 DWord
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ShowTaskViewButton 0 DWord
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests' value 0 DWord
    # Wylacz Teams autostart
    Remove-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' com.squirrel.Teams.Teams -ErrorAction SilentlyContinue
    try { Set-Svc Teams Disabled 'Teams' } catch {}
    Write-Ok 'Widgety/Copilot/Teams OFF.'; Add-Applied 'ui-copilot'
}
function Disable-StickyKeys {
    Write-Step 'Klawiatura: Sticky/Filter/Toggle Keys OFF'
    $sk='HKCU:\Control Panel\Accessibility\StickyKeys'
    $fk='HKCU:\Control Panel\Accessibility\Keyboard Response'
    $tk='HKCU:\Control Panel\Accessibility\ToggleKeys'
    # Klucze Accessibility przechowuja Flags jako REG_SZ; wpis DWORD byl ignorowany przez czesc wersji Windows.
    Set-Reg $sk Flags '506' String
    Set-Reg $fk Flags '122' String
    Set-Reg $tk Flags '58' String
    Write-Ok 'Sticky/Filter/Toggle Keys OFF.'; Add-Applied 'kbd-sticky'
}
function Disable-VisualFX {
    Write-Step 'System: WSZYSTKIE animacje/efekty wizualne OFF'
    Ensure-Backup
    # Wylacz cienie, animacje okien, fade/slide, przezroczystosc, Aero Shake, menu animacje
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' VisualFXSetting 2 DWord
    Set-Reg 'HKCU:\Control Panel\Desktop' DragFullWindows 0 String
    Set-Reg 'HKCU:\Control Panel\Desktop' FontSmoothing 2 String
    Set-Reg 'HKCU:\Control Panel\Desktop' UserPreferencesMask ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) Binary
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' MinAnimate 0 String
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' TaskbarAnimations 0 DWord
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ListviewShadow 0 DWord
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ListviewAlphaSelect 0 DWord
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' DisablePreviewDesktop 0 DWord
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' EnableTransparency 0 DWord
    Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' ForceRemoteDesktopComposition 1 DWord
    Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' Composition 1 DWord
    # Aero Shake off
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' DisallowShaking 1 DWord
    # Wylacz animacje paska zadan/startu
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' Start_ShowRecentDocs 0 DWord
    # Nie nadpisujemy MachinePreferredUILanguages: to cache jezyka interfejsu, nie ustawienie wydajnosci.
    # Uzyj prostego planu wydajnosci
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ThemeManager' ThemeActive 0 String
    Write-Ok 'Efekty wizualne i animacje wylaczone.'; Add-Applied 'ui-visualfx'
}
function Set-MaxPerf {
    Write-Step 'CPU/System: Maksymalna wydajnosc procesow pierwszoplanowych'
    Ensure-Backup
    # Win32PrioritySeparation 0x2A = 42 = krotkie kwanty + zmienny priorytet pierwszego planu.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' Win32PrioritySeparation 42 DWord
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' LargeSystemCache 0 DWord
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' DisablePagingExecutive 1 DWord
    # Nie ustawiamy numproc ani wartosci SubSystems: ograniczaja one boot lub moga uszkodzic konfiguracje sesji Windows.
    Write-Ok 'CPU Priority (0x2A), LargeSystemCache off, DisablePagingExecutive on.'
    Add-Applied 'cpu-maxperf'
}
function Invoke-GamePriorityWatcher {
    Write-Step 'Game Priority Watcher w tle'
    if(-not $script:Licensed){ Write-Err 'Tylko pelna wersja.'; return }
    $games = @('cs2','csgo','valorant-win64-shipping','fortniteclient-win64-shipping','r5apex','escapefromtarkov',
        'leagueclient','league of legends','overwatch','rainbowsix','pubg','dota2','gta5','gtav',
        'minecraft','modernwarfare','warzone','apex','rocketleague','lol.launcher.admin')
    $script:PriJob = Start-Job -ScriptBlock {
        param($list)
        Add-Type @'
using System; using System.Runtime.InteropServices;
namespace D01iGP {
    public class W {
        [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(int a, bool b, int c);
        [DllImport("kernel32.dll")] public static extern bool SetPriorityClass(IntPtr h, int p);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    }
}
'@ -ErrorAction SilentlyContinue
        while($true){
            $procs = Get-Process -ErrorAction SilentlyContinue
            foreach($p in $procs){
                try {
                    if($list -contains $p.ProcessName.ToLower()){
                        $h = [D01iGP.W]::OpenProcess((0x200 -bor 0x400), $false, $p.Id)
                        if($h -ne [IntPtr]::Zero){
                            [void][D01iGP.W]::SetPriorityClass($h, 0x80)  # HIGH_PRIORITY_CLASS
                            [void][D01iGP.W]::CloseHandle($h)
                        }
                    }
                } catch {}
            }
            Start-Sleep -Seconds 10
        }
    } -Arg (,$games)
    Write-Ok 'Game Priority Watcher uruchomiony (daje priorytet HIGH gdy wykryje gre).'; Add-Applied 'game-priority'
}
function Disable-Win11Context {
    Write-Step 'Windows 11: Stare menu kontekstowe (bez "Pokaz wiecej opcji")'
    Ensure-Backup
    if((Get-CimInstance Win32_OperatingSystem).BuildNumber -ge 22000){
        $contextPath = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
        if (-not (Test-Path -LiteralPath $contextPath)) {
            New-Item -Path $contextPath -Force -ErrorAction Stop | Out-Null
            if ($script:State.CreatedRegistryKeys -notcontains $contextPath) {
                $script:State.CreatedRegistryKeys += $contextPath
                Save-State
            }
        }
        Set-Reg $contextPath '(default)' '' String
        Write-Ok 'Stare menu kontekstowe wlaczone (restart explorer.exe).'
        try { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Process explorer } catch {}
    } else { Write-Info 'Nie masz Win11, pomijam.' }
    Add-Applied 'ui-win11context'
}
function Disable-ReservedStorage {
    Write-Step 'Dysk: wylacz Reserved Storage (zwalnia 2-7 GB)'
    Ensure-Backup
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager'
    Set-Reg -Path $path -Name ShippedWithReserves -Value 0 -Type DWord
    $disabled = $false
    try { $disabled = ((Get-ItemPropertyValue -LiteralPath $path -Name ShippedWithReserves -ErrorAction Stop) -eq 0) } catch {}
    if (-not $disabled) {
        Write-Warn 'Reserved Storage: probuje ustawic przez DISM (Win10 2004+).'
        & dism.exe /Online /Set-ReservedStorageState /State:Disabled 2>&1 | Out-Null
        $disabled = ($LASTEXITCODE -eq 0)
    }
    if ($disabled) {
        Write-Ok 'Reserved Storage wylaczone.'
        Add-Applied 'disk-reserved'
    } else {
        Write-Warn 'Nie udalo sie wylaczyc Reserved Storage.'
    }
}
function Set-AutostartGame {
    Write-Step 'Autostart: Smart ISLC + ProBalance + Game Priority po logowaniu'
    if (-not $script:Licensed) { Write-Err 'Autostart wymaga aktywnej pelnej licencji.'; return }
    Ensure-Backup

    $ps1Path = Join-Path $script:Root 'd01i_PRO.ps1'
    if (-not (Test-Path -LiteralPath $ps1Path)) { Write-Err "Nie znaleziono skryptu: $ps1Path"; return }
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe)) { $powershellExe = 'powershell.exe' }

    try {
        $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -AutoRun' -f $ps1Path
        $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $script:AutoRunTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

        # Usuwamy stary launcher z folderu Startup; nie potrafil podniesc uprawnien po logowaniu.
        $legacyBat = Join-Path ([Environment]::GetFolderPath('Startup')) 'd01i_PRO_autorun.bat'
        Remove-Item -LiteralPath $legacyBat -Force -ErrorAction SilentlyContinue
        Write-Ok "Autostart zapisany jako zadanie Harmonogramu: $($script:AutoRunTaskName)"
        Write-Info 'Po logowaniu zadanie uruchomi ukryty, podniesiony proces dla timera, Smart ISLC, ProBalance i Game Priority.'
        Add-Applied 'autostart'
    } catch {
        Write-Err "Nie udalo sie utworzyc zadania autostartu: $($_.Exception.Message)"
    }
}
function Set-CstateOff {
    Write-Step 'CPU: profil niskich opoznien (bez zmian firmware C-state)'
    Ensure-Backup
    # C3/C6/C7 sa ustawieniami BIOS/UEFI zaleznymi od platformy. Uniwersalne wpisy
    # rejestru Capabilities/CStatePolicy nie wylaczaja ich wiarygodnie i moga uszkodzic
    # konfiguracje zasilania, dlatego modyfikujemy wylacznie udokumentowany plan zasilania.
    [void](Set-Power -SubG 'SUB_PROCESSOR' -Setting 'PROCTHROTTLEMIN' -Val '100' -AcDc AC)
    [void](Set-Power -SubG 'SUB_PROCESSOR' -Setting 'PROCTHROTTLEMIN' -Val '100' -AcDc DC)
    & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null
    Write-Info 'Glebokie C-state zmienia sie w BIOS/UEFI; skrypt ustawil minimalny stan CPU na 100%.'
    Add-Applied 'cpu-cstate'
}
function Disable-DiscordAccel {
    Write-Step 'Discord/Electron: wylaczenie akceleracji sprzetowej (mniej GPU w tle)'
    Ensure-Backup
    $paths = @(
        "$env:APPDATA\discord\settings.json",
        "$env:APPDATA\DiscordCanary\settings.json",
        "$env:APPDATA\DiscordPTB\settings.json",
        "$env:APPDATA\Slack\settings.json",
        "$env:LOCALAPPDATA\Programs\Microsoft Teams\settings.json"
    )
    $fixed=0
    foreach ($p in $paths) {
        if(Test-Path $p){
            try {
                $j = Get-Content $p -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                if($j){
                    $j | Add-Member -Force -NotePropertyMembers @{hardwareAcceleration=$false; disableHardwareAcceleration=$true}
                    $j | ConvertTo-Json -Depth 10 | Set-Content $p -Encoding UTF8 -Force
                    $fixed++
                }
            } catch {}
        }
    }
    Write-Ok "Wykonano dla $fixed aplikacji Electron/Discord."; Add-Applied 'discord-accel'
}
function Set-NvidiaShaderCache {
    Write-Step 'NVIDIA: katalog cache shaderow + ustawienia telemetryczne'
    Ensure-Backup
    try {
        if($script:Hw -and $script:Hw.GpuVendor -eq 'NVIDIA'){
            $nvprefs = "$env:LOCALAPPDATA\NVIDIA Corporation\DXCache"
            if(-not (Test-Path $nvprefs)){ New-Item $nvprefs -ItemType Directory -Force | Out-Null }
            # Weryfikujemy katalog cache i wylaczamy dostepne ustawienia telemetryczne.
            # Limit cache shaderow jest ustawieniem sterownika/profilu NVIDIA i nie ma bezpiecznego,
            # uniwersalnego wpisu rejestru dla wszystkich wersji sterownika.
            $nvkey='HKLM:\SOFTWARE\NVIDIA Corporation\Global'
            Set-Reg $nvkey SetTelemetry 0 DWord -ErrorAction SilentlyContinue
            Set-Reg "$nvkey\NvTweak" DisableNVScheduledTelemetry 1 DWord -ErrorAction SilentlyContinue
            Write-Ok 'NVIDIA telemetry off; katalog cache shaderow jest gotowy.'
        } else { Write-Info 'Brak NVIDIA, pomijam.' }
    } catch { Write-Warn "NVIDIA tweaks: $_" }
    Add-Applied 'nv-tweaks'
}
function Disable-DeliveryOptimization {
    Write-Step 'Delivery Optimization P2P OFF'
    Ensure-Backup
    Set-Svc DoSvc Disabled 'Delivery Optimization'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' DODownloadMode 0 DWord
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' DODownloadMode 0 DWord
    Write-Ok 'P2P Delivery Optimization OFF.'; Add-Applied 'do-p2p-off'
}
function Invoke-ProBalance {
    Write-Step 'ProBalance Watcher (inteligentna regulacja priorytetow w tle)'
    if(-not $script:Licensed){ Write-Err 'Tylko w pelnej wersji.'; return }
    $script:PBJob = Start-Job -ScriptBlock {
        $gameList = @('cs2','csgo','valorant-win64-shipping','fortniteclient-win64-shipping','r5apex','escapefromtarkov',
            'leagueclient','overwatch','rainbowsix','pubg','dota2','gta5','gtav','warzone','rocketleague','minecraft')
        $protected = @('system','system idle process','idle','registry','smss','csrss','wininit','services','lsass','svchost','dwm')
        $logicalProcessors = [Math]::Max([Environment]::ProcessorCount, 1)
        while($true){
            try {
                # Pobieramy probke wszystkich procesow jednoczesnie. Poprzednia wersja robila
                # 400 ms przerwy dla kazdego procesu z osobna, wiec przy wielu procesach sama
                # zuzywala dziesiatki sekund na jedno sprawdzenie.
                $samples = @{}
                Get-Process -ErrorAction SilentlyContinue | Where-Object {
                    $_.CPU -gt 0 -and $_.WorkingSet -gt 50MB -and
                    $gameList -notcontains $_.ProcessName.ToLower() -and
                    $protected -notcontains $_.ProcessName.ToLower()
                } | ForEach-Object {
                    try { $samples[$_.Id] = $_.TotalProcessorTime } catch {}
                }
                Start-Sleep -Milliseconds 400
                foreach($id in @($samples.Keys)){
                    try {
                        $p = Get-Process -Id $id -ErrorAction Stop
                        $deltaMs = ($p.TotalProcessorTime - $samples[$id]).TotalMilliseconds
                        $cpuPercent = ($deltaMs / (400 * $logicalProcessors)) * 100
                        if($cpuPercent -gt 40 -and
                           $p.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::Idle -and
                           $p.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::BelowNormal){
                            $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                        }
                    } catch {}
                }
            } catch {}
            Start-Sleep -Seconds 8
        }
    }
    Write-Ok 'ProBalance Watcher uruchomiony (obniza priorytet procesom stale zuzywajacym >40% CPU).'
    Add-Applied 'probalance'
}
function Invoke-SmartISLC {
    Write-Step 'Smart ISLC: inteligentne czyszczenie RAM (progi zalezne od RAMu)'
    if(-not $script:Licensed){ Write-Err 'Tylko w pelnej wersji.'; return }
    # Progi wg zalecen ISLC Wagnard: standby >= X i free < Y
    $ramGB=[math]::Round(((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB),0)
    if($ramGB -ge 64){$standbyThresh=4096MB;$freeThresh=8192MB}
    elseif($ramGB -ge 32){$standbyThresh=2048MB;$freeThresh=4096MB}
    elseif($ramGB -ge 16){$standbyThresh=1024MB;$freeThresh=2048MB}
    else{$standbyThresh=512MB;$freeThresh=1024MB}
    Write-Info "Progi dla ${ramGB}GB: standby>$([math]::Round($standbyThresh/1MB))MB i free<$([math]::Round($freeThresh/1MB))MB"
    $script:ISLCJob = Start-Job -ScriptBlock {
        param($st,$ft)
        Add-Type @'
using System; using System.Runtime.InteropServices;
namespace D01iSLC {
    public class M {
        [DllImport("ntdll.dll")] public static extern uint NtSetSystemInformation(int c, ref uint v, int s);
        [DllImport("ntdll.dll")] public static extern uint NtSetTimerResolution(uint d, bool s, out uint c);
        [DllImport("kernel32.dll", SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)] public static extern bool GlobalMemoryStatusEx([In,Out] MEMORYSTATUSEX lpBuffer);
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)] public class MEMORYSTATUSEX { public uint dwLength; public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys; public ulong ullTotalPageFile; public ulong ullAvailPageFile; public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual; public MEMORYSTATUSEX(){dwLength=(uint)Marshal.SizeOf(this);} }
    }
}
'@ -ErrorAction SilentlyContinue
        $c=[uint32]0;[D01iSLC.M]::NtSetTimerResolution(5000,$true,[ref]$c)|Out-Null
        while($true){
            try {
                $m = New-Object D01iSLC.M+MEMORYSTATUSEX
                [D01iSLC.M]::GlobalMemoryStatusEx($m) | Out-Null
                $free = $m.ullAvailPhys
                # Standby liczymy prosto z licznika performance counter
                $standby = (Get-Counter '\Memory\Standby Cache Reserve Bytes' -ErrorAction SilentlyContinue).CounterSamples.CookedValue
                $standby += (Get-Counter '\Memory\Standby Cache Normal Priority Bytes' -ErrorAction SilentlyContinue).CounterSamples.CookedValue
                $standby += (Get-Counter '\Memory\Standby Cache Core Bytes' -ErrorAction SilentlyContinue).CounterSamples.CookedValue
                if(($standby -gt $st) -and ($free -lt $ft)){
                    $v=[uint32]4;[D01iSLC.M]::NtSetSystemInformation(80,[ref]$v,4)|Out-Null
                }
            } catch {}
            Start-Sleep -Seconds 5
        }
    } -Arg $standbyThresh,$freeThresh
    Write-Ok 'Smart ISLC uruchomiony.'; Add-Applied 'smart-islc'
}
function Disable-USBSelectiveSuspend {
    Write-Step 'USB: Selective Suspend OFF (mysz/klawiatura nie idzie spac)'
    Ensure-Backup
    # Wylacz w planie zasilania
    & powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>&1 | Out-Null
    & powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>&1 | Out-Null
    # USB disable selective suspend na wszystkich hubach w rejestrze
    $usbPath='HKLM:\SYSTEM\CurrentControlSet\Services\USB'
    Set-Reg $usbPath DisableSelectiveSuspend 1 DWord
    Write-Ok 'USB Selective Suspend OFF.'; Add-Applied 'usb-suspend'
}
function Set-SSDTweaks {
    Write-Step 'Dysk SSD/NVMe: optymalizacja zapisow'
    Ensure-Backup
    $fs='HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    Set-Reg $fs NtfsDisableLastAccessUpdate 1 DWord  # wylacz znacznik ostatniego dostepu
    Set-Reg $fs NtfsMemoryUsage 2 DWord             # cache NTFS na maksa
    Set-Reg $fs DontVerifyRandomDrivers 1 DWord
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' WaitToKillServiceTimeout 2000 String
    Set-Reg 'HKCU:\Control Panel\Desktop' WaitToKillAppTimeout 2000 String
    Set-Reg 'HKCU:\Control Panel\Desktop' HungAppTimeout 2000 String
    Set-Reg 'HKCU:\Control Panel\Desktop' AutoEndTasks '1' String
    Set-Reg $fs NtfsDisable8dot3NameCreation 2 DWord
    Write-Ok 'SSD optymalizacja, szybkie wylaczanie (2s).'; Add-Applied 'ssd-tweaks'
}
function Disable-EdgePreload {
    Write-Step 'Edge Startup Boost i widgety OFF'
    Ensure-Backup
    $edge='HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    if(-not (Test-Path $edge)){New-Item $edge -Force | Out-Null}
    Set-Reg $edge StartupBoostEnabled 0 DWord
    Set-Reg $edge BackgroundModeEnabled 0 DWord
    Set-Reg $edge HardwareAccelerationModeEnabled 1 DWord
    # Wylacz dostepne uslugi widgetow i zapisz ich poprzedni tryb uruchamiania.
    Set-Svc Widgets Disabled 'Widgets' -ErrorAction SilentlyContinue
    Set-Svc WidgetService Disabled 'Widgets' -ErrorAction SilentlyContinue
    Write-Ok 'Edge Startup Boost OFF.'; Add-Applied 'edge-preload'
}
function Disable-WUDriverUpdates {
    Write-Step 'WU: blokada nadpisywania sterownikow GPU'
    Ensure-Backup
    $wu='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    if(-not (Test-Path $wu)){New-Item $wu -Force | Out-Null}
    Set-Reg $wu ExcludeWUDriversInQualityUpdate 1 DWord
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' SearchOrderConfig 0 DWord
    Write-Ok 'WU nie bedzie nadpisywal sterownikow GPU.'; Add-Applied 'wu-drivers'
}
function Set-GameServerPing {
    Write-Step 'Ping do serwerow gier'
    $servers = @(
        @{N='CS2 Warszawa';H='146.66.152.1'},
        @{N='CS2 Frankfurt';H='146.66.155.1'},
        @{N='Valorant Warszawa';H='185.46.228.2'},
        @{N='Valorant Frankfurt';H='92.204.195.2'},
        @{N='Fortnite EU';H='3.251.8.1'},
        @{N='LoL EUNE';H='185.40.64.1'},
        @{N='Discord EU';H='162.159.128.233'},
        @{N='Steam PL';H='146.66.152.3'}
    )
    Write-Host ''
    foreach($t in $servers){
        try {
            $r=Test-Connection -ComputerName $t.H -Count 3 -ErrorAction Stop
            $pings=$r.ResponseTime|Where-Object{$_ -gt 0}
            if($pings){
                $avg=[math]::Round(($pings|Measure-Object -Average).Average,1)
                $min=($pings|Measure-Object -Minimum).Minimum
                $max=($pings|Measure-Object -Maximum).Maximum
                $jitter=[math]::Round(($pings|ForEach-Object -Begin {$l=$null}{if($l){[math]::Abs($_-$l)}$l=$_}|Measure-Object -Average).Average,1)
                $color=if($avg -lt 30 -and $jitter -lt 4){'Green'}elseif($avg -lt 70){'Yellow'}else{'Red'}
                Write-Host "   $($t.N)".PadRight(22) -ForegroundColor White -NoNewline
                Write-Host "avg=$avg  min=$min  max=$max  jitter=$jitter ms" -ForegroundColor $color
            } else { Write-Host "   $($t.N): timeout" -ForegroundColor Red }
        } catch { Write-Host "   $($t.N): nieosiagalny" -ForegroundColor DarkGray }
    }
    Wait-Enter
}
function Copy-HwidToClipboard {
    try {
        Set-Clipboard -Value $script:Hwid -ErrorAction Stop
        Write-Ok "HWID $script:Hwid skopiowany do schowka!"
    } catch { Write-Warn 'Nie mozna skopiowac - zaznacz i skopiuj recznie.' }
    Start-Sleep 1
}
function Disable-SpectreMeltdown {
    Write-Step 'Spectre/Meltdown mitigations OFF (+5-15% FPS, restart)'
    Write-Warn 'OBNIZA BEZPIECZENSTWO SYSTEMU (wylacza zabezpieczenia procesora).'
    Write-Warn 'Na wlasne ryzyko! Wymaga restartu.'
    if(-not (Read-YesNo 'NA PEWNO wylaczyc mitigations?')){ return }
    Ensure-Backup
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' FeatureSettingsOverride 3 DWord
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' FeatureSettingsOverrideMask 3 DWord
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' EnableVirtualizationBasedSecurity 0 DWord
    & bcdedit /set nx AlwaysOff 2>&1 | Out-Null
    $script:RebootNeeded=$true; Add-Applied 'adv-spectre'
    Write-Ok 'Mitigations OFF - restart po zakonczeniu.'
}
function Set-MouseMenuDelay {
    Write-Step 'Mysz: 0ms opoznienia menu'
    Ensure-Backup
    Set-Reg 'HKCU:\Control Panel\Desktop' MenuShowDelay 0 String
    Set-Reg 'HKCU:\Control Panel\Mouse' MouseHoverTime 0 String
    Set-Reg 'HKCU:\Control Panel\Mouse' DoubleClickSpeed 50 String
    Write-Ok 'MenuShowDelay=0, MouseHoverTime=0.'; Add-Applied 'mouse-menu'
}
function Disable-TelemetryHosts {
    Write-Step 'Telemetria: blokada domen w hosts + wylaczenie zadan'
    Ensure-Backup
    $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
    # Zachowaj pierwszy, niezmodyfikowany hosts. Nadpisywanie backupu przy kolejnym
    # uruchomieniu uniemozliwialo poprawne cofniecie zmian.
    $hostsBackup = "$hostsFile.d01i.bak"
    if (-not (Test-Path -LiteralPath $hostsBackup)) {
        Copy-Item -LiteralPath $hostsFile -Destination $hostsBackup -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $hostsBackup) {
        $script:State.HostsBackupFile = $hostsBackup
        Save-State
    }
    $blocked = @(
        'vortex.data.microsoft.com','vortex-win.data.microsoft.com','telecommand.telemetry.microsoft.com',
        'telecommand.telemetry.microsoft.com.nsatc.net','oca.telemetry.microsoft.com',
        'oca.telemetry.microsoft.com.nsatc.net','sqm.telemetry.microsoft.com','sqm.telemetry.microsoft.com.nsatc.net',
        'watson.telemetry.microsoft.com','watson.telemetry.microsoft.com.nsatc.net','redir.metaservices.microsoft.com',
        'choice.microsoft.com','choice.microsoft.com.nsatc.net','df.telemetry.microsoft.com',
        'reports.wes.df.telemetry.microsoft.com','wes.df.telemetry.microsoft.com','telemetry.microsoft.com',
        'services.wes.df.telemetry.microsoft.com','sqm.df.telemetry.microsoft.com','corpext.msitadfs.glbdns2.microsoft.com',
        'cs1.wpc.v0cdn.net','db5wns1b2w.nsatc.net','fe2.update.microsoft.com.akadns.net','sls.update.microsoft.com.akadns.net',
        'diagnostics.support.microsoft.com','corp.sms.phicdn.net','feedback.microsoft-hohm.com',
        'feedback.search.microsoft.com','rad.microsoft.com','preview.msn.com','i1.services.social.microsoft.com',
        'i1.services.social.microsoft.com.nsatc.net','feedback.windows.com','ca.telemetry.microsoft.com',
        'oca.microsoft.com','watson.live.com','watson.microsoft.com','statsfe1.ws.microsoft.com','statsfe2.ws.microsoft.com',
        'survey.watson.microsoft.com','watsonline.microsoft.com','watson.ppe.telemetry.microsoft.com',
        'telemetry.appex.bing.net','telemetry.urs.microsoft.com','settings-sandbox.data.microsoft.com',
        'watson.microsoft.com','vortex.bing.com','vortex.data.glbdns2.microsoft.com',
        'login.live.com'
    )
    try {
        $existing = Get-Content $hostsFile -ErrorAction SilentlyContinue
        $toAdd = New-Object System.Collections.ArrayList
        foreach ($dom in $blocked) {
            if (($existing | Where-Object { $_ -match $dom } | Measure-Object).Count -eq 0) {
                [void]$toAdd.Add("0.0.0.0 $dom")
            }
        }
        if ($toAdd.Count -gt 0) {
            $newContent = $existing + "# d01i tweakz p telemetry block begin" + $toAdd + "# d01i tweakz p telemetry block end"
            $newContent | Set-Content $hostsFile -Encoding ASCII -Force
            Write-Ok "Dodano $($toAdd.Count) domen telemetrycznych do hosts."
        } else { Write-Ok 'Domeny telemetryczne juz zablokowane.' }
    } catch { Write-Warn "Brak uprawnien do zapisu hosts: $($_.Exception.Message)" }
    # Wszystkie zadania telemetrii poza tymi z base
    $exTasks = @(
        '\Microsoft\Windows\Application Experience\AitAgent',
        '\Microsoft\Windows\Application Experience\PcaPatchDbTask',
        '\Microsoft\Windows\Application Experience\StartupAppTask',
        '\Microsoft\Windows\Autoplay\Microsoft Autoplay Repair',
        '\Microsoft\Windows\Bluetooth\UninstallDeviceTask',
        '\Microsoft\Windows\Chkdsk\ProactiveScan',
        '\Microsoft\Windows\Customer Experience Improvement Program\BthSQM',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\CreateObjectTask',
        '\Microsoft\Windows\Customer Experience Improvement Program\Uploader',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticResolver',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
        '\Microsoft\Windows\NetTrace\GatherNetworkInfo',
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
    )
    foreach ($t in $exTasks) { Set-Task $t Disable }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' AllowTelemetry 0 DWord
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' AllowTelemetry 0 DWord
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds' AllowBuildPreview 0 DWord
    Add-Applied 'telemetry-block'
}
function Add-GameDefenderExclusions {
    Write-Step 'Defender: wykluczenia dla Steam/Epic/Riot/Battle.net (NIE wylaczam AV)'
    Ensure-Backup
    $candidates = @(
        "${env:ProgramFiles(x86)}\Steam",
        "$env:ProgramFiles\Steam",
        "$env:ProgramFiles\Epic Games",
        "${env:ProgramFiles(x86)}\Epic Games",
        "$env:ProgramFiles\Riot Games",
        "${env:ProgramFiles(x86)}\Riot Games",
        "${env:ProgramFiles(x86)}\Battle.net",
        "$env:ProgramFiles\Battle.net",
        "$env:ProgramFiles\Ubisoft\Ubisoft Game Launcher",
        "${env:ProgramFiles(x86)}\Ubisoft\Ubisoft Game Launcher",
        "$env:ProgramFiles\EA Games",
        "$env:USERPROFILE\Saved Games",
        "$env:LOCALAPPDATA\Valorant",
        "$env:LOCALAPPDATA\Counter-Strike 2"
    )
    try { $preferences = Get-MpPreference -ErrorAction Stop } catch { Write-Warn 'Nie mozna odczytac ustawien Defendera.'; return }
    $existingPaths = @($preferences.ExclusionPath)
    $existingProcesses = @($preferences.ExclusionProcess)
    $added=0
    foreach ($p in $candidates) {
        if ((Test-Path -LiteralPath $p) -and $existingPaths -notcontains $p) {
            try {
                Add-MpPreference -ExclusionPath $p -ErrorAction Stop
                $script:State.DefenderExclusions += [pscustomobject]@{Type='Path';Value=$p}
                $existingPaths += $p
                $added++
            } catch { Write-Warn "Nie dodano wykluczenia Defendera: $p" }
        }
    }
    foreach ($proc in @('cs2.exe','valorant-win64-shipping.exe','fortniteclient-win64-shipping.exe','r5apex.exe','escapefromtarkov.exe')) {
        if ($existingProcesses -notcontains $proc) {
            try {
                Add-MpPreference -ExclusionProcess $proc -ErrorAction Stop
                $script:State.DefenderExclusions += [pscustomobject]@{Type='Process';Value=$proc}
                $existingProcesses += $proc
                $added++
            } catch { Write-Warn "Nie dodano wykluczenia procesu Defendera: $proc" }
        }
    }
    Save-State
    Write-Ok "Dodano $added wykluczen dla gier w Defenderze."
    Add-Applied 'defender-excl'
}
function Disable-AllNotifications {
    Write-Step 'System: wszystkie powiadomienia/Focus Assist ON'
    Ensure-Backup
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' ToastEnabled 0 DWord
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' DisableNotificationCenter 1 DWord
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' EnableBalloonTips 0 DWord
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudNotifications' DisableCloudNotifications 1 DWord
    # Focus assist always on - alarms only. Nie zapisujemy wartosci domyslnej w CloudStore,
    # poniewaz jest to cache zarzadzany przez Windows i wpis nie steruje tym ustawieniem.
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\QuietHours' Enabled 1 DWord
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' NOC_GLOBAL_SETTING_TOASTS_ENABLED 0 DWord
    Write-Ok 'Wszystkie powiadomienia wylaczone, Focus Assist ON.'; Add-Applied 'notif-off'
}
function Disable-Maintenance {
    Write-Step 'System: wylaczenie automatycznej konserwacji w tle'
    Ensure-Backup
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' MaintenanceDisabled 1 DWord
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' WakeUp 0 DWord
    # Wylacz defrag automatyczny i zapisz stan zadania do cofniecia.
    Set-Task '\Microsoft\Windows\Defrag\ScheduledDefrag' Disable
    Write-Ok 'Automatyczna konserwacja i defrag w tle OFF.'; Add-Applied 'maint-off'
}
function Block-WU-Completely {
    Write-Step 'WU: BLOKADA trwala (nie tylko 30 dni)'
    Ensure-Backup
    Set-Svc wuauserv Disabled 'Windows Update'
    Set-Svc UsoSvc Disabled 'Update Orchestrator'
    Set-Svc WaaSMedicSvc Disabled 'WaaS Medic'
    Set-Svc dosvc Disabled 'Delivery Optimization'
    Set-Task '\Microsoft\Windows\WindowsUpdate\Scheduled Start' Disable
    Set-Task '\Microsoft\Windows\WindowsUpdate\sih' Disable
    Set-Task '\Microsoft\Windows\WindowsUpdate\sihboot' Disable
    Set-Task '\Microsoft\Windows\UpdateOrchestrator\Policy Install' Disable
    Set-Task '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan' Disable
    Set-Task '\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker' Disable
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' NoAutoUpdate 1 DWord
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' AUOptions 2 DWord
    Write-Ok 'WU zablokowany trwale (odblokuj recznie w services.msc).'; Add-Applied 'wu-block'
}
function Invoke-AggressiveMode {
    Write-Step 'TRYB AGRESYWNY (zabija explorer.exe podczas gry)'
    Write-Warn 'Zamyka EXPLORER.EXE (pasek zadan/pulpit/eksplorator plikow) podczas gry.'
    Write-Warn 'Sugerowane dla slabych komputerow (dodatkowe 1-3% FPS i mniej nakladek).'
    if(-not (Read-YesNo 'Wlaczyc tryb agresywny?')){ return }
    Ensure-Backup
    $scriptPath = Join-Path $script:Root 'd01i_aggressive.ps1'
    @'
param([string]$GameExe)
if(-not $GameExe){
    $games='cs2','valorant-win64-shipping','fortniteclient-win64-shipping','r5apex','escapefromtarkov','leagueclient','overwatch','rainbowsix','pubg','dota2','gta5','gtav'
} else { $games=@($GameExe) }
Write-Host "Aggressive mode: czekam na gre..." -ForegroundColor Cyan
$explorerKilled=$false
while($true){
    $found=$false
    foreach($g in $games){
        $p=Get-Process -Name $g -ErrorAction SilentlyContinue | Select-Object -First 1
        if($p){ $found=$true; break }
    }
    if($found -and -not $explorerKilled){
        Write-Host "Gra wykryta! Zamykanie explorer.exe..." -ForegroundColor Yellow
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        $explorerKilled=$true
    }
    if(-not $found -and $explorerKilled){
        Write-Host "Gra zamknieta - przywracanie explorer.exe..." -ForegroundColor Green
        Start-Process explorer.exe
        $explorerKilled=$false
    }
    Start-Sleep -Seconds 5
}
'@ | Set-Content $scriptPath -Encoding UTF8
    $bat = Join-Path $script:Root 'TRYB_AGRESYWNY.bat'
    "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"`r`n" | Set-Content $bat -Encoding ASCII
    Write-Ok "Skrypt agresywny zapisany: $bat"
    Write-Info 'Uruchom TRYB_AGRESYWNY.bat przed gra, a po zamknieciu gry explorer sie przywroci.'
    Add-Applied 'aggressive'
}
function Test-NetworkPing {
    Write-Step 'Test pingu i jittera'
    $targets = @(
        @{N='Brama domowa';H=(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop},
        @{N='Cloudflare';H='1.1.1.1'},
        @{N='Google';H='8.8.8.8'},
        @{N='Quad9';H='9.9.9.9'},
        @{N='OpenDNS';H='208.67.222.222'}
    )
    Write-Host ''
    foreach($t in $targets){
        if(-not $t.H){ continue }
        $r=Test-Connection -ComputerName $t.H -Count 5 -ErrorAction SilentlyContinue
        if($r){
            $pings = $r.ResponseTime | Where-Object { $_ -gt 0 }
            if($pings){
                $avg=[math]::Round(($pings|Measure-Object -Average).Average,1)
                $min=($pings|Measure-Object -Minimum).Minimum
                $max=($pings|Measure-Object -Maximum).Maximum
                $jitter=[math]::Round(($pings|ForEach-Object -Begin {$l=$null}{if($l){[math]::Abs($_-$l)}$l=$_}|Measure-Object -Average).Average,1)
                $loss=(5-$pings.Count)*20
                $color=if($avg -lt 30 -and $jitter -lt 5){'Green'}elseif($avg -lt 80){'Yellow'}else{'Red'}
                Write-Host "   $($t.N)".PadRight(18) -ForegroundColor White -NoNewline
                Write-Host " avg=$avg ms  min=$min  max=$max  jitter=$jitter  loss=$loss%" -ForegroundColor $color
            } else { Write-Host "   $($t.N): straty/timeout" -ForegroundColor Red }
        } else { Write-Host "   $($t.N): nieosiagalny" -ForegroundColor DarkGray }
    }
    Wait-Enter
}
function Restore-RegistryUndo {
    foreach ($entry in @($script:State.RegUndo)) {
        if (-not $entry.Path) { continue }
        try {
            if ([bool]$entry.HadValue) {
                if (-not (Test-Path -LiteralPath $entry.Path)) { New-Item -Path $entry.Path -Force -ErrorAction Stop | Out-Null }
                $value = $entry.OldValue
                if ($entry.OldType -eq 'Binary' -and $null -ne $value) { $value = [byte[]]@($value | ForEach-Object { [byte]$_ }) }
                if ($entry.Name -eq '(default)') {
                    Set-Item -LiteralPath $entry.Path -Value $value -Type $entry.OldType -Force -ErrorAction Stop | Out-Null
                } else {
                    New-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $value -PropertyType $entry.OldType -Force -ErrorAction Stop | Out-Null
                }
            } elseif (Test-Path -LiteralPath $entry.Path) {
                Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Force -ErrorAction SilentlyContinue
            }
        } catch { Write-Warn "Nie przywrocono REG $($entry.Path)\$($entry.Name): $($_.Exception.Message)" }
    }
}
function Restore-CreatedRegistryKeys {
    # Usuwamy tylko klucze utworzone przez skrypt; istniejacych wczesniej nie dotykamy.
    foreach ($path in @($script:State.CreatedRegistryKeys | Sort-Object Length -Descending)) {
        try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
        catch { Write-Warn "Nie usunieto utworzonego klucza REG: $path" }
    }
}
function Restore-ServiceUndo {
    foreach ($entry in @($script:State.ServiceUndo)) {
        $mode = switch -Regex ([string]$entry.OldMode) {
            '^(Auto|Automatic)$' { 'Automatic'; break }
            '^(Manual|Demand)$' { 'Manual'; break }
            '^Disabled$' { 'Disabled'; break }
            default { $null }
        }
        if (-not $mode) { continue }
        try {
            Set-Service -Name $entry.Name -StartupType $mode -ErrorAction Stop
            if ($entry.WasRunning -eq $true) { Start-Service -Name $entry.Name -ErrorAction SilentlyContinue }
        } catch { Write-Warn "Nie przywrocono uslugi $($entry.Name)." }
    }
}
function Restore-TaskUndo {
    foreach ($full in @($script:State.DisabledTasks)) {
        if (-not $full) { continue }
        $lastSlash = $full.LastIndexOf('\')
        if ($lastSlash -lt 0) { continue }
        $taskPath = $full.Substring(0, $lastSlash + 1)
        $taskName = $full.Substring($lastSlash + 1)
        try { Enable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Out-Null }
        catch { Write-Warn "Nie przywrocono zadania $full." }
    }
}
function Restore-DefenderUndo {
    foreach ($entry in @($script:State.DefenderExclusions)) {
        try {
            if ($entry.Type -eq 'Path') { Remove-MpPreference -ExclusionPath $entry.Value -ErrorAction Stop }
            elseif ($entry.Type -eq 'Process') { Remove-MpPreference -ExclusionProcess $entry.Value -ErrorAction Stop }
        } catch { Write-Warn "Nie usunieto wykluczenia Defendera: $($entry.Value)" }
    }
}
function Invoke-Undo {
    Write-Step 'COFANIE WSZYSTKICH ZMIAN'
    Write-Warn 'Przywraca zapisane ustawienia rejestru, uslug, zadan i wykluczen Defendera.'
    if(-not (Read-YesNo 'NA PEWNO cofnac wszystkie zmiany?')){ return }

    if($script:State.LastBackupDir -and (Test-Path -LiteralPath $script:State.LastBackupDir)){
        Write-Host '   Przywracam backup rejestru...' -ForegroundColor Cyan
        Get-ChildItem -LiteralPath $script:State.LastBackupDir -Filter *.reg -ErrorAction SilentlyContinue | ForEach-Object {
            & reg.exe import $_.FullName 2>&1 | Out-Null
        }
        Write-Ok 'Backup rejestru przywrocony.'
    }
    Restore-RegistryUndo
    Restore-CreatedRegistryKeys
    Restore-ServiceUndo
    Restore-TaskUndo
    Restore-DefenderUndo

    if ($script:State.HostsBackupFile -and (Test-Path -LiteralPath $script:State.HostsBackupFile)) {
        try {
            Copy-Item -LiteralPath $script:State.HostsBackupFile -Destination "$env:SystemRoot\System32\drivers\etc\hosts" -Force -ErrorAction Stop
            Write-Ok 'Plik hosts przywrocony.'
        } catch { Write-Warn 'Nie przywrocono pliku hosts.' }
    }
    try { Unregister-ScheduledTask -TaskName $script:AutoRunTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) 'd01i_PRO_autorun.bat') -Force -ErrorAction SilentlyContinue

    if ($script:State.HibernationWasEnabled -eq $true) { & powercfg.exe /hibernate on 2>&1 | Out-Null }
    elseif ($script:State.HibernationWasEnabled -eq $false) { & powercfg.exe /hibernate off 2>&1 | Out-Null }
    if ($script:State.MemoryCompressionWasEnabled -eq $true) { Enable-MMAgent -mc -ErrorAction SilentlyContinue }
    elseif ($script:State.MemoryCompressionWasEnabled -eq $false) { Disable-MMAgent -mc -ErrorAction SilentlyContinue }
    if ($script:State.PreviousPowerScheme) { & powercfg.exe /setactive $script:State.PreviousPowerScheme 2>&1 | Out-Null }

    # Usuwamy tylko wartosci BCD ustawiane przez ten skrypt.
    foreach ($setting in @('useplatformclock','useplatformtick','disabledynamictick','tscsyncpolicy','numproc','nx','hypervisorlaunchtype')) {
        & bcdedit.exe /deletevalue '{current}' $setting 2>&1 | Out-Null
    }

    $script:State = [ordered]@{
        Version='2.5'; LastBackupDir=''; RegUndo=@(); ServiceUndo=@(); DisabledTasks=@()
        VbsDisabled=$false; CreatedUltimate=$false; UltimateSchemeGuid=''; PreviousPowerScheme=''
        HibernationWasEnabled=$null; MemoryCompressionWasEnabled=$null; Applied=@(); MsiTouched=@(); DefenderExclusions=@(); HostsBackupFile=''; CreatedRegistryKeys=@()
    }
    Save-State
    $script:BackupDone=$false
    $script:RebootNeeded=$true
    Write-Host ''
    Write-Ok 'Zapisane zmiany zostaly cofniete. Zrestartuj komputer.'
    if(Read-YesNo 'Zrestartowac TERAZ?'){ Restart-Computer -Force }
}

function Set-Nvidia {
    Write-Step 'NVIDIA: uslugi w tle -> Manual'
    Set-Svc NVDisplay.ContainerLocalSystem Manual 'NVIDIA Container'
    Set-Svc NvTelemetryContainer Disabled 'NVIDIA telemetria'
    Add-Applied 'gpu-nv'
}
function Set-Amd {
    Write-Step 'AMD: External Events -> Manual'
    Set-Svc 'AMD External Events Utility' Manual
    Add-Applied 'gpu-amd'
}
function Set-Hags {
    Write-Step 'GPU: HAGS ON'
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' HwSchMode 2 DWord
    Write-Ok 'HAGS wlaczony (restart wymagany).'
    $script:RebootNeeded=$true; Add-Applied 'gpu-hags'
}
function Clear-Shaders {
    Write-Step 'Cache shaderow i Temp'
    $paths = @(
        "$env:LOCALAPPDATA\NVIDIA\DXCache",
        "$env:LOCALAPPDATA\NVIDIA\GLCache",
        "$env:LOCALAPPDATA\NVIDIA Corporation\NV_Cache",
        "$env:LOCALAPPDATA\AMD\DxCache",
        "$env:LOCALAPPDATA\AMD\GLCache",
        "$env:LOCALAPPDATA\D3DSCache",
        "$env:TEMP"
    )
    $sum=0
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $s = [math]::Round(((Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum/1MB),1)
            Remove-Item "$p\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok "$(Split-Path $p -Leaf): $s MB"
            $sum+=$s
        }
    }
    Write-Ok "Zwolniono $([math]::Round($sum,1)) MB."; Add-Applied 'clean-cache'
}
function Invoke-KillMode {
    Write-Step 'KILL MODE: zamykanie procesow w tle (NIE rusza Discorda/Steama/przegladarek)'
    if (-not $script:Licensed) { Write-Err 'Tylko w pelnej wersji!'; return }
    # TYLKO syf ktory NIE jest potrzebny w tle podczas gry - nie zabijamy komunikatorow/przegladarek
    $killList = @(
        'OneDrive','OneDriveSetup','Teams','CCXProcess','CoreSync','AdobeIPCBroker',
        'GoogleUpdate','EpicWebHelper','EpicGamesLauncher','Battle.net','SteamWebHelper',
        'SearchHost','StartMenuExperienceHost','WidgetService','Widgets','GameBar','GameDVR',
        'GameBarFTServer','OfficeClickToRun','TeamViewer','AnyDesk','SkypeApp',
        'Mozilla Firefox Crash Reporter','DiscordCanary','DiscordPTB',
        'Cortana','CompatTelRunner','wsappx','Clipchamp','Telemetry','NvTelemetryContainer',
        'Razer Central','Razer Synapse','Razer Chroma SDK','Razer Chroma Host',
        'LogiRegistryService','LogiOptions','LGHUB'
    )
    $k=0
    $beforeRam = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
    foreach ($pn in $killList) {
        Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; $k++ } catch {}
        }
    }
    Clear-Ram
    $afterRam = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
    $freedMb = [math]::Round(($afterRam-$beforeRam)/1024,0)
    Write-Ok "Zamknieto procesow: $k, zwolniono ok. $freedMb MB RAM."; Add-Applied 'kill-mode'
}
function Disable-Vbs {
    Write-Step 'VBS/HVCI/Core Isolation: wylaczenie'
    Write-Warn 'Obniza bezpieczenstwo, ale daje +5-15% FPS.'
    if (-not (Read-YesNo 'Wylaczyc VBS/HVCI? (restart)')) { return }
    Ensure-Backup
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' EnableVirtualizationBasedSecurity 0 DWord
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' Enabled 0 DWord
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard' Enabled 0 DWord
    & bcdedit.exe /set {current} hypervisorlaunchtype off | Out-Null
    $script:State.VbsDisabled=$true; Save-State
    Write-Ok 'VBS/HVCI wylaczone.'
    $script:RebootNeeded=$true; Add-Applied 'adv-vbs'
}

# ====================== SELF-TEST ======================
function Invoke-SelfTest {
    Show-Banner; Show-Section 'SELF-TEST'
    $res = New-Object System.Collections.ArrayList
    function CK($cat,$name,$ok,$exp='',$act='') {
        [void]$res.Add([pscustomobject]@{Cat=$cat;Name=$name;OK=$ok;Exp=$exp;Act=$act})
    }
    function GW($p,$n){ try { [int64](Get-ItemProperty -LiteralPath $p -Name $n -ErrorAction Stop).$n } catch { return $null } }
    function GS($p,$n){ try { [string](Get-ItemProperty -LiteralPath $p -Name $n -ErrorAction Stop).$n } catch { return $null } }

    $cat='Zasilanie'
    try { $a=& powercfg.exe /getactivescheme; CK $cat 'Plan Ultimate/High/Ryzen' ($a -match 'e9a42b02|Ultimate|Ryzen|Wysoka') 'Ultimate' ($a -replace '^.*:\s*','') } catch {}
    CK $cat 'Hibernacja wylaczona' (-not (Test-Path "$env:SystemDrive\hiberfil.sys")) 'wyl' 'wl'

    $cat='MMCSS/Rejestr'
    $mp='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    CK $cat 'SystemResponsiveness=0' ((GW $mp SystemResponsiveness) -eq 0) '0' (GW $mp SystemResponsiveness)
    CK $cat 'NetworkThrottling=-1' ((GW $mp NetworkThrottlingIndex) -eq 0xFFFFFFFF) 'FFFFFFFF' (GW $mp NetworkThrottlingIndex)
    CK $cat 'Win32PrioritySeparation=42' ((GW 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' Win32PrioritySeparation) -eq 42) '42' (GW 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' Win32PrioritySeparation)
    CK $cat 'GameDVR off' ((GW 'HKCU:\System\GameConfigStore' GameDVR_Enabled) -eq 0) '0' (GW 'HKCU:\System\GameConfigStore' GameDVR_Enabled)
    CK $cat 'GameMode on' ((GW 'HKCU:\SOFTWARE\Microsoft\GameBar' AutoGameModeEnabled) -eq 1) '1' (GW 'HKCU:\SOFTWARE\Microsoft\GameBar' AutoGameModeEnabled)

    $cat='Mysz'
    CK $cat 'MouseSpeed=0 (1:1)' ((GS 'HKCU:\Control Panel\Mouse' MouseSpeed) -eq '0') '0' (GS 'HKCU:\Control Panel\Mouse' MouseSpeed)

    $cat='Siec'
    CK $cat 'TCPNoDelay=1' ((GW 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' TCPNoDelay) -eq 1) '1' (GW 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' TCPNoDelay)
    CK $cat 'QoS NonBestEffort=0' ((GW 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' NonBestEffortLimit) -eq 0) '0' (GW 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' NonBestEffortLimit)

    $cat='GPU'
    CK $cat 'HAGS=2' ((GW 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' HwSchMode) -eq 2) '2' (GW 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' HwSchMode)

    $cat='Uslugi'
    foreach ($sv in 'DiagTrack','XblAuthManager','MapsBroker') {
        $s=Get-CimInstance Win32_Service -Filter "Name='$sv'" -ErrorAction SilentlyContinue
        if ($s){ CK $cat "$sv disabled" ($s.StartMode -eq 'Disabled') 'Disabled' $s.StartMode }
    }

    $tot=0; $pass=0; $fail=0
    foreach($x in $res){$tot++; if($x.OK){$pass++}else{$fail++}}

    foreach($g in ($res|Group-Object Cat)){
        Write-Host "   [$($g.Name)]" -ForegroundColor Cyan
        foreach($x in $g.Group){
            $m = if($x.OK){'[+] PASS'}else{'[X] FAIL'}
            $c = if($x.OK){'Green'}else{'Red'}
            Write-Host "     $m  $($x.Name)" -ForegroundColor $c
            if(-not $x.OK){ Write-Host "            oczekiwane: $($x.Exp)  |  aktualne: $($x.Act)  |  naprawa: opcja [01]" -ForegroundColor DarkYellow }
        }
        Write-Host ''
    }
    Write-Host ('  ' + ('-'*72)) -ForegroundColor DarkGray
    Write-Host "   Podsumowanie: $pass/$tot OK" -ForegroundColor $(if($fail){'Yellow'}else{'Green'})
    if($fail -gt 0){
        Write-Host "   Bledne: $fail" -ForegroundColor Red
        if(Read-YesNo 'Uruchomic naprawe?') { Invoke-FullProfile }
    } else { Write-Host '   Wszystkie optymalizacje AKTYWNE.' -ForegroundColor Green }
    Wait-Enter
}

# ====================== FULL PROFILE ======================
function Show-Progress {
    param(
        [int]$Step,
        [int]$Total,
        [string]$Label
    )
    if ($Total -le 0) { $Total = 1 }
    $pct = [Math]::Min([Math]::Max([int](($Step / [double]$Total) * 100), 0), 100)
    $filled = [Math]::Min(50, [int][Math]::Floor($pct / 2))
    # ASCII bar avoids console-encoding/parser problems in legacy Windows PowerShell hosts.
    $bar = ('#' * $filled) + ('.' * (50 - $filled))
    Write-Host ('   [{0}] {1}%  {2}' -f $bar, $pct, $Label) -NoNewline -ForegroundColor Green
    if ($Step -ge $Total) { Write-Host '' }
}
function Invoke-ProfileSafe {
    Write-Step 'PROFIL SAFE - bezpieczny (polecany na start / laptopy)'
    if(-not $script:Licensed){ Write-Err 'Tylko w pelnej wersji!'; return }
    $total=12; $i=0
    Show-Progress (++$i) $total 'Backup...'; Ensure-Backup
    Show-Progress (++$i) $total 'Plan Ultimate...'; Enable-Ultimate
    Show-Progress (++$i) $total 'MMCSS...'; Set-Mmcss
    Show-Progress (++$i) $total 'Priorytety...'; Set-Priority
    Show-Progress (++$i) $total 'Mouse fix...'; Set-MouseFix
    Show-Progress (++$i) $total 'Timer 0.5ms...'; Set-Timer05
    Show-Progress (++$i) $total 'TCP/IP safe...'; Set-Network
    Show-Progress (++$i) $total 'HAGS...'; Set-Hags
    Show-Progress (++$i) $total 'Cache...'; Clear-Shaders
    Show-Progress (++$i) $total 'RAM...'; Clear-Ram
    Show-Progress (++$i) $total 'Edge preload off...'; Disable-EdgePreload
    Show-Progress (++$i) $total 'Discord accel off...'; Disable-DiscordAccel
    Add-Applied 'profile-safe'; Save-State
    Show-Progress $total $total 'Gotowe SAFE!'
    Write-Host ''; Write-Ok 'PROFIL SAFE zastosowany! (bezpieczny, latwo cofnac [16])'
    Write-Info 'Restart zalecany.'
    Wait-Enter
}
function Invoke-ProfileBalanced {
    Write-Step 'PROFIL BALANCED - zbalansowany (polecany 90% graczy)'
    if(-not $script:Licensed){ Write-Err 'Tylko w pelnej wersji!'; return }
    $total=22; $i=0
    Show-Progress (++$i) $total 'Backup...'; Ensure-Backup
    Show-Progress (++$i) $total 'Plan Ultimate...'; Enable-Ultimate
    Show-Progress (++$i) $total 'Hibernacja off...'; Disable-Hibernation
    Show-Progress (++$i) $total 'MMCSS...'; Set-Mmcss
    Show-Progress (++$i) $total 'Priorytety...'; Set-Priority
    Show-Progress (++$i) $total 'CPU MaxPerf...'; Set-MaxPerf
    Show-Progress (++$i) $total 'Timer...'; Set-Timer05
    Show-Progress (++$i) $total 'USB off...'; Disable-USBSelectiveSuspend
    Show-Progress (++$i) $total 'Mouse fix...'; Set-MouseFix
    Show-Progress (++$i) $total 'TCP/IP...'; Set-Network
    Show-Progress (++$i) $total 'Auto DNS...'; Set-AutoDns
    Show-Progress (++$i) $total 'MSI Mode...'; Set-MsiMode
    Show-Progress (++$i) $total 'Uslugi base...'; Disable-BaseSvc
    Show-Progress (++$i) $total 'HAGS...'; Set-Hags
    Show-Progress (++$i) $total 'Fullscreen Opt...'; Disable-FullscreenOpt
    Show-Progress (++$i) $total 'SSD tweaks...'; Set-SSDTweaks
    Show-Progress (++$i) $total 'Cache...'; Clear-Shaders
    Show-Progress (++$i) $total 'RAM...'; Clear-Ram
    Show-Progress (++$i) $total 'Smart ISLC...'; Invoke-SmartISLC
    Show-Progress (++$i) $total 'Game Priority...'; Invoke-GamePriorityWatcher
    Show-Progress (++$i) $total 'Autostart...'; Set-AutostartGame
    Add-Applied 'profile-balanced'; Save-State
    Show-Progress $total $total 'Gotowe BALANCED!'
    Write-Host ''; Write-Ok 'PROFIL BALANCED zastosowany!'
    Write-Info 'Restart zalecany.'
    Wait-Enter
}
function Invoke-ProfileAdvanced {
    Write-Step 'PROFIL ADVANCED - zaawansowany (wiecej FPS, wiecej zmian)'
    if(-not $script:Licensed){ Write-Err 'Tylko w pelnej wersji!'; return }
    Write-Warn 'Zawiera: NDIS latency, Visual FX off, Powiadomienia off, WU pause.'
    if(-not (Read-YesNo 'Kontynuowac ADVANCED?')){ return }
    $total=32; $i=0
    Show-Progress (++$i) $total 'Backup...'; Ensure-Backup
    Show-Progress (++$i) $total 'Plan Ultimate...'; Enable-Ultimate
    Show-Progress (++$i) $total 'Hibernacja off...'; Disable-Hibernation
    Show-Progress (++$i) $total 'MMCSS...'; Set-Mmcss
    Show-Progress (++$i) $total 'Priorytety...'; Set-Priority
    Show-Progress (++$i) $total 'CPU MaxPerf...'; Set-MaxPerf
    Show-Progress (++$i) $total 'Timer...'; Set-Timer05
    Show-Progress (++$i) $total 'Core Parking...'; Disable-CoreParking
    Show-Progress (++$i) $total 'CPU latency...'; Set-CstateOff
    Show-Progress (++$i) $total 'USB...'; Disable-USBSelectiveSuspend
    Show-Progress (++$i) $total 'Mouse...'; Set-MouseFix
    Show-Progress (++$i) $total 'Mouse delay...'; Set-MouseMenuDelay
    Show-Progress (++$i) $total 'TCP/IP...'; Set-Network
    Show-Progress (++$i) $total 'Auto DNS...'; Set-AutoDns
    Show-Progress (++$i) $total 'NDIS latency...'; Set-NetworkLatency
    Show-Progress (++$i) $total 'Sticky Keys...'; Disable-StickyKeys
    Show-Progress (++$i) $total 'Visual FX off...'; Disable-VisualFX
    Show-Progress (++$i) $total 'SSD...'; Set-SSDTweaks
    Show-Progress (++$i) $total 'Edge...'; Disable-EdgePreload
    Show-Progress (++$i) $total 'WU drivers...'; Disable-WUDriverUpdates
    Show-Progress (++$i) $total 'MSI...'; Set-MsiMode
    Show-Progress (++$i) $total 'Uslugi...'; Disable-BaseSvc
    Show-Progress (++$i) $total 'WU pause...'; Pause-WU
    Show-Progress (++$i) $total 'Powiadomienia...'; Disable-AllNotifications
    Show-Progress (++$i) $total 'Konserwacja...'; Disable-Maintenance
    Show-Progress (++$i) $total 'HAGS...'; Set-Hags
    Show-Progress (++$i) $total 'Fullscreen...'; Disable-FullscreenOpt
    Show-Progress (++$i) $total 'Widgety...'; Disable-WidgetsCopilot
    Show-Progress (++$i) $total 'MemoryComp...'; if($script:Hw -and $script:Hw.RamGB -ge 16){ Disable-MemoryCompression } else { Write-Info 'RAM <16GB pomijam' }
    Show-Progress (++$i) $total 'HPET...'; Disable-HpetGlobally
    Show-Progress (++$i) $total 'Cache...'; Clear-Shaders
    Show-Progress (++$i) $total 'RAM...'; Clear-Ram
    Show-Progress (++$i) $total 'Smart ISLC...'; Invoke-SmartISLC
    Show-Progress (++$i) $total 'ProBalance...'; Invoke-ProBalance
    Add-Applied 'profile-advanced'; Save-State
    Show-Progress $total $total 'Gotowe ADVANCED!'
    Write-Host ''; Write-Ok 'PROFIL ADVANCED zastosowany!'
    Wait-Enter
}
function Invoke-FullProfile {
    Write-Step 'PROFIL GAMINGOWY PELNY 1-CLICK'
    if(-not $script:Licensed){ Write-Err 'Tylko w pelnej wersji!'; return }
    $total=43; $i=0
    Show-Progress (++$i) $total 'Backup + Restore Point...'; Ensure-Backup
    Show-Progress (++$i) $total 'Plan Ultimate...'; Enable-Ultimate
    Show-Progress (++$i) $total 'Hibernacja off...'; Disable-Hibernation
    Show-Progress (++$i) $total 'MMCSS...'; Set-Mmcss
    Show-Progress (++$i) $total 'Priorytety...'; Set-Priority
    Show-Progress (++$i) $total 'CPU MaxPerf...'; Set-MaxPerf
    Show-Progress (++$i) $total 'Timer 0.5ms...'; Set-Timer05
    Show-Progress (++$i) $total 'Core Parking off...'; Disable-CoreParking
    Show-Progress (++$i) $total 'CPU low-latency...'; Set-CstateOff
    Show-Progress (++$i) $total 'USB Suspend off...'; Disable-USBSelectiveSuspend
    Show-Progress (++$i) $total 'Mouse fix...'; Set-MouseFix
    Show-Progress (++$i) $total 'Mouse menu delay...'; Set-MouseMenuDelay
    Show-Progress (++$i) $total 'TCP/IP...'; Set-Network
    Show-Progress (++$i) $total 'Auto DNS...'; Set-AutoDns
    Show-Progress (++$i) $total 'NDIS latency...'; Set-NetworkLatency
    Show-Progress (++$i) $total 'Sticky Keys off...'; Disable-StickyKeys
    Show-Progress (++$i) $total 'Visual FX off...'; Disable-VisualFX
    Show-Progress (++$i) $total 'SSD tweaks...'; Set-SSDTweaks
    Show-Progress (++$i) $total 'Edge preload off...'; Disable-EdgePreload
    Show-Progress (++$i) $total 'WU sterowniki...'; Disable-WUDriverUpdates
    Show-Progress (++$i) $total 'MSI Mode...'; Set-MsiMode
    Show-Progress (++$i) $total 'Uslugi...'; Disable-BaseSvc
    Show-Progress (++$i) $total 'WU Pause...'; Pause-WU
    Show-Progress (++$i) $total 'Telemetria...'; Disable-TelemetryHosts
    Show-Progress (++$i) $total 'Powiadomienia off...'; Disable-AllNotifications
    Show-Progress (++$i) $total 'Konserwacja off...'; Disable-Maintenance
    Show-Progress (++$i) $total 'Delivery Optimization...'; Disable-DeliveryOptimization
    Show-Progress (++$i) $total 'Defender wykluczenia...'; Add-GameDefenderExclusions
    Show-Progress (++$i) $total 'HAGS...'; Set-Hags
    Show-Progress (++$i) $total 'Fullscreen Opt off...'; Disable-FullscreenOpt
    Show-Progress (++$i) $total 'Widgety/Copilot off...'; Disable-WidgetsCopilot
    if($script:Hw -and $script:Hw.RamGB -ge 16){ Show-Progress (++$i) $total 'Memory Compression...'; Disable-MemoryCompression } else { ++$i }
    Show-Progress (++$i) $total 'HPET off...'; Disable-HpetGlobally
    Show-Progress (++$i) $total 'Reserved Storage off...'; Disable-ReservedStorage
    if((Get-CimInstance Win32_OperatingSystem).BuildNumber -ge 22000){ Show-Progress (++$i) $total 'Win11 context...'; Disable-Win11Context } else { ++$i }
    if($script:Hw){ if($script:Hw.GpuVendor -eq 'NVIDIA'){Set-Nvidia;Set-NvidiaShaderCache} elseif($script:Hw.GpuVendor -eq 'AMD'){Set-Amd} }
    Show-Progress (++$i) $total 'Discord accel off...'; Disable-DiscordAccel
    Show-Progress (++$i) $total 'Cache...'; Clear-Shaders
    Show-Progress (++$i) $total 'RAM...'; Clear-Ram
    Show-Progress (++$i) $total 'Smart ISLC w tle...'; Invoke-SmartISLC
    Show-Progress (++$i) $total 'ProBalance Watcher...'; Invoke-ProBalance
    Show-Progress (++$i) $total 'Game Priority...'; Invoke-GamePriorityWatcher
    Show-Progress (++$i) $total 'Autostart...'; Set-AutostartGame
    Show-Progress (++$i) $total 'Zapis...'; Add-Applied 'profile-full'; Save-State
    Show-Progress $total $total 'Gotowe!'
    Write-Host ''; Write-Ok 'PROFIL GAMINGOWY ZASTOSOWANY!'
    Write-Info 'ZALECANY RESTART komputera.'
    Wait-Enter
}

# ====================== DIAG ======================
function New-Diag {
    Write-Step 'Raport diagnostyczny'
    $file = Join-Path $script:Root ("d01i_diag_$(Get-Date -Format yyyyMMdd_HHmmss).txt")
    $lines=@()
    $lines += "d01i tweakz p - RAPORT $(Get-Date)"
    $lines += ('='*60)
    $lines += "HWID: $script:Hwid"
    $licStatus = 'DEMO'
    if ($script:Licensed) {
        if ($script:LicenseExpires.Year -ge 2099 -or $script:LicenseExpires -eq [datetime]::MaxValue) { $licStatus = 'PERMANENTNA' }
        else { $licStatus = "wazna do $($script:LicenseExpires.ToString('yyyy-MM-dd'))" }
    }
    $lines += "Licencja: $licStatus"
    $lines += ''
    if($script:Hw){
        $lines += "CPU: $($script:Hw.CpuName) [$($script:Hw.CpuVendor)]"
        $lines += "GPU: $($script:Hw.GpuName) [$($script:Hw.GpuVendor)]"
        $lines += "RAM: $($script:Hw.RamGB)GB | Dysk: $($script:Hw.DiskType)"
    }
    $lines += ''
    $lines += 'ZASTOSOWANE:'
    $lines += ($script:State.Applied | ForEach-Object { "  - $_" })
    Set-Content $file ($lines -join "`r`n") -Encoding UTF8
    Write-Ok "Raport: $file"
    try { Invoke-Item $file } catch {}
    Wait-Enter
}

# ====================== MENU ======================
function Write-MenuEntry {
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Text, [string]$Color='White')
    # Dla 2-kolumn: zwraca sformatowany string bez wypisywania
    $s = "[{0}] {1}" -f $Code.PadLeft(2), $Text
    return $s
}
function Write-MenuCategory {
    param([string]$Title, [string]$Color='Cyan')
    $w = 96
    $line = "-- $Title --"
    $pad = [math]::Floor(($w - $line.Length)/2)
    $full = (" " * $pad) + $line
    Write-Host $full -ForegroundColor $Color
}
function Show-Menu {
    $totalW = 96
    # Tytul wycentrowany
    $title = "d01i tweakz  •  p  •  MENU"
    $pad = [math]::Floor(($totalW - $title.Length)/2)
    Write-Host (" " * $pad + $title) -ForegroundColor Cyan
    Write-Host (" " * $pad + ("-" * $title.Length)) -ForegroundColor DarkCyan
    Write-Host ""

    # Helper do wypisania 2 kolumn w jednym wierszu
    function Row2($c1,$t1,$col1,$c2,$t2,$col2) {
        $left  = Write-MenuEntry $c1 $t1
        $right = if ($c2) { Write-MenuEntry $c2 $t2 } else { "" }
        $leftPad = $left.PadRight(48)
        # Kolory osobno
        Write-Host ("  " + $leftPad) -ForegroundColor $col1 -NoNewline
        if ($right) { Write-Host $right -ForegroundColor $col2 } else { Write-Host "" }
    }

    Write-MenuCategory "PROFILE SZYBKIE  •  1-CLICK" "Cyan"
    Row2 'S' 'SAFE - bezpieczny' 'Green' 'B' 'BALANCED - polecany 90%' 'Green'
    Row2 'A' 'ADVANCED - zaawansowany' 'Yellow' 'F' 'FULL - pelny (43 kroki)' 'Green'
    Row2 '01' 'FULL alias 01 - ULTIMATE' 'Green' '' '' 'White'
    Write-Host ""

    Write-MenuCategory "PODSTAWOWE" "DarkCyan"
    Row2 '02' 'KILL MODE + RAM clean' 'White' '07' 'Czyszczenie cache/RAM' 'White'
    Row2 '08' 'SELF-TEST' 'Magenta' '09' 'Raport diagnostyczny' 'Cyan'
    Row2 '15' 'Kopiuj HWID' 'White' '' '' 'White'
    Write-Host ""

    Write-MenuCategory "SIEĆ & PING" "DarkCyan"
    Row2 '04' 'Siec TCP + Auto DNS' 'White' '13' 'Ping ogolny' 'White'
    Row2 '14' 'Ping serwerow gier' 'White' '' '' 'White'
    Write-Host ""

    Write-MenuCategory "WYDAJNOŚĆ  •  GPU & CPU" "DarkCyan"
    Row2 '03' 'Mouse Fix 1:1' 'White' '05' 'GPU HAGS + MSI + Cache' 'White'
    Row2 '11' 'NDIS latency' 'White' '12' 'Smart ISLC w tle' 'White'
    Row2 '17' 'Efekty wizualne OFF' 'White' '18' 'CPU MaxPerf (0x2A)' 'White'
    Row2 '19' 'Priority Watcher' 'White' '29' 'CPU low-latency 100%' 'White'
    Row2 '30' 'Discord bez GPU' 'White' '31' 'NVIDIA cache' 'White'
    Row2 '33' 'ProBalance' 'White' '' '' 'White'
    Write-Host ""

    Write-MenuCategory "PRYWATNOŚĆ & SYSTEM" "DarkCyan"
    Row2 '22' 'Menu delay 0ms' 'White' '23' 'Telemetria OFF' 'White'
    Row2 '24' 'Defender excl.' 'White' '25' 'Powiadomienia OFF' 'White'
    Row2 '26' 'Konserwacja OFF' 'White' '32' 'Delivery Opt OFF' 'White'
    Write-Host ""

    Write-MenuCategory "ZAAWANSOWANE  •  RYZYKO" "Yellow"
    Row2 '06' 'VBS/HVCI OFF' 'Yellow' '10' 'Spectre OFF (ryzyko)' 'DarkYellow'
    Row2 '27' 'Blokada WU trwala' 'Yellow' '28' 'Tryb AGRESYWNY' 'DarkRed'
    Write-Host ""

    Write-MenuCategory "SYSTEM" "DarkCyan"
    Row2 '20' 'Win11 menu + Reserved OFF' 'White' '21' 'Autostart' 'White'
    Row2 '16' 'COFNIJ WSZYSTKIE ZMIANY' 'Red' '0' 'Wyjscie' 'Red'
    Write-Host ""
    Write-Host "  Wybierz [S/B/A/F/01-33/0]  •  SAFE=B  •  FULL=F" -ForegroundColor DarkGray
}


# ====================== START ======================
Write-Log '========== d01i tweakz p START =========='
Load-State
Invoke-Preflight
$script:Hw = Get-Hardware

# --- AUTO RUN (uruchamiane z Harmonogramu zadan po logowaniu) ---
if ($AutoRun) {
    try {
        $script:Hwid = Get-Hwid
        $script:Licensed = Test-StoredLicense -Quiet
        if (-not $script:Licensed) {
            Write-Log 'Auto-run pomiety: brak waznej lokalnej licencji.' 'WARN'
            exit 0
        }
        try { [D01i.Native]::SetTimer05() | Out-Null } catch {}
        Invoke-KillMode
        Invoke-SmartISLC
        Invoke-ProBalance
        Invoke-GamePriorityWatcher
        $jobs = @(@($script:ISLCJob, $script:PBJob, $script:PriJob) | Where-Object { $null -ne $_ })
        if ($jobs.Count -gt 0) {
            Write-Log 'Auto-run: Smart ISLC + ProBalance + Game Priority dzialaja w tle.' 'INFO'
            # Nie konczymy procesu: zadania Start-Job zostalyby ubite razem z procesem nadrzednym.
            Wait-Job -Job $jobs | Out-Null
        }
        exit 0
    } catch {
        Write-Err "Auto-run error: $($_.Exception.Message)"
        Start-Sleep 5
        exit 1
    }
}

$script:Licensed = Invoke-License
Write-Host ''
if(-not $script:Licensed){ Write-Warn 'TRYB DEMO (tylko plan zasilania). Aktywuj licencje.'; Start-Sleep 2 }

do {
    Show-Banner; Show-Hw; Show-Menu
    $c = (Read-Host '  Wybierz').Trim()
    switch ($c) {
        'S'  { if($script:Licensed){ Invoke-ProfileSafe } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        'B'  { if($script:Licensed){ Invoke-ProfileBalanced } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        'A'  { if($script:Licensed){ Invoke-ProfileAdvanced } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        'F'  { if($script:Licensed){ Invoke-FullProfile } else { Enable-Ultimate; Wait-Enter } }
        '01' { if($script:Licensed){ Invoke-FullProfile } else { Enable-Ultimate; Wait-Enter } }
        '02' { Invoke-KillMode; Wait-Enter }
        '03' { if($script:Licensed){Set-MouseFix}else{Write-Err 'Tylko pelna wersja.'}; Wait-Enter }
        '04' { if($script:Licensed){Set-Network;Set-AutoDns}else{Write-Err 'Tylko pelna wersja.'}; Wait-Enter }
        '05' { if($script:Licensed){Set-Hags;Set-MsiMode;Clear-Shaders;if($script:Hw){if($script:Hw.GpuVendor -eq 'NVIDIA'){Set-Nvidia}elseif($script:Hw.GpuVendor -eq 'AMD'){Set-Amd}} }else{Write-Err 'Tylko pelna wersja.'}; Wait-Enter }
        '06' { Disable-Vbs; Wait-Enter }
        '07' { Clear-Shaders; Clear-Ram; Wait-Enter }
        '08' { Invoke-SelfTest }
        '09' { New-Diag }
        '10' { if($script:Licensed){ Disable-SpectreMeltdown; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '11' { if($script:Licensed){ Ensure-Backup; Set-NetworkLatency; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '12' { Invoke-SmartISLC; Wait-Enter }
        '13' { Test-NetworkPing }
        '29' { if($script:Licensed){ Set-CstateOff; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '30' { if($script:Licensed){ Disable-DiscordAccel; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '31' { if($script:Licensed){ Set-NvidiaShaderCache; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '32' { if($script:Licensed){ Disable-DeliveryOptimization; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '33' { if($script:Licensed){ Invoke-ProBalance; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '14' { Set-GameServerPing }
        '15' { Copy-HwidToClipboard; Wait-Enter }
        '16' { Invoke-Undo; Wait-Enter }
        '17' { if($script:Licensed){ Disable-VisualFX; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '18' { if($script:Licensed){ Set-MaxPerf; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '19' { if($script:Licensed){ Invoke-GamePriorityWatcher; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '20' { Disable-Win11Context; Disable-ReservedStorage; Wait-Enter }
        '21' { if($script:Licensed){ Set-AutostartGame } else { Write-Err 'Tylko pelna wersja.' }; Wait-Enter }
        '22' { if($script:Licensed){ Set-MouseMenuDelay; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '23' { if($script:Licensed){ Disable-TelemetryHosts; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '24' { if($script:Licensed){ Add-GameDefenderExclusions; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '25' { if($script:Licensed){ Disable-AllNotifications; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '26' { if($script:Licensed){ Disable-Maintenance; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '27' { if($script:Licensed){ Block-WU-Completely; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '28' { if($script:Licensed){ Invoke-AggressiveMode; Wait-Enter } else { Write-Err 'Tylko pelna wersja.'; Wait-Enter } }
        '0'  { }
        default { Write-Warn 'Zla opcja.'; Start-Sleep -Milliseconds 500 }
    }
} while ($c -ne '0')

Write-Host ''
if ($script:RebootNeeded) {
    Write-Warn 'Czesc zmian wymaga RESTARTU!'
    if(Read-YesNo 'Uruchomic ponownie TERAZ?'){ Restart-Computer -Force }
}
Write-Log '========== d01i tweakz p STOP =========='
Write-Host "  Powodzenia na serwerach! - $script:ProductName" -ForegroundColor Cyan
Write-Host ''

