# D01i Tweakz - dezinstalacja na Windows. NIE usuwa bazy danych bez potwierdzenia.
#requires -Version 5.1
param(
    [string]$InstallDir = "$env:ProgramFiles\D01iTweakz",
    [string]$DataDir = "$env:ProgramData\D01iTweakz"
)
$ErrorActionPreference = 'Continue'
& (Join-Path $PSScriptRoot 'Stop-Backend.ps1')
$r = Read-Host "Usunąć katalog aplikacji $InstallDir? [y/N]"
if ($r -eq 'y') { Remove-Item $InstallDir -Recurse -Force; Write-Host "Usunięto $InstallDir" }
$r = Read-Host "Usunąć konfigurację i klucze $DataDir? [y/N]"
if ($r -eq 'y') { Remove-Item $DataDir -Recurse -Force; Write-Host "Usunięto $DataDir" }
$r = Read-Host "Usunąć bazę d01i_tweakz z PostgreSQL? [y/N]"
if ($r -eq 'y') {
    $psql = Get-ChildItem 'C:\Program Files\PostgreSQL' -Recurse -Filter psql.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ($psql) {
        & $psql -U postgres -h 127.0.0.1 -c "DROP DATABASE IF EXISTS d01i_tweakz;" postgres
        & $psql -U postgres -h 127.0.0.1 -c "DROP ROLE IF EXISTS d01i_app;" postgres
        Write-Host "Usunięto bazę i użytkownika."
    }
}
Write-Host "Dezinstalacja zakończona."
