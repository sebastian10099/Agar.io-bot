@echo off
setlocal
title OmniRoute Setup

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
