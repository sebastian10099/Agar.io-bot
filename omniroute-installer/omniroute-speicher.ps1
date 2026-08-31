#Requires -Version 5.1
<#
.SYNOPSIS
    Zeigt, wieviel Platz OmniRoute und sein Umfeld belegen - und was sich
    gefahrlos loeschen laesst.

.DESCRIPTION
    OmniRoute ist gross: das globale npm-Paket entpackt sich zu ueber 400 MB in
    rund 22000 Dateien, weil eine komplette Web-Anwendung darin steckt. Dazu
    kommen Node.js, der npm-Zwischenspeicher und - falls installiert - die
    Electron-Desktop-App.

    Dieses Skript misst nach, listet die groessten Ordner im Benutzerprofil und
    sagt, was weg kann, ohne dass etwas kaputtgeht.

.PARAMETER Aufraeumen
    Fragt fuer jeden gefahrlos loeschbaren Posten einzeln nach und loescht ihn
    auf Wunsch. Ohne diesen Schalter wird nur gemessen, nichts veraendert.

.PARAMETER Tiefe
    Wieviele der groessten Ordner im Benutzerprofil gezeigt werden. Standard 12.

.EXAMPLE
    .\omniroute-speicher.ps1

.EXAMPLE
    .\omniroute-speicher.ps1 -Aufraeumen
#>
[CmdletBinding()]
param(
    [switch]$Aufraeumen,
    [int]$Tiefe = 12
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'omniroute-common.ps1')

function Format-Groesse {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0,7:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0,7:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0,7:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0,7} B ' -f $Bytes)
}

function Get-OrdnerGroesse {
    <# Summiert alle Dateien darunter. Nicht lesbare Ordner werden uebersprungen. #>
    param([string]$Pfad)
    if (-not $Pfad -or -not (Test-Path $Pfad)) { return $null }
    try {
        $summe = 0
        Get-ChildItem -LiteralPath $Pfad -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $summe += $_.Length }
        return $summe
    } catch {
        return $null
    }
}

function Show-Posten {
    param([string]$Name, [string]$Pfad, [string]$Hinweis = '')
    $groesse = Get-OrdnerGroesse $Pfad
    if ($null -eq $groesse) {
        Write-Host ("    {0,-28} {1,10}   {2}" -f $Name, 'nicht da', $Pfad) -ForegroundColor DarkGray
        return $null
    }
    $farbe = if ($groesse -ge 1GB) { 'Yellow' } elseif ($groesse -ge 200MB) { 'White' } else { 'Gray' }
    Write-Host ("    {0,-28} {1}   {2}" -f $Name, (Format-Groesse $groesse), $Pfad) -ForegroundColor $farbe
    if ($Hinweis) { Write-Host ("    {0,-28} {1}" -f '', $Hinweis) -ForegroundColor DarkGray }
    return [pscustomobject]@{ Name = $Name; Pfad = $Pfad; Bytes = $groesse }
}

# ------------------------------------------------------------- Laufwerke ----

Write-Host ""
Write-Host "  OmniRoute Speicherbericht" -ForegroundColor White
Write-Host "  -------------------------------------------------" -ForegroundColor DarkGray

Write-Step "Laufwerke"
try {
    Get-PSDrive -PSProvider FileSystem -ErrorAction Stop |
        Where-Object { $_.Used -ne $null -and ($_.Used + $_.Free) -gt 0 } |
        ForEach-Object {
            $gesamt = $_.Used + $_.Free
            $prozent = [math]::Round(($_.Free / $gesamt) * 100, 1)
            $farbe = if ($prozent -lt 10) { 'Red' } elseif ($prozent -lt 20) { 'Yellow' } else { 'Green' }
            Write-Host ("    {0}:  frei {1}  von {2}   ({3} %)" -f `
                $_.Name, (Format-Groesse $_.Free), (Format-Groesse $gesamt), $prozent) -ForegroundColor $farbe
        }
} catch {
    Write-Warn2 "Laufwerksinformationen nicht lesbar: $($_.Exception.Message)"
}

# ---------------------------------------------------- OmniRoute-Umgebung ----

Write-Step "Was OmniRoute belegt"

$npmPrefix = $null
$npm = Get-NpmPath
if ($npm) {
    $p = Invoke-External -File $npm -Arguments @('prefix', '-g') -Quiet
    if ($p.ExitCode -eq 0 -and $p.Output) { $npmPrefix = $p.Output.Trim() }
}

$posten = @()

if ($npmPrefix) {
    $posten += Show-Posten 'omniroute (npm global)' (Join-Path $npmPrefix 'node_modules\omniroute') `
        'Das Paket selbst. Wird beim Deinstallieren frei.'
    $posten += Show-Posten 'alle globalen npm-Pakete' (Join-Path $npmPrefix 'node_modules')
}

$npmCache = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'npm-cache' } else { $null }
$cachePosten = Show-Posten 'npm-Zwischenspeicher' $npmCache 'Kann geloescht werden - npm baut ihn neu auf.'
if ($cachePosten) { $posten += $cachePosten }

$posten += Show-Posten 'OmniRoute-Daten (APPDATA)' (Join-Path $env:APPDATA 'omniroute') `
    'Enthaelt deine Einstellungen. NICHT loeschen.'
$posten += Show-Posten 'OmniRoute-Daten (Profil)' (Join-Path $env:USERPROFILE '.omniroute') `
    'Enthaelt Provider und Schluessel. NICHT loeschen.'

$app = Find-OmniRouteDesktopApp
if ($app) {
    $posten += Show-Posten 'Desktop-App' (Split-Path $app -Parent) `
        'Optional. Das Dashboard im Browser kann dasselbe.'
}

$logPosten = Show-Posten 'Protokolle dieses Setups' $script:LogDir 'Kann weg.'
if ($logPosten) { $posten += $logPosten }

$nodePfad = Get-CommandPath 'node'
if ($nodePfad) {
    $posten += Show-Posten 'Node.js' (Split-Path $nodePfad -Parent) 'Wird von OmniRoute gebraucht.'
}

$summe = ($posten | Where-Object { $_ } | Measure-Object -Property Bytes -Sum).Sum
Write-Host ""
Write-Host ("    Zusammen: {0}" -f (Format-Groesse ([long]$summe))) -ForegroundColor White

# ------------------------------------------------- Groesste Ordner ----

Write-Step "Die groessten Ordner in deinem Benutzerprofil"
Write-Info "Das dauert einen Moment..."

$gross = @()
try {
    foreach ($ordner in (Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue)) {
        $b = Get-OrdnerGroesse $ordner.FullName
        if ($b) { $gross += [pscustomobject]@{ Name = $ordner.Name; Bytes = $b } }
    }
} catch { }

Write-Host ""
foreach ($g in ($gross | Sort-Object Bytes -Descending | Select-Object -First $Tiefe)) {
    $farbe = if ($g.Bytes -ge 5GB) { 'Yellow' } else { 'Gray' }
    Write-Host ("    {0}   {1}" -f (Format-Groesse $g.Bytes), $g.Name) -ForegroundColor $farbe
}

# ------------------------------------------------------------ Empfehlungen ----

Write-Step "Was du gefahrlos loeschen kannst"

$loeschbar = @()
if ($cachePosten -and $cachePosten.Bytes -gt 100MB) {
    $loeschbar += [pscustomobject]@{
        Name  = 'npm-Zwischenspeicher'
        Pfad  = $cachePosten.Pfad
        Bytes = $cachePosten.Bytes
        Wie   = 'npm'
    }
}
if ($logPosten -and $logPosten.Bytes -gt 1MB) {
    $loeschbar += [pscustomobject]@{
        Name  = 'Protokolle dieses Setups'
        Pfad  = $logPosten.Pfad
        Bytes = $logPosten.Bytes
        Wie   = 'ordner'
    }
}

$tempPfad = $env:TEMP
$tempGr = Get-OrdnerGroesse $tempPfad
if ($tempGr -and $tempGr -gt 500MB) {
    $loeschbar += [pscustomobject]@{
        Name  = 'Temp-Ordner'
        Pfad  = $tempPfad
        Bytes = $tempGr
        Wie   = 'temp'
    }
}

if ($loeschbar.Count -eq 0) {
    Write-Ok "Nichts Auffaelliges. Der Platz geht woanders drauf."
} else {
    foreach ($l in $loeschbar) {
        Write-Host ("    {0}   {1}" -f (Format-Groesse $l.Bytes), $l.Name) -ForegroundColor Yellow
    }
    $frei = ($loeschbar | Measure-Object -Property Bytes -Sum).Sum
    Write-Host ""
    Write-Host ("    Zu holen: rund {0}" -f (Format-Groesse ([long]$frei))) -ForegroundColor Green
}

Write-Host ""
Write-Host "  Nicht anfassen:" -ForegroundColor Yellow
Write-Host "    - APPDATA\omniroute und .omniroute - da stecken deine Provider drin"
Write-Host "    - node_modules - OmniRoute laeuft sonst nicht mehr"
Write-Host ""
Write-Host "  Wenn OmniRoute ganz weg soll:" -ForegroundColor Gray
Write-Host "    Im Menue Punkt 1 abbrechen und stattdessen OmniRoute-Entfernen.bat"
Write-Host "    mit 'j' ausfuehren - das gibt die $(Format-Groesse 431MB) des Pakets wieder frei."
Write-Host ""
Write-Host "  Grosse Brocken ausserhalb von OmniRoute findet die Windows-eigene"
Write-Host "  Datenspeicher-Uebersicht: Einstellungen > System > Speicher." -ForegroundColor Gray

# ---------------------------------------------------------------- Aufraeumen ----

if ($Aufraeumen -and $loeschbar.Count -gt 0) {
    Write-Step "Aufraeumen"
    foreach ($l in $loeschbar) {
        Write-Host ""
        Write-Host ("    {0} ({1})" -f $l.Name, (Format-Groesse $l.Bytes)) -ForegroundColor White
        Write-Host ("    $($l.Pfad)") -ForegroundColor DarkGray
        $antwort = (Read-Host "    Loeschen? (j/n)").Trim()
        if ($antwort -notmatch '^[jJyY]') {
            Write-Info "Uebersprungen."
            continue
        }

        switch ($l.Wie) {
            'npm' {
                $r = Invoke-External -File (Get-NpmPath) -Arguments @('cache', 'clean', '--force') -Quiet
                if ($r.ExitCode -eq 0) { Write-Ok "npm-Zwischenspeicher geleert." }
                else { Write-Warn2 "npm meldete Exitcode $($r.ExitCode)." }
            }
            'ordner' {
                try { Remove-Item $l.Pfad -Recurse -Force -ErrorAction Stop; Write-Ok "Geloescht." }
                catch { Write-Warn2 "Nicht vollstaendig loeschbar: $($_.Exception.Message)" }
            }
            'temp' {
                # Was gerade benutzt wird, laesst sich nicht loeschen - das ist normal.
                $vorher = Get-OrdnerGroesse $l.Pfad
                Get-ChildItem -LiteralPath $l.Pfad -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                $nachher = Get-OrdnerGroesse $l.Pfad
                Write-Ok ("Freigeraeumt: {0}" -f (Format-Groesse ([long]($vorher - $nachher))))
                Write-Info "Dateien, die gerade in Benutzung sind, bleiben liegen. Das ist normal."
            }
        }
    }
}
elseif ($loeschbar.Count -gt 0) {
    Write-Host ""
    Write-Host "  Zum Aufraeumen dieses Skript mit -Aufraeumen starten," -ForegroundColor Gray
    Write-Host "  oder im Menue den Punkt Speicher erneut waehlen und j druecken." -ForegroundColor Gray
    Write-Host ""
}

exit 0
