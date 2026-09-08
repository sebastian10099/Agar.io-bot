#Requires -Version 5.1
<#
.SYNOPSIS
    Fuehrt durch das Eintragen eines Anbieters - der eine Schritt, der fehlt.

.DESCRIPTION
    OmniRoute ist nur ein Verteiler und hat selbst keine KI. Ohne einen
    eingetragenen Anbieter hat es nichts, wohin es weiterleiten koennte, und
    Codex bekommt keine Verbindung.

    Dieses Skript zeigt Anbieter mit dauerhaft kostenlosem Kontingent, die
    keine Kreditkarte verlangen, oeffnet die Anmeldeseite, nimmt den Schluessel
    entgegen und traegt ihn ein. Anschliessend wird geprueft, ob es wirkt.

    Die Anmeldung selbst kann dir niemand abnehmen - dafuer braucht es deine
    E-Mail-Adresse und deine Zustimmung zu den Bedingungen des Anbieters.

.PARAMETER Anbieter
    Anbieter direkt waehlen (google, groq, cerebras, mistral, openrouter),
    ohne Auswahlliste.

.PARAMETER ApiKey
    Schluessel direkt uebergeben, statt danach zu fragen.

.EXAMPLE
    .\omniroute-anbieter.ps1

.EXAMPLE
    .\omniroute-anbieter.ps1 -Anbieter groq
#>
[CmdletBinding()]
param(
    [ValidateSet('google', 'groq', 'cerebras', 'mistral', 'openrouter')]
    [string]$Anbieter,
    [string]$ApiKey
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

. (Join-Path $PSScriptRoot 'omniroute-common.ps1')

# Stand der Angaben: September 2026. Kostenlose Kontingente aendern sich -
# die aktuelle Lage steht immer unter /dashboard/free-tiers.
$script:Empfehlungen = @(
    [pscustomobject]@{
        Id       = 'google'
        Name     = 'Google AI Studio (Gemini)'
        Kurz     = 'Das grosszuegigste Kontingent. Bis 1 Mio. Zeichen Kontext.'
        Url      = 'https://aistudio.google.com/apikey'
        Karte    = $false
        Slugs    = @('google', 'gemini', 'google-ai-studio', 'googleaistudio')
        Empfohlen = $true
    },
    [pscustomobject]@{
        Id       = 'groq'
        Name     = 'Groq'
        Kurz     = 'Sehr schnell. 30 Anfragen/Minute, rund 14400 pro Tag.'
        Url      = 'https://console.groq.com/keys'
        Karte    = $false
        Slugs    = @('groq')
        Empfohlen = $true
    },
    [pscustomobject]@{
        Id       = 'cerebras'
        Name     = 'Cerebras'
        Kurz     = '1 Mio. Token pro Tag. Modellauswahl schwankt aber.'
        Url      = 'https://cloud.cerebras.ai/'
        Karte    = $false
        Slugs    = @('cerebras')
        Empfohlen = $false
    },
    [pscustomobject]@{
        Id       = 'mistral'
        Name     = 'Mistral'
        Kurz     = 'Rund 1 Mrd. Token pro Monat auf La Plateforme.'
        Url      = 'https://console.mistral.ai/api-keys'
        Karte    = $false
        Slugs    = @('mistral', 'mistralai')
        Empfohlen = $false
    },
    [pscustomobject]@{
        Id       = 'openrouter'
        Name     = 'OpenRouter'
        Kurz     = 'Ein Schluessel, 20+ kostenlose Modelle verschiedener Anbieter.'
        Url      = 'https://openrouter.ai/keys'
        Karte    = $false
        Slugs    = @('openrouter')
        Empfohlen = $false
    }
)

function Show-Empfehlungen {
    Write-Host ""
    Write-Host "  Anbieter mit dauerhaft kostenlosem Kontingent" -ForegroundColor White
    Write-Host "  Keiner davon verlangt eine Kreditkarte." -ForegroundColor DarkGray
    Write-Host ""

    $i = 1
    foreach ($e in $script:Empfehlungen) {
        $marke = if ($e.Empfohlen) { ' (empfohlen)' } else { '' }
        Write-Host ("    [{0}]  {1}{2}" -f $i, $e.Name, $marke) -ForegroundColor White
        Write-Host ("         {0}" -f $e.Kurz) -ForegroundColor Gray
        Write-Host ("         {0}" -f $e.Url) -ForegroundColor DarkGray
        Write-Host ""
        $i++
    }
    Write-Host "    [0]  Abbrechen" -ForegroundColor DarkGray
    Write-Host ""
}

function Read-ApiKey {
    param([string]$AnbieterName)
    Write-Host ""
    Write-Info "Der Schluessel wird verdeckt eingegeben und nicht angezeigt."
    $sicher = Read-Host "    Schluessel von $AnbieterName einfuegen" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sicher)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Add-Provider {
    <#
        Versucht die bekannten Schreibweisen des Anbieternamens durch, bis eine
        angenommen wird. OmniRoute benennt Anbieter nicht ueberall gleich.
    #>
    param([string]$Omni, [object]$Eintrag, [string]$Key)

    foreach ($slug in $Eintrag.Slugs) {
        Write-Info "Versuche '$slug'..."
        $r = Invoke-External -File $Omni -Arguments @(
            'setup', '--non-interactive', '--add-provider',
            '--provider', $slug, '--api-key', $Key
        ) -Quiet

        if ($r.ExitCode -eq 0) {
            return [pscustomobject]@{ Erfolg = $true; Slug = $slug; Ausgabe = $r.Output }
        }
    }
    return [pscustomobject]@{ Erfolg = $false; Slug = $null; Ausgabe = $r.Output }
}

# ------------------------------------------------------------------ Main ----

try {
    Write-Host ""
    Write-Host "  Anbieter einrichten" -ForegroundColor White
    Write-Host "  =================================================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  OmniRoute ist ein Verteiler ohne eigene KI. Erst mit einem" -ForegroundColor Gray
    Write-Host "  Anbieter dahinter kann Codex ueberhaupt etwas bekommen." -ForegroundColor Gray

    $omni = Get-OmniRoutePath
    if (-not $omni) {
        Write-Host ""
        Write-Err2 "omniroute ist nicht installiert."
        Write-Info "Bitte zuerst Punkt 1 im Menue ausfuehren."
        Write-Host ""
        exit 1
    }

    # --------------------------------------------------- Anbieter waehlen
    $eintrag = $null
    if ($Anbieter) {
        $eintrag = $script:Empfehlungen | Where-Object { $_.Id -eq $Anbieter } | Select-Object -First 1
    } else {
        Show-Empfehlungen
        $wahl = (Read-Host "  Auswahl").Trim()
        if ($wahl -eq '0' -or $wahl -eq '') { Write-Info "Abgebrochen."; exit 0 }
        $nummer = 0
        if ([int]::TryParse($wahl, [ref]$nummer) -and $nummer -ge 1 -and $nummer -le $script:Empfehlungen.Count) {
            $eintrag = $script:Empfehlungen[$nummer - 1]
        }
    }

    if (-not $eintrag) {
        Write-Warn2 "Keine gueltige Auswahl."
        exit 1
    }

    Write-Host ""
    Write-Host "  Gewaehlt: $($eintrag.Name)" -ForegroundColor Green

    # --------------------------------------------------- Anmeldeseite
    if (-not $ApiKey) {
        Write-Step "Schritt 1/3 - Schluessel holen"
        Write-Host ""
        Write-Host "  So kommst du an den Schluessel:" -ForegroundColor White
        Write-Host "    1. Die Seite oeffnet sich gleich im Browser"
        Write-Host "    2. Mit E-Mail-Adresse anmelden (Kreditkarte wird nicht verlangt)"
        Write-Host "    3. Einen neuen API-Key erzeugen"
        Write-Host "    4. Key kopieren und hier einfuegen"
        Write-Host ""
        Write-Host "  $($eintrag.Url)" -ForegroundColor Cyan
        Write-Host ""
        Read-Host "  Enter druecken, um die Seite zu oeffnen" | Out-Null

        try { Start-Process $eintrag.Url | Out-Null }
        catch { Write-Warn2 "Browser liess sich nicht oeffnen - Adresse bitte von Hand eintippen." }

        $ApiKey = Read-ApiKey $eintrag.Name
    }

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        Write-Host ""
        Write-Warn2 "Kein Schluessel eingegeben - abgebrochen."
        Write-Info "Du kannst diesen Punkt jederzeit neu starten."
        Write-Host ""
        exit 1
    }

    # --------------------------------------------------- Eintragen
    Write-Step "Schritt 2/3 - Eintragen"
    $ergebnis = Add-Provider -Omni $omni -Eintrag $eintrag -Key $ApiKey

    if ($ergebnis.Erfolg) {
        Write-Ok "$($eintrag.Name) eingetragen (als '$($ergebnis.Slug)')."
    } else {
        Write-Warn2 "Das Eintragen ueber die Befehlszeile hat nicht geklappt."
        if ($ergebnis.Ausgabe) {
            Write-Host ""
            foreach ($l in ($ergebnis.Ausgabe -split "`r?`n" | Select-Object -First 15)) {
                if ($l.Trim()) { Write-Info $l }
            }
        }
        Write-Host ""
        Write-Host "  Dann von Hand - das dauert auch nur eine Minute:" -ForegroundColor Yellow
        Write-Host "    1. Das Dashboard oeffnet sich gleich"
        Write-Host "    2. Links auf 'Providers'"
        Write-Host "    3. $($eintrag.Name) suchen und auswaehlen"
        Write-Host "    4. Deinen Schluessel dort einfuegen und speichern"
        Write-Host ""
        Write-Host "  Uebrigens: unter /dashboard/free-tiers listet OmniRoute alle" -ForegroundColor Gray
        Write-Host "  Anbieter mit kostenlosem Kontingent auf - dort siehst du," -ForegroundColor Gray
        Write-Host "  was gerade tatsaechlich verfuegbar ist." -ForegroundColor Gray
        Write-Host ""

        if (-not (Test-OmniRouteReachable)) {
            Write-Info "Der Server laeuft nicht - ich starte ihn zuerst."
            Start-OmniRouteServer -Omni $omni | Out-Null
        }
        try { Start-Process "http://localhost:$($script:Port)/dashboard" | Out-Null } catch { }

        Write-Host ""
        Read-Host "  Enter druecken, wenn du fertig bist" | Out-Null
    }

    # --------------------------------------------------- Nachpruefen
    Write-Step "Schritt 3/3 - Nachpruefen"

    if (-not (Test-OmniRouteReachable)) {
        Write-Info "Der Server muss dafuer laufen - starte ihn."
        if (-not (Start-OmniRouteServer -Omni $omni)) {
            Write-Warn2 "Der Server antwortet nicht. Bitte Punkt 5 im Menue ausfuehren."
            exit 1
        }
    }

    $pruef = Join-Path $PSScriptRoot 'omniroute-test.ps1'
    if (Test-Path $pruef) {
        Write-Info "Starte den Verbindungstest..."
        Write-Host ""
        & $pruef
        exit $LASTEXITCODE
    }

    Write-Ok "Fertig. Pruefe mit Punkt 6, ob die Verbindung jetzt steht."
    Write-Host ""
    exit 0
}
catch {
    Write-Host ""
    Write-Err2 $_.Exception.Message
    Write-Host ""
    Write-Host "  Punkt 4 (Diagnose) sammelt einen vollstaendigen Bericht." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
