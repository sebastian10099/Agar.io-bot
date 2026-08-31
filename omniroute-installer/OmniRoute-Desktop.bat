@echo off
setlocal
title OmniRoute Desktop starten

echo.
echo   OmniRoute Desktop starten
echo   -------------------------------------------------
echo.
echo   Startet zuerst den Server und danach die App.
echo   Genau diese Reihenfolge fehlt, wenn das Fenster schwarz bleibt.
echo.
echo     [1]  Normal starten          (Standard)
echo     [2]  Mit --disable-gpu       (wenn das Fenster trotzdem schwarz bleibt)
echo     [3]  Nur Browser oeffnen     (ohne Desktop-App)
echo.
set "WAHL="
set /p WAHL=Auswahl [1]:

if "%WAHL%"=="2" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0omniroute-desktop.ps1" -DisableGpu
) else if "%WAHL%"=="3" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0omniroute-desktop.ps1" -BrowserOnly
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0omniroute-desktop.ps1"
)

set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo   Beendet mit Fehlercode %RC%. Die Meldungen oben sagen, woran es lag.
)
echo.
pause
exit /b %RC%
