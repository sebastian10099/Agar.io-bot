@echo off
setlocal
title OmniRoute

where omniroute >nul 2>&1
if errorlevel 1 (
    echo omniroute wurde nicht gefunden.
    echo Bitte zuerst OmniRoute-Setup.bat ausfuehren.
    echo.
    pause
    exit /b 1
)

echo Starte OmniRoute auf http://localhost:20128/dashboard
echo Dieses Fenster offen lassen - es ist der Server. Beenden mit Strg+C.
echo.
omniroute
pause
