@echo off
setlocal
title OmniRoute entfernen

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

echo Entfernt Autostart-Eintrag und die von diesem Setup gesetzten
echo Umgebungsvariablen. Das npm-Paket omniroute bleibt installiert.
echo.
echo Soll auch das npm-Paket entfernt werden? (j = ja, sonst Enter)
set /p PURGE=Auswahl:

if /I "%PURGE%"=="j" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0omniroute-setup.ps1" -Remove -Purge
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0omniroute-setup.ps1" -Remove
)

pause
