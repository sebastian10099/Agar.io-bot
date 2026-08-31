#Requires -Version 5.1
<#
.SYNOPSIS
    Findet heraus, was den Festplattenplatz belegt - auch die unsichtbaren Posten.

.DESCRIPTION
    Wenn die Platte voll ist und man "nichts sieht", liegt es fast immer an
    Systemordnern, die der Explorer versteckt: die Ruhezustandsdatei, alte
    Windows-Versionen, Wiederherstellungspunkte, der Update-Zwischenspeicher.
    Die koennen zusammen zweistellige Gigabyte-Betraege ausmachen.

    Dieses Skript misst der Reihe nach:
      1. Freien Platz pro Laufwerk
      2. Die bekannten grossen Systemposten, mit Angabe was davon weg darf
      3. Was OmniRoute selbst belegt
      4. Die groessten Ordner im Benutzerprofil
      5. node_modules-Ordner aus Programmierprojekten
      6. Die groessten Einzeldateien

    Geloescht wird nur mit -Aufraeumen, und dann bei jedem Posten einzeln nach
    Rueckfrage. Alles, was Windows beschaedigen koennte, wird nur erklaert -
    nie automatisch angefasst.

.PARAMETER Aufraeumen
    Fragt fuer jeden gefahrlos loeschbaren Posten nach und loescht ihn auf Wunsch.

.PARAMETER Tiefe
    Wieviele Eintraege je Liste gezeigt werden. Standard 12.

.PARAMETER Schnell
    Ueberspringt die langsamen Teile (groesste Dateien, node_modules-Suche).

.EXAMPLE
    .\omniroute-speicher.ps1

.EXAMPLE
    .\omniroute-speicher.ps1 -Aufraeumen
#>
[CmdletBinding()]
param(
    [switch]$Aufraeumen,
    [int]$Tiefe = 12,
    [switch]$Schnell
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'omniroute-common.ps1')

$script:Loeschbar = @()

function Format-Groesse {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0,8:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0,8:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0,8:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0,8} B ' -f $Bytes)
}

function Get-OrdnerGroesse {
    <# Summiert alle Dateien darunter. Gesperrte Ordner werden uebersprungen. #>
    param([string]$Pfad)
    if ([string]::IsNullOrWhiteSpace($Pfad) -or -not (Test-Path -LiteralPath $Pfad)) { return $null }
    try {
        $summe = 0
        Get-ChildItem -LiteralPath $Pfad -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $summe += $_.Length }
        return $summe
    } catch { return $null }
}

function Get-DateiGroesse {
    param([string]$Pfad)
    if ([string]::IsNullOrWhiteSpace($Pfad)) { return $null }
    try {
        $f = Get-Item -LiteralPath $Pfad -Force -ErrorAction Stop
        return $f.Length
    } catch { return $null }
}

function Add-Loeschbar {
    param([string]$Name, [string]$Pfad, [long]$Bytes, [string]$Wie)
    $script:Loeschbar += [pscustomobject]@{ Name = $Name; Pfad = $Pfad; Bytes = $Bytes; Wie = $Wie }
}

function Show-Zeile {
    param([long]$Bytes, [string]$Text, [string]$Unterzeile = '', [string]$Farbe = '')
    if (-not $Farbe) {
        $Farbe = if ($Bytes -ge 5GB) { 'Red' } elseif ($Bytes -ge 1GB) { 'Yellow' } elseif ($Bytes -ge 200MB) { 'White' } else { 'Gray' }
    }
    Write-Host ("    {0}   {1}" -f (Format-Groesse $Bytes), $Text) -ForegroundColor $Farbe
    if ($Unterzeile) { Write-Host ("    {0,-11}   {1}" -f '', $Unterzeile) -ForegroundColor DarkGray }
}

# ------------------------------------------------------------- Laufwerke ----

Write-Host ""
Write-Host "  Speicheranalyse" -ForegroundColor White
Write-Host "  =================================================" -ForegroundColor DarkGray

Write-Step "1/6 - Laufwerke"
$vollesLaufwerk = $false
try {
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction Stop)) {
        if ($null -eq $d.Used -or ($d.Used + $d.Free) -le 0) { continue }
        $gesamt = $d.Used + $d.Free
        $prozent = [math]::Round(($d.Free / $gesamt) * 100, 1)
        $farbe = if ($prozent -lt 10) { 'Red' } elseif ($prozent -lt 20) { 'Yellow' } else { 'Green' }
        if ($prozent -lt 15) { $vollesLaufwerk = $true }
        Write-Host ("    {0}:   frei {1}   von {2}   ({3} %)" -f `
            $d.Name, (Format-Groesse $d.Free), (Format-Groesse $gesamt), $prozent) -ForegroundColor $farbe
    }
} catch {
    Write-Warn2 "Laufwerksinformationen nicht lesbar: $($_.Exception.Message)"
}

# ------------------------------------------------- Die unsichtbaren Posten ----

Write-Step "2/6 - Die grossen Systemposten (hier liegt meistens die Antwort)"
Write-Info "Diese Ordner versteckt der Explorer - deshalb 'sieht' man sie nicht."
Write-Host ""

$sys = $env:SystemDrive
if (-not $sys) { $sys = 'C:' }

# --- Ruhezustandsdatei: so gross wie der Arbeitsspeicher
$hiber = Get-DateiGroesse (Join-Path "$sys\" 'hiberfil.sys')
if ($hiber) {
    Show-Zeile $hiber 'hiberfil.sys - Ruhezustand' `
        'Abschaltbar: Eingabeaufforderung als Administrator, dann  powercfg /h off'
}

# --- Auslagerungsdatei
$page = Get-DateiGroesse (Join-Path "$sys\" 'pagefile.sys')
if ($page) {
    Show-Zeile $page 'pagefile.sys - Auslagerungsdatei' `
        'Braucht Windows. Nur verkleinern, wenn du weisst was du tust.'
}
$swap = Get-DateiGroesse (Join-Path "$sys\" 'swapfile.sys')
if ($swap) { Show-Zeile $swap 'swapfile.sys' 'Braucht Windows.' }

# --- Alte Windows-Version nach einem grossen Update
$winold = Join-Path "$sys\" 'Windows.old'
$winoldGr = Get-OrdnerGroesse $winold
if ($winoldGr) {
    Show-Zeile $winoldGr 'Windows.old - deine vorherige Windows-Version' `
        'Oft 10-30 GB. Entfernen ueber: Einstellungen > System > Speicher > Bereinigungsempfehlungen'
}

# --- Update-Zwischenspeicher
$updates = Join-Path "$sys\" 'Windows\SoftwareDistribution\Download'
$updGr = Get-OrdnerGroesse $updates
if ($updGr) {
    Show-Zeile $updGr 'Windows-Update-Zwischenspeicher' `
        'Darf weg. Windows laedt bei Bedarf neu.'
    if ($updGr -gt 500MB) { Add-Loeschbar 'Windows-Update-Zwischenspeicher' $updates $updGr 'ordnerinhalt' }
}

# --- Komponentenspeicher
$winsxs = Join-Path "$sys\" 'Windows\WinSxS'
$sxsGr = Get-OrdnerGroesse $winsxs
if ($sxsGr) {
    Show-Zeile $sxsGr 'WinSxS - Komponentenspeicher' `
        'NIE von Hand loeschen. Verkleinern mit:  Dism /Online /Cleanup-Image /StartComponentCleanup'
}

# --- Absturzabbilder
$dump = Get-DateiGroesse (Join-Path "$sys\" 'Windows\MEMORY.DMP')
if ($dump) {
    Show-Zeile $dump 'MEMORY.DMP - Absturzabbild' 'Darf weg, wenn du keinen Absturz untersuchst.'
    Add-Loeschbar 'MEMORY.DMP' (Join-Path "$sys\" 'Windows\MEMORY.DMP') $dump 'datei'
}
$minidump = Get-OrdnerGroesse (Join-Path "$sys\" 'Windows\Minidump')
if ($minidump -and $minidump -gt 50MB) {
    Show-Zeile $minidump 'Minidump - kleine Absturzabbilder' 'Darf weg.'
}

# --- Papierkorb
$papier = Get-OrdnerGroesse (Join-Path "$sys\" '$Recycle.Bin')
if ($papier) {
    Show-Zeile $papier 'Papierkorb' 'Darf weg - aber vorher reinschauen.'
    if ($papier -gt 200MB) { Add-Loeschbar 'Papierkorb' 'Papierkorb' $papier 'papierkorb' }
}

# --- Temp
$tempGr = Get-OrdnerGroesse $env:TEMP
if ($tempGr) {
    Show-Zeile $tempGr 'Temp-Ordner (Benutzer)' 'Darf weg. Was in Benutzung ist, bleibt liegen.'
    if ($tempGr -gt 300MB) { Add-Loeschbar 'Temp-Ordner' $env:TEMP $tempGr 'ordnerinhalt' }
}
$winTemp = Join-Path "$sys\" 'Windows\Temp'
$winTempGr = Get-OrdnerGroesse $winTemp
if ($winTempGr -and $winTempGr -gt 100MB) {
    Show-Zeile $winTempGr 'Temp-Ordner (Windows)' 'Darf weg.'
    Add-Loeschbar 'Temp-Ordner (Windows)' $winTemp $winTempGr 'ordnerinhalt'
}

# --- Wiederherstellungspunkte
Write-Host ""
$vss = Get-CommandPath 'vssadmin.exe'
if ($vss) {
    $r = Invoke-External -File $vss -Arguments @('list', 'shadowstorage') -Quiet
    if ($r.Output -match '(?i)verwendet|used') {
        Write-Info "Wiederherstellungspunkte (Schattenkopien):"
        foreach ($l in ($r.Output -split "`r?`n")) {
            if ($l -match '(?i)(verwendet|used|zugeordnet|allocated|maximum)') { Write-Host "      $($l.Trim())" -ForegroundColor Gray }
        }
        Write-Host "      Verkleinern: Systemsteuerung > System > Computerschutz > Konfigurieren" -ForegroundColor DarkGray
    } else {
        Write-Info "Wiederherstellungspunkte: Angabe braucht Administratorrechte."
        Write-Host "      Nachschauen: Systemsteuerung > System > Computerschutz" -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------------- OmniRoute ----

Write-Step "3/6 - Was OmniRoute belegt"

$npmPrefix = $null
$npm = Get-NpmPath
if ($npm) {
    $p = Invoke-External -File $npm -Arguments @('prefix', '-g') -Quiet
    if ($p.ExitCode -eq 0 -and $p.Output) { $npmPrefix = $p.Output.Trim() }
}

$orSumme = 0
if ($npmPrefix) {
    $g = Get-OrdnerGroesse (Join-Path $npmPrefix 'node_modules\omniroute')
    if ($g) { Show-Zeile $g 'omniroute (npm global)' 'Das Paket selbst - rund 22000 Dateien.'; $orSumme += $g }
}
$npmCache = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'npm-cache' } else { $null }
$cacheGr = Get-OrdnerGroesse $npmCache
if ($cacheGr) {
    Show-Zeile $cacheGr 'npm-Zwischenspeicher' 'Darf weg. npm baut ihn neu auf.'
    $orSumme += $cacheGr
    if ($cacheGr -gt 200MB) { Add-Loeschbar 'npm-Zwischenspeicher' $npmCache $cacheGr 'npm' }
}
foreach ($paar in @(
    @{ P = (Join-Path $env:APPDATA 'omniroute');      T = 'OmniRoute-Daten (APPDATA)'; H = 'Deine Einstellungen. NICHT loeschen.' },
    @{ P = (Join-Path $env:USERPROFILE '.omniroute'); T = 'OmniRoute-Daten (Profil)';  H = 'Provider und Schluessel. NICHT loeschen.' }
)) {
    $g = Get-OrdnerGroesse $paar.P
    if ($g) { Show-Zeile $g $paar.T $paar.H; $orSumme += $g }
}
$app = Find-OmniRouteDesktopApp
if ($app) {
    $g = Get-OrdnerGroesse (Split-Path $app -Parent)
    if ($g) { Show-Zeile $g 'OmniRoute Desktop-App' 'Optional - der Browser kann dasselbe.'; $orSumme += $g }
}
$logGr = Get-OrdnerGroesse $script:LogDir
if ($logGr -and $logGr -gt 1MB) {
    Show-Zeile $logGr 'Protokolle dieses Setups' 'Darf weg.'
    Add-Loeschbar 'Protokolle dieses Setups' $script:LogDir $logGr 'ordner'
    $orSumme += $logGr
}
$nodePfad = Get-CommandPath 'node'
if ($nodePfad) {
    $g = Get-OrdnerGroesse (Split-Path $nodePfad -Parent)
    if ($g) { Show-Zeile $g 'Node.js' 'Braucht OmniRoute.'; $orSumme += $g }
}

Write-Host ""
Show-Zeile $orSumme 'Zusammen fuer OmniRoute und Node.js' '' 'White'

# --------------------------------------------------- Groesste Profilordner ----

Write-Step "4/6 - Groesste Ordner in deinem Benutzerprofil"
Write-Info "Einen Moment..."
Write-Host ""

$gross = @()
foreach ($ordner in (Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue)) {
    $b = Get-OrdnerGroesse $ordner.FullName
    if ($b) { $gross += [pscustomobject]@{ Name = $ordner.Name; Bytes = $b } }
}
foreach ($g in ($gross | Sort-Object Bytes -Descending | Select-Object -First $Tiefe)) {
    Show-Zeile $g.Bytes $g.Name
}

# ----------------------------------------------------------- node_modules ----

if (-not $Schnell) {
    Write-Step "5/6 - node_modules aus Programmierprojekten"
    Write-Info "Die sammeln sich unbemerkt an. Suche laeuft..."

    $nm = @()
    try {
        Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Recurse -Force -Filter 'node_modules' -ErrorAction SilentlyContinue |
            Select-Object -First 60 |
            ForEach-Object {
                # Verschachtelte node_modules nicht doppelt zaehlen
                if ($_.FullName -notmatch 'node_modules.+node_modules') {
                    $b = Get-OrdnerGroesse $_.FullName
                    if ($b) { $nm += [pscustomobject]@{ Pfad = $_.FullName; Bytes = $b } }
                }
            }
    } catch { }

    Write-Host ""
    if ($nm.Count -eq 0) {
        Write-Info "Keine gefunden."
    } else {
        foreach ($n in ($nm | Sort-Object Bytes -Descending | Select-Object -First $Tiefe)) {
            Show-Zeile $n.Bytes $n.Pfad
        }
        $nmSumme = ($nm | Measure-Object -Property Bytes -Sum).Sum
        Write-Host ""
        Show-Zeile ([long]$nmSumme) "Zusammen in $($nm.Count) node_modules-Ordnern" `
            'Jeder laesst sich mit npm install wiederherstellen.' 'White'
    }
} else {
    Write-Step "5/6 - node_modules"
    Write-Info "Uebersprungen (-Schnell)."
}

# -------------------------------------------------------- Groesste Dateien ----

if (-not $Schnell) {
    Write-Step "6/6 - Groesste Einzeldateien im Benutzerprofil"
    Write-Info "Einen Moment..."
    Write-Host ""

    try {
        Get-ChildItem -LiteralPath $env:USERPROFILE -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 200MB } |
            Sort-Object Length -Descending |
            Select-Object -First $Tiefe |
            ForEach-Object { Show-Zeile $_.Length $_.FullName }
    } catch { }
} else {
    Write-Step "6/6 - Groesste Dateien"
    Write-Info "Uebersprungen (-Schnell)."
}

# ------------------------------------------------------------ Zusammenfassung ----

Write-Host ""
Write-Host "  =================================================" -ForegroundColor DarkGray
Write-Host "  Was du gefahrlos loeschen kannst" -ForegroundColor White
Write-Host ""

if ($script:Loeschbar.Count -eq 0) {
    Write-Ok "Nichts Auffaelliges gefunden."
    Write-Info "Dann steckt der Platz in den Posten oben, die Windows braucht."
} else {
    foreach ($l in ($script:Loeschbar | Sort-Object Bytes -Descending)) {
        Show-Zeile $l.Bytes $l.Name '' 'Yellow'
    }
    $frei = ($script:Loeschbar | Measure-Object -Property Bytes -Sum).Sum
    Write-Host ""
    Show-Zeile ([long]$frei) 'Zu holen' '' 'Green'
}

Write-Host ""
Write-Host "  Nicht von Hand anfassen:" -ForegroundColor Yellow
Write-Host "    WinSxS, pagefile.sys, APPDATA\omniroute, .omniroute"
Write-Host ""
Write-Host "  Die groessten Brocken loest Windows selbst am besten:" -ForegroundColor Gray
Write-Host "    Einstellungen > System > Speicher > Bereinigungsempfehlungen"
Write-Host "    Dort stecken Windows.old, alte Updates und der Papierkorb drin."
Write-Host ""

if ($vollesLaufwerk -and $script:Loeschbar.Count -eq 0) {
    Write-Warn2 "Ein Laufwerk ist fast voll, aber hier ist nichts Loeschbares."
    Write-Info "Dann lohnt der Blick in die Windows-Speicheruebersicht - siehe oben."
}

# ---------------------------------------------------------------- Aufraeumen ----

if ($Aufraeumen -and $script:Loeschbar.Count -gt 0) {
    Write-Step "Aufraeumen"
    Write-Info "Jeder Posten wird einzeln abgefragt. Enter oder n ueberspringt."

    foreach ($l in ($script:Loeschbar | Sort-Object Bytes -Descending)) {
        Write-Host ""
        Write-Host ("    {0}  {1}" -f (Format-Groesse $l.Bytes), $l.Name) -ForegroundColor White
        if ($l.Pfad -ne $l.Name) { Write-Host "    $($l.Pfad)" -ForegroundColor DarkGray }

        $antwort = (Read-Host "    Loeschen? (j/n)").Trim()
        if ($antwort -notmatch '^[jJyY]') { Write-Info "Uebersprungen."; continue }

        switch ($l.Wie) {
            'npm' {
                $r = Invoke-External -File (Get-NpmPath) -Arguments @('cache', 'clean', '--force') -Quiet
                if ($r.ExitCode -eq 0) { Write-Ok "Geleert." } else { Write-Warn2 "npm meldete Exitcode $($r.ExitCode)." }
            }
            'papierkorb' {
                try {
                    Clear-RecycleBin -Force -ErrorAction Stop
                    Write-Ok "Papierkorb geleert."
                } catch {
                    Write-Warn2 "Nicht moeglich: $($_.Exception.Message)"
                    Write-Info "Von Hand: Rechtsklick auf den Papierkorb > Papierkorb leeren."
                }
            }
            'datei' {
                try { Remove-Item -LiteralPath $l.Pfad -Force -ErrorAction Stop; Write-Ok "Geloescht." }
                catch { Write-Warn2 "Nicht loeschbar: $($_.Exception.Message)"; Write-Info "Braucht meist Administratorrechte." }
            }
            'ordner' {
                try { Remove-Item -LiteralPath $l.Pfad -Recurse -Force -ErrorAction Stop; Write-Ok "Geloescht." }
                catch { Write-Warn2 "Nicht vollstaendig loeschbar: $($_.Exception.Message)" }
            }
            'ordnerinhalt' {
                $vorher = Get-OrdnerGroesse $l.Pfad
                Get-ChildItem -LiteralPath $l.Pfad -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                $nachher = Get-OrdnerGroesse $l.Pfad
                $geholt = [long]($vorher - $nachher)
                Write-Ok ("Freigeraeumt: {0}" -f (Format-Groesse $geholt))
                if ($nachher -gt 0) { Write-Info "Der Rest ist gerade in Benutzung. Das ist normal." }
            }
        }
    }
    Write-Host ""
}
elseif ($script:Loeschbar.Count -gt 0) {
    Write-Host "  Zum Loeschen dieses Skript mit -Aufraeumen starten." -ForegroundColor Gray
    Write-Host ""
}

exit 0
