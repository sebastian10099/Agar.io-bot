#Requires -Version 5.1
<#
.SYNOPSIS
    Prueft die Kette Server -> Schluessel -> Provider -> Modelle -> Antwort.

.DESCRIPTION
    Beantwortet die Frage "warum nimmt Codex die Verbindung nicht an?", indem
    jedes Glied einzeln geprueft wird. Der erste rote Punkt ist die Ursache -
    alles danach kann gar nicht funktionieren.

      1. Antwortet der Server auf Port 20128?
      2. Gibt es einen API-Schluessel und wo kommt er her?
      3. Liefert /v1/models Modelle? (Leer = kein Provider eingetragen)
      4. Zeigen Claude Code und Codex ueberhaupt auf OmniRoute?
      5. Kommt auf eine echte Anfrage eine Antwort zurueck?

.PARAMETER ApiKey
    Schluessel direkt angeben. Ohne Angabe wird in den Umgebungsvariablen und
    den Konfigurationsdateien gesucht, sonst danach gefragt.

.PARAMETER Model
    Bestimmtes Modell testen. Ohne Angabe wird das erste verfuegbare genommen.

.EXAMPLE
    .\omniroute-test.ps1
#>
[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$Model
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

. (Join-Path $PSScriptRoot 'omniroute-common.ps1')

$script:Problem = $null

function Set-Problem {
    param([string]$Text, [string[]]$Loesung)
    if (-not $script:Problem) {
        $script:Problem = [pscustomobject]@{ Text = $Text; Loesung = $Loesung }
    }
}

function Get-KeyFromConfig {
    <#
        Sucht den Schluessel dort, wo die Werkzeuge ihn ablegen. Gibt Wert und
        Fundort zurueck. Es wird nur gelesen, nichts veraendert.
    #>
    $env1 = [Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'User')
    if ($env1) { return [pscustomobject]@{ Key = $env1; Quelle = 'Umgebungsvariable ANTHROPIC_AUTH_TOKEN' } }

    $env2 = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')
    if ($env2) { return [pscustomobject]@{ Key = $env2; Quelle = 'Umgebungsvariable OPENAI_API_KEY' } }

    if ($env:ANTHROPIC_AUTH_TOKEN) { return [pscustomobject]@{ Key = $env:ANTHROPIC_AUTH_TOKEN; Quelle = 'Sitzungsvariable ANTHROPIC_AUTH_TOKEN' } }
    if ($env:OPENAI_API_KEY)       { return [pscustomobject]@{ Key = $env:OPENAI_API_KEY;       Quelle = 'Sitzungsvariable OPENAI_API_KEY' } }

    return $null
}

function Get-ClientConfigs {
    <#
        Schaut in die Konfigurationsdateien der Werkzeuge und meldet, ob dort
        Port 20128 auftaucht. Die Pfade sind Kandidaten - was fehlt, wird als
        "nicht gefunden" gemeldet, nicht als Fehler.
    #>
    $kandidaten = @(
        @{ Name = 'Claude Code'; Pfad = (Join-Path $env:USERPROFILE '.claude\settings.json') },
        @{ Name = 'Codex CLI';   Pfad = (Join-Path $env:USERPROFILE '.codex\config.toml')   },
        @{ Name = 'Codex CLI';   Pfad = (Join-Path $env:USERPROFILE '.codex\config.json')   }
    )

    $ergebnis = @()
    foreach ($k in $kandidaten) {
        if (-not (Test-Path $k.Pfad)) {
            $ergebnis += [pscustomobject]@{ Name = $k.Name; Pfad = $k.Pfad; Vorhanden = $false; Verbunden = $false }
            continue
        }
        $inhalt = ''
        try { $inhalt = Get-Content $k.Pfad -Raw -ErrorAction Stop } catch { }
        $ergebnis += [pscustomobject]@{
            Name      = $k.Name
            Pfad      = $k.Pfad
            Vorhanden = $true
            Verbunden = ($inhalt -match [regex]::Escape("$($script:Port)"))
        }
    }
    return $ergebnis
}

function Invoke-Gateway {
    param([string]$Pfad, [string]$Key, [hashtable]$Body, [int]$TimeoutSec = 60)
    $uri = "http://localhost:$($script:Port)$Pfad"
    $headers = @{ 'Authorization' = "Bearer $Key" }
    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 6
        return Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body $json `
                                 -ContentType 'application/json' -TimeoutSec $TimeoutSec
    }
    return Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec $TimeoutSec
}

# ------------------------------------------------------------------ Main ----

try {
    Write-Host ""
    Write-Host "  OmniRoute Verbindungstest" -ForegroundColor White
    Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray

    # ------------------------------------------------------ 1. Server
    Write-Step "1/5 - Laeuft der Server?"
    if (Test-OmniRouteReachable) {
        Write-Ok "Der Server antwortet auf Port $($script:Port)."
    } else {
        Write-Err2 "Keine Antwort auf Port $($script:Port)."
        Set-Problem "Der OmniRoute-Server laeuft nicht." @(
            "Im Menue Punkt 5 waehlen - dann laeuft der Server sichtbar und zeigt seine Meldungen.",
            "Laeuft er dort auch nicht: Punkt 4 (Diagnose) ausfuehren."
        )
        throw 'ABBRUCH'
    }

    # ------------------------------------------------------ 2. Schluessel
    Write-Step "2/5 - Gibt es einen API-Schluessel?"
    $quelle = 'Eingabe'
    if (-not $ApiKey) {
        $gefunden = Get-KeyFromConfig
        if ($gefunden) {
            $ApiKey = $gefunden.Key
            $quelle = $gefunden.Quelle
        }
    }

    if (-not $ApiKey) {
        Write-Warn2 "Kein Schluessel gefunden."
        Write-Info "Den erzeugst du im Dashboard unter 'Endpoints'."
        Write-Info "Ich oeffne die Seite - Key kopieren und hier einfuegen."
        try { Start-Process $script:DashboardUrl | Out-Null } catch { }
        Write-Host ""
        $ApiKey = (Read-Host "    API-Schluessel einfuegen (Enter zum Ueberspringen)").Trim()
        $quelle = 'Eingabe'
    }

    if (-not $ApiKey) {
        Write-Err2 "Ohne Schluessel kann nicht weitergetestet werden."
        Set-Problem "Es gibt keinen API-Schluessel." @(
            "Dashboard oeffnen: $($script:DashboardUrl)",
            "Dort unter 'Endpoints' einen Key erzeugen.",
            "Danach im Menue Punkt 1 erneut ausfuehren - das traegt ihn in Claude Code und Codex ein."
        )
        throw 'ABBRUCH'
    }
    Write-Ok "Schluessel vorhanden (Laenge $($ApiKey.Length), Quelle: $quelle)."

    # ------------------------------------------------------ 3. Modelle
    Write-Step "3/5 - Sind Provider eingetragen?"
    $modelle = @()
    try {
        $antwort = Invoke-Gateway -Pfad '/v1/models' -Key $ApiKey
        if ($antwort.data) { $modelle = @($antwort.data) }
        elseif ($antwort.models) { $modelle = @($antwort.models) }
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 401 -or $code -eq 403) {
            Write-Err2 "Der Server lehnt den Schluessel ab (HTTP $code)."
            Set-Problem "Der API-Schluessel ist falsch oder abgelaufen." @(
                "Im Dashboard unter 'Endpoints' einen neuen Key erzeugen: $($script:DashboardUrl)",
                "Danach im Menue Punkt 1 ausfuehren, damit er ueberall eingetragen wird."
            )
            throw 'ABBRUCH'
        }
        Write-Err2 "Die Modellliste liess sich nicht abrufen: $($_.Exception.Message)"
        Set-Problem "Der Server antwortet, liefert aber keine Modellliste." @(
            "Punkt 4 (Diagnose) ausfuehren und den Bericht anschauen."
        )
        throw 'ABBRUCH'
    }

    if ($modelle.Count -eq 0) {
        Write-Err2 "Der Server kennt kein einziges Modell."
        Write-Host ""
        Write-Host "    Das ist mit hoher Wahrscheinlichkeit dein Problem." -ForegroundColor Yellow
        Write-Host "    OmniRoute ist nur ein Verteiler. Ohne eingetragenen Anbieter" -ForegroundColor Yellow
        Write-Host "    hat es nichts, wohin es weiterleiten koennte - und dann nimmt" -ForegroundColor Yellow
        Write-Host "    Codex auch keine Verbindung an." -ForegroundColor Yellow
        Set-Problem "Es ist kein Anbieter (Provider) eingetragen." @(
            "Dashboard oeffnen: $($script:DashboardUrl)",
            "Links auf 'Providers' gehen.",
            "Einen Anbieter mit kostenlosem Kontingent auswaehlen und dessen Schluessel eintragen.",
            "Danach diesen Test erneut ausfuehren."
        )
        try { Start-Process "http://localhost:$($script:Port)/dashboard" | Out-Null } catch { }
        throw 'ABBRUCH'
    }

    Write-Ok "$($modelle.Count) Modell(e) verfuegbar."
    $namen = @($modelle | ForEach-Object { if ($_.id) { $_.id } else { $_ } } | Select-Object -First 8)
    foreach ($n in $namen) { Write-Info "  $n" }
    if ($modelle.Count -gt $namen.Count) { Write-Info "  ... und $($modelle.Count - $namen.Count) weitere" }

    # ------------------------------------------------------ 4. Clients
    Write-Step "4/5 - Zeigen Claude Code und Codex auf OmniRoute?"
    $configs = Get-ClientConfigs
    $verbunden = @($configs | Where-Object { $_.Verbunden })

    foreach ($c in $configs) {
        if ($c.Verbunden)      { Write-Ok   "$($c.Name): verbunden ($($c.Pfad))" }
        elseif ($c.Vorhanden)  { Write-Warn2 "$($c.Name): Konfiguration da, aber ohne Port $($script:Port) ($($c.Pfad))" }
        else                   { Write-Info  "$($c.Name): keine Konfiguration unter $($c.Pfad)" }
    }

    if ($verbunden.Count -eq 0) {
        Write-Warn2 "Keine der Konfigurationen verweist auf OmniRoute."
        Set-Problem "Claude Code und Codex zeigen nicht auf OmniRoute." @(
            "Im Menue Punkt 1 ausfuehren - das setzt beide Werkzeuge um.",
            "Danach alle offenen Terminals schliessen und neu oeffnen."
        )
    }

    # ------------------------------------------------------ 5. Echte Anfrage
    Write-Step "5/5 - Kommt eine echte Antwort zurueck?"
    if (-not $Model) {
        $Model = if ($namen.Count -gt 0) { $namen[0] } else { 'auto' }
    }
    Write-Info "Teste mit Modell: $Model"

    try {
        $body = @{
            model    = $Model
            messages = @(@{ role = 'user'; content = 'Antworte nur mit dem Wort: OK' })
            max_tokens = 16
        }
        $r = Invoke-Gateway -Pfad '/v1/chat/completions' -Key $ApiKey -Body $body -TimeoutSec 90
        $text = $null
        if ($r.choices -and $r.choices.Count -gt 0) { $text = $r.choices[0].message.content }
        if ($text) {
            Write-Ok "Antwort erhalten: $($text.Trim())"
            Write-Host ""
            Write-Host "    Die Kette funktioniert. Codex und Claude Code koennen ueber" -ForegroundColor Green
            Write-Host "    OmniRoute arbeiten." -ForegroundColor Green
        } else {
            Write-Warn2 "Der Server hat geantwortet, aber ohne Textinhalt."
            Set-Problem "Der Anbieter liefert keine verwertbare Antwort." @(
                "Im Dashboard unter 'Providers' pruefen, ob der Anbieter als aktiv angezeigt wird.",
                "Gegebenenfalls einen zweiten Anbieter eintragen."
            )
        }
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        Write-Err2 "Die Anfrage ist fehlgeschlagen$(if ($code) { " (HTTP $code)" })."
        Write-Info $_.Exception.Message
        Set-Problem "Der Anbieter nimmt die Anfrage nicht an." @(
            "Haeufigste Ursache: das Kontingent des Anbieters ist aufgebraucht oder sein Schluessel ist falsch.",
            "Im Dashboard unter 'Providers' einen zweiten Anbieter eintragen - dann kann OmniRoute umschalten.",
            "Danach diesen Test erneut ausfuehren."
        )
    }
}
catch {
    if ($_.Exception.Message -ne 'ABBRUCH') {
        Write-Host ""
        Write-Err2 $_.Exception.Message
    }
}
finally {
    Write-Host ""
    Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray
    if ($script:Problem) {
        Write-Host "  Das ist die Ursache:" -ForegroundColor Yellow
        Write-Host "  $($script:Problem.Text)" -ForegroundColor White
        Write-Host ""
        Write-Host "  So behebst du es:" -ForegroundColor Yellow
        $i = 1
        foreach ($l in $script:Problem.Loesung) {
            Write-Host "   $i. $l"
            $i++
        }
    } else {
        Write-Host "  Kein Problem gefunden." -ForegroundColor Green
    }
    Write-Host ""
}

if ($script:Problem) { exit 1 } else { exit 0 }
