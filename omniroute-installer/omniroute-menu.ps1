#Requires -Version 5.1
<#
.SYNOPSIS
    Menue fuer alle OmniRoute-Aufgaben: installieren, starten, diagnostizieren.

.DESCRIPTION
    Einstiegspunkt der Alles-in-einem-Variante. Ruft die Skripte im selben
    Ordner auf und laeuft so lange, bis Beenden gewaehlt wird.

.PARAMETER Auswahl
    Direkt eine Aktion ausfuehren, ohne Menue (1-5).
#>
[CmdletBinding()]
param(
    [ValidateSet('1', '2', '3', '4', '5', '6', '7', '8')]
    [string]$Auswahl
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'omniroute-common.ps1')

function Invoke-Teil {
    param([string]$Datei, [hashtable]$Parameter = @{})
    $pfad = Join-Path $PSScriptRoot $Datei
    if (-not (Test-Path $pfad)) {
        Write-Err2 "Die Datei $Datei fehlt neben diesem Skript."
        return 1
    }
    & $pfad @Parameter
    return $LASTEXITCODE
}

function Show-Status {
    Write-Host ""
    Write-Host "  Aktueller Stand" -ForegroundColor White

    $node = Get-NodeVersion
    if ($node) {
        if (Test-NodeSupported $node) { Write-Ok "Node.js $node" }
        else { Write-Warn2 "Node.js $node - nicht unterstuetzt (noetig: 22.22.2+ oder 24.x-26.x)" }
    } else {
        Write-Warn2 "Node.js nicht installiert"
    }

    $omni = Get-OmniRoutePath
    if ($omni) { Write-Ok "OmniRoute installiert" } else { Write-Warn2 "OmniRoute nicht installiert" }

    if (Test-OmniRouteReachable) {
        Write-Ok "Server laeuft auf Port $($script:Port)"
    } else {
        Write-Warn2 "Server laeuft nicht"
    }

    $app = Find-OmniRouteDesktopApp
    if ($app) { Write-Ok "Desktop-App gefunden" } else { Write-Info "Desktop-App nicht installiert (optional)" }
}

function Show-Menu {
    Write-Host ""
    Write-Host "  ================================================" -ForegroundColor DarkGray
    Write-Host "   OmniRoute" -ForegroundColor White
    Write-Host "  ================================================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    [1]  Installieren / reparieren" -ForegroundColor White
    Write-Host "         Node.js, OmniRoute, Claude Code und Codex einrichten"
    Write-Host ""
    Write-Host "    [8]  Anbieter einrichten  <<< ohne das laeuft nichts" -ForegroundColor Yellow
    Write-Host "         OmniRoute hat keine eigene KI. Erst ein Anbieter macht es nutzbar."
    Write-Host ""
    Write-Host "    [2]  Desktop-App starten" -ForegroundColor White
    Write-Host "         Erst den Server, dann die App - gegen das schwarze Fenster"
    Write-Host ""
    Write-Host "    [3]  Nur das Dashboard im Browser oeffnen" -ForegroundColor White
    Write-Host ""
    Write-Host "    [4]  Diagnose - Bericht auf den Desktop schreiben" -ForegroundColor White
    Write-Host "         Wenn etwas klemmt: das hier ausfuehren"
    Write-Host ""
    Write-Host "    [5]  Server im Vordergrund starten (Meldungen sichtbar)" -ForegroundColor White
    Write-Host ""
    Write-Host "    [6]  Verbindung testen" -ForegroundColor White
    Write-Host "         Warum nimmt Codex die Verbindung nicht an? Das hier sagt es"
    Write-Host ""
    Write-Host "    [7]  Speicherplatz anzeigen und aufraeumen" -ForegroundColor White
    Write-Host "         OmniRoute belegt ueber 400 MB - hier steht, wo der Platz hin ist"
    Write-Host ""
    Write-Host "    [0]  Beenden" -ForegroundColor DarkGray
    Write-Host ""
}

function Invoke-Auswahl {
    param([string]$Wahl)

    switch ($Wahl) {
        '1' { return Invoke-Teil 'omniroute-setup.ps1' }
        '2' { return Invoke-Teil 'omniroute-desktop.ps1' }
        '3' { return Invoke-Teil 'omniroute-desktop.ps1' @{ BrowserOnly = $true } }
        '4' { return Invoke-Teil 'omniroute-diagnose.ps1' }
        '5' {
            $omni = Get-OmniRoutePath
            if (-not $omni) {
                Write-Err2 "omniroute ist nicht installiert. Bitte zuerst Punkt 1 waehlen."
                return 1
            }
            Write-Host ""
            Write-Info "Server laeuft jetzt in diesem Fenster. Beenden mit Strg+C."
            Write-Host ""
            & $omni
            return $LASTEXITCODE
        }
        '6' { return Invoke-Teil 'omniroute-test.ps1' }
        '7' { return Invoke-Teil 'omniroute-speicher.ps1' @{ Aufraeumen = $true } }
        '8' { return Invoke-Teil 'omniroute-anbieter.ps1' }
        default { return 0 }
    }
}

# ------------------------------------------------------------------ Main ----

try {
    if ($Auswahl) {
        exit (Invoke-Auswahl $Auswahl)
    }

    while ($true) {
        Show-Menu
        Show-Status
        Write-Host ""
        $wahl = Read-Host "  Auswahl"
        $wahl = $wahl.Trim()

        if ($wahl -eq '0' -or $wahl -eq '') { break }
        if ($wahl -notin @('1', '2', '3', '4', '5', '6', '7', '8')) {
            Write-Warn2 "Bitte eine Zahl von 0 bis 8 eingeben."
            continue
        }

        $code = Invoke-Auswahl $wahl
        Write-Host ""
        if ($code -and $code -ne 0) {
            Write-Warn2 "Der Punkt wurde mit Fehlercode $code beendet."
            Write-Info "Punkt 4 (Diagnose) sagt dir, woran es liegt."
        }
        Write-Host ""
        Read-Host "  Weiter mit Enter" | Out-Null
    }

    exit 0
}
catch {
    Write-Host ""
    Write-Err2 $_.Exception.Message
    Write-Host ""
    Read-Host "  Enter zum Beenden" | Out-Null
    exit 1
}
