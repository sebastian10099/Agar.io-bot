#Requires -Version 5.1
<#
.SYNOPSIS
    Installiert OmniRoute und verbindet Claude Code sowie Codex automatisch damit.

.DESCRIPTION
    Ablauf:
      1. Node.js pruefen (benoetigt 22.22.2+ oder 24.x-26.x), bei Bedarf per winget nachinstallieren
      2. npm install -g omniroute
      3. Ersteinrichtung (Dashboard-Passwort)
      4. OmniRoute-Server im Hintergrund starten und auf Bereitschaft warten
      5. Claude Code und Codex automatisch auf OmniRoute umbiegen
      6. Optional: Autostart bei der Windows-Anmeldung einrichten

.PARAMETER Password
    Dashboard-Passwort. Ohne Angabe wird danach gefragt; leer lassen erzeugt ein Zufallspasswort.

.PARAMETER NoAutostart
    Keinen Autostart-Eintrag anlegen.

.PARAMETER SkipNodeInstall
    Node.js nicht automatisch installieren, nur pruefen.

.PARAMETER Remove
    Macht die Aenderungen rueckgaengig (Autostart, Umgebungsvariablen). Entfernt das
    npm-Paket nur zusammen mit -Purge.

.PARAMETER Purge
    Zusammen mit -Remove: entfernt auch das globale npm-Paket omniroute.

.EXAMPLE
    .\omniroute-setup.ps1

.EXAMPLE
    .\omniroute-setup.ps1 -Password "meinGeheimesPasswort" -NoAutostart
#>
[CmdletBinding()]
param(
    [string]$Password,
    [switch]$NoAutostart,
    [switch]$SkipNodeInstall,
    [switch]$Remove,
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:Port         = 20128
$script:BaseUrl      = "http://localhost:$($script:Port)/v1"
$script:HealthUrl    = "http://127.0.0.1:$($script:Port)/"
$script:DashboardUrl = "http://localhost:$($script:Port)/dashboard"
$script:Failures     = @()

# ---------------------------------------------------------------- Ausgabe ----

function Write-Step  { param($m) Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Info  { param($m) Write-Host "    $m" -ForegroundColor Gray }
function Write-Warn2 { param($m) Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Write-Err2  { param($m) Write-Host "    [x]  $m" -ForegroundColor Red }

function Add-Failure {
    param($Titel, $Hinweis)
    $script:Failures += [pscustomobject]@{ Titel = $Titel; Hinweis = $Hinweis }
}

function Show-Banner {
    Write-Host ""
    Write-Host "  OmniRoute Setup" -ForegroundColor White
    Write-Host "  Lokales AI-Gateway fuer Claude Code und Codex" -ForegroundColor DarkGray
    Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray
}

# ------------------------------------------------------------- Hilfsmittel ----

function Update-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Get-CommandPath {
    param([string]$Name)
    $c = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Get-NpmPath {
    $npm = Get-CommandPath 'npm.cmd'
    if (-not $npm) { $npm = Get-CommandPath 'npm' }
    return $npm
}

function Invoke-External {
    # Fuehrt ein externes Programm aus und liefert Exitcode samt Ausgabe zurueck.
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @(),
        [switch]$Quiet
    )
    # npm und winget schreiben Fortschritt und Warnungen auf stderr. Mit
    # ErrorActionPreference 'Stop' wuerde das eine Ausnahme ausloesen, statt
    # uns den Exitcode auswerten zu lassen. Die Zuweisung gilt nur in dieser
    # Funktion, der Rest des Skripts bleibt streng.
    $ErrorActionPreference = 'Continue'

    $out = & $File @Arguments 2>&1
    $code = $LASTEXITCODE
    if (-not $Quiet) { $out | ForEach-Object { Write-Info $_ } }
    return [pscustomobject]@{ ExitCode = $code; Output = ($out -join [Environment]::NewLine) }
}

function New-RandomPassword {
    param([int]$Length = 20)
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#%^*_-'
    $bytes = New-Object byte[] $Length
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

# ------------------------------------------------------------------ Node ----

function Get-NodeVersion {
    if (-not (Get-CommandPath 'node')) { return $null }
    $raw = (& node -v) 2>$null
    if ($raw -match 'v(\d+)\.(\d+)\.(\d+)') {
        return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    }
    return $null
}

function Test-NodeSupported {
    # OmniRoute engines: >=22.22.2 <23 || >=24.0.0 <27
    param([version]$Version)
    if (-not $Version) { return $false }
    if ($Version.Major -eq 22) { return $Version -ge [version]'22.22.2' }
    if ($Version.Major -ge 24 -and $Version.Major -lt 27) { return $true }
    return $false
}

function Install-Node {
    if (-not (Get-CommandPath 'winget')) {
        throw "winget wurde nicht gefunden. Bitte Node.js 22 LTS oder 24 LTS manuell von https://nodejs.org/ installieren und dieses Setup erneut starten."
    }
    Write-Info "Installiere Node.js LTS ueber winget (das kann ein paar Minuten dauern)..."
    $r = Invoke-External -File 'winget' -Arguments @(
        'install', '--id', 'OpenJS.NodeJS.LTS', '-e',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    # winget: 0 = Erfolg, -1978335189 = bereits aktuell installiert
    if ($r.ExitCode -ne 0 -and $r.ExitCode -ne -1978335189) {
        throw "winget konnte Node.js nicht installieren (Exitcode $($r.ExitCode))."
    }
    Update-PathFromRegistry
}

function Confirm-Node {
    Write-Step "Schritt 1/6 - Node.js pruefen"
    $v = Get-NodeVersion
    if (Test-NodeSupported $v) {
        Write-Ok "Node.js $v ist passend."
        return
    }

    if ($v) { Write-Warn2 "Node.js $v wird von OmniRoute nicht unterstuetzt (noetig: 22.22.2+ oder 24.x-26.x)." }
    else    { Write-Warn2 "Node.js wurde nicht gefunden." }

    if ($SkipNodeInstall) {
        throw "Node.js fehlt oder ist zu alt und -SkipNodeInstall ist gesetzt. Abbruch."
    }

    Install-Node
    $v = Get-NodeVersion
    if (-not (Test-NodeSupported $v)) {
        throw "Nach der Installation ist weiterhin keine unterstuetzte Node.js-Version aktiv (gefunden: $v). Bitte dieses Fenster schliessen, ein neues oeffnen und das Setup erneut starten."
    }
    Write-Ok "Node.js $v installiert."
}

# ------------------------------------------------------------- OmniRoute ----

function Install-OmniRoute {
    Write-Step "Schritt 2/6 - OmniRoute installieren"
    $npm = Get-NpmPath
    if (-not $npm) { throw "npm wurde nicht gefunden, obwohl Node.js vorhanden ist. Bitte Node.js neu installieren." }

    Write-Info "npm install -g omniroute"
    $r = Invoke-External -File $npm -Arguments @('install', '-g', 'omniroute')
    if ($r.ExitCode -ne 0) {
        throw "npm install -g omniroute ist fehlgeschlagen (Exitcode $($r.ExitCode)). Ausgabe siehe oben."
    }
    Update-PathFromRegistry

    $omni = Get-CommandPath 'omniroute.cmd'
    if (-not $omni) { $omni = Get-CommandPath 'omniroute' }
    if (-not $omni) {
        # npm-Prefix direkt nachschlagen, falls der PATH noch nicht aktualisiert ist
        $p = Invoke-External -File $npm -Arguments @('prefix', '-g') -Quiet
        if ($p.ExitCode -eq 0 -and $p.Output) {
            $cand = Join-Path $p.Output.Trim() 'omniroute.cmd'
            if (Test-Path $cand) { $omni = $cand }
        }
    }
    if (-not $omni) { throw "omniroute wurde nach der Installation nicht im PATH gefunden." }

    Write-Ok "OmniRoute installiert: $omni"
    return $omni
}

function Initialize-OmniRoute {
    param([string]$Omni)
    Write-Step "Schritt 3/6 - Ersteinrichtung"

    $pw = $Password
    if (-not $pw) {
        Write-Info "OmniRoute schuetzt sein lokales Dashboard mit einem Passwort."
        Write-Info "Einfach Enter druecken, um ein sicheres Zufallspasswort erzeugen zu lassen."
        $secure = Read-Host "    Dashboard-Passwort" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    $generated = $false
    if ([string]::IsNullOrWhiteSpace($pw)) {
        $pw = New-RandomPassword
        $generated = $true
    }

    $r = Invoke-External -File $Omni -Arguments @('setup', '--non-interactive', '--password', $pw) -Quiet
    if ($r.ExitCode -ne 0) {
        Write-Warn2 "Die Ersteinrichtung meldete Exitcode $($r.ExitCode)."
        Write-Warn2 "Das ist normal, wenn OmniRoute hier schon eingerichtet war - dann gilt das alte Passwort weiter."
        $generated = $false
    } else {
        Write-Ok "Ersteinrichtung abgeschlossen."
    }

    if ($generated) {
        $file = Join-Path $env:APPDATA 'omniroute\dashboard-passwort.txt'
        $dir = Split-Path $file -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $file -Value $pw -Encoding UTF8
        Write-Host ""
        Write-Host "    Erzeugtes Dashboard-Passwort: $pw" -ForegroundColor Yellow
        Write-Host "    Gespeichert in: $file" -ForegroundColor Yellow
        Write-Host "    Bitte notieren - die Datei liegt im Klartext auf der Platte." -ForegroundColor Yellow
    }
}

function Test-OmniRouteReachable {
    try {
        $null = Invoke-WebRequest -Uri $script:HealthUrl -UseBasicParsing -TimeoutSec 5
        return $true
    } catch {
        # Auch 401/403/404 heissen: es lauscht etwas. Nur Verbindungsfehler zaehlen als "nicht da".
        if ($_.Exception.Response) { return $true }
        return $false
    }
}

function Start-OmniRouteServer {
    param([string]$Omni)
    Write-Step "Schritt 4/6 - Server starten"

    if (Test-OmniRouteReachable) {
        Write-Ok "OmniRoute laeuft bereits auf Port $($script:Port)."
        return
    }

    Start-Process -FilePath $Omni -WindowStyle Minimized | Out-Null
    Write-Info "Warte darauf, dass der Server auf Port $($script:Port) antwortet..."

    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        if (Test-OmniRouteReachable) {
            Write-Ok "Server ist erreichbar: $($script:DashboardUrl)"
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "Der Server hat nach 120 Sekunden nicht geantwortet. Bitte 'omniroute' einmal manuell in einem Terminal starten und die Meldungen pruefen."
}

# ------------------------------------------------------- Clients verbinden ----

function Connect-Clients {
    param([string]$Omni)
    Write-Step "Schritt 5/6 - Claude Code und Codex verbinden"

    $ziele = @(
        @{ Name = 'Claude Code'; Befehl = 'setup-claude' },
        @{ Name = 'Codex CLI';   Befehl = 'setup-codex'  }
    )

    foreach ($z in $ziele) {
        Write-Info "omniroute $($z.Befehl)"
        $r = Invoke-External -File $Omni -Arguments @($z.Befehl) -Quiet
        if ($r.ExitCode -eq 0) {
            Write-Ok "$($z.Name) zeigt jetzt auf OmniRoute."
        } else {
            Write-Warn2 "$($z.Name) konnte nicht automatisch konfiguriert werden (Exitcode $($r.ExitCode))."
            if ($r.Output) { Write-Info $r.Output }
            Add-Failure -Titel $z.Name -Hinweis "Manuell 'omniroute $($z.Befehl)' im Terminal ausfuehren, oder im Dashboard unter Endpoints einen Key erzeugen und als Base URL $($script:BaseUrl) eintragen."
        }
    }

    if ($script:Failures.Count -gt 0) {
        Write-Info "Oeffne das Dashboard, damit du dort einen API-Key erzeugen kannst..."
        try { Start-Process $script:DashboardUrl | Out-Null }
        catch { Write-Info "Dashboard bitte manuell oeffnen: $($script:DashboardUrl)" }
    }
}

# --------------------------------------------------------------- Autostart ----

function Get-StartupShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'OmniRoute.lnk'
}

function Set-Autostart {
    param([string]$Omni)
    Write-Step "Schritt 6/6 - Autostart einrichten"

    if ($NoAutostart) {
        Write-Info "Uebersprungen (-NoAutostart)."
        return
    }

    $lnkPath = Get-StartupShortcutPath
    $shell = New-Object -ComObject WScript.Shell
    try {
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath       = $Omni
        $lnk.WorkingDirectory = Split-Path $Omni -Parent
        $lnk.WindowStyle      = 7   # minimiert
        $lnk.Description      = 'Startet das lokale OmniRoute AI-Gateway'
        $lnk.Save()
        Write-Ok "OmniRoute startet ab jetzt automatisch bei der Anmeldung."
        Write-Info "Rueckgaengig: diese Datei loeschen - $lnkPath"
    } finally {
        [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    }
}

# ---------------------------------------------------------- Deinstallation ----

function Invoke-Removal {
    Show-Banner
    Write-Step "OmniRoute-Einrichtung entfernen"

    $lnkPath = Get-StartupShortcutPath
    if (Test-Path $lnkPath) {
        Remove-Item $lnkPath -Force
        Write-Ok "Autostart-Eintrag entfernt."
    } else {
        Write-Info "Kein Autostart-Eintrag vorhanden."
    }

    foreach ($name in @('ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'OPENAI_BASE_URL', 'OPENAI_API_KEY')) {
        $cur = [Environment]::GetEnvironmentVariable($name, 'User')
        if ($cur -and $cur -like "*$($script:Port)*") {
            [Environment]::SetEnvironmentVariable($name, $null, 'User')
            Write-Ok "Umgebungsvariable $name entfernt."
        }
    }

    if ($Purge) {
        $npm = Get-NpmPath
        if ($npm) {
            Write-Info "npm uninstall -g omniroute"
            Invoke-External -File $npm -Arguments @('uninstall', '-g', 'omniroute') | Out-Null
            Write-Ok "npm-Paket entfernt."
        }
    } else {
        Write-Info "Das npm-Paket bleibt installiert. Mit -Purge wird es ebenfalls entfernt."
    }

    Write-Host ""
    Write-Warn2 "Claude Code und Codex zeigen eventuell noch auf OmniRoute."
    Write-Warn2 "Deren eigene Konfiguration (z. B. ~/.claude/settings.json) bitte selbst pruefen."
    Write-Host ""
}

# ------------------------------------------------------------- Abschluss ----

function Show-Summary {
    Write-Host ""
    Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray
    if ($script:Failures.Count -eq 0) {
        Write-Host "  Fertig. Alles eingerichtet." -ForegroundColor Green
    } else {
        Write-Host "  Fertig - mit offenen Punkten." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Dashboard : $($script:DashboardUrl)"
    Write-Host "  API       : $($script:BaseUrl)"
    Write-Host ""

    if ($script:Failures.Count -gt 0) {
        Write-Host "  Noch zu erledigen:" -ForegroundColor Yellow
        foreach ($f in $script:Failures) {
            Write-Host "   - $($f.Titel): $($f.Hinweis)" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    Write-Host "  Naechster Schritt: im Dashboard unter Providers mindestens einen"
    Write-Host "  Anbieter hinzufuegen. Danach uebernimmt OmniRoute die Modellwahl"
    Write-Host "  und schaltet bei aufgebrauchtem Kontingent selbst auf einen"
    Write-Host "  anderen Anbieter um."
    Write-Host ""
    Write-Host "  Wichtig: neue Terminalfenster oeffnen, damit die Aenderungen greifen."
    Write-Host ""
}

# ------------------------------------------------------------------ Main ----

try {
    if ($Remove) {
        Invoke-Removal
        exit 0
    }

    Show-Banner
    Confirm-Node
    $omni = Install-OmniRoute
    Initialize-OmniRoute -Omni $omni
    Start-OmniRouteServer -Omni $omni
    Connect-Clients -Omni $omni
    Set-Autostart -Omni $omni
    Show-Summary
    exit 0
}
catch {
    Write-Host ""
    Write-Err2 $_.Exception.Message
    Write-Host ""
    Write-Host "  Setup abgebrochen. Es bleibt nichts halbfertig zurueck, das ein"
    Write-Host "  erneuter Durchlauf nicht ueberschreiben wuerde - du kannst dieses"
    Write-Host "  Skript einfach nochmal ausfuehren."
    Write-Host ""
    exit 1
}
