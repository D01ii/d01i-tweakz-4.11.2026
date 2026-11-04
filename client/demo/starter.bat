starter.bat

@echo off
rem ============================================================
rem   d01i - universal  |  LAUNCHER
rem   Uruchamia glowny skrypt PowerShell:
rem     - wlacz kodowanie UTF-8 (poprawne logo ASCII)
rem     - wymus uprawnienia Administratora (UAC)
rem     - uruchom demo.ps1
rem
rem   Tryb podgladu (bez zapisu zmian - DRY-RUN):
rem     d01i_universal.bat -DryRun
rem ============================================================

chcp 65001 >nul
title d01i - universal ^| launcher

rem --- sprawdz, czy juz jestesmy Administratorem ----------------
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo.
    echo   [ d01i - universal ]
    echo.
    echo   Ten program wymaga uprawnien Administratora.
    echo   Za chwile pojawi sie okno zgody UAC...
    echo.
    rem --- podnies uprawnienia i uruchom ten sam plik ponownie ---
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%*'" >nul 2>&1
    exit /b
)

rem --- jestesmy Adminem: odpal wlasciwy skrypt ------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0demo.ps1" %*

if %errorlevel% NEQ 0 (
    echo.
    echo   [UWAGA] Skrypt zakonczyl sie z kodem bledu: %errorlevel%
)

echo.
pause


