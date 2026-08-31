@echo off
setlocal
title OmniRoute entfernen

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
