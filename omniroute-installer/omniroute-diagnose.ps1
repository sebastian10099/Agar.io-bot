#Requires -Version 5.1
<#
.SYNOPSIS
    Sammelt einen Bericht darueber, warum OmniRoute nicht laeuft.

.DESCRIPTION
    Prueft Node.js, npm, die OmniRoute-Installation, den Port 20128, die
    Desktop-App, die Datenverzeichnisse und die gesetzten Umgebungsvariablen.
    Schreibt alles in eine Textdatei auf dem Desktop und oeffnet sie.

    Der Bericht ist zum Weitergeben gedacht. Deshalb werden Schluessel und
    Passwoerter nicht ausgegeben - nur, ob sie gesetzt sind und wie lang sie sind.

.PARAMETER OutFile
    Zielpfad des Berichts. Standard: OmniRoute-Diagnose.txt auf dem Desktop.

.PARAMETER NoOpen
    Bericht nicht automatisch oeffnen.

.EXAMPLE
    .\omniroute-diagnose.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

. (Join-Path $PSScriptRoot 'omniroute-common.ps1')

if (-not $OutFile) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = $env:USERPROFILE }
    $OutFile = Join-Path $desktop 'OmniRoute-Diagnose.txt'
}

$zeilen = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$T = '') $zeilen.Add($T) }
function Add-Head {
    param([string]$T)
    Add-Line
    Add-Line ('-' * 60)
    Add-Line $T
    Add-Line ('-' * 60)
}
function Show-Secret {
    # Nie den Wert selbst ausgeben - der Bericht wird weitergegeben.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'nicht gesetzt' }
    return "gesetzt (Laenge $($Value.Length))"
}

Write-Host ""
Write-Host "  OmniRoute Diagnose" -ForegroundColor White
Write-Host "  Sammle Informationen..." -ForegroundColor DarkGray

Add-Line "OmniRoute Diagnosebericht"
Add-Line ("Erstellt: {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date))

# --------------------------------------------------------------- System ----

Add-Head 'System'
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Add-Line "Windows      : $($os.Caption) $($os.Version) ($($os.OSArchitecture))"
} catch {
    Add-Line "Windows      : nicht ermittelbar ($($_.Exception.Message))"
}
Add-Line "PowerShell   : $($PSVersionTable.PSVersion)"
Add-Line "Benutzer     : $env:USERNAME"

# ----------------------------------------------------------------- Node ----

Add-Head 'Node.js und npm'
$nodePfad = Get-CommandPath 'node'
$nodeVer  = Get-NodeVersion
if ($nodePfad) {
    Add-Line "node         : $nodePfad"
    Add-Line "Version      : $nodeVer"
    if (Test-NodeSupported $nodeVer) {
        Add-Line "Bewertung    : OK (OmniRoute verlangt >=22.22.2 <23 oder >=24 <27)"
    } else {
        Add-Line "Bewertung    : NICHT UNTERSTUETZT - OmniRoute verlangt >=22.22.2 <23 oder >=24 <27"
        Add-Line "               Das allein kann schon die Ursache sein."
    }
} else {
    Add-Line "node         : NICHT GEFUNDEN"
}

$npm = Get-NpmPath
if ($npm) {
    Add-Line "npm          : $npm"
    $r = Invoke-External -File $npm -Arguments @('--version') -Quiet
    Add-Line "npm-Version  : $($r.Output.Trim())"
} else {
    Add-Line "npm          : NICHT GEFUNDEN"
}

# ------------------------------------------------------------ OmniRoute ----

Add-Head 'OmniRoute-Installation'
$omni = Get-OmniRoutePath
if ($omni) {
    Add-Line "omniroute    : $omni"
    $v = Invoke-External -File $omni -Arguments @('--version') -Quiet
    Add-Line "Version      : $($v.Output.Trim())"
    Add-Line "Exitcode     : $($v.ExitCode)"
} else {
    Add-Line "omniroute    : NICHT GEFUNDEN (npm install -g omniroute fehlt oder PATH veraltet)"
}

if ($npm) {
    $ls = Invoke-External -File $npm -Arguments @('ls', '-g', '--depth', '0') -Quiet
    Add-Line
    Add-Line "Global installierte npm-Pakete:"
    foreach ($l in ($ls.Output -split "`r?`n")) { if ($l.Trim()) { Add-Line "  $l" } }
}

# ----------------------------------------------------------------- Port ----

Add-Head "Port $($script:Port)"
$pids = Get-PortListener
if ($pids.Count -gt 0) {
    Add-Line "Es lauscht etwas auf dem Port. PID(s): $($pids -join ', ')"
    foreach ($p in $pids) {
        try {
            $proc = Get-Process -Id $p -ErrorAction Stop
            Add-Line "  PID $p = $($proc.ProcessName) ($($proc.Path))"
        } catch {
            Add-Line "  PID $p = Prozess nicht lesbar"
        }
    }
} else {
    Add-Line "NIEMAND lauscht auf Port $($script:Port)."
    Add-Line "Das ist die haeufigste Ursache fuer das schwarze Fenster der Desktop-App:"
    Add-Line "die App laedt http://localhost:$($script:Port), bekommt nichts und zeigt eine leere Flaeche."
}

Add-Line
if (Test-OmniRouteReachable) {
    Add-Line "HTTP-Test    : Der Server antwortet auf $($script:HealthUrl)"
} else {
    Add-Line "HTTP-Test    : KEINE ANTWORT auf $($script:HealthUrl)"
}

# ---------------------------------------------------------- Desktop-App ----

Add-Head 'Desktop-App'
$app = Find-OmniRouteDesktopApp
if ($app) {
    Add-Line "Gefunden     : $app"
    try {
        $fi = Get-Item $app
        Add-Line "Dateiversion : $($fi.VersionInfo.FileVersion)"
        Add-Line "Geaendert    : $($fi.LastWriteTime)"
    } catch { }
} else {
    Add-Line "Nicht gefunden (nur die CLI-Variante ist installiert - das ist in Ordnung)."
}
$procs = @(Get-Process -Name 'OmniRoute' -ErrorAction SilentlyContinue)
Add-Line "Laufende App-Prozesse: $($procs.Count)"

# ------------------------------------------------------------- Daten ----

Add-Head 'Datenverzeichnisse'
$pfade = @(
    (Join-Path $env:APPDATA 'omniroute'),
    (Join-Path $env:USERPROFILE '.omniroute'),
    (Join-Path $env:USERPROFILE '.omniroute\storage.sqlite')
)
foreach ($p in $pfade) {
    if (Test-Path $p) {
        $item = Get-Item $p
        if ($item.PSIsContainer) {
            $anzahl = @(Get-ChildItem $p -Recurse -ErrorAction SilentlyContinue).Count
            Add-Line "vorhanden    : $p ($anzahl Eintraege)"
        } else {
            Add-Line "vorhanden    : $p ($([math]::Round($item.Length / 1KB, 1)) KB)"
        }
    } else {
        Add-Line "fehlt        : $p"
    }
}

# ------------------------------------------------- Umgebungsvariablen ----

Add-Head 'Umgebungsvariablen (Benutzer)'
Add-Line "ANTHROPIC_BASE_URL  : $([Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL','User'))"
Add-Line "OPENAI_BASE_URL     : $([Environment]::GetEnvironmentVariable('OPENAI_BASE_URL','User'))"
Add-Line "ANTHROPIC_AUTH_TOKEN: $(Show-Secret ([Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN','User')))"
Add-Line "OPENAI_API_KEY      : $(Show-Secret ([Environment]::GetEnvironmentVariable('OPENAI_API_KEY','User')))"
Add-Line
Add-Line "(Schluessel werden absichtlich nicht ausgegeben, damit der Bericht"
Add-Line " gefahrlos weitergegeben werden kann.)"

$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'OmniRoute.lnk'
Add-Line
Add-Line "Autostart-Verknuepfung: $(if (Test-Path $lnk) { 'vorhanden' } else { 'nicht vorhanden' })"

# ------------------------------------------------------- Selbsttest ----

Add-Head 'omniroute doctor'
if ($omni) {
    $doc = Invoke-External -File $omni -Arguments @('doctor') -Quiet
    Add-Line "Exitcode: $($doc.ExitCode)"
    foreach ($l in ($doc.Output -split "`r?`n")) { Add-Line $l }
} else {
    Add-Line "uebersprungen - omniroute ist nicht installiert"
}

# ------------------------------------------------------- Letztes Log ----

Add-Head 'Letztes Setup-Protokoll'
if (Test-Path $script:LogDir) {
    $log = Get-ChildItem $script:LogDir -Filter 'setup-*.log' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($log) {
        Add-Line "Datei: $($log.FullName)"
        Add-Line "Letzte 60 Zeilen:"
        Add-Line
        foreach ($l in (Get-Content $log.FullName -Tail 60 -ErrorAction SilentlyContinue)) { Add-Line $l }
    } else {
        Add-Line "Kein Protokoll gefunden - das Setup lief auf diesem Rechner noch nicht durch."
    }
} else {
    Add-Line "Kein Protokollverzeichnis ($($script:LogDir)) - das Setup lief noch nicht."
}

# ------------------------------------------------------------- Schreiben ----

Add-Head 'Ende des Berichts'

try {
    $zeilen | Set-Content -Path $OutFile -Encoding UTF8
    Write-Host ""
    Write-Host "  Bericht geschrieben:" -ForegroundColor Green
    Write-Host "  $OutFile" -ForegroundColor White
    Write-Host ""
    Write-Host "  Diese Datei kannst du komplett weitergeben - Schluessel stehen nicht drin." -ForegroundColor Gray
    Write-Host ""
    if (-not $NoOpen) {
        try { Start-Process notepad.exe $OutFile | Out-Null } catch { }
    }
    exit 0
} catch {
    Write-Host ""
    Write-Host "  Der Bericht liess sich nicht speichern: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Hier die Ausgabe direkt:" -ForegroundColor Yellow
    Write-Host ""
    $zeilen | ForEach-Object { Write-Host $_ }
    exit 1
}
