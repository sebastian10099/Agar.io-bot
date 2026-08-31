@echo off
setlocal
title OmniRoute Desktop starten

rem Ohne die zugehoerige .ps1 daneben kann diese Datei nichts tun.
if not exist "%~dp0omniroute-desktop.ps1" (
    echo.
    echo   FEHLER: Die Datei omniroute-desktop.ps1 fehlt in diesem Ordner.
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
