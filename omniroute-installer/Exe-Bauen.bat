@echo off
setlocal
title OmniRoute-Setup.exe bauen

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

echo Baut OmniRoute-Setup.exe aus omniroute-setup.ps1 mit ps2exe.
echo Die EXE entsteht dabei auf deinem eigenen Rechner - so laedst du
echo keine fremde, unsignierte Datei aus dem Internet herunter.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "if (-not (Get-Module -ListAvailable -Name ps2exe)) { Write-Host 'Installiere ps2exe...' -ForegroundColor Cyan; Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber }; Import-Module ps2exe; Invoke-PS2EXE -InputFile '%~dp0omniroute-setup.ps1' -OutputFile '%~dp0OmniRoute-Setup.exe' -noConsole:$false -title 'OmniRoute Setup' -description 'Installiert OmniRoute und verbindet Claude Code und Codex' -requireAdmin:$false"

if errorlevel 1 (
    echo.
    echo Der Build ist fehlgeschlagen. Du kannst stattdessen einfach
    echo OmniRoute-Setup.bat per Doppelklick verwenden - die macht dasselbe.
) else (
    echo.
    echo Fertig: OmniRoute-Setup.exe
    echo.
    echo Hinweis: Die EXE ist nicht signiert. Windows SmartScreen zeigt
    echo beim ersten Start eine Warnung - dort auf "Weitere Informationen"
    echo und dann "Trotzdem ausfuehren" klicken.
)

echo.
pause
