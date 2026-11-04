starter.bat
@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
title d01i tweakz p
set "D01I_ROOT=%~dp0"

fltmc >nul 2>&1
if not errorlevel 1 goto admin_ok

echo ============================================================
echo   Uruchamiam z uprawnieniami ADMINISTRATORA...
echo   Kliknij TAK w okienku UAC ktore sie pojawi.
echo ============================================================

powershell.exe -NoProfile -Command "try { Start-Process -FilePath 'powershell.exe' -WorkingDirectory $env:D01I_ROOT -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','d01i_PRO.ps1') -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 (
    echo.
    echo Nie udalo sie uruchomic okna UAC.
    pause
)
exit /b

:admin_ok
cd /d "%D01I_ROOT%" || (
    echo Nie mozna otworzyc folderu skryptu.
    pause
    exit /b 1
)

echo ============================================================
echo   d01i tweakz p v2.5 BITSUM
echo   Odblokowywanie plikow...
echo ============================================================
echo.

powershell.exe -NoProfile -Command "Get-ChildItem -LiteralPath $env:D01I_ROOT -Recurse -File -Include *.ps1,*.bat,*.txt,*.md -ErrorAction SilentlyContinue | Unblock-File"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%D01I_ROOT%d01i_PRO.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo Skrypt zakonczyl dzialanie. Kod: %EXIT_CODE%
pause
exit /b %EXIT_CODE%

