<#
.SYNOPSIS
    Baut OmniRoute.bat - eine einzelne Datei, die alle Skripte enthaelt.

.DESCRIPTION
    Packt die .ps1-Dateien in ein ZIP, haengt es als Base64 an eine Batch-Datei
    an und schreibt das Ergebnis nach OmniRoute.bat. Beim Doppelklick entpackt
    sich das Archiv in ein temporaeres Verzeichnis, das Menue startet, und am
    Ende wird das Verzeichnis wieder geloescht.

    Damit gibt es nur eine Datei zum Herunterladen - es kann nicht mehr passieren,
    dass eine .bat ihre .ps1 nicht findet.

    Die Skripte bleiben die einzige Quelle: dieses Werkzeug erzeugt nur eine
    Verpackung, es kopiert keinen Code.

.EXAMPLE
    pwsh -NoProfile -File .\tools\Build-Standalone.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

$quelle = Split-Path $PSScriptRoot -Parent
if (-not $OutFile) { $OutFile = Join-Path $quelle 'OmniRoute.bat' }

$dateien = @(
    'omniroute-common.ps1',
    'omniroute-menu.ps1',
    'omniroute-setup.ps1',
    'omniroute-desktop.ps1',
    'omniroute-diagnose.ps1'
)

Write-Host "Packe folgende Dateien ein:" -ForegroundColor Cyan
$pfade = @()
foreach ($d in $dateien) {
    $p = Join-Path $quelle $d
    if (-not (Test-Path $p)) { throw "Datei fehlt: $p" }
    Write-Host "  $d"
    $pfade += $p
}

# ---------------------------------------------------------------- Packen ----

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("orbuild-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'payload.zip'

try {
    Copy-Item $pfade -Destination $tmp
    $stage = Join-Path $tmp 'stage'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($d in $dateien) { Copy-Item (Join-Path $quelle $d) -Destination $stage }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)

    $bytes = [IO.File]::ReadAllBytes($zip)
    $b64 = [Convert]::ToBase64String($bytes)
    Write-Host ""
    Write-Host ("Archiv: {0:N1} KB  ->  Base64: {1:N1} KB" -f ($bytes.Length / 1KB), ($b64.Length / 1KB)) -ForegroundColor Gray
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# --------------------------------------------------------------- Schreiben ----

# Die PowerShell-Zeile liest die eigene .bat, sammelt alle mit ::: beginnenden
# Zeilen ein, dekodiert sie zum ZIP, entpackt es und startet das Menue.
$ps = @(
    "`$ErrorActionPreference='Stop';"
    "`$dir=Join-Path `$env:TEMP ('OmniRoute-'+[Guid]::NewGuid().ToString('N'));"
    "try {"
    "New-Item -ItemType Directory -Path `$dir -Force | Out-Null;"
    "`$b64=((Get-Content -LiteralPath '%~f0' -Encoding ASCII) | Where-Object { `$_.StartsWith(':::') } | ForEach-Object { `$_.Substring(3) }) -join '';"
    "`$zip=Join-Path `$dir 'payload.zip';"
    "[IO.File]::WriteAllBytes(`$zip,[Convert]::FromBase64String(`$b64));"
    "Add-Type -AssemblyName System.IO.Compression.FileSystem;"
    "[IO.Compression.ZipFile]::ExtractToDirectory(`$zip,`$dir);"
    "Remove-Item `$zip -Force;"
    "& (Join-Path `$dir 'omniroute-menu.ps1');"
    "} catch {"
    "Write-Host '';"
    "Write-Host ('  Fehler beim Entpacken: ' + `$_.Exception.Message) -ForegroundColor Red;"
    "Write-Host '';"
    "} finally {"
    "if (Test-Path `$dir) { Remove-Item `$dir -Recurse -Force -ErrorAction SilentlyContinue }"
    "}"
) -join ' '

$kopf = @"
@echo off
setlocal
title OmniRoute
echo.
echo   OmniRoute
echo   Alle Werkzeuge stecken in dieser einen Datei.
echo.

where powershell >nul 2>&1
if errorlevel 1 (
    echo   Windows PowerShell wurde nicht gefunden.
    echo   Dieses Werkzeug braucht Windows.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ps"

set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
    echo   Beendet mit Fehlercode %RC%.
    echo.
)
pause
exit /b %RC%

rem ------------------------------------------------------------------
rem  Ab hier folgt das eingebettete Archiv. Batch liest nicht so weit -
rem  die Zeilen oben beenden das Programm vorher. Nicht bearbeiten.
rem ------------------------------------------------------------------
"@

$zeilen = New-Object System.Collections.Generic.List[string]
foreach ($l in ($kopf -split "`r?`n")) { $zeilen.Add($l) }

# Base64 in handliche Zeilen zerlegen
$breite = 200
for ($i = 0; $i -lt $b64.Length; $i += $breite) {
    $len = [Math]::Min($breite, $b64.Length - $i)
    $zeilen.Add(':::' + $b64.Substring($i, $len))
}

# Batch braucht CRLF
$inhalt = ($zeilen -join "`r`n") + "`r`n"
[IO.File]::WriteAllText($OutFile, $inhalt, (New-Object Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "Geschrieben: $OutFile" -ForegroundColor Green
Write-Host ("Groesse: {0:N1} KB" -f ((Get-Item $OutFile).Length / 1KB)) -ForegroundColor Gray
