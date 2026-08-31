@echo off
setlocal
title OmniRoute Setup

rem Ohne die zugehoerige .ps1 daneben kann diese Datei nichts tun.
if not exist "%~dp0omniroute-setup.ps1" (
    echo.
    echo   FEHLER: Die Datei omniroute-setup.ps1 fehlt in diesem Ordner.
    echo.
    echo   Diese .bat ist nur eine Starthilfe - sie braucht die
    echo   gleichnamige .ps1 direkt daneben. Es reicht nicht,
    echo   nur die .bat herunterzuladen.
    echo.
    echo   Einfachste Loesung: OmniRoute.bat verwenden.
    echo   Da stecken alle Skripte in einer einzigen Datei.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0omniroute-setup.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo Das Setup wurde mit Fehlercode %RC% beendet.
    echo Bitte die Meldungen oben lesen - meistens steht dort schon die Loesung.
    echo.
)
pause
exit /b %RC%
