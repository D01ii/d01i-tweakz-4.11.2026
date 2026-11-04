<#
================================================================================
  D01i Tweakz — moduł licencjonowania (WERSJA SERWEROWA, Runda 5)
================================================================================
  ZASADY:
  - Serwer (backend) jest JEDYNYM źródłem prawdy o licencji.
  - Klient NIE zawiera żadnych sekretów: ani klucza prywatnego Ed25519,
    ani SECRET_ENC_KEY, ani lokalnego algorytmu generującego klucze.
  - Brak internetu = brak autoryzacji do funkcji wymagających licencji
    (STRICT ONLINE, bez trybu offline / grace period).
  - Token sesji ma krótki TTL (domyślnie 120 s, patrz TOKEN_TTL_SECONDS
    backendu) i jest odświeżany przez /api/v1/license/refresh.
  Wymagania: PowerShell 5.1+.
================================================================================
#>

$script:D01iStateDir  = Join-Path $env:ProgramData 'D01iTweakz'
$script:D01iStateFile = Join-Path $script:D01iStateDir 'license.json'

function Get-D01iApiBase {
    # Kolejność: parametr → zmienna środowiskowa → domyślna domena produkcyjna.
    if ($env:D01I_API_BASE) { return $env:D01I_API_BASE.TrimEnd('/') }
    return 'https://api.twojadomena.pl'
}

function Get-D01iHwid {
    # Stabilny HWID maszyny (SHA-256, 16 znaków HEX). Sam HWID nie jest
    # granicą bezpieczeństwa — serwer egzekwuje HWID_MISMATCH i limit urządzeń.
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $mb  = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        $raw = "$($cpu.ProcessorId)|$($mb.SerialNumber)|$($env:COMPUTERNAME)"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
            return ((($h | ForEach-Object { $_.ToString('X2') }) -join '').Substring(0, 16).ToUpper())
        } finally { $sha.Dispose() }
    } catch { return 'HWID-ERR00000000' }
}

function Get-D01iInstallId {
    # Stabilny identyfikator instalacji = MachineGuid (trwały per maszyna),
    # zahashowany SHA-256. Przechowywany lokalnie, wysyłany do serwera.
    try {
        $mg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("D01I-INSTALL|$mg"))
            return ((($h | ForEach-Object { $_.ToString('X2') }) -join '').Substring(0, 32).ToUpper())
        } finally { $sha.Dispose() }
    } catch {
        # awaryjnie: plik z losowym ID pod ProgramData (przetrwa reinstalację klienta)
        $f = Join-Path $script:D01iStateDir 'install_id.txt'
        if (Test-Path $f) { return (Get-Content $f -Raw).Trim().ToUpper() }
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $b = New-Object byte[] 16; $rng.GetBytes($b)
        $id = ((($b | ForEach-Object { $_.ToString('X2') }) -join '')).ToUpper()
        New-Item -ItemType Directory -Path $script:D01iStateDir -Force -ErrorAction SilentlyContinue | Out-Null
        Set-Content -Path $f -Value $id -NoNewline
        return $id
    }
}

function Invoke-D01iApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body = $null,
        [int]$TimeoutSec = 15
    )
    $uri = (Get-D01iApiBase) + $Path
    try {
        if ($Method -eq 'GET') {
            $resp = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
            return @{ ok = $true; status = 200; body = $resp }
        }
        $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 6 -Compress } else { '{}' }
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Body $json -ContentType 'application/json' `
                 -TimeoutSec $TimeoutSec -ErrorAction Stop
        return @{ ok = $true; status = 200; body = $resp }
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
        return @{ ok = $false; status = $status; error = $_.Exception.Message; body = $errBody }
    }
}

function Get-D01iLicenseState {
    if (-not (Test-Path $script:D01iStateFile)) { return $null }
    try { return (Get-Content $script:D01iStateFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-D01iLicenseState {
    param([Parameter(Mandatory)]$State)
    New-Item -ItemType Directory -Path $script:D01iStateDir -Force -ErrorAction SilentlyContinue | Out-Null
    $State | ConvertTo-Json -Depth 6 | Set-Content -Path $script:D01iStateFile -Force
    # ACL: tylko SYSTEM i Administratorzy (plik zawiera token sesji)
    try {
        $acl = Get-Acl $script:D01iStateFile
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM','FullControl','Allow')
        $acl.AddAccessRule($rule)
        $rule2 = New-Object System.Security.AccessControl.FileSystemAccessRule('Administrators','FullControl','Allow')
        $acl.AddAccessRule($rule2)
        Set-Acl $script:D01iStateFile $acl
    } catch {}
}

function Invoke-D01iActivate {
    # Aktywacja ręczna kluczem licencyjnym. Zwraca $true przy sukcesie.
    param([Parameter(Mandatory)][string]$Key)
    $key = ($Key.Trim() -replace '\s+','').ToUpper()
    if ($key.Length -lt 10) { return @{ ok=$false; reason='KEY_TOO_SHORT' } }
    $payload = @{
        key        = $key
        install_id = Get-D01iInstallId
        hwid       = Get-D01iHwid
        label      = $env:COMPUTERNAME
    }
    $r = Invoke-D01iApi -Method POST -Path '/api/v1/license/activate' -Body $payload
    if (-not $r.ok) {
        $code = if ($r.body -and $r.body.error) { $r.body.error } else { "HTTP_$($r.status)" }
        return @{ ok=$false; reason=$code; message=$r.body.message }
    }
    Save-D01iLicenseState @{
        key              = $key
        install_id       = $payload.install_id
        hwid             = $payload.hwid
        token            = $r.body.token
        token_expires_at = $r.body.token_expires_at
        license          = $r.body.license
        activated_at     = (Get-Date).ToString('o')
    }
    return @{ ok=$true; license=$r.body.license }
}

function Invoke-D01iRefresh {
    # Odświeżenie tokena (rotacja). Sukces → nowy token zapisany lokalnie.
    param([Parameter(Mandatory)]$State)
    if (-not $State.token) { return @{ ok=$false; reason='NO_TOKEN' } }
    $r = Invoke-D01iApi -Method POST -Path '/api/v1/license/refresh' -Body @{ token = $State.token }
    if (-not $r.ok) { return @{ ok=$false; reason=($r.body.error ? $r.body.error : "HTTP_$($r.status)") } }
    $State.token = $r.body.token
    if ($r.body.token_expires_at) { $State.token_expires_at = $r.body.token_expires_at }
    Save-D01iLicenseState $State
    return @{ ok=$true }
}

function Test-D01iLicense {
    <#
      ONLINE walidacja licencji. Zwraca obiekt:
      @{ valid=$bool; type='PREMIUM_LIFETIME'|...; reason='...' }
      valid=$true TYLKO gdy serwer potwierdzi token (po ewentualnym odświeżeniu).
      Brak internetu / 401 / revoke / expiry / HWID_MISMATCH → valid=$false.
    #>
    param([string[]]$AllowTypes = @('DEMO','PREMIUM_30D','PREMIUM_90D','PREMIUM_LIFETIME'))
    $st = Get-D01iLicenseState
    if (-not $st -or -not $st.token) { return @{ valid=$false; reason='NO_LICENSE' } }
    # jeśli token wygasa za < 30 s — najpierw spróbuj odświeżyć
    try {
        $exp = [datetime]::Parse($st.token_expires_at)
        if ($exp -lt (Get-Date).AddSeconds(30)) {
            $rf = Invoke-D01iRefresh $st
            if (-not $rf.ok) { return @{ valid=$false; reason=$rf.reason } }
            $st = Get-D01iLicenseState
        }
    } catch {}
    $r = Invoke-D01iApi -Method POST -Path '/api/v1/license/validate' -Body @{ token = $st.token }
    if (-not $r.ok -or -not $r.body.valid) {
        return @{ valid=$false; reason=($r.body.error ? $r.body.error : "HTTP_$($r.status)") }
    }
    $type = $r.body.license.type
    if ($AllowTypes -notcontains $type) { return @{ valid=$false; reason="TYPE_$type" } }
    return @{ valid=$true; type=$type; license=$r.body.license; device_id=$r.body.device_id }
}

function Assert-D01iPremium {
    <# Wymaga licencji PREMIUM (online). Zwraca $true/$false i wypisuje komunikat. #>
    param([string]$Feature = 'Ta funkcja')
    $lic = Test-D01iLicense -AllowTypes @('PREMIUM_30D','PREMIUM_90D','PREMIUM_LIFETIME')
    if ($lic.valid) { return $true }
    $map = @{
        'NO_LICENSE'='Brak aktywnej licencji. Aktywuj klucz (menu: licencja).'
        'OFFLINE'='Brak polaczenia z serwerem licencji — funkcja PREMIUM niedostepna (tryb online).'
        'TOKEN_REVOKED'='Licencja zostala uniewazniona (revoke).'
        'TOKEN_EXPIRED'='Sesja wygasla i nie mozna jej odswiezyc.'
        'LICENSE_REVOKED'='Licencja zostala uniewazniona.'
        'LICENSE_EXPIRED'='Licencja wygasla.'
        'HWID_MISMATCH'='HWID nie zgadza sie z aktywacja — skontaktuj sie z supportem.'
    }
    $msg = if ($map[$lic.reason]) { $map[$lic.reason] } else { "Licencja niewazna ($($lic.reason))." }
    Write-Host "   [BŁĄD] $Feature wymaga aktywnej licencji PREMIUM: $msg" -ForegroundColor Red
    return $false
}

function Get-D01iLicenseStatus {
    # Diagnostyka: /status (nie wymaga odświeżania, tylko ważnego tokenu).
    $st = Get-D01iLicenseState
    if (-not $st -or -not $st.token) { return @{ ok=$false; reason='NO_LICENSE' } }
    $r = Invoke-D01iApi -Method POST -Path '/api/v1/license/status' -Body @{ token = $st.token }
    if (-not $r.ok) { return @{ ok=$false; reason=($r.body.error ? $r.body.error : "HTTP_$($r.status)") } }
    return @{ ok=$true; status=$r.body }
}

function Invoke-D01iDeactivate {
    # Dezaktywacja biezacego urzadzenia (zwalnia slot limitu 2 urzadzen).
    $st = Get-D01iLicenseState
    if (-not $st) { return @{ ok=$false; reason='NO_LICENSE' } }
    $r = Invoke-D01iApi -Method POST -Path '/api/v1/license/deactivate' -Body @{ token = $st.token; key = $st.key; install_id = $st.install_id }
    if ($r.ok) { Remove-Item $script:D01iStateFile -Force -ErrorAction SilentlyContinue }
    return @{ ok=$r.ok; reason=($r.body.error ? $r.body.error : $null) }
}

Export-ModuleMember -Function Get-D01iApiBase, Get-D01iHwid, Get-D01iInstallId, Invoke-D01iApi, `
    Invoke-D01iActivate, Invoke-D01iRefresh, Test-D01iLicense, Assert-D01iPremium, `
    Get-D01iLicenseStatus, Invoke-D01iDeactivate, Get-D01iLicenseState
