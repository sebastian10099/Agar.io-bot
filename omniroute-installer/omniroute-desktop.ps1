#Requires -Version 5.1
<#
.SYNOPSIS
    Startet die OmniRoute-Desktop-App in der richtigen Reihenfolge.

.DESCRIPTION
    Die Desktop-App zeigt haeufig nur ein schwarzes Fenster. Ursache laut den
    Fehlerberichten des Projekts (Issues 1253 und 1270) ist nicht die App selbst,
    sondern der lokale Server: die App laedt http://localhost:20128, bekommt keine
    Antwort und landet auf einer Fehlerseite - sichtbar als schwarze Flaeche.

    Dieses Skript dreht die Reihenfolge um:
      1. CLI-Server starten und warten, bis Port 20128 wirklich antwortet
      2. erst danach die Desktop-App oeffnen

    Wird die App nicht gefunden, wird stattdessen das Dashboard im Browser
    geoeffnet - inhaltlich dieselbe Oberflaeche.

.PARAMETER DisableGpu
    Startet die App mit --disable-gpu. Hilft, wenn das Fenster trotz laufendem
    Server schwarz bleibt (Grafiktreiber-Probleme unter Electron).

.PARAMETER BrowserOnly
    Desktop-App ueberspringen und direkt das Dashboard im Browser oeffnen.

.PARAMETER TimeoutSeconds
    Wie lange auf den Server gewartet wird. Standard 120.

.EXAMPLE
    .\omniroute-desktop.ps1

.EXAMPLE
    .\omniroute-desktop.ps1 -DisableGpu
#>
[CmdletBinding()]
param(
    [switch]$DisableGpu,
    [switch]$BrowserOnly,
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

. (Join-Path $PSScriptRoot 'omniroute-common.ps1')

function Open-Dashboard {
    Write-Info "Oeffne das Dashboard im Browser: $($script:DashboardUrl)"
    try { Start-Process $script:DashboardUrl | Out-Null; return $true }
    catch {
        Write-Warn2 "Der Browser liess sich nicht oeffnen. Bitte die Adresse von Hand eingeben:"
        Write-Host "    $($script:DashboardUrl)" -ForegroundColor White
        return $false
    }
}

try {
    Write-Host ""
    Write-Host "  OmniRoute Desktop starten" -ForegroundColor White
    Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray

    # -------------------------------------------------- 1. Server sicherstellen
    Write-Step "Schritt 1/2 - Server"

    $omni = Get-OmniRoutePath
    if (-not $omni -and -not (Test-OmniRouteReachable)) {
        Write-Err2 "omniroute wurde nicht gefunden und es laeuft auch nichts auf Port $($script:Port)."
        Write-Host ""
        Write-Host "  Bitte zuerst OmniRoute-Setup.bat ausfuehren." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    if (-not (Start-OmniRouteServer -Omni $omni -TimeoutSeconds $TimeoutSeconds)) {
        Write-Host ""
        Write-Err2 "Der Server antwortet nicht auf Port $($script:Port)."
        Write-Host ""
        Write-Host "  Die Desktop-App wuerde jetzt nur ein schwarzes Fenster zeigen -" -ForegroundColor Yellow
        Write-Host "  deshalb wird sie gar nicht erst gestartet." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  So findest du die Ursache:" -ForegroundColor Yellow
        Write-Host "    1. OmniRoute-Start.bat ausfuehren - dort steht die Fehlermeldung im Klartext"
        Write-Host "    2. Diagnose.bat ausfuehren - schreibt einen vollstaendigen Bericht"
        Write-Host ""
        exit 1
    }

    # ------------------------------------------------- 2. Oberflaeche oeffnen
    Write-Step "Schritt 2/2 - Oberflaeche"

    if ($BrowserOnly) {
        Open-Dashboard | Out-Null
        Write-Host ""
        exit 0
    }

    $laeuft = @(Get-Process -Name 'OmniRoute' -ErrorAction SilentlyContinue)
    if ($laeuft.Count -gt 0) {
        Write-Ok "Die Desktop-App laeuft bereits ($($laeuft.Count) Fenster/Prozesse)."
        Write-Info "Falls sie schwarz war: jetzt schliessen und dieses Skript erneut starten -"
        Write-Info "sie muss nach dem Server gestartet werden, nicht davor."
        Write-Host ""
        exit 0
    }

    $app = Find-OmniRouteDesktopApp
    if (-not $app) {
        Write-Warn2 "Die Desktop-App wurde auf diesem Rechner nicht gefunden."
        Write-Info "Sie ist optional - das Dashboard im Browser zeigt dieselbe Oberflaeche."
        Write-Info "Download der App: https://github.com/diegosouzapw/OmniRoute/releases"
        Write-Host ""
        Open-Dashboard | Out-Null
        Write-Host ""
        exit 0
    }

    Write-Info "Gefunden: $app"
    $argumente = @()
    if ($DisableGpu) {
        $argumente += '--disable-gpu'
        Write-Info "Starte mit --disable-gpu."
    }

    if ($argumente.Count -gt 0) {
        Start-Process -FilePath $app -ArgumentList $argumente | Out-Null
    } else {
        Start-Process -FilePath $app | Out-Null
    }

    Write-Ok "Desktop-App gestartet - der Server lief vorher, sie sollte jetzt laden."
    Write-Host ""
    Write-Host "  Bleibt das Fenster trotzdem schwarz:" -ForegroundColor Yellow
    Write-Host "    - App schliessen und OmniRoute-Desktop.bat mit Option 2 (--disable-gpu) starten"
    Write-Host "    - oder einfach im Browser arbeiten: $($script:DashboardUrl)"
    Write-Host ""
    exit 0
}
catch {
    Write-Host ""
    Write-Err2 $_.Exception.Message
    Write-Host ""
    Write-Host "  Fuer einen vollstaendigen Bericht: Diagnose.bat ausfuehren." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
