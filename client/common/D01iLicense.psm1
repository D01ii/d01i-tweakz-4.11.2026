<#
================================================================================
  D01i Tweakz - modul licencjonowania (WERSJA SERWEROWA, Runda 6)
================================================================================
  ZASADY:
  - Serwer (backend) jest JEDYNYM zrodlem prawdy o licencji.
  - Klient NIE zawiera zadnych sekretow: ani klucza prywatnego Ed25519,
    ani SECRET_ENC_KEY, ani lokalnego algorytmu generujacego klucze.
  - Brak internetu = brak autoryzacji do funkcji wymagajacych licencji
    (STRICT ONLINE, bez grace period / trybu offline).
  - Token sesji ma krotki TTL (domyslnie 120 s) i jest odswiezany przez
    /api/v1/license/refresh; po wygasnieciu tokena klient wykonuje ponowna
    aktywacje online zapamietanym kluczem (chronionym DPAPI).
  - Adres API konfiguruje uzytkownik (D01I_API_BASE lub config.json) -
    w kliencie NIE ma domyslnej przykladowej domeny.
  - Zgodnosc: Windows PowerShell 5.1 (brak operatorow ?? ?: && || ?.)
    oraz PowerShell 7.
================================================================================
#>

$script:D01iStateDir   = Join-Path $env:ProgramData 'D01iTweakz'
$script:D01iStateFile  = Join-Path $script:D01iStateDir 'license.json'
$script:D01iConfigFile = Join-Path $script:D01iStateDir 'config.json'

# --- SID-y (nie nazwy angielskie grup) ---
$script:SidSystem = 'S-1-5-18'
$script:SidAdmins = 'S-1-5-32-544'

function Get-D01iApiBase {
    <# Zwraca skonfigurowany adres API lub $null (brak konfiguracji). NIGDY nie zwraca przykladowej domeny. #>
    $raw = $env:D01I_API_BASE
    if (-not $raw -and (Test-Path $script:D01iConfigFile)) {
        try {
            $cfg = Get-Content $script:D01iConfigFile -Raw | ConvertFrom-Json
            $raw = $cfg.api_base
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw.Trim().TrimEnd('/')
}

function Test-D01iApiBase {
    <# Walidacja adresu API. Zwraca @{ok; base; error} #>
    $base = Get-D01iApiBase
    if (-not $base) {
        return @{ ok=$false; error='CONFIG_MISSING'; message='Nie skonfigurowano adresu API. Ustaw zmienna srodowiskowa D01I_API_BASE (https://twoj-serwer:8443) lub api_base w %ProgramData%\D01iTweakz\config.json.' }
    }
    $uri = $null
    if (-not [System.Uri]::TryCreate($base, [System.UriKind]::Absolute, [ref]$uri)) {
        return @{ ok=$false; error='URL_INVALID'; message="Adres API nie jest prawidlowym URL: $base" }
    }
    $isLocal = ($uri.Host -eq 'localhost' -or $uri.Host -eq '127.0.0.1' -or $uri.Host -eq '::1')
    if ($uri.Scheme -eq 'https') { return @{ ok=$true; base=$base } }
    if ($uri.Scheme -eq 'http' -and $isLocal -and $env:D01I_ALLOW_HTTP -eq '1') {
        return @{ ok=$true; base=$base }
    }
    return @{ ok=$false; error='HTTP_NOT_ALLOWED'; message="Adres API musi uzywac HTTPS (dopuszczalne HTTP tylko dla localhost z D01I_ALLOW_HTTP=1): $base" }
}

function Get-D01iHwid {
    <# Stabilny HWID = SHA-256(CPU ProcessorId | plyta SerialNumber | dysk fizyczny 0 SerialNumber), 16 znakow HEX.
       Brak ktorejkolwiek danej = JAWNY BLAD (brak stalego HWID awaryjnego - wiele maszyn nie mogloby wspoldzielic ID).
       Nazwa komputera NIE jest czescia HWID. #>
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $mb  = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
    $disk = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Where-Object { $_.Index -eq 0 } | Select-Object -First 1
    if (-not $cpu -or [string]::IsNullOrWhiteSpace([string]$cpu.ProcessorId)) { throw 'HWID: brak ProcessorId CPU - aktywacja niemozliwa.' }
    if (-not $mb -or [string]::IsNullOrWhiteSpace([string]$mb.SerialNumber)) { throw 'HWID: brak SerialNumber plyty glownej - aktywacja niemozliwa.' }
    if (-not $disk -or [string]::IsNullOrWhiteSpace([string]$disk.SerialNumber)) { throw 'HWID: brak SerialNumber dysku 0 - aktywacja niemozliwa.' }
    $raw = "$($cpu.ProcessorId)|$($mb.SerialNumber)|$($disk.SerialNumber)"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
        return ((($h | ForEach-Object { $_.ToString('X2') }) -join '').Substring(0, 16).ToUpper())
    } finally { $sha.Dispose() }
}

function Get-D01iInstallId {
    <# Stabilny identyfikator instalacji = SHA-256(MachineGuid). Trwaly per maszyna; nie zmienia sie przy restarcie.
       Brak MachineGuid = jawny blad (nie generujemy losowego ID, ktore mogloby zdradzic slot urzadzenia). #>
    $mg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
    if ([string]::IsNullOrWhiteSpace([string]$mg)) { throw 'Brak MachineGuid - identyfikator instalacji niedostepny.' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("D01I-INSTALL|$mg"))
        return ((($h | ForEach-Object { $_.ToString('X2') }) -join '').Substring(0, 32).ToUpper())
    } finally { $sha.Dispose() }
}

function Invoke-D01iApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body = $null,
        [int]$TimeoutSec = 15
    )
    $v = Test-D01iApiBase
    if (-not $v.ok) { return @{ ok=$false; status=0; error=$v.error; message=$v.message } }
    $uri = $v.base + $Path
    try {
        if ($Method -eq 'GET') {
            $resp = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
            return @{ ok=$true; status=200; body=$resp }
        }
        $json = '{}'
        if ($null -ne $Body) { $json = $Body | ConvertTo-Json -Depth 6 -Compress }
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Body $json -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop
        return @{ ok=$true; status=200; body=$resp }
    } catch {
        $status = 0; $errBody = $null
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errBody = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction SilentlyContinue
                $reader.Dispose()
            } catch {}
        }
        $reason = "HTTP_$status"
        if ($errBody -and $errBody.error) { $reason = $errBody.error }
        return @{ ok=$false; status=$status; error=$reason; body=$errBody; message=$_.Exception.Message }
    }
}

function Protect-D01iSecret {
    <# DPAPI (CurrentUser) - klucz licencyjny nigdy nie lezy na dysku jako jawny tekst. #>
    param([Parameter(Mandatory)][string]$Plain)
    if ($IsWindows -eq $false -and -not (Get-Variable IsWindows -ErrorAction SilentlyContinue)) {
        # PS 5.1 nie ma $IsWindows - wykrywamy platforme przez [System.Environment]::OSVersion
    }
    $os = [System.Environment]::OSVersion.Platform
    if ($os -ne [System.PlatformID]::Win32NT) { throw 'DPAPI dostepne tylko na Windows. Odmowa zapisu klucza jako jawnego tekstu.' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($enc)
}

function Unprotect-D01iSecret {
    param([Parameter(Mandatory)][string]$B64)
    $enc = [Convert]::FromBase64String($B64)
    $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($dec)
}

function Set-D01iSecureAcl {
    <# Restrykcyjny ACL katalogu/pliku: tylko SYSTEM (S-1-5-18) i lokalni Administratorzy (S-1-5-32-544).
       Bledy NIE sa ignorowane - zwracamy $false. #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $acl = Get-Acl $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($script:SidSystem, $script:SidAdmins)) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                (New-Object System.Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl $Path $acl
        return $true
    } catch { return $false }
}

function Save-D01iAtomic {
    <# Atomowy zapis: temp + move. Awaria w trakcie zapisu nie zostawia uszkodzonego pliku. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $tmp = $Path + '.tmp'
    Set-Content -Path $tmp -Value $Content -Force
    if (-not (Set-D01iSecureAcl -Path $tmp)) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; throw "Nie udalo sie zabezpieczyc ACL pliku stanu: $tmp" }
    Move-Item -Path $tmp -Destination $Path -Force
}

function Get-D01iLicenseState {
    if (-not (Test-Path $script:D01iStateFile)) { return $null }
    try { return (Get-Content $script:D01iStateFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-D01iLicenseState {
    param([Parameter(Mandatory)]$State)
    if (-not (Test-Path $script:D01iStateDir)) {
        New-Item -ItemType Directory -Path $script:D01iStateDir -Force | Out-Null
        if (-not (Set-D01iSecureAcl -Path $script:D01iStateDir)) { throw 'Nie udalo sie zabezpieczyc katalogu stanu licencji.' }
    }
    Save-D01iAtomic -Path $script:D01iStateFile -Content ($State | ConvertTo-Json -Depth 6)
    if (-not (Set-D01iSecureAcl -Path $script:D01iStateFile)) { throw 'Nie udalo sie zabezpieczyc pliku stanu licencji.' }
}

function Invoke-D01iActivate {
    <# Aktywacja online kluczem. Klucz zapisujemy WYLACZNIE jako DPAPI blob. #>
    param([Parameter(Mandatory)][string]$Key)
    $key = ($Key.Trim() -replace '\s+','').ToUpper()
    if ($key.Length -lt 10) { return @{ ok=$false; reason='KEY_TOO_SHORT' } }
    $hwid = $null; $installId = $null
    try { $hwid = Get-D01iHwid } catch { return @{ ok=$false; reason='HWID_UNAVAILABLE'; message=$_.Exception.Message } }
    try { $installId = Get-D01iInstallId } catch { return @{ ok=$false; reason='INSTALL_ID_UNAVAILABLE'; message=$_.Exception.Message } }
    $payload = @{ key=$key; install_id=$installId; hwid=$hwid; label=$env:COMPUTERNAME }
    $r = Invoke-D01iApi -Method POST -Path '/api/v1/license/activate' -Body $payload
    if (-not $r.ok) { return @{ ok=$false; reason=$r.error; message=$r.message } }
    $st = @{
        key_dpapi        = Protect-D01iSecret -Plain $key
        install_id       = $installId
        hwid             = $hwid
        token            = $r.body.token
        token_expires_at = $r.body.token_expires_at
        license          = $r.body.license
        activated_at     = (Get-Date).ToString('o')
    }
    Save-D01iLicenseState $st
    return @{ ok=$true; license=$r.body.license }
}

function Invoke-D01iRefresh {
    param([Parameter(Mandatory)]$State)
    if (-not $State.token) { return @{ ok=$false; reason='NO_TOKEN' } }
    $r = Invoke-D01iApi -Method POST -Path '/api/v1/license/refresh' -Body @{ token=$State.token }
    if (-not $r.ok) { return @{ ok=$false; reason=$r.error } }
    $State.token = $r.body.token
    if ($r.body.token_expires_at) { $State.token_expires_at = $r.body.token_expires_at }
    Save-D01iLicenseState $State
    return @{ ok=$true }
}

function Invoke-D01iReauth {
    <# Ponowna aktywacja online po wygasnieciu tokena - klucz odczytany z DPAPI, uzytkownik nie wpisuje go ponownie. #>
    $st = Get-D01iLicenseState
    if (-not $st -or -not $st.key_dpapi) { return @{ ok=$false; reason='NO_STORED_KEY' } }
    $key = $null
    try { $key = Unprotect-D01iSecret -B64 $st.key_dpapi } catch { return @{ ok=$false; reason='DPAPI_UNAVAILABLE'; message=$_.Exception.Message } }
    return Invoke-D01iActivate -Key $key
}

function Test-D01iLicense {
    <# ONLINE walidacja. valid=$true tylko gdy serwer potwierdzi.
       Cykl: wazny token ? OK; token bliski wygasniecia ? refresh; token wygasly ? ponowna aktywacja kluczem DPAPI;
       revoke/expiry/HWID_MISMATCH/brak internetu ? valid=$false (blokada PREMIUM, bez grace period). #>
    param([string[]]$AllowTypes = @('DEMO','PREMIUM_30D','PREMIUM_90D','PREMIUM_LIFETIME'))
    $v = Test-D01iApiBase
    if (-not $v.ok) { return @{ valid=$false; reason=$v.error; message=$v.message } }
    $st = Get-D01iLicenseState
    if (-not $st -or -not $st.token) { return @{ valid=$false; reason='NO_LICENSE' } }
    # 1) token jeszcze wazny i ma zapas ?30 s ? validate
    $needsRefresh = $true
    try {
        $exp = [datetime]::Parse($st.token_expires_at)
        if ($exp -gt (Get-Date).AddSeconds(30)) { $needsRefresh = $false }
    } catch {}
    if ($needsRefresh) {
        $rf = Invoke-D01iRefresh $st
        if (-not $rf.ok) {
            # 2) refresh odrzucony (np. token wygasl) ? ponowna aktywacja zapamietanym kluczem
            if ($rf.reason -eq 'TOKEN_EXPIRED' -or $rf.reason -eq 'TOKEN_REVOKED' -or $rf.reason -eq 'TOKEN_INVALID') {
                $ra = Invoke-D01iReauth
                if (-not $ra.ok) { return @{ valid=$false; reason=$ra.reason; message=$ra.message } }
                $st = Get-D01iLicenseState
            } else {
                return @{ valid=$false; reason=$rf.reason }   # brak internetu / blad sieci
            }
        } else { $st = Get-D01iLicenseState }
    }
    $r = Invoke-D01iApi -Method POST -Path '/api/v1/license/validate' -Body @{ token=$st.token }
    if (-not $r.ok -or -not $r.body.valid) { return @{ valid=$false; reason=$r.error } }
    if ($AllowTypes -notcontains $r.body.license.type) { return @{ valid=$false; reason="TYPE_$($r.body.license.type)" } }
    return @{ valid=$true; type=$r.body.license.type; license=$r.body.license; device_id=$r.body.device_id }
}

function Assert-D01iPremium {
    param([string]$Feature = 'Ta funkcja')
    $lic = Test-D01iLicense -AllowTypes @('PREMIUM_30D','PREMIUM_90D','PREMIUM_LIFETIME')
    if ($lic.valid) { return $true }
    $map = @{
        'CONFIG_MISSING'   = 'Nie skonfigurowano adresu API (D01I_API_BASE).'
        'URL_INVALID'      = 'Adres API jest nieprawidlowy.'
        'HTTP_NOT_ALLOWED' = 'Adres API musi miec HTTPS (HTTP tylko localhost dev).'
        'NO_LICENSE'       = 'Brak aktywnej licencji. Aktywuj klucz (menu: licencja).'
        'TOKEN_REVOKED'    = 'Licencja zostala uniewazniona (revoke).'
        'LICENSE_REVOKED'  = 'Licencja zostala uniewazniona.'
        'LICENSE_EXPIRED'  = 'Licencja wygasla.'
        'HWID_MISMATCH'    = 'HWID nie zgadza sie z aktywacja - skontaktuj sie z supportem.'
        'HWID_UNAVAILABLE' = 'Nie mozna odczytac HWID - aktywacja niemozliwa.'
    }
    $msg = "Licencja niewazna ($($lic.reason))."
    if ($map.ContainsKey($lic.reason)) { $msg = $map[$lic.reason] }
    if ($lic.reason -like 'HTTP_*' -or $lic.reason -like 'CONFIG_*') { $msg = "Brak polaczenia z serwerem licencji - funkcja PREMIUM niedostepna (tryb online). $msg" }
    Write-Host "   [BLAD] $Feature wymaga aktywnej licencji PREMIUM: $msg" -ForegroundColor Red
    return $false
}

function Get-D01iLicenseStatus {
    $st = Get-D01iLicenseState
    if (-not $st -or -not $st.token) { return @{ ok=$false; reason='NO_LICENSE' } }
    $r = Invoke-D01iApi -Method POST -Path '/api/v1/license/status' -Body @{ token=$st.token }
    if (-not $r.ok) { return @{ ok=$false; reason=$r.error } }
    return @{ ok=$true; status=$r.body }
}

function Invoke-D01iDeactivate {
    <# Dezaktywacja: najpierw token; jesli token wygasly - key + install_id (backend przyjmuje oba warianty),
       zeby wygasly token NIGDY nie blokowal zwolnienia slotu licencji. #>
    $st = Get-D01iLicenseState
    if (-not $st) { return @{ ok=$false; reason='NO_LICENSE' } }
    $body = @{ install_id=$st.install_id }
    if ($st.token) { $body.token = $st.token }
    if ($st.key_dpapi) {
        try { $body.key = Unprotect-D01iSecret -B64 $st.key_dpapi } catch {}
    }
    $r = Invoke-D01iApi -Method POST -Path '/api/v1/license/deactivate' -Body $body
    if ($r.ok) { Remove-Item $script:D01iStateFile -Force -ErrorAction SilentlyContinue }
    return @{ ok=$r.ok; reason=$r.error }
}

Export-ModuleMember -Function Get-D01iApiBase, Test-D01iApiBase, Get-D01iHwid, Get-D01iInstallId, Invoke-D01iApi, `
    Invoke-D01iActivate, Invoke-D01iRefresh, Invoke-D01iReauth, Test-D01iLicense, Assert-D01iPremium, `
    Get-D01iLicenseStatus, Invoke-D01iDeactivate, Get-D01iLicenseState
