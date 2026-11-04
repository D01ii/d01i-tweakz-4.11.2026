# D01i Tweakz - dezinstalacja na Windows. NIE usuwa bazy danych bez potwierdzenia.
#requires -Version 5.1
param(
    [string]$InstallDir = "$env:ProgramFiles\D01iTweakz",
    [string]$DataDir = "$env:ProgramData\D01iTweakz"
)
$ErrorActionPreference = 'Continue'
& (Join-Path $PSScriptRoot 'Stop-Backend.ps1')
$r = Read-Host "Usunac katalog aplikacji $InstallDir? [y/N]"
if ($r -eq 'y') { Remove-Item $InstallDir -Recurse -Force; Write-Host "Usunieto $InstallDir" }
$r = Read-Host "Usunac konfiguracje i klucze $DataDir? [y/N]"
if ($r -eq 'y') { Remove-Item $DataDir -Recurse -Force; Write-Host "Usunieto $DataDir" }
$r = Read-Host "Usunac baze d01i_tweakz z PostgreSQL? [y/N]"
if ($r -eq 'y') {
    $psql = Get-ChildItem 'C:\Program Files\PostgreSQL' -Recurse -Filter psql.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ($psql) {
        & $psql -U postgres -h 127.0.0.1 -c "DROP DATABASE IF EXISTS d01i_tweakz;" postgres
        & $psql -U postgres -h 127.0.0.1 -c "DROP ROLE IF EXISTS d01i_app;" postgres
        Write-Host "Usunieto baze i uzytkownika."
    }
}
Write-Host "Dezinstalacja zakonczona."
