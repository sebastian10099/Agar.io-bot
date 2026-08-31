@echo off
setlocal
title OmniRoute Diagnose

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
