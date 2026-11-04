<#
================================================================================
  d01i - universal  |  Zaawansowany optymalizator Windows pod gry
================================================================================
  Wersja:        1.0.0
  Systemy:       Windows 10 22H2 / Windows 11 23H2 / 24H2 (64-bit)
  Uruchamianie:  d01i_universal.bat   (zalecane)
                 lub czysty PowerShell:  powershell -ExecutionPolicy Bypass -File .\d01i_universal.ps1 [-DryRun]

  Główne cechy:
    - automatyczny punkt przywracania + eksport rejestru przed PIERWSZĄ zmianą,
    - każdy tweak jest odwracalny (opcja 9 w menu),
    - logowanie wszystkiego do d01i_log.txt z timestampami,
    - tryb DRY-RUN: podgląd zmian bez ich aplikowania,
    - wykrywanie sprzętu: CPU (Intel/AMD), GPU (NVIDIA/AMD/Intel), RAM, dysk, laptop/desktop,
    - blokada dla serwerów i ostrzeżenie dla maszyn domenowych (firmowych),
    - gotowe profile sprzętowe „jednym kliknięciem".

  UWAGA:  Skrypt NIE wyłącza Windows Defendera, NIE rusza antywirusa i NIE
          dokonuje destrukcyjnych zmian napięć. Sekcja „Zaawansowane" (VBS/HVCI)
          wymaga świadomej zgody użytkownika.

  Korzystasz WYŁĄCZNIE na własną odpowiedzialność.
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$DryRun,   # tylko podgląd zmian, nic nie zapisywane
    [switch]$Force     # pomiń ostrzeżenie o domenie (świadoma decyzja)
)

# ----------------------------------------------------------------------------
# KODOWANIE / KONSOLA
# ----------------------------------------------------------------------------
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch { }

try { $Host.UI.RawUI.WindowTitle = 'd01i - universal  |  Gaming Optimizer' } catch { }

$ErrorActionPreference = 'Continue'

# ----------------------------------------------------------------------------
# GLOBALNE ZMIENNE PROJEKTU
# ----------------------------------------------------------------------------
$script:Version      = '1.0.0'
$script:Root         = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($script:Root)) { $script:Root = (Get-Location).Path }
$script:LogFile      = Join-Path $script:Root 'd01i_log.txt'
$script:BackupDir    = Join-Path $script:Root 'd01i_backups'
$script:StateFile    = Join-Path $script:Root 'd01i_state.json'
$script:DryRun       = [bool]$DryRun
$script:Force        = [bool]$Force
$script:BackupDone   = $false
$script:RebootNeeded = $false
$script:ProductType  = 1
$script:Hw           = $null

# ----------------------------------------------------------------------------
# LOGO PROJEKTU (dokładnie wg specyfikacji)
# ----------------------------------------------------------------------------
$script:Logo = @'
░███████     ░████     ░██   ░██      ░██                                            ░██
░██   ░██   ░██ ░██  ░████            ░██                                            ░██
░██    ░██ ░██ ░████   ░██   ░██   ░████████ ░██    ░██    ░██  ░███████   ░██████   ░██    ░██░█████████
░██    ░██ ░██░██░██   ░██   ░██      ░██    ░██    ░██    ░██ ░██    ░██       ░██  ░██   ░██      ░███
░██    ░██ ░████ ░██   ░██   ░██      ░██     ░██  ░████  ░██  ░█████████  ░███████  ░███████     ░███
░██   ░██   ░██ ░██    ░██   ░██      ░██      ░██░██ ░██░██   ░██        ░██   ░██  ░██   ░██  ░███
░███████     ░████   ░██████ ░██       ░████    ░███   ░███     ░███████   ░█████░██ ░██    ░██░█████████
'@

# ----------------------------------------------------------------------------
# STAN ZMIAN (do odwracania)  –  d01i_state.json
# ----------------------------------------------------------------------------
$script:State = [ordered]@{
    Version         = $script:Version
    CreatedUltimate = $false        # czy to my utworzyliśmy plan Ultimate
    VbsDisabled     = $false        # czy to my wyłączyliśmy VBS/HVCI
    PagefileTouched = $false        # czy ruszaliśmy plik strony
    LastBackupDir   = ''
    RegUndo         = @()           # lista wpisów rejestru do cofnięcia
    ServiceUndo     = @()           # lista usług do cofnięcia
    DisabledTasks   = @()           # lista zadań wyłączonych przez skrypt
    DnsBackup       = @()           # oryginalne adresy DNS
    QosPolicies     = @()           # utworzone polityki QoS
    Applied         = @()           # identyfikatory zastosowanych pakietów
}

function Load-D01State {
    if (Test-Path $script:StateFile) {
        try {
            $raw = Get-Content -Path $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            foreach ($k in @('RegUndo','ServiceUndo','DisabledTasks','DnsBackup','QosPolicies','Applied')) {
                if ($null -ne $raw.$k) { $script:State[$k] = @($raw.$k) }
            }
            foreach ($k in @('CreatedUltimate','VbsDisabled','PagefileTouched','LastBackupDir')) {
                if ($null -ne $raw.$k) { $script:State[$k] = $raw.$k }
            }
        } catch {
            Write-Host '  [!] Nie można odczytać d01i_state.json - start z czystym stanem.' -ForegroundColor Yellow
        }
    }
}

function Save-D01State {
    try {
        ($script:State | ConvertTo-Json -Depth 6) | Set-Content -Path $script:StateFile -Encoding UTF8 -Force
    } catch {
        Write-Log ("Błąd zapisu pliku stanu: {0}" -f $_.Exception.Message) 'ERROR'
    }
}

# ----------------------------------------------------------------------------
# LOGOWANIE + KOLOROWE KOMUNIKATY
# ----------------------------------------------------------------------------
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
    param([string]$Text = 'Naciśnij Enter, aby kontynuować...')
    Write-Host ''
    Read-Host "  $Text" | Out-Null
}

function Read-YesNo {
    param([string]$Prompt)
    $a = Read-Host "  $Prompt [T/N]"
    return ($a.Trim().ToUpper() -eq 'T' -or $a.Trim().ToUpper() -eq 'Y')
}

function Add-D01Applied {
    param([string]$Id, [string]$Desc = '')
    if ($script:State.Applied -notcontains $Id) { $script:State.Applied += $Id; Save-D01State }
    if ($Desc) { Write-Log $Desc 'APPLY' }
}

function Show-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray
    Write-Host ("  $Title") -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray
}

# ----------------------------------------------------------------------------
# BANER / LOGO
# ----------------------------------------------------------------------------
function Show-Banner {
    try { Clear-Host } catch { }
    Write-Host $script:Logo -ForegroundColor Cyan
    Write-Host ''
    Write-Host ("        d01i - universal  v$($script:Version)   |   optymalizacja Windows pod gry   |   $(Get-Date -Format 'yyyy-MM-dd')") -ForegroundColor DarkGray
    if ($script:DryRun) {
        Write-Host '        >>> TRYB DRY-RUN: ŻADNA zmiana nie zostanie zapisana <<<' -ForegroundColor Black -BackgroundColor Yellow
    }
    Write-Host ''
}

function Show-HardwareLine {
    if ($null -eq $script:Hw) { return }
    $h = $script:Hw
    Write-Host ("   CPU : {0}  [{1}]" -f $h.CpuName, $h.CpuVendor) -ForegroundColor White
    Write-Host ("   GPU : {0}  [{1}]" -f $h.GpuName, $h.GpuVendor) -ForegroundColor White
    Write-Host ("   RAM : {0} GB    Dysk: {1}    Obudowa: {2}" -f $h.RamGB, $h.DiskType, $h.Chassis) -ForegroundColor White
    Write-Host ("   OS  : {0} (build {1})" -f $h.OsCaption, $h.OsBuild) -ForegroundColor White
    Write-Host ("   Log : d01i_log.txt    Zastosowane pakiety: {0}" -f $script:State.Applied.Count) -ForegroundColor DarkGray
    Write-Host ''
}

# ----------------------------------------------------------------------------
# KONTROLA ŚRODOWISKA (admin / serwer / domena / wersja OS)
# ----------------------------------------------------------------------------
function Test-IsAdmin {
    try {
        $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pri = New-Object Security.Principal.WindowsPrincipal($id)
        return $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Invoke-Preflight {
    # --- uprawnienia
    if (-not (Test-IsAdmin)) {
        Write-Host ''
        Write-Host '  [ d01i - universal ]' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  Ten skrypt MUSI działać jako Administrator.' -ForegroundColor Red
        if (Read-YesNo 'Uruchomić ponownie z podniesionymi uprawnieniami (UAC)?') {
            $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
            if ($script:DryRun) { $argList += '-DryRun' }
            try {
                Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($argList -join ' ')
            } catch {
                Write-Host ("  Nie udało się podnieść uprawnień: {0}" -f $_.Exception.Message) -ForegroundColor Red
            }
        } else {
            Write-Host '  Przerwano na życzenie użytkownika.' -ForegroundColor Yellow
        }
        exit 1
    }

    # --- typ maszyny: blokada serwerów / kontrolerów domeny
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $script:ProductType = [int]$os.ProductType
    } catch {
        $script:ProductType = 1
    }
    if ($script:ProductType -ne 1) {
        Write-Host ''
        Write-Host '  WYKRYTO SYSTEM SERWEROWY (serwer lub kontroler domeny).' -ForegroundColor Red
        Write-Host '  d01i - universal jest przeznaczony WYŁĄCZNIE dla stacji Windows 10/11.' -ForegroundColor Red
        Write-Log 'Przerwano: wykryto system serwerowy.' 'ERROR'
        exit 1
    }

    # --- ostrzeżenie dla maszyn firmowych (domena AD)
    try {
        $partOfDomain = [bool](Get-CimInstance Win32_ComputerSystem).PartOfDomain
    } catch { $partOfDomain = $false }
    if ($partOfDomain -and -not $script:Force) {
        Write-Host ''
        Write-Host '  Ten komputer należy do domeny (prawdopodobnie maszyna FIRMOWA).' -ForegroundColor Yellow
        Write-Host '  Tweaki mogą kolidować z politykami GPO i regulaminem firmy.' -ForegroundColor Yellow
        $code = Read-Host '  Wpisz TAK, aby kontynuować na własną odpowiedzialność'
        if ($code.Trim().ToUpper() -ne 'TAK') {
            Write-Host '  Przerwano.' -ForegroundColor Yellow
            exit 0
        }
        Write-Log 'Kontynuacja mimo domeny (jawna zgoda użytkownika).' 'WARN'
    }

    # --- wersja systemu (informacyjnie)
    try {
        $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
        if ($build -lt 19045) {
            Write-Warn "Build $build może być starszy niż Windows 10 22H2 - część opcji może nie działać."
        } elseif ($build -ge 26100) {
            Write-Info "Wykryto Windows 11 24H2+ (build $build)."
        } elseif ($build -ge 22000) {
            Write-Info "Wykryto Windows 11 (build $build)."
        } else {
            Write-Info "Wykryto Windows 10 22H2 (build $build)."
        }
    } catch { }
}

# ----------------------------------------------------------------------------
# WYKRYWANIE SPRZĘTU
# ----------------------------------------------------------------------------
function Get-D01Hardware {
    Write-Step 'Wykrywanie sprzętu'
    $hw = [pscustomobject][ordered]@{
        CpuName   = 'nieznany'
        CpuVendor = 'Nieznany'
        GpuName   = 'nieznany'
        GpuVendor = 'Nieznany'
        RamGB     = 0
        IsLaptop  = $false
        Chassis   = 'Desktop'
        OsCaption = 'Windows'
        OsBuild   = 0
        DiskType  = 'nieznany'
        IsSSD     = $false
    }

    # CPU
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $hw.CpuName = ($cpu.Name -replace '\s+', ' ').Trim()
        if ($cpu.Manufacturer -match 'AMD' -or $hw.CpuName -match 'Ryzen|EPYC|Athlon|FX') { $hw.CpuVendor = 'AMD' }
        elseif ($cpu.Manufacturer -match 'Intel' -or $hw.CpuName -match 'Intel|Core|Xeon|Pentium|Celeron') { $hw.CpuVendor = 'Intel' }
        Write-Ok ("CPU: {0} [{1}]" -f $hw.CpuName, $hw.CpuVendor)
    } catch { Write-Warn ("CPU: nie wykryto ({0})" -f $_.Exception.Message) }

    # GPU (preferuj dedykowaną NVIDIA/AMD przed zintegrowaną)
    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction Stop
        $pick = $null
        foreach ($g in $gpus) {
            if ($g.AdapterCompatibility -match 'NVIDIA|Advanced Micro Devices|ATI') { $pick = $g; break }
        }
        if ($null -eq $pick) { $pick = $gpus | Select-Object -First 1 }
        if ($null -ne $pick) {
            $hw.GpuName = ($pick.Name -replace '\s+', ' ').Trim()
            if ($pick.AdapterCompatibility -match 'NVIDIA') { $hw.GpuVendor = 'NVIDIA' }
            elseif ($pick.AdapterCompatibility -match 'AMD|Advanced Micro|ATI') { $hw.GpuVendor = 'AMD' }
            elseif ($pick.AdapterCompatibility -match 'Intel') { $hw.GpuVendor = 'Intel' }
        }
        Write-Ok ("GPU: {0} [{1}]" -f $hw.GpuName, $hw.GpuVendor)
    } catch { Write-Warn ("GPU: nie wykryto ({0})" -f $_.Exception.Message) }

    # RAM
    try { $hw.RamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB) } catch { }

    # Laptop / Desktop
    try {
        $types = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes)
        $laptopTypes = @(8,9,10,11,12,14,18,21,30,31,32)
        $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        foreach ($t in $types) { if ($laptopTypes -contains [int]$t) { $hw.IsLaptop = $true } }
        if ($battery) { $hw.IsLaptop = $true }
        if ($hw.IsLaptop) { $hw.Chassis = 'Laptop' }
    } catch { }

    # OS
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $hw.OsCaption = $os.Caption.Trim()
        $hw.OsBuild   = [int]$os.BuildNumber
    } catch { }

    # Dysk systemowy
    try {
        $disk = $null
        $sysLetter = ($env:SystemDrive).TrimEnd(':')
        $part = Get-Partition -DriveLetter $sysLetter -ErrorAction SilentlyContinue
        if ($part) {
            $disk = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq "$($part.DiskNumber)" } | Select-Object -First 1
        }
        if ($null -eq $disk) {
            $disk = Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1
        }
        if ($disk) {
            $hw.DiskType = ('{0}/{1}' -f $disk.BusType, $disk.MediaType)
            if ($disk.MediaType -eq 'SSD' -or $disk.BusType -eq 'NVMe') { $hw.IsSSD = $true }
        }
        Write-Ok ("Dysk: {0}  |  RAM: {1} GB  |  {2}" -f $hw.DiskType, $hw.RamGB, $hw.Chassis)
    } catch { Write-Warn ("Dysk: nie wykryto ({0})" -f $_.Exception.Message) }

    Write-Log ("HW: {0} | {1} | RAM {2}GB | {3} | {4} build {5}" -f $hw.CpuName, $hw.GpuName, $hw.RamGB, $hw.DiskType, $hw.OsCaption, $hw.OsBuild)
    return $hw
}

# ----------------------------------------------------------------------------
# BACKUP: punkt przywracania + eksport rejestru (AUTOMATYCZNIE przed 1. zmianą)
# ----------------------------------------------------------------------------
function Ensure-D01Backup {
    if ($script:BackupDone) { return }

    if ($script:DryRun) {
        Write-Info '[DRY-RUN] Tu powstałby punkt przywracania systemu + eksport rejestru.'
        $script:BackupDone = $true
        return
    }

    Write-Step 'Zabezpieczenia: punkt przywracania + backup rejestru (jednorazowo, przed pierwszą zmianą)'
    New-D01RestorePoint
    Export-D01Registry
    $script:BackupDone = $true
    Save-D01State
    Write-Ok 'Zabezpieczenia gotowe.'
}

function New-D01RestorePoint {
    try {
        Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop
    } catch {
        Write-Warn ("Nie można włączyć Ochrony systemu: {0}" -f $_.Exception.Message)
    }

    # zdejmij dzienny limit punktów przywracania na czas tworzenia backupu
    try {
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    } catch { }

    try {
        Write-Info 'Tworzenie punktu przywracania (może potrwać 30-90 s)...'
        Checkpoint-Computer -Description 'd01i - universal / przed optymalizacją' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Ok 'Utworzono punkt przywracania systemu.'
    } catch {
        Write-Warn ("Punkt przywracania: {0}" -f $_.Exception.Message)
    }
}

function Export-D01Registry {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dir   = Join-Path $script:BackupDir ("reg_" + $stamp)
    try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }

    $keys = @(
        'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia',
        'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl',
        'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management',
        'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers',
        'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard',
        'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces',
        'HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR',
        'HKLM\SOFTWARE\Policies\Microsoft\Windows\Psched',
        'HKCU\System\GameConfigStore',
        'HKCU\Control Panel\Desktop',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    )
    $okCount = 0
    foreach ($k in $keys) {
        $file = Join-Path $dir (($k -replace '[\\/:\s]', '_') + '.reg')
        & reg.exe export $k $file /y | Out-Null
        if ($LASTEXITCODE -eq 0) { $okCount++ } else { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
    $script:State.LastBackupDir = $dir
    Save-D01State
    if ($okCount -gt 0) { Write-Ok ("Eksport rejestru: {0} gałęzi -> {1}" -f $okCount, $dir) }
    else { Write-Warn 'Nie udało się wyeksportować żadnej gałęzi rejestru.' }
}

# ----------------------------------------------------------------------------
# GENERYCZNE HELPERY ZMIAN (z odwracaniem)
# ----------------------------------------------------------------------------

# Zapis wartości rejestru z zapamiętaniem starego stanu
function Set-D01Reg {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][AllowNull()]$Value,
        [ValidateSet('DWord','QWord','String','ExpandString','Binary','MultiString')]
        [string]$Type = 'DWord',
        [string]$Desc = ''
    )
    Ensure-D01Backup

    $hadValue = $false; $oldValue = $null; $oldType = 'DWord'
    try {
        $existing = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        $oldValue = $existing.$Name
        $hadValue = $true
        try { $oldType = (Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueKind($Name).ToString() } catch { }
    } catch { }

    if ($script:DryRun) {
        $stare = if ($hadValue) { " (stare: $oldValue)" } else { ' (nowy wpis)' }
        Write-Info ("[DRY-RUN] REG: {0} :: {1} = {2} [{3}]{4}" -f $Path, $Name, $Value, $Type, $stare)
        return
    }

    # zapisz do listy cofania (tylko raz na klucz)
    $dup = @($script:State.RegUndo | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name } | Select-Object -First 1)
    if ($dup.Count -eq 0) {
        $script:State.RegUndo += [pscustomobject]@{ Path=$Path; Name=$Name; HadValue=$hadValue; OldValue=$oldValue; OldType=$oldType }
        Save-D01State
    }

    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        Write-Ok ("REG: {0} :: {1} = {2}" -f $Path, $Name, $Value)
        if ($Desc) { Write-Log $Desc }
    } catch {
        Write-Err ("REG {0} :: {1}: {2}" -f $Path, $Name, $_.Exception.Message)
    }
}

# Usunięcie wartości rejestru (także z zapamiętaniem stanu)
function Remove-D01Reg {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Desc = ''
    )
    Ensure-D01Backup

    $hadValue = $false; $oldValue = $null; $oldType = 'DWord'
    try {
        $existing = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        $oldValue = $existing.$Name
        $hadValue = $true
        try { $oldType = (Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueKind($Name).ToString() } catch { }
    } catch { return }   # nie było czego usuwać

    if ($script:DryRun) {
        Write-Info ("[DRY-RUN] REG-DEL: {0} :: {1} (było: {2})" -f $Path, $Name, $oldValue)
        return
    }

    $dup = @($script:State.RegUndo | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name } | Select-Object -First 1)
    if ($dup.Count -eq 0) {
        $script:State.RegUndo += [pscustomobject]@{ Path=$Path; Name=$Name; HadValue=$hadValue; OldValue=$oldValue; OldType=$oldType }
        Save-D01State
    }

    try {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop
        Write-Ok ("REG-DEL: {0} :: {1}" -f $Path, $Name)
        if ($Desc) { Write-Log $Desc }
    } catch {
        Write-Err ("REG-DEL {0} :: {1}: {2}" -f $Path, $Name, $_.Exception.Message)
    }
}

# Zmiana trybu startu usługi (z zapamiętaniem starego)
function Set-D01Service {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][ValidateSet('Disabled','Manual','Automatic')][string]$Startup,
        [string]$Desc = ''
    )
    Ensure-D01Backup

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Info ("Usługa {0}: nie istnieje w tym systemie - pomijam." -f $Name); return }

    $oldMode = 'Manual'
    $wmi = Get-CimInstance Win32_Service -Filter ("Name='" + $Name + "'") -ErrorAction SilentlyContinue
    if ($wmi) { $oldMode = $wmi.StartMode }
    $oldDelayed = 0
    try { $oldDelayed = [int](Get-ItemProperty -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $Name) -Name DelayedAutoStart -ErrorAction Stop).DelayedAutoStart } catch { }

    if ($script:DryRun) {
        Write-Info ("[DRY-RUN] SVC: {0}: {1} -> {2}" -f $Name, $oldMode, $Startup)
        return
    }

    $dup = @($script:State.ServiceUndo | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
    if ($dup.Count -eq 0) {
        $script:State.ServiceUndo += [pscustomobject]@{ Name=$Name; OldMode=$oldMode; OldDelayed=$oldDelayed }
        Save-D01State
    }

    try {
        if ($Startup -ne 'Automatic') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $Name -StartupType $Startup -ErrorAction Stop
        # przy Automatic bez delayed-uśpienia doprecyzuj flagę
        Set-ItemProperty -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $Name) -Name DelayedAutoStart -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Ok ("SVC: {0}: {1} -> {2} {3}" -f $Name, $oldMode, $Startup, $(if ($Desc) { ' | ' + $Desc } else { '' }))
    } catch {
        Write-Err ("SVC {0}: {1}" -f $Name, $_.Exception.Message)
    }
}

# Standardowe (fabryczne) tryby startu - używane przy przywracaniu, gdy brak zapisu
$script:ServiceDefaults = @{
    'DiagTrack'                    = 'Automatic'
    'dmwappushservice'             = 'Manual'
    'RetailDemo'                   = 'Manual'
    'MapsBroker'                   = 'Automatic'
    'WMPNetworkSvc'                = 'Manual'
    'Fax'                          = 'Manual'
    'XblAuthManager'               = 'Manual'
    'XblGameSave'                  = 'Manual'
    'XboxNetApiSvc'                = 'Manual'
    'XboxGipSvc'                   = 'Manual'
    'DoSvc'                        = 'Automatic'
    'WSearch'                      = 'Automatic'
    'SysMain'                      = 'Automatic'
    'wuauserv'                     = 'Manual'
    'NvTelemetryContainer'         = 'Automatic'
    'NVDisplay.ContainerLocalSystem' = 'Automatic'
    'AMD External Events Utility'  = 'Automatic'
}

# Wyłącz / włącz zadanie planowane (ścieżka pełna, np. '\Microsoft\Windows\Xyz\Zadanie')
function Set-D01Task {
    param(
        [Parameter(Mandatory=$true)][string]$FullName,
        [Parameter(Mandatory=$true)][ValidateSet('Disable','Enable')][string]$Action
    )
    Ensure-D01Backup
    $dir  = $FullName.Substring(0, $FullName.LastIndexOf('\') + 1)
    $name = $FullName.Substring($FullName.LastIndexOf('\') + 1)

    $task = $null
    try { $task = Get-ScheduledTask -TaskPath $dir -TaskName $name -ErrorAction Stop }
    catch { Write-Info ("Zadanie pominięte (nie istnieje): {0}" -f $FullName); return }

    if ($Action -eq 'Disable' -and $task.State -eq 'Disabled') { Write-Info ("Zadanie już wyłączone: {0}" -f $name); return }

    if ($script:DryRun) {
        Write-Info ("[DRY-RUN] TASK {0}: {1}" -f $Action, $FullName)
        return
    }

    try {
        if ($Action -eq 'Disable') {
            Disable-ScheduledTask -TaskPath $dir -TaskName $name -ErrorAction Stop | Out-Null
            if ($script:State.DisabledTasks -notcontains $FullName) { $script:State.DisabledTasks += $FullName; Save-D01State }
            Write-Ok ("TASK wyłączone: {0}" -f $name)
        } else {
            Enable-ScheduledTask -TaskPath $dir -TaskName $name -ErrorAction Stop | Out-Null
            $script:State.DisabledTasks = @($script:State.DisabledTasks | Where-Object { $_ -ne $FullName }); Save-D01State
            Write-Ok ("TASK włączone: {0}" -f $name)
        }
    } catch {
        Write-Warn ("TASK {0}: {1}" -f $name, $_.Exception.Message)
    }
}

$script:TelemetryTasks = @(
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

# ----------------------------------------------------------------------------
# 1) ZASILANIE
# ----------------------------------------------------------------------------
function Enable-UltimatePlan {
    Write-Step 'Plan zasilania: Najwyższa wydajność (Ultimate Performance)'
    $guid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    if ($script:DryRun) {
        Write-Info ("[DRY-RUN] powercfg /duplicatescheme {0}; powercfg /setactive {0}" -f $guid)
        return
    }
    Ensure-D01Backup
    $exists = $false
    & powercfg.exe /query $guid 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $exists = $true }

    if (-not $exists) {
        & powercfg.exe /duplicatescheme $guid 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $script:State.CreatedUltimate = $true; Save-D01State
            Write-Ok 'Odblokowano ukryty plan Ultimate Performance.'
        } else {
            Write-Err 'Nie udało się utworzyć planu Ultimate Performance.'
            return
        }
    } else {
        Write-Info 'Plan Ultimate Performance już istnieje.'
    }
    & powercfg.exe /setactive $guid 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'Aktywowano plan Ultimate Performance.' } else { Write-Err 'Nie udało się aktywować planu.' }
    Add-D01Applied 'power-ultimate' 'Plan zasilania: Ultimate Performance'
}

function Set-BalancedPlan {
    if ($script:DryRun) { Write-Info '[DRY-RUN] powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e (Zrównoważony)'; return }
    & powercfg.exe /setactive '381b4222-f694-41f0-9685-ff5bb260df2e' 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'Aktywowano plan Zrównoważony (domyślny).' } else { Write-Warn 'Nie udało się zmienić planu zasilania.' }
    if ($script:State.CreatedUltimate) {
        & powercfg.exe /delete 'e9a42b02-d5df-448d-aa00-03f14749eb61' 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Usunięto duplikat planu Ultimate utworzony przez d01i.' }
        $script:State.CreatedUltimate = $false; Save-D01State
    }
}

function Set-RyzenPlan {
    <#  Dla Ryzen 5000/7000 zalecany jest plan Zrównoważony + sterownik chipsetu AMD.
        Szukamy planu "AMD Ryzen Balanced"; jeśli brak - zwykły Zrównoważony.   #>
    Write-Step 'Plan zasilania dla AMD Ryzen'
    if ($script:DryRun) { Write-Info '[DRY-RUN] Wybór planu AMD Ryzen Balanced / Zrównoważony'; return }
    $chosenGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $list = & powercfg.exe /list 2>&1 | Out-String
    foreach ($line in ($list -split "`r?`n")) {
        if ($line -match 'Ryzen' -and $line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $chosenGuid = $Matches[1]; break
        }
    }
    & powercfg.exe /setactive $chosenGuid 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok ("Aktywowano plan: {0}" -f $chosenGuid) } else { Write-Warn 'Nie udało się zmienić planu.' }
    Write-Info 'Wskazówka: zainstaluj aktualne sterowniki chipsetu AMD (plan AMD Ryzen Balanced pojawia się wraz z nimi).'
}

function Disable-Hibernation {
    Write-Step 'Hibernacja: WYŁĄCZENIE'
    if ($script:DryRun) { Write-Info '[DRY-RUN] powercfg /hibernate off (zwalnia miejsce na C:, szybszy start/stop)' ; return }
    Ensure-D01Backup
    & powercfg.exe /hibernate off 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'Hibernacja wyłączona (hiberfil.sys usunięty, Fast Startup rozbrojony).' }
    else { Write-Err 'Nie udało się wyłączyć hibernacji.' }
    Add-D01Applied 'power-hibernation-off' 'Hibernacja wyłączona'
    Write-Info 'Efekt uboczny: wyłącza także funkcję Szybki rozruch (Fast Startup) - dla czystych, powtarzalnych startów.'
}

function Enable-Hibernation {
    if ($script:DryRun) { Write-Info '[DRY-RUN] powercfg /hibernate on'; return }
    & powercfg.exe /hibernate on 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'Hibernacja włączona (stan domyślny).' } else { Write-Warn 'Nie udało się włączyć hibernacji.' }
}

function Set-PowerLowLatency {
    <#  PCIe ASPM off, USB selective suspend off, min. stan CPU 100% (AC), brak parkowania rdzeni.  #>
    param([switch]$SkipCpuBoostBits)
    Write-Step 'Zasilanie: niskie opóźnienia (PCIe / USB / CPU)'
    $cmds = @(
        @('Wyłączenie PCIe ASPM (AC)', '/setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0'),
        @('Wyłączenie PCIe ASPM (DC)', '/setdcvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0'),
        @('Wyłączenie zawieszania USB (AC)', '/setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0')
    )
    if (-not $SkipCpuBoostBits) {
        $cmds += @('Minimalny stan procesora 100% (AC)', '/setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100')
        $cmds += @('Brak parkowania rdzeni 100% (AC)', '/setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 100')
    }
    foreach ($c in $cmds) {
        if ($script:DryRun) { Write-Info ("[DRY-RUN] powercfg {0}   # {1}" -f $c[1], $c[0]); continue }
        Ensure-D01Backup
        $parts = @($c[1] -split ' ')
        & powercfg.exe $parts 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok $c[0] } else { Write-Warn ("{0}: powercfg zwrócił kod {1}" -f $c[0], $LASTEXITCODE) }
    }
    if (-not $script:DryRun) {
        & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null
        Add-D01Applied 'power-lowlatency' 'Zasilanie: PCIe ASPM off / USB suspend off / CPU 100%'
    }
}

function Reset-PowerLowLatency {
    Write-Step 'Zasilanie: przywracanie zachowań domyślnych'
    $cmds = @(
        '/setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 1',
        '/setdcvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 1',
        '/setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 1',
        '/setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5'
    )
    foreach ($c in $cmds) {
        if ($script:DryRun) { Write-Info ("[DRY-RUN] powercfg {0}" -f $c); continue }
        $parts = @($c -split ' ')
        & powercfg.exe $parts 2>&1 | Out-Null
    }
    if (-not $script:DryRun) { & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null; Write-Ok 'Przywrócono domyślne zachowanie zasilania.' }
}

# ----------------------------------------------------------------------------
# 2) REJESTR: opóźnienia / MMCSS / priorytety / GameDVR / pamięć
# ----------------------------------------------------------------------------
function Set-MmcssGaming {
    Write-Step 'Rejestr: Multimedia Class Scheduler (MMCSS) + responsywność'
    $profile = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-D01Reg -Path $profile -Name 'SystemResponsiveness'  -Value 0  -Desc '0% czasu CPU zarezerwowane dla procesów w tle podczas zadań multimedialnych'
    Set-D01Reg -Path $profile -Name 'NetworkThrottlingIndex' -Value -1 -Desc 'Wyłączenie throttlingu sieci podczas multimediów (0xFFFFFFFF)'

    $games = $profile + '\Tasks\Games'
    Set-D01Reg -Path $games -Name 'GPU Priority'         -Value 8      -Desc 'Profil Games: priorytet GPU = 8'
    Set-D01Reg -Path $games -Name 'Priority'             -Value 6      -Desc 'Profil Games: priorytet = 6'
    Set-D01Reg -Path $games -Name 'Scheduling Category'  -Value 'High' -Type String -Desc 'Profil Games: High'
    Set-D01Reg -Path $games -Name 'SFIO Priority'        -Value 'High' -Type String -Desc 'Profil Games: I/O = High'
    Add-D01Applied 'reg-mmcss' 'MMCSS / SystemResponsiveness / profile Games'
}

function Set-PrioritiesPack {
    Write-Step 'Rejestr: priorytety procesów + GameDVR OFF + Game Mode ON'
    Set-D01Reg -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name 'Win32PrioritySeparation' -Value 38 -Desc '0x26: krótkie kwanty, preferencja aplikacji pierwszoplanowej (mniejszy input lag)'

    Set-D01Reg -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 -Desc 'GameDVR/nagrywanie w tle = OFF'
    Set-D01Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0 -Desc 'Polityka: GameDVR zablokowany'

    Set-D01Reg -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'AllowAutoGameMode' -Value 1 -Desc 'Tryb gry: ON'
    Set-D01Reg -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -Value 1 -Desc 'Tryb gry: ON'
    Add-D01Applied 'reg-priorities' 'Win32PrioritySeparation / GameDVR off / Game Mode on'
}

function Set-MemoryManagementPack {
    Write-Step 'Rejestr: Memory Management'
    if ($null -ne $script:Hw -and $script:Hw.RamGB -lt 16) {
        Write-Warn ("Wykryto tylko {0} GB RAM - DisablePagingExecutive nie jest zalecane poniżej 16 GB." -f $script:Hw.RamGB)
        if (-not (Read-YesNo 'Zastosować mimo to?')) { return }
    }
    $mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    Set-D01Reg -Path $mm -Name 'DisablePagingExecutive' -Value 1 -Desc 'Jądro i sterowniki trzymane w RAM (mniej wywołań strony = mniej mikro-stutterów)'
    Set-D01Reg -Path $mm -Name 'LargeSystemCache' -Value 0 -Desc 'Priorytet pamięci podręcznej dla programów (nie serwerowych)'
    $script:RebootNeeded = $true
    Add-D01Applied 'reg-memory' 'Memory Management: DisablePagingExecutive=1'
}

# ----------------------------------------------------------------------------
# 3) USŁUGI I ZADANIA
# ----------------------------------------------------------------------------
function Disable-TelemetryServices {
    Write-Step 'Usługi: telemetria i diagnostyka'
    Set-D01Service -Name 'DiagTrack'         -Startup Disabled -Desc 'Telemetria (Connected User Experiences and Telemetry)'
    Set-D01Service -Name 'dmwappushservice'  -Startup Disabled -Desc 'WAP push / routing telemetrii'
    foreach ($t in $script:TelemetryTasks) { Set-D01Task -FullName $t -Action Disable }
    Add-D01Applied 'svc-telemetry' 'Telemetria: usługi i zadania wyłączone'
}

function Disable-XboxServices {
    Write-Step 'Usługi: Xbox / Game Bar w tle'
    Write-Info 'Jeśli grasz przez Game Pass / używasz kontrolera Xbox z Game Bar - rozważ pominięcie.'
    Set-D01Service -Name 'XblAuthManager'  -Startup Disabled -Desc 'Xbox Live Auth'
    Set-D01Service -Name 'XblGameSave'     -Startup Disabled -Desc 'Xbox Live Game Save'
    Set-D01Service -Name 'XboxNetApiSvc'   -Startup Disabled -Desc 'Xbox Live Networking'
    Set-D01Service -Name 'XboxGipSvc'      -Startup Disabled -Desc 'Xbox Accessory Management'
    Add-D01Applied 'svc-xbox' 'Usługi Xbox wyłączone'
}

function Disable-MiscServices {
    Write-Step 'Usługi: pozostałe zbędne (Mapy, Retail Demo, Fax, WMP, Delivery Optimization)'
    Set-D01Service -Name 'MapsBroker'       -Startup Disabled -Desc 'Menedżer pobranych map (Mapy offline)'
    Set-D01Service -Name 'RetailDemo'       -Startup Disabled -Desc 'Tryb demonstracyjny sklepu'
    Set-D01Service -Name 'Fax'              -Startup Disabled -Desc 'Faks'
    Set-D01Service -Name 'WMPNetworkSvc'    -Startup Disabled -Desc 'Udostępnianie w sieci Windows Media Player'
    Set-D01Service -Name 'DoSvc'            -Startup Disabled -Desc 'Optymalizacja dostarczania (P2P aktualizacje w tle)'
    Add-D01Applied 'svc-misc' 'Usługi: Maps/Retail/Fax/WMP/DoSvc wyłączone'
}

function Disable-WindowsSearch {
    Write-Step 'Usługa: Windows Search (indeksowanie)'
    Write-Warn 'Po wyłączeniu wyszukiwanie w menu Start/eksploratorze nadal działa, ale będzie WOLNIEJSZE (bez indeksu).'
    if ($script:DryRun) { Write-Info '[DRY-RUN] WSearch: Automatic -> Disabled'; return }
    Set-D01Service -Name 'WSearch' -Startup Disabled -Desc 'Windows Search / indeksowanie plików'
    Add-D01Applied 'svc-wsearch' 'Windows Search wyłączone'
}

function Suspend-WindowsUpdate {
    Write-Step 'Usługa: Windows Update w tle (wstrzymanie na czas grania)'
    Write-Warn 'System przestanie pobierać/instalować aktualizacje W TLE. Pamiętaj, by czasem wznowić usługę (menu 3 -> [7]).'
    Set-D01Service -Name 'wuauserv' -Startup Disabled -Desc 'Windows Update (wstrzymany przez d01i)'
    Set-D01Service -Name 'DoSvc'    -Startup Disabled -Desc 'Optymalizacja dostarczania'
    Set-D01Task -FullName '\Microsoft\Windows\WindowsUpdate\Scheduled Start' -Action Disable
    Add-D01Applied 'svc-wu-paused' 'Windows Update wstrzymany'
}

function Resume-WindowsUpdate {
    Write-Step 'Usługa: Windows Update - wznowienie'
    Set-D01Service -Name 'wuauserv' -Startup Manual -Desc 'Windows Update (przywrócony)'
    Set-D01Task -FullName '\Microsoft\Windows\WindowsUpdate\Scheduled Start' -Action Enable
    Add-D01Applied 'svc-wu-resumed' 'Windows Update wznowiony'
}

function Invoke-ServiceBasePack {
    Disable-TelemetryServices
    Disable-XboxServices
    Disable-MiscServices
    Write-Ok 'Zestaw bazowy usług zastosowany.'
}

function Restore-ServicesDefault {
    Write-Step 'Przywracanie usług do stanu domyślnego'
    $restored = 0
    # 1) na podstawie zapisanych stanów
    $saved = @($script:State.ServiceUndo)
    foreach ($s in $saved) {
        $mode = $s.OldMode
        if ($mode -eq 'Auto') { $mode = 'Automatic' }
        if ($script:DryRun) { Write-Info ("[DRY-RUN] SVC-UNDO: {0} -> {1}" -f $s.Name, $mode); continue }
        try {
            Set-Service -Name $s.Name -StartupType $mode -ErrorAction Stop
            Set-ItemProperty -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $s.Name) -Name DelayedAutoStart -Value ([int]$s.OldDelayed) -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Ok ("SVC-UNDO: {0} -> {1}" -f $s.Name, $mode)
            $restored++
        } catch { Write-Warn ("SVC-UNDO {0}: {1}" -f $s.Name, $_.Exception.Message) }
    }
    # 2) dla usług bez zapisu - wartości fabryczne
    foreach ($name in $script:ServiceDefaults.Keys) {
        $already = @($saved | Where-Object { $_.Name -eq $name }).Count -gt 0
        if ($already) { continue }
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($script:DryRun) { Write-Info ("[DRY-RUN] SVC-DEFAULT: {0} -> {1}" -f $name, $script:ServiceDefaults[$name]); continue }
        try {
            Set-Service -Name $name -StartupType $script:ServiceDefaults[$name] -ErrorAction Stop
            $restored++
        } catch { Write-Warn ("SVC-DEFAULT {0}: {1}" -f $name, $_.Exception.Message) }
    }
    if (-not $script:DryRun) { $script:State.ServiceUndo = @(); Save-D01State }
    Write-Ok ("Przywrócono usług: {0}" -f $restored)
}

function Enable-TelemetryTasks {
    Write-Step 'Włączanie zadań planowanych (przywracanie)'
    foreach ($t in $script:TelemetryTasks) { Set-D01Task -FullName $t -Action Enable }
    Set-D01Task -FullName '\Microsoft\Windows\WindowsUpdate\Scheduled Start' -Action Enable
    Set-D01Task -FullName '\Microsoft\Windows\Defrag\ScheduledDefrag' -Action Enable
}

# ----------------------------------------------------------------------------
# 4) DEBLOAT / INTERFEJS
# ----------------------------------------------------------------------------
$script:BloatList = @(
    'Microsoft.3DBuilder',                 # 3D Builder
    'Microsoft.Microsoft3DViewer',         # Podgląd 3D
    'Microsoft.BingNews',                  # Wiadomości
    'Microsoft.BingWeather',               # Pogoda
    'Microsoft.GetHelp',                   # Uzyskaj pomoc
    'Microsoft.Getstarted',                # Wskazówki
    'Microsoft.MicrosoftOfficeHub',        # Office (hub reklamowy)
    'Microsoft.MicrosoftSolitaireCollection', # Pasjans
    'Microsoft.People',                    # Osoby
    'Microsoft.SkypeApp',                  # Skype
    'Microsoft.Todos',                     # To Do
    'Microsoft.WindowsFeedbackHub',        # Centrum opinii
    'Microsoft.WindowsMaps',               # Mapy
    'Microsoft.YourPhone',                 # Łącze z telefonem
    'Microsoft.ZuneMusic',                 # Media Player (reklamowe)
    'Microsoft.ZuneVideo',                 # Filmy i TV
    'Microsoft.MixedReality.Portal',       # Portal MR
    'MicrosoftTeams',                      # Teams (osobisty)
    'Clipchamp.Clipchamp',                 # Clipchamp
    'SpotifyAB.SpotifyMusic',              # preinstalowany Spotify
    'king.com.CandyCrushSaga',             # promocje Candy Crush
    'king.com.CandyCrushSodaSaga',
    'Disney.37853FC22B2CE'                 # Disney+ (promocja)
)

function Remove-Bloatware {
    Write-Step 'Debloat: usuwanie bezpiecznych aplikacji preinstalowanych'
    Write-Host ''
    Write-Host '  Lista usuwanych aplikacji (apki sklepowe, odinstalowywalne, NIE ruszamy: Microsoft Store, Kalkulator, Zdjęcia, sterowników):' -ForegroundColor DarkGray
    foreach ($b in $script:BloatList) { Write-Host ('   - ' + $b) -ForegroundColor DarkGray }
    Write-Host ''
    if (-not (Read-YesNo 'Kontynuować usuwanie powyższych aplikacji?')) { Write-Info 'Anulowano.'; return }

    $removed = 0
    foreach ($pkgName in $script:BloatList) {
        if ($script:DryRun) {
            Write-Info ("[DRY-RUN] AppX: Remove-AppxPackage -AllUsers {0}" -f $pkgName)
            continue
        }
        Ensure-D01Backup
        try {
            $pkgs = Get-AppxPackage -Name $pkgName -AllUsers -ErrorAction SilentlyContinue
            foreach ($p in $pkgs) {
                try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; $removed++ } catch { }
            }
            $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $pkgName }
            foreach ($pp in $prov) {
                try { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null } catch { }
            }
            if ($pkgs -or $prov) { Write-Ok ("AppX usunięta: {0}" -f $pkgName) }
        } catch {
            Write-Warn ("AppX {0}: {1}" -f $pkgName, $_.Exception.Message)
        }
    }
    if ($script:DryRun) { Write-Info '[DRY-RUN] Powyższe pakiety ZOSTAŁYBY usunięte.' ; return }
    Write-Ok ("Debloat zakończony. Usunięto pakietów: {0}" -f $removed)
    Write-Info 'Przywracanie: Microsoft Store -> Biblioteka, albo np.  winget install 9WZDNCRFHVJL  (wskazana apka).'
    Add-D01Applied 'debloat-appx' ("Debloat: usunięto {0} pakietów" -f $removed)
}

function Set-UiPerformance {
    Write-Step 'Interfejs: animacje i opóźnienia -> tryb wydajności'
    Set-D01Reg -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2 -Desc 'Dopasuj dla uzyskania najlepszej wydajności'
    Set-D01Reg -Path 'HKCU:\Control Panel\Desktop' -Name 'MenuShowDelay' -Value '0' -Type String -Desc 'Menu otwierane natychmiast'
    Set-D01Reg -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '0' -Type String -Desc 'Brak animacji minimalizowania'
    Set-D01Reg -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Value 0 -Desc 'Przezroczystość paska zadań OFF'
    Set-D01Reg -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAnimations' -Value 0 -Desc 'Animacje paska zadań OFF'
    Write-Info 'Pełny efekt po ponownym ZALOGOWANIU.'
    Add-D01Applied 'ui-performance' 'Interfejs: tryb wydajności'
    $script:RebootNeeded = $true
}

function Disable-BackgroundApps {
    Write-Step 'Aplikacje w tle: WYŁĄCZENIE globalne'
    Write-Warn 'Może wpłynąć na powiadomienia z apek sklepowych, widgety i Łącze z telefonem.'
    if (-not (Read-YesNo 'Kontynuować?')) { return }
    Set-D01Reg -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' -Name 'GlobalUserDisabled' -Value 1 -Desc 'Globalne wyłączenie działania aplikacji w tle'
    Add-D01Applied 'ui-background' 'Aplikacje w tle wyłączone'
}

function Disable-WidgetsAndNews {
    Write-Step 'Widżety / Wiadomości i zainteresowania / podpowiedzi wyszukiwania: OFF'
    Set-D01Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0 -Desc 'Polityka: widżety/wiadomości OFF'
    Set-D01Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' -Name 'EnableFeeds' -Value 0 -Desc 'Polityka: kanały informacyjne OFF'
    Set-D01Reg -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' -Name 'IsDynamicSearchBoxEnabled' -Value 0 -Desc 'Wyróżnienia wyszukiwania OFF'
    Set-D01Reg -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SilentInstalledAppsEnabled' -Value 0 -Desc 'Brak cichej instalacji sugerowanych apek'
    Set-D01Reg -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SystemPaneSuggestionsEnabled' -Value 0 -Desc 'Brak sugestii w menu Start'
    Set-D01Reg -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338389Enabled' -Value 0 -Desc 'Brak porad i wskazówek systemowych'
    Add-D01Applied 'ui-widgets' 'Widżety/wiadomości/sugestie wyłączone'
}

# ----------------------------------------------------------------------------
# 5) SIEĆ
# ----------------------------------------------------------------------------
function Get-ActivePhysicalAdapters {
    try { return @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }) }
    catch { return @() }
}

function Set-D01Dns {
    param([string[]]$Servers, [string]$ProviderName)
    Write-Step ("DNS: {0} ({1})" -f $ProviderName, ($Servers -join ', '))
    $adapters = Get-ActivePhysicalAdapters
    if ($adapters.Count -eq 0) { Write-Warn 'Brak aktywnych fizycznych kart sieciowych.'; return }

    foreach ($a in $adapters) {
        if ($script:DryRun) {
            Write-Info ("[DRY-RUN] DNS na karcie '{0}' -> {1}" -f $a.Name, ($Servers -join ', '))
            continue
        }
        Ensure-D01Backup
        # zapisz poprzednie DNS (jednorazowo na kartę)
        $saved = @($script:State.DnsBackup | Where-Object { $_.ifIndex -eq $a.ifIndex }).Count -gt 0
        if (-not $saved) {
            try {
                $old = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses
                $script:State.DnsBackup += [pscustomobject]@{ ifIndex=$a.ifIndex; Name=$a.Name; Servers=@($old) }
                Save-D01State
            } catch { }
        }
        try {
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $Servers -ErrorAction Stop
            Write-Ok ("DNS ({0}) ustawione na karcie: {1}" -f $ProviderName, $a.Name)
            Add-D01Applied ("net-dns-{0}" -f $ProviderName) ("DNS={0}" -f $ProviderName)
        } catch { Write-Err ("DNS na karcie {0}: {1}" -f $a.Name, $_.Exception.Message) }
    }
    Write-Info 'Zmiana jest natychmiastowa. Przywrócenie: menu Sieć -> [3].'
}

function Reset-D01Dns {
    Write-Step 'DNS: przywracanie ustawień'
    $adapters = Get-ActivePhysicalAdapters
    $backup = @($script:State.DnsBackup)
    if ($backup.Count -eq 0) {
        Write-Info 'Brak zapisanego stanu DNS - przywracam automatyczne pobieranie (DHCP).'
    }
    foreach ($a in $adapters) {
        if ($script:DryRun) { Write-Info ("[DRY-RUN] DNS reset na karcie {0}" -f $a.Name); continue }
        $b = $backup | Where-Object { $_.ifIndex -eq $a.ifIndex } | Select-Object -First 1
        try {
            if ($b -and @($b.Servers).Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses ([string[]]$b.Servers) -ErrorAction Stop
                Write-Ok ("DNS przywrócone na karcie {0}: {1}" -f $a.Name, ([string[]]$b.Servers -join ', '))
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
                Write-Ok ("DNS z DHCP przywrócone na karcie {0}" -f $a.Name)
            }
        } catch { Write-Warn ("DNS reset {0}: {1}" -f $a.Name, $_.Exception.Message) }
    }
    if (-not $script:DryRun) { $script:State.DnsBackup = @(); Save-D01State }
}

function Disable-Nagle {
    Write-Step "Wyłączanie algorytmu Nagle'a (TCP no-delay) na wszystkich interfejsach"
    Write-Info 'Obniża opóźnienie małych pakietów TCP (input w grach online / kliknięcia / pozycje).'
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    $ifs = @()
    try { $ifs = @(Get-ChildItem -LiteralPath $base -ErrorAction Stop) } catch { Write-Err 'Brak dostępu do klucza interfejsów TCP/IP.'; return }
    foreach ($i in $ifs) {
        Set-D01Reg -Path $i.PSPath -Name 'TcpAckFrequency' -Value 1 -Desc 'Potwierdzaj każdy segment TCP natychmiast'
        Set-D01Reg -Path $i.PSPath -Name 'TCPNoDelay'      -Value 1 -Desc 'Wyłącz buforowanie Nagle'
    }
    if (-not $script:DryRun) {
        Write-Ok ("Przetworzono interfejsów: {0}" -f $ifs.Count)
        Write-Info 'Zrestartuj kartę sieciową lub komputer, aby zmiana weszła w życie.'
        Add-D01Applied 'net-nagle' "Algorytm Nagle'a wyłączony"
    }
    $script:RebootNeeded = $true
}

function Set-QosBandwidth {
    Write-Step 'QoS: wyłączenie rezerwacji pasma (NonBestEffortLimit = 0)'
    Set-D01Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' -Name 'NonBestEffortLimit' -Value 0 -Desc '0% pasma zarezerwowane dla QoS (domyślnie 20%)'
    Add-D01Applied 'net-qos-bandwidth' 'NonBestEffortLimit=0'
}

function New-GameQosPolicy {
    Write-Step 'QoS: polityka priorytetowa dla wybranej gry (DSCP 46)'
    $exe = Read-Host '  Podaj pełną ścieżkę do pliku .exe gry'
    if ([string]::IsNullOrWhiteSpace($exe)) { Write-Info 'Przerwano.'; return }
    $exe = $exe.Trim('"')
    if (-not (Test-Path $exe)) { Write-Warn 'Plik nie istnieje - i tak mogę utworzyć politykę, ale sprawdź ścieżkę.'; }

    $policyName = 'd01i-' + (Split-Path $exe -Leaf)
    if ($script:DryRun) {
        Write-Info ("[DRY-RUN] New-NetQosPolicy -Name '{0}' -AppPathName '{1}' -DSCP 46" -f $policyName, $exe)
        return
    }
    Ensure-D01Backup
    try {
        $existing = Get-NetQosPolicy -Name $policyName -ErrorAction SilentlyContinue
        if ($existing) { Remove-NetQosPolicy -Name $policyName -Confirm:$false -ErrorAction SilentlyContinue }
        New-NetQosPolicy -Name $policyName -AppPathNameMatchCondition $exe -IPProtocolMatchCondition Both -DSCPAction 46 -ErrorAction Stop | Out-Null
        $script:State.QosPolicies += $policyName; Save-D01State
        Write-Ok ("Utworzono politykę QoS: {0} (DSCP EF/46)" -f $policyName)
        Write-Info 'Priorytet DSCP zadziała w pełni, gdy router/ISP honoruje znaczniki DSCP.'
        Add-D01Applied 'net-qos-game' ("QoS dla: {0}" -f $exe)
    } catch { Write-Err ("QoS: {0}" -f $_.Exception.Message) }
}

function Disable-NicPowerSaving {
    Write-Step 'Karty sieciowe: wyłączanie oszczędzania energii'
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    if ($adapters.Count -eq 0) { Write-Warn 'Nie znaleziono fizycznych kart.'; return }
    foreach ($a in $adapters) {
        if ($script:DryRun) { Write-Info ("[DRY-RUN] Disable-NetAdapterPowerManagement -Name '{0}'" -f $a.Name); continue }
        Ensure-D01Backup
        try {
            Disable-NetAdapterPowerManagement -Name $a.Name -ErrorAction Stop
            Write-Ok ("Zarządzanie energią OFF: {0}" -f $a.Name)
        } catch { Write-Warn ("{0}: {1}" -f $a.Name, $_.Exception.Message) }
    }
    Add-D01Applied 'net-nic-power' 'Power management kart sieciowych wyłączony'
}

function Show-MtuMenu {
    Write-Step 'MTU: podgląd / zmiana'
    try {
        Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.ConnectionState -eq 'Connected' } |
            Select-Object InterfaceAlias, NlMtu | Format-Table -AutoSize | Out-Host
    } catch { Write-Warn 'Nie można odczytać interfejsów.' ; return }

    if (-not (Read-YesNo 'Chcesz zmienić MTU na wybranej karcie?')) { return }
    $alias = Read-Host '  Nazwa karty (InterfaceAlias)'
    $mtu   = Read-Host '  Nowe MTU (typowo 1500; dla PPPoE często 1492)'
    [int]$mtuInt = 0
    if (-not [int]::TryParse($mtu, [ref]$mtuInt) -or $mtuInt -lt 576 -or $mtuInt -gt 9000) { Write-Err 'Nieprawidłowa wartość MTU.'; return }
    if ($script:DryRun) { Write-Info ("[DRY-RUN] Set-NetIPInterface -InterfaceAlias '{0}' -NlMtuBytes {1}" -f $alias, $mtuInt); return }
    Ensure-D01Backup
    try {
        Set-NetIPInterface -InterfaceAlias $alias -NlMtuBytes $mtuInt -ErrorAction Stop
        Write-Ok ("MTU zmienione: {0} -> {1}" -f $alias, $mtuInt)
        Write-Info 'Test fragmentacji:  ping -f -l 1472 1.1.1.1  (dla MTU 1500)'
    } catch { Write-Err ("MTU: {0}" -f $_.Exception.Message) }
}

# ----------------------------------------------------------------------------
# 6) GPU
# ----------------------------------------------------------------------------
function Enable-Hags {
    Write-Step 'GPU: Hardware-Accelerated GPU Scheduling (HAGS) - WŁĄCZENIE'
    if ($null -ne $script:Hw -and $script:Hw.GpuVendor -eq 'Intel') {
        Write-Warn 'Wykryto GPU Intel - HAGS wspierany tylko na części układów; efekt może być neutralny.'
    }
    Set-D01Reg -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2 -Desc 'HAGS: harmonogramowanie GPU sprzętowo (mniejszy narzut, lepsze frame-time)'
    $script:RebootNeeded = $true
    Add-D01Applied 'gpu-hags' 'HAGS włączony'
}

function Disable-Hags {
    Set-D01Reg -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 1 -Desc 'HAGS: przywrócenie domyślnego (software scheduling)'
    $script:RebootNeeded = $true
}

function Get-ReBarStatus {
    Write-Step 'Re-Size BAR / Smart Access Memory: status'
    $found = $false
    if ($null -ne $script:Hw -and $script:Hw.GpuVendor -eq 'NVIDIA') {
        try {
            $smi = (& nvidia-smi.exe -q 2>&1 | Out-String)
            if ($smi -match 'Resizable BAR\s*:\s*Yes') { Write-Ok 'NVIDIA: Resizable BAR = WŁĄCZONY'; $found = $true }
            elseif ($smi -match 'Resizable BAR\s*:\s*No') { Write-Warn 'NVIDIA: Resizable BAR = WYŁĄCZONY (włącz w BIOS - patrz manual, sekcja 6)'; $found = $true }
        } catch { Write-Info 'nvidia-smi niedostępne (brak w PATH) - sprawdź w Panelu NVIDIA: Informacje o systemie.' }
    }
    if (-not $found) {
        Write-Info 'Status Re-Size BAR sprawdzisz: NVIDIA -> nvidia-smi -q | AMD -> Radeon Software -> Wydajność.'
        Write-Info 'Włącz w BIOS: PCI/PCIe Subsystem -> "Above 4G Decoding" + "Re-Size BAR Support" (CSM wyłączony).'
    }
    Write-Info 'Szczegóły: d01i_bios_manual.md, sekcja 6.'
}

function Clear-ShaderCaches {
    Write-Step 'GPU: czyszczenie cache shaderów'
    $paths = @(
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA Corporation\NV_Cache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'D3DSCache')
    )
    $totalMB = 0
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $size = 0
            try { $size = [math]::Round(((Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB), 1) } catch { }
            if ($script:DryRun) { Write-Info ("[DRY-RUN] Czyszczenie: {0} ({1} MB)" -f $p, $size); continue }
            try {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                Write-Ok ("Wyczyszczono: {0} ({1} MB)" -f $p, $size)
                $totalMB += $size
            } catch { Write-Warn ("{0}: {1}" -f $p, $_.Exception.Message) }
        }
    }
    if (-not $script:DryRun) {
        Write-Ok ("Cache shaderów wyczyszczony. Zwolniono ok. {0} MB." -f [math]::Round($totalMB,1))
        Write-Info 'Pierwsze uruchomienie gier po czyszczeniu może trochę trwać (shadery skompilują się od nowa - potem będzie gładko).'
    }
    Add-D01Applied 'gpu-shadercache' ("Cache shaderów: {0} MB" -f $totalMB)
}

function Disable-NvidiaBackground {
    Write-Step 'NVIDIA: ograniczanie procesów w tle'
    Set-D01Service -Name 'NvTelemetryContainer' -Startup Disabled -Desc 'Telemetria NVIDIA (jeśli istnieje w starszych sterownikach)'
    Write-Warn 'NVDisplay.ContainerLocalSystem przełączam w tryb Manual. Panel NVIDIA wystartuje usługę na żądanie.'
    Set-D01Service -Name 'NVDisplay.ContainerLocalSystem' -Startup Manual -Desc 'NVIDIA Container -> Manual'
    Add-D01Applied 'gpu-nvidia-bg' 'NVIDIA: usługi w tle ograniczone'
}

function Set-AmdBackground {
    Write-Step 'AMD: usługi w tle -> Manual'
    Set-D01Service -Name 'AMD External Events Utility' -Startup Manual -Desc 'AMD External Events -> Manual'
    Add-D01Applied 'gpu-amd-bg' 'AMD External Events -> Manual'
}

# ----------------------------------------------------------------------------
# 7) PROFILE SPRZĘTOWE (jedno kliknięcie)
# ----------------------------------------------------------------------------
function Get-RecommendedProfileId {
    if ($null -eq $script:Hw) { return '' }
    if ($script:Hw.IsLaptop) { return 'LAPTOP' }
    if ($script:Hw.CpuVendor -eq 'AMD'   -and $script:Hw.GpuVendor -eq 'NVIDIA') { return 'RYZEN-NVIDIA' }
    if ($script:Hw.CpuVendor -eq 'Intel' -and $script:Hw.GpuVendor -eq 'NVIDIA') { return 'INTEL-NVIDIA' }
    if ($script:Hw.CpuVendor -eq 'AMD'   -and $script:Hw.GpuVendor -eq 'AMD')    { return 'RYZEN-AMD' }
    if ($script:Hw.CpuVendor -eq 'Intel' -and $script:Hw.GpuVendor -eq 'AMD')    { return 'INTEL-AMD' }
    return ''
}

function Invoke-Profile {
    param([string]$ProfileId)
    Write-Step ("PROFIL: {0}" -f $ProfileId)
    Write-Host '  Profil zastosuje sprawdzony zestaw: zasilanie + rejestr (MMCSS/priorytety/GameDVR) +' -ForegroundColor DarkGray
    Write-Host '  usługi bazowe + zadania + Nagle off + QoS limit + HAGS + czyszczenie cache shaderów.' -ForegroundColor DarkGray
    Write-Host '  Sekcja ZAAWANSOWANA (VBS itd.) oraz DEBLOAT NIE są częścią profilu - uruchamiasz je świadomie z menu.' -ForegroundColor DarkGray
    Write-Host ''
    if (-not (Read-YesNo 'Zastosować profil teraz?')) { Write-Info 'Anulowano.'; return }

    Ensure-D01Backup

    switch ($ProfileId) {
        'RYZEN-NVIDIA' {
            Set-RyzenPlan
            Set-PowerLowLatency -SkipCpuBoostBits    # Ryzen sam zarządza parkowaniem / CPPC
        }
        'RYZEN-AMD' {
            Set-RyzenPlan
            Set-PowerLowLatency -SkipCpuBoostBits
        }
        'INTEL-NVIDIA' {
            Enable-UltimatePlan
            Set-PowerLowLatency
        }
        'INTEL-AMD' {
            Enable-UltimatePlan
            Set-PowerLowLatency
        }
        'LAPTOP' {
            Write-Info 'Profil laptopa: bez wymuszania 100% CPU, nacisk na niskie opóźnienia i przewidywalny pakiet.'
            Set-BalancedPlan
            Set-PowerLowLatency -SkipCpuBoostBits
        }
        default { Write-Err 'Nieznany profil.'; return }
    }

    Set-MmcssGaming
    Set-PrioritiesPack
    Invoke-ServiceBasePack
    Suspend-WindowsUpdate
    Disable-Nagle
    Set-QosBandwidth
    Disable-NicPowerSaving
    Enable-Hags
    Clear-ShaderCaches

    if ($null -ne $script:Hw) {
        if ($script:Hw.GpuVendor -eq 'NVIDIA') { Disable-NvidiaBackground }
        if ($script:Hw.GpuVendor -eq 'AMD')    { Set-AmdBackground }
    }

    Add-D01Applied ("profile-" + $ProfileId) ("Zastosowano profil {0}" -f $ProfileId)
    Write-Host ''
    Write-Ok ("Profil {0} zastosowany." -f $ProfileId)
    Write-Info 'Pamiętaj o restarcie systemu, jeśli pojawiło się o tym info. Debloat i VBS zostają Twoją decyzją (menu 4 i 8).'
}

# ----------------------------------------------------------------------------
# 8) ZAAWANSOWANE  (VBS/HVCI, SysMain, defragmentacja SSD, plik strony)
# ----------------------------------------------------------------------------
function Show-VbsStatus {
    Write-Step 'Status VBS / HVCI (Core Isolation / Memory Integrity)'
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
        $vbsState = [int]$dg.VirtualizationBasedSecurityStatus   # 0=off, 1=enabled-not-running, 2=running
        $hvci = @($dg.SecurityServicesRunning) -contains 2
        $vbsTxt = switch ($vbsState) { 0 {'WYŁĄCZONY (działa pełna wydajność)'} 1 {'WŁĄCZONY, ale nieaktywny'} 2 {'AKTYWNY (uruchomiony)'} default {"nieznany ($vbsState)"} }
        Write-Host ("   VBS : {0}" -f $vbsTxt) -ForegroundColor $(if ($vbsState -eq 2) {'Yellow'} else {'Green'})
        Write-Host ("   HVCI (Memory Integrity): {0}" -f $(if ($hvci) {'AKTYWNY'} else {'nieaktywny'})) -ForegroundColor $(if ($hvci) {'Yellow'} else {'Green'})
        Write-Host '   Uwaga: aktywne VBS/HVCI kosztuje zwykle 3-8% wydajności CPU-bound w grach.' -ForegroundColor DarkGray
    } catch {
        Write-Warn 'Nie można odczytać statusu DeviceGuard (brak klasy WMI?).'
    }
}

function Disable-Vbs {
    Write-Step 'WYŁĄCZANIE VBS / HVCI (Core Isolation)'
    Write-Host ''
    Write-Host '  !! OSTRZEŻENIE BEZPIECZEŃSTWA !!' -ForegroundColor Red
    Write-Host '  Wyłączenie VBS/HVCI obniża odporność systemu na ataki (m.in. na sterowniki' -ForegroundColor Yellow
    Write-Host '  i kradzież poświadczeń). Na maszynie wyłącznie do gier zysk bywa odczuwalny,' -ForegroundColor Yellow
    Write-Host '  ale jeśli używasz tego komputera do bankowości/pracy - NIE rób tego.' -ForegroundColor Yellow
    Write-Host '  Zmiana jest odwracalna (opcja [3] w tej sekcji). Wymagany restart.' -ForegroundColor Yellow
    Write-Host ''
    $code = Read-Host '  Aby potwierdzić, wpisz dokładnie: WYLACZ'
    if ($code.Trim().ToUpper() -ne 'WYLACZ') { Write-Info 'Anulowano.'; return }

    Show-VbsStatus
    Set-D01Reg -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -Value 0 -Desc 'VBS OFF'
    Set-D01Reg -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -Value 0 -Desc 'HVCI / Memory Integrity OFF'
    Set-D01Reg -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard' -Name 'Enabled' -Value 0 -Desc 'Credential Guard OFF'

    if ($script:DryRun) {
        Write-Info '[DRY-RUN] bcdedit /set {current} hypervisorlaunchtype off'
    } else {
        & bcdedit.exe /set '{current}' hypervisorlaunchtype off 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Hypervisor launch: OFF' } else { Write-Warn 'bcdedit zwrócił błąd (Hyper-V może być nadal aktywny).' }
        $script:State.VbsDisabled = $true; Save-D01State
    }
    $script:RebootNeeded = $true
    Add-D01Applied 'adv-vbs-off' 'VBS/HVCI wyłączone (świadoma zgoda)'
    Write-Warn 'Wymagany PEŁNY restart komputera. Po restarcie sprawdź status opcją [1].'
}

function Enable-Vbs {
    Write-Step 'WŁĄCZANIE ponowne VBS / HVCI'
    Remove-D01Reg -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -Desc 'VBS: powrót do ustawień systemowych'
    Remove-D01Reg -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -Desc 'HVCI: powrót do ustawień systemowych'
    Remove-D01Reg -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard' -Name 'Enabled' -Desc 'Credential Guard: powrót do ustawień systemowych'
    if ($script:DryRun) {
        Write-Info '[DRY-RUN] bcdedit /set {current} hypervisorlaunchtype Auto'
    } else {
        & bcdedit.exe /set '{current}' hypervisorlaunchtype Auto 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Hypervisor launch: Auto' } else { Write-Warn 'bcdedit zwrócił błąd.' }
        $script:State.VbsDisabled = $false; Save-D01State
    }
    $script:RebootNeeded = $true
    Write-Info 'Po restarcie włącz Izolację rdzenia w: Zabezpieczenia Windows -> Zabezpieczenia urządzenia.'
}

function Disable-SysMain {
    Write-Step 'SysMain (Superfetch) - wyłączenie'
    if ($null -ne $script:Hw -and -not $script:Hw.IsSSD) {
        Write-Warn 'Wykryto dysk HDD - SysMain wyłącza się raczej tylko na SSD/NVMe.'
        if (-not (Read-YesNo 'Zastosować mimo to?')) { return }
    }
    Set-D01Service -Name 'SysMain' -Startup Disabled -Desc 'Superfetch wyłączony (SSD)'
    Add-D01Applied 'adv-sysmain' 'SysMain wyłączony'
}

function Disable-ScheduledDefrag {
    Write-Step 'Zaplanowana defragmentacja - wyłączenie'
    if ($null -ne $script:Hw -and -not $script:Hw.IsSSD) {
        Write-Warn 'Na HDD regularna defragmentacja jest POTRZEBNA. Przerywam.'
        return
    }
    Write-Warn 'To samo zadanie wykonuje cykliczny TRIM. Rozważ ręczne "Optimize drives" raz na miesiąc.'
    Set-D01Task -FullName '\Microsoft\Windows\Defrag\ScheduledDefrag' -Action Disable
    Add-D01Applied 'adv-defrag' 'ScheduledDefrag wyłączony (SSD)'
}

function Set-PagefileMenu {
    Write-Step 'Plik strony (pagefile)'
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        Write-Info ("Automatyczne zarządzanie: {0}" -f $(if ($cs.AutomaticManagedPagefile) {'TAK (domyślne, zalecane)'} else {'NIE'}))
    } catch { }
    Write-Host '   [1] Zarządzany przez system (ZALECANE w 95% przypadków)' -ForegroundColor White
    Write-Host '   [2] Stały rozmiar (zaawansowane - np. gdy SSD ma mało miejsca)' -ForegroundColor White
    Write-Host '   [0] Powrót' -ForegroundColor White
    $c = Read-Host '  Wybór'
    switch ($c) {
        '1' {
            if ($script:DryRun) { Write-Info '[DRY-RUN] AutomaticManagedPagefile = True'; return }
            Ensure-D01Backup
            try {
                $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
                Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
                Write-Ok 'Plik strony: zarządzany przez system.'
                $script:State.PagefileTouched = $false; Save-D01State
            } catch { Write-Err ("Pagefile: {0}" -f $_.Exception.Message) }
            $script:RebootNeeded = $true
        }
        '2' {
            $mbTxt = Read-Host '  Stały rozmiar w MB (np. 8192). Minimalnie 2048'
            [int]$mb = 0
            if (-not [int]::TryParse($mbTxt, [ref]$mb) -or $mb -lt 2048) { Write-Err 'Nieprawidłowa wartość (min. 2048 MB).'; return }
            if ($script:DryRun) { Write-Info ("[DRY-RUN] Pagefile stały = {0} MB na {1}" -f $mb, $env:SystemDrive); return }
            Ensure-D01Backup
            try {
                $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
                Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
                $pfPath = $env:SystemDrive + '\pagefile.sys'
                $wqlName = $pfPath -replace '\\', '\\'
                $pf = Get-CimInstance Win32_PageFileSetting -Filter ("Name='" + $wqlName + "'") -ErrorAction SilentlyContinue
                if ($pf) {
                    Set-CimInstance -InputObject $pf -Property @{ InitialSize = $mb; MaximumSize = $mb } -ErrorAction Stop
                } else {
                    New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $pfPath; InitialSize = $mb; MaximumSize = $mb } -ErrorAction Stop | Out-Null
                }
                Write-Ok ("Plik strony ustawiony: {0} MB (stały) na {1}" -f $mb, $env:SystemDrive)
                $script:State.PagefileTouched = $true; Save-D01State
            } catch { Write-Err ("Pagefile: {0}" -f $_.Exception.Message) }
            $script:RebootNeeded = $true
        }
        default { return }
    }
}

# ----------------------------------------------------------------------------
# 9) PRZYWRACANIE DOMYŚLNYCH / COFANIE ZMIAN
# ----------------------------------------------------------------------------
function Import-RegistryBackup {
    Write-Step 'Import pełnego backupu rejestru (.reg)'
    $dirs = @()
    try { $dirs = @(Get-ChildItem -LiteralPath $script:BackupDir -Directory -ErrorAction Stop | Sort-Object Name -Descending) } catch { }
    if ($dirs.Count -eq 0) { Write-Warn 'Brak katalogów backupu rejestru.'; return }

    for ($i = 0; $i -lt $dirs.Count; $i++) { Write-Host ("   [{0}] {1}" -f ($i + 1), $dirs[$i].Name) -ForegroundColor White }
    $sel = Read-Host '  Wybierz numer backupu (Enter = najnowszy)'
    $idx = 0
    if (-not [string]::IsNullOrWhiteSpace($sel)) {
        if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $dirs.Count) { Write-Err 'Zły wybór.'; return }
        $idx = $idx - 1
    }
    $chosen = $dirs[$idx].FullName
    $files = @(Get-ChildItem -LiteralPath $chosen -Filter '*.reg' -ErrorAction SilentlyContinue)
    Write-Warn ("Import nastąpi z: {0} ({1} plików .reg)" -f $chosen, $files.Count)
    if (-not (Read-YesNo 'Kontynuować import?')) { return }

    foreach ($f in $files) {
        if ($script:DryRun) { Write-Info ("[DRY-RUN] reg import {0}" -f $f.FullName); continue }
        & reg.exe import ($f.FullName) 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok ("Zaimportowano: {0}" -f $f.Name) } else { Write-Warn ("Import nieudany: {0}" -f $f.Name) }
    }
    $script:RebootNeeded = $true
}

function Restore-D01RegistryChanges {
    Write-Step 'Cofanie wpisów rejestru wykonanych przez d01i (z pliku stanu)'
    $items = @($script:State.RegUndo)
    if ($items.Count -eq 0) { Write-Info 'Brak zapisanych zmian rejestru do cofnięcia.'; return }

    $done = 0
    for ($i = $items.Count - 1; $i -ge 0; $i--) {
        $u = $items[$i]
        if ($script:DryRun) {
            $what = if ($u.HadValue) { "przywróć = $($u.OldValue)" } else { 'usuń wartość' }
            Write-Info ("[DRY-RUN] REG-UNDO: {0} :: {1} -> {2}" -f $u.Path, $u.Name, $what)
            continue
        }
        try {
            if ($u.HadValue) {
                New-ItemProperty -LiteralPath $u.Path -Name $u.Name -Value $u.OldValue -PropertyType $u.OldType -Force -ErrorAction Stop | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $u.Path -Name $u.Name -Force -ErrorAction SilentlyContinue
            }
            $done++
        } catch { Write-Warn ("REG-UNDO {0}\{1}: {2}" -f $u.Path, $u.Name, $_.Exception.Message) }
    }
    if (-not $script:DryRun) {
        $script:State.RegUndo = @(); Save-D01State
        Write-Ok ("Cofnięto wpisów rejestru: {0}" -f $done)
    }
}

function Remove-D01QosPolicies {
    Write-Step 'Usuwanie polityk QoS utworzonych przez d01i'
    $policies = @()
    try { $policies = @(Get-NetQosPolicy -ErrorAction Stop | Where-Object { $_.Name -like 'd01i-*' }) } catch { }
    if ($policies.Count -eq 0) { Write-Info 'Brak polityk d01i-* do usunięcia.'; $script:State.QosPolicies = @(); Save-D01State; return }
    foreach ($p in $policies) {
        if ($script:DryRun) { Write-Info ("[DRY-RUN] Remove-NetQosPolicy {0}" -f $p.Name); continue }
        try { Remove-NetQosPolicy -Name $p.Name -Confirm:$false -ErrorAction Stop; Write-Ok ("Usunięto: {0}" -f $p.Name) } catch { Write-Warn ("QoS {0}: {1}" -f $p.Name, $_.Exception.Message) }
    }
    if (-not $script:DryRun) { $script:State.QosPolicies = @(); Save-D01State }
}

function Invoke-RestoreDefaults {
    Write-Step 'PRZYWRACANIE USTAWIEŃ DOMYŚLNYCH / COFANIE OPTYMALIZACJI'
    Write-Host ''
    Write-Host '  Cofnięte zostaną: plan zasilania, wpisy rejestru, usługi, zadania, DNS,' -ForegroundColor Yellow
    Write-Host '  polityki QoS, hibernacja, (opcjonalnie) VBS. Usunięte apki sklepowe' -ForegroundColor Yellow
    Write-Host '  przywrócisz z Microsoft Store (info na ekranie). Punkt przywracania systemu' -ForegroundColor Yellow
    Write-Host '  utworzony na starcie pozostaje dostępny jako ostateczny ratunek.' -ForegroundColor Yellow
    Write-Host ''
    if (-not (Read-YesNo 'Na pewno COFNIĘĆ wszystkie zmiany d01i?')) { Write-Info 'Anulowano.'; return }

    Write-Step '1/8 Plan zasilania -> Zrównoważony'
    Set-BalancedPlan
    Reset-PowerLowLatency

    Write-Step '2/8 Hibernacja -> włączona (stan fabryczny)'
    Enable-Hibernation

    Write-Step '3/8 Wpisy rejestru -> cofnięcie'
    Restore-D01RegistryChanges

    Write-Step '4/8 Usługi -> domyślne'
    Restore-ServicesDefault

    Write-Step '5/8 Zadania planowane -> włączone'
    Enable-TelemetryTasks

    Write-Step '6/8 DNS + QoS -> przywrócenie'
    Reset-D01Dns
    Remove-D01QosPolicies

    Write-Step '7/8 VBS/HVCI'
    if ($script:State.VbsDisabled) {
        if (Read-YesNo 'd01i wyłączył VBS/HVCI. Włączyć z powrotem? (zalecane)') { Enable-Vbs }
    } else {
        Write-Info 'VBS nie było ruszane przez d01i.'
    }
    Disable-Hags | Out-Null   # przywrócenie domyślnego harmonogramowania, jeśli było zmienione

    Write-Step '8/8 Plik strony'
    if ($script:State.PagefileTouched -and (Read-YesNo 'Przywrócić plik strony zarządzany przez system?')) {
        try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
            $script:State.PagefileTouched = $false; Save-D01State
            Write-Ok 'Plik strony: zarządzany przez system.'
        } catch { Write-Warn ("Pagefile: {0}" -f $_.Exception.Message) }
    }

    if (-not $script:DryRun) {
        $script:State.Applied = @(); Save-D01State
        Write-Host ''
        Write-Ok 'Przywracanie zakończone.'
        Write-Info 'Aplikacje usunięte w debloat: Microsoft Store -> Biblioteka -> pobierz ponownie.'
        Write-Info 'Dodatkowo masz dostępny punkt przywracania systemu: "d01i - universal / przed optymalizacją".'
        $script:RebootNeeded = $true
    }
}

# ----------------------------------------------------------------------------
# EKRANY POMOCNICZE
# ----------------------------------------------------------------------------
function Show-StatusScreen {
    Show-Section 'STATUS SYSTEMU'
    Show-HardwareLine
    Show-VbsStatus
    Write-Host ''
    try {
        $scheme = (& powercfg.exe /getactivescheme 2>&1 | Out-String).Trim()
        Write-Host ("   Aktywny plan: {0}" -f $scheme) -ForegroundColor White
    } catch { }
    Write-Host ("   Backup rejestru: {0}" -f $(if ($script:State.LastBackupDir) { $script:State.LastBackupDir } else { 'brak (utworzy się przed pierwszą zmianą)' })) -ForegroundColor White
    Write-Host ("   Restart potrzebny: {0}" -f $(if ($script:RebootNeeded) { 'TAK' } else { 'nie' })) -ForegroundColor $(if ($script:RebootNeeded) {'Yellow'} else {'White'})
    Write-Host ''
    Write-Host '   Zastosowane pakiety:' -ForegroundColor White
    if ($script:State.Applied.Count -eq 0) { Write-Host '     (brak - czysto)' -ForegroundColor DarkGray }
    else { foreach ($a in $script:State.Applied) { Write-Host ('     - ' + $a) -ForegroundColor DarkGreen } }
    Wait-Enter
}

# ----------------------------------------------------------------------------
# MENU
# ----------------------------------------------------------------------------
function Show-MainMenu {
    $w = 66   # szerokość wnętrza ramki
    $rows = @(
        @{ T = '[1] Zasilanie i plan energii';                                     C = 'White'  },
        @{ T = '[2] Rejestr: opóźnienia / MMCSS / priorytety / GameDVR';           C = 'White'  },
        @{ T = '[3] Usługi i zadania systemowe';                                   C = 'White'  },
        @{ T = '[4] Odchudzanie systemu (debloat / interfejs)';                    C = 'White'  },
        @{ T = '[5] Sieć: DNS / Nagle / QoS / MTU';                                C = 'White'  },
        @{ T = '[6] GPU: HAGS / Re-Size BAR / cache shaderów';                     C = 'White'  },
        @{ T = '[7] PROFILE SPRZĘTOWE  (zastosuj zestaw jednym kliknięciem)';      C = 'Green'  },
        @{ T = '[8] ZAAWANSOWANE: VBS/HVCI / SysMain / pagefile   [OSTROŻNIE]';    C = 'Yellow' },
        @{ T = '[9] Przywróć ustawienia domyślne / cofnij optymalizację';          C = 'White'  },
        @{ T = '';                                                                 C = 'White'  },
        @{ T = '[B] Backup teraz (punkt przywracania + rejestr)';                  C = 'White'  },
        @{ T = '[I] Import backupu rejestru (.reg)';                               C = 'White'  },
        @{ T = '[S] Status systemu i zastosowanych zmian';                         C = 'White'  },
        @{ T = ('[D] Tryb DRY-RUN: przełącz  (teraz: ' + $(if ($script:DryRun) { 'WŁ' } else { 'WYŁ' }) + ')'); C = $(if ($script:DryRun) { 'Yellow' } else { 'White' }) },
        @{ T = '[L] Otwórz dziennik (d01i_log.txt)';                               C = 'White'  },
        @{ T = '[0] Wyjście';                                                      C = 'White'  }
    )
    Write-Host ('  ┌' + ('─' * ($w + 2)) + '┐') -ForegroundColor DarkCyan
    Write-Host ('  │' + ('      >>>  d01i - universal | MENU GŁÓWNE  <<<      ').PadRight($w + 2) + '│') -ForegroundColor DarkCyan
    Write-Host ('  ├' + ('─' * ($w + 2)) + '┤') -ForegroundColor DarkCyan
    foreach ($r in $rows) {
        $inner = ('  ' + $r.T).PadRight($w + 2)
        Write-Host ('  │' + $inner + '│') -ForegroundColor $r.C
    }
    Write-Host ('  └' + ('─' * ($w + 2)) + '┘') -ForegroundColor DarkCyan
}

function Menu-Power {
    do {
        Show-Banner
        Show-Section '1) ZASILANIE I PLAN ENERGII'
        Write-Host '   [1] Ultimate Performance (odblokuj ukryty plan + aktywuj)' -ForegroundColor White
        Write-Host '   [2] Niskie opóźnienia: PCIe ASPM off, USB suspend off, CPU min 100%, bez parkowania rdzeni' -ForegroundColor White
        Write-Host '   [3] Hibernacja: wyłącz (szybszy start, więcej miejsca na C:)' -ForegroundColor White
        Write-Host '   [4] Plan dla Ryzen (AMD Ryzen Balanced / Zrównoważony + CPPC)' -ForegroundColor White
        Write-Host '   [5] Przywróć plan Zrównoważony + domyślne zachowanie' -ForegroundColor White
        Write-Host '   [0] Powrót' -ForegroundColor White
        $c = Read-Host '  Wybierz opcję'
        switch ($c) {
            '1' { Enable-UltimatePlan; Wait-Enter }
            '2' { Set-PowerLowLatency; Wait-Enter }
            '3' { Disable-Hibernation; Wait-Enter }
            '4' { Set-RyzenPlan; Wait-Enter }
            '5' { Set-BalancedPlan; Reset-PowerLowLatency; Enable-Hibernation; Wait-Enter }
            '0' { return }
            default { Write-Warn 'Nieznana opcja.'; Start-Sleep -Milliseconds 600 }
        }
    } while ($true)
}

function Menu-Registry {
    do {
        Show-Banner
        Show-Section '2) REJESTR WINDOWS'
        Write-Host '   [1] MMCSS: SystemResponsiveness=0, throttling sieci off, profil "Games"=High' -ForegroundColor White
        Write-Host '   [2] Priorytety: Win32PrioritySeparation=0x26 + GameDVR OFF + Game Mode ON' -ForegroundColor White
        Write-Host '   [3] Memory Management: jądro w RAM (DisablePagingExecutive)' -ForegroundColor White
        Write-Host '   [4] ZASTOSUJ WSZYSTKO Z TEJ KATEGORII (zalecane)' -ForegroundColor Green
        Write-Host '   [0] Powrót' -ForegroundColor White
        $c = Read-Host '  Wybierz opcję'
        switch ($c) {
            '1' { Set-MmcssGaming; Wait-Enter }
            '2' { Set-PrioritiesPack; Wait-Enter }
            '3' { Set-MemoryManagementPack; Wait-Enter }
            '4' { Set-MmcssGaming; Set-PrioritiesPack; Set-MemoryManagementPack; Wait-Enter }
            '0' { return }
            default { Write-Warn 'Nieznana opcja.'; Start-Sleep -Milliseconds 600 }
        }
    } while ($true)
}

function Menu-Services {
    do {
        Show-Banner
        Show-Section '3) USŁUGI I ZADANIA SYSTEMOWE'
        Write-Host '   [1] Telemetria i diagnostyka (DiagTrack, zadania CEIP...)                [bezpieczne]' -ForegroundColor White
        Write-Host '   [2] Usługi Xbox / Game Bar w tle                                          [bezpieczne*]' -ForegroundColor White
        Write-Host '   [3] Inne: Mapy, Retail Demo, Fax, WMP, Delivery Optimization              [bezpieczne]' -ForegroundColor White
        Write-Host '   [4] Windows Search (indeksowanie) - OFF                                   [opcjonalne]' -ForegroundColor White
        Write-Host '   [5] Windows Update w tle - wstrzymaj na czas grania                       [opcjonalne]' -ForegroundColor White
        Write-Host '   [6] ZASTOSUJ ZESTAW BAZOWY (1+2+3)                                        [polecane]' -ForegroundColor Green
        Write-Host '   [7] Wznów Windows Update (przywróć ręczną kontrolę)' -ForegroundColor White
        Write-Host '   [8] Przywróć WSZYSTKIE usługi i zadania do stanu fabrycznego' -ForegroundColor White
        Write-Host '   [0] Powrót' -ForegroundColor White
        Write-Host '   * jeśli grasz z Game Pass, pomiń punkt [2] (potrzebne usługi Xbox).' -ForegroundColor DarkGray
        $c = Read-Host '  Wybierz opcję'
        switch ($c) {
            '1' { Disable-TelemetryServices; Wait-Enter }
            '2' { Disable-XboxServices; Wait-Enter }
            '3' { Disable-MiscServices; Wait-Enter }
            '4' { Disable-WindowsSearch; Wait-Enter }
            '5' { Suspend-WindowsUpdate; Wait-Enter }
            '6' { Invoke-ServiceBasePack; Wait-Enter }
            '7' { Resume-WindowsUpdate; Wait-Enter }
            '8' { Restore-ServicesDefault; Enable-TelemetryTasks; Wait-Enter }
            '0' { return }
            default { Write-Warn 'Nieznana opcja.'; Start-Sleep -Milliseconds 600 }
        }
    } while ($true)
}

function Menu-Debloat {
    do {
        Show-Banner
        Show-Section '4) ODCHUDZANIE SYSTEMU'
        Write-Host '   [1] Usuń standardowy bloatware (lista bezpiecznych apek sklepowych)' -ForegroundColor White
        Write-Host '   [2] Interfejs: animacje/przezroczystość/opóźnienia -> wydajność' -ForegroundColor White
        Write-Host '   [3] Aplikacje w tle: globalne wyłączenie' -ForegroundColor White
        Write-Host '   [4] Widżety / Wiadomości / inwazyjne sugestie: OFF' -ForegroundColor White
        Write-Host '   [0] Powrót' -ForegroundColor White
        $c = Read-Host '  Wybierz opcję'
        switch ($c) {
            '1' { Remove-Bloatware; Wait-Enter }
            '2' { Set-UiPerformance; Wait-Enter }
            '3' { Disable-BackgroundApps; Wait-Enter }
            '4' { Disable-WidgetsAndNews; Wait-Enter }
            '0' { return }
            default { Write-Warn 'Nieznana opcja.'; Start-Sleep -Milliseconds 600 }
        }
    } while ($true)
}

function Menu-Network {
    do {
        Show-Banner
        Show-Section '5) SIEĆ'
        Write-Host '   [1] DNS: Cloudflare (1.1.1.1 / 1.0.0.1)' -ForegroundColor White
        Write-Host '   [2] DNS: Google (8.8.8.8 / 8.4.4.8)' -ForegroundColor White
        Write-Host '   [3] DNS: przywróć (zapisany stan / DHCP)' -ForegroundColor White
        Write-Host "   [4] Wyłącz algorytm Nagle'a (TcpAckFrequency=1, TCPNoDelay=1)" -ForegroundColor White
        Write-Host '   [5] QoS: polityka DSCP dla wybranej gry (.exe)' -ForegroundColor White
        Write-Host '   [6] QoS: wyłącz rezerwację pasma (NonBestEffortLimit=0)' -ForegroundColor White
        Write-Host '   [7] Karta sieciowa: wyłącz oszczędzanie energii' -ForegroundColor White
        Write-Host '   [8] MTU: podgląd / zmiana' -ForegroundColor White
        Write-Host '   [0] Powrót' -ForegroundColor White
        $c = Read-Host '  Wybierz opcję'
        switch ($c) {
            '1' { Set-D01Dns -Servers @('1.1.1.1','1.0.0.1') -ProviderName 'Cloudflare'; Wait-Enter }
            '2' { Set-D01Dns -Servers @('8.8.8.8','8.4.4.8') -ProviderName 'Google'; Wait-Enter }
            '3' { Reset-D01Dns; Wait-Enter }
            '4' { Disable-Nagle; Wait-Enter }
            '5' { New-GameQosPolicy; Wait-Enter }
            '6' { Set-QosBandwidth; Wait-Enter }
            '7' { Disable-NicPowerSaving; Wait-Enter }
            '8' { Show-MtuMenu; Wait-Enter }
            '0' { return }
            default { Write-Warn 'Nieznana opcja.'; Start-Sleep -Milliseconds 600 }
        }
    } while ($true)
}

function Menu-Gpu {
    do {
        Show-Banner
        $vendor = if ($script:Hw) { $script:Hw.GpuVendor } else { 'Nieznany' }
        Show-Section ("6) GPU  (wykryto: {0})" -f $vendor)
        Write-Host '   [1] HAGS - włącz Hardware-Accelerated GPU Scheduling' -ForegroundColor White
        Write-Host '   [2] HAGS - przywróć domyślne' -ForegroundColor White
        Write-Host '   [3] Re-Size BAR / SAM - sprawdź status + jak włączyć (BIOS)' -ForegroundColor White
        Write-Host '   [4] Wyczyść cache shaderów (NVIDIA/AMD/DirectX)' -ForegroundColor White
        Write-Host '   [5] NVIDIA: wyłącz procesy w tle (telemetria, kontener)' -ForegroundColor White
        Write-Host '   [6] AMD: usługa External Events -> Manual' -ForegroundColor White
        Write-Host '   [0] Powrót' -ForegroundColor White
        $c = Read-Host '  Wybierz opcję'
        switch ($c) {
            '1' { Enable-Hags; Wait-Enter }
            '2' { Disable-Hags; Wait-Enter }
            '3' { Get-ReBarStatus; Wait-Enter }
            '4' { Clear-ShaderCaches; Wait-Enter }
            '5' {
                if ($vendor -ne 'NVIDIA') { Write-Warn 'Nie wykryto GPU NVIDIA - kontynuuję tylko na wyraźne życzenie.'; if (-not (Read-YesNo 'Na pewno?')) { Wait-Enter; continue } }
                Disable-NvidiaBackground; Wait-Enter
            }
            '6' {
                if ($vendor -ne 'AMD') { Write-Warn 'Nie wykryto GPU AMD - kontynuuję tylko na wyraźne życzenie.'; if (-not (Read-YesNo 'Na pewno?')) { Wait-Enter; continue } }
                Set-AmdBackground; Wait-Enter
            }
            '0' { return }
            default { Write-Warn 'Nieznana opcja.'; Start-Sleep -Milliseconds 600 }
        }
    } while ($true)
}

function Menu-Profiles {
    do {
        Show-Banner
        Show-Section '7) PROFILE SPRZĘTOWE - jedno kliknięcie'
        $reco = Get-RecommendedProfileId
        $hwDesc = if ($script:Hw) { "{0} + {1} ({2})" -f $script:Hw.CpuVendor, $script:Hw.GpuVendor, $script:Hw.Chassis } else { 'nieznany' }
        Write-Host ("   Wykryto sprzęt : {0}" -f $hwDesc) -ForegroundColor White
        Write-Host ("   Zalecany profil: {0}" -f $(if ($reco) { $reco } else { 'brak (wybierz ręcznie)' })) -ForegroundColor Green
        Write-Host ''
        Write-Host '   [1] Ryzen + NVIDIA' -ForegroundColor White
        Write-Host '   [2] Intel + NVIDIA' -ForegroundColor White
        Write-Host '   [3] Ryzen + AMD' -ForegroundColor White
        Write-Host '   [4] Intel + AMD' -ForegroundColor White
        Write-Host '   [5] Laptop (szacunek do temperatur i baterii)' -ForegroundColor White
        Write-Host '   [A] AUTO: zastosuj wykryty profil' -ForegroundColor Green
        Write-Host '   [0] Powrót' -ForegroundColor White
        $c = Read-Host '  Wybierz'
        switch ($c.Trim().ToUpper()) {
            '1' { Invoke-Profile 'RYZEN-NVIDIA'; Wait-Enter }
            '2' { Invoke-Profile 'INTEL-NVIDIA'; Wait-Enter }
            '3' { Invoke-Profile 'RYZEN-AMD'; Wait-Enter }
            '4' { Invoke-Profile 'INTEL-AMD'; Wait-Enter }
            '5' { Invoke-Profile 'LAPTOP'; Wait-Enter }
            'A' {
                if ($reco) { Invoke-Profile $reco; Wait-Enter } else { Write-Warn 'Nie wykryto pasującego profilu.'; Start-Sleep -Seconds 1 }
            }
            '0' { return }
            default { Write-Warn 'Nieznana opcja.'; Start-Sleep -Milliseconds 600 }
        }
    } while ($true)
}

function Menu-Advanced {
    do {
        Show-Banner
        Show-Section '8) ZAAWANSOWANE - CZYTAJ OPISY, ZMIANY ODWRACALNE'
        Write-Host '   [1] Pokaż status VBS / HVCI / Core Isolation' -ForegroundColor White
        Write-Host '   [2] WYŁĄCZ VBS + Memory Integrity  [! bezpieczeństwo, wymaga wpisania WYLACZ]' -ForegroundColor Yellow
        Write-Host '   [3] Włącz ponownie VBS / HVCI' -ForegroundColor White
        Write-Host '   [4] SysMain (Superfetch): wyłącz   [tylko SSD/NVMe]' -ForegroundColor White
        Write-Host '   [5] Zaplanowana defragmentacja: wyłącz   [tylko SSD/NVMe]' -ForegroundColor White
        Write-Host '   [6] Plik strony: zarządzany przez system / stały rozmiar' -ForegroundColor White
        Write-Host '   [0] Powrót' -ForegroundColor White
        Write-Host ''
        Write-Host '   Celowo NIE wyłączamy: Windows Defendera, mitigacji Spectre/Meltdown' -ForegroundColor DarkGray
        Write-Host '   i innych mechanizmów krytycznych dla bezpieczeństwa.' -ForegroundColor DarkGray
        $c = Read-Host '  Wybierz opcję'
        switch ($c) {
            '1' { Show-VbsStatus; Wait-Enter }
            '2' { Disable-Vbs; Wait-Enter }
            '3' { Enable-Vbs; Wait-Enter }
            '4' { Disable-SysMain; Wait-Enter }
            '5' { Disable-ScheduledDefrag; Wait-Enter }
            '6' { Set-PagefileMenu; Wait-Enter }
            '0' { return }
            default { Write-Warn 'Nieznana opcja.'; Start-Sleep -Milliseconds 600 }
        }
    } while ($true)
}

# ----------------------------------------------------------------------------
# START / PĘTLA GŁÓWNA
# ----------------------------------------------------------------------------
Write-Log '================= d01i - universal START ================='
Write-Log ("Wersja {0} | DryRun={1}" -f $script:Version, $script:DryRun)

Load-D01State
Show-Banner
Invoke-Preflight

$script:Hw = Get-D01Hardware
if ($script:BackupDone -eq $false -and $script:State.LastBackupDir) {
    # backup był kiedyś robiony - nie spamuj punktami przywracania przy każdym starcie
    $script:BackupDone = $true
}

Write-Host ''
Write-Info 'Przed pierwszą zmianą w tej sesji zostanie AUTOMATYCZNIE utworzony punkt przywracania + backup rejestru.'
Start-Sleep -Seconds 2

do {
    Show-Banner
    Show-HardwareLine
    Show-MainMenu
    $choice = (Read-Host '  Wybierz opcję').Trim().ToUpper()
    Write-Log ("Wybór menu: {0}" -f $choice)
    switch ($choice) {
        '1' { Menu-Power }
        '2' { Menu-Registry }
        '3' { Menu-Services }
        '4' { Menu-Debloat }
        '5' { Menu-Network }
        '6' { Menu-Gpu }
        '7' { Menu-Profiles }
        '8' { Menu-Advanced }
        '9' { Show-Banner; Invoke-RestoreDefaults; Wait-Enter }
        'B' { $script:BackupDone = $false; New-D01RestorePoint; Export-D01Registry; $script:BackupDone = $true; Save-D01State; Wait-Enter }
        'I' { Import-RegistryBackup; Wait-Enter }
        'S' { Show-Banner; Show-StatusScreen }
        'D' {
            $script:DryRun = -not $script:DryRun
            Write-Log ("Tryb DRY-RUN: {0}" -f $script:DryRun)
            if ($script:DryRun) { Write-Warn 'DRY-RUN WŁĄCZONY - zmiany będą tylko pokazywane.' } else { Write-Info 'DRY-RUN WYŁĄCZONY - zmiany będą zapisywane.' }
            Start-Sleep -Seconds 1
        }
        'L' { try { Invoke-Item $script:LogFile } catch { Write-Warn 'Nie można otworzyć pliku logu.'; Start-Sleep -Seconds 1 } }
        '0' { }
        default { Write-Warn 'Nieznana opcja.'; Start-Sleep -Milliseconds 600 }
    }
} while ($choice -ne '0')

# ----------------------------------------------------------------------------
# ZAKOŃCZENIE
# ----------------------------------------------------------------------------
Write-Host ''
if ($script:RebootNeeded) {
    Write-Host '  Część zmian wymaga RESTARTU komputera, aby zadziałała.' -ForegroundColor Yellow
    if (Read-YesNo 'Uruchomić ponownie TERAZ?') {
        Write-Log 'Restart na życzenie użytkownika.'
        Restart-Computer -Force
    } else {
        Write-Info 'OK - zrestartuj ręcznie, gdy będzie Ci wygodnie.'
    }
}
Write-Log '================= d01i - universal STOP =================='
Write-Host '  Dzięki za użycie d01i - universal. Powodzenia na serwerach!' -ForegroundColor Cyan
Write-Host ''
