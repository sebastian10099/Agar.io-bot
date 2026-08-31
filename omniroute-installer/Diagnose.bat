@echo off
setlocal
title OmniRoute Diagnose

rem Ohne die zugehoerige .ps1 daneben kann diese Datei nichts tun.
if not exist "%~dp0omniroute-diagnose.ps1" (
    echo.
    echo   FEHLER: Die Datei omniroute-diagnose.ps1 fehlt in diesem Ordner.
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

echo.
echo   Sammelt einen Bericht darueber, warum OmniRoute nicht laeuft.
echo   Der Bericht landet als OmniRoute-Diagnose.txt auf dem Desktop
echo   und oeffnet sich danach im Editor.
echo.
echo   Passwoerter und Schluessel stehen absichtlich nicht darin -
echo   die Datei kannst du gefahrlos weitergeben.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0omniroute-diagnose.ps1"

echo.
pause
