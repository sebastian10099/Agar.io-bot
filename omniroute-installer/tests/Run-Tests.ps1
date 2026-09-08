<#
.SYNOPSIS
    Prueft die Skripte im Ordner auf Syntaxfehler und testet die reine Logik.

.DESCRIPTION
    Laeuft auf Windows PowerShell 5.1 und PowerShell 7 (auch unter Linux/macOS).
    Es wird nichts installiert und nichts am System veraendert - aus den Skripten
    werden nur die Funktionsdefinitionen geladen, der Hauptteil bleibt aussen vor.

.EXAMPLE
    pwsh -NoProfile -File .\tests\Run-Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:Root = Split-Path $PSScriptRoot -Parent
$script:Skripte = @(
    'omniroute-common.ps1',
    'omniroute-menu.ps1',
    'omniroute-setup.ps1',
    'omniroute-desktop.ps1',
    'omniroute-diagnose.ps1',
    'omniroute-test.ps1',
    'omniroute-speicher.ps1',
    'omniroute-anbieter.ps1'
)

$script:Fails = 0
function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red
        $script:Fails++
    }
}

function Get-Ast {
    param([string]$Pfad)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Pfad, [ref]$tokens, [ref]$errors)
    return [pscustomobject]@{ Ast = $ast; Errors = $errors }
}

# ------------------------------------------------------------ Syntaxpruefung ----

Write-Host "`nSyntaxpruefung" -ForegroundColor Cyan
$alleAsts = @{}
foreach ($name in $script:Skripte) {
    $pfad = Join-Path $script:Root $name
    if (-not (Test-Path $pfad)) {
        Check -Name "$name vorhanden" -Condition $false
        continue
    }
    $res = Get-Ast $pfad
    if ($res.Errors -and $res.Errors.Count -gt 0) {
        Check -Name "$name ohne Syntaxfehler" -Condition $false -Detail "($($res.Errors.Count) Fehler)"
        foreach ($e in $res.Errors) {
            Write-Host ("        Zeile {0}, Spalte {1}: {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message) -ForegroundColor Red
        }
        continue
    }
    Check -Name "$name ohne Syntaxfehler" -Condition $true
    $alleAsts[$name] = $res.Ast
}

if ($script:Fails -gt 0) {
    Write-Host "`nSyntaxfehler - weitere Tests werden uebersprungen." -ForegroundColor Red
    exit 1
}

# Funktionen aus allen Skripten einsammeln
$definiert = @()
foreach ($ast in $alleAsts.Values) {
    $definiert += $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name }
}
$definiert = $definiert | Sort-Object -Unique

# Jedes aufgerufene Kommando muss definiert oder verfuegbar sein.
# Windows-eigene Cmdlets fehlen unter Linux/macOS. Die Skripte fangen das
# jeweils ab (try/catch mit Ersatzweg), also sind sie hier erlaubt.
$nurWindows = @('Get-NetTCPConnection', 'Get-CimInstance', 'Clear-RecycleBin')

Write-Host "`nAufloesbarkeit der Aufrufe" -ForegroundColor Cyan
foreach ($name in $alleAsts.Keys) {
    $unbekannt = @()
    $calls = $alleAsts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique
    foreach ($c in $calls) {
        if ($definiert -contains $c) { continue }
        if ($nurWindows -contains $c) { continue }
        if (Get-Command $c -ErrorAction SilentlyContinue) { continue }
        $unbekannt += $c
    }
    Check -Name "$name - alle Aufrufe aufloesbar" -Condition ($unbekannt.Count -eq 0) -Detail "($($unbekannt -join ', '))"
}

# omniroute-common.ps1 ganz einbinden: die Datei enthaelt nur Definitionen und
# Konstanten, kein Hauptprogramm. So wird geprueft, was die Skripte wirklich laden.
. (Join-Path $script:Root 'omniroute-common.ps1')

# ------------------------------------------------------- Test-NodeSupported ----

Write-Host "`nTest-NodeSupported (engines: >=22.22.2 <23 || >=24 <27)" -ForegroundColor Cyan
$cases = @(
    @{ v = $null;     erwartet = $false },
    @{ v = '18.20.0'; erwartet = $false },
    @{ v = '20.11.0'; erwartet = $false },
    @{ v = '22.22.1'; erwartet = $false },
    @{ v = '22.22.2'; erwartet = $true  },
    @{ v = '22.30.5'; erwartet = $true  },
    @{ v = '23.5.0';  erwartet = $false },
    @{ v = '24.0.0';  erwartet = $true  },
    @{ v = '26.99.0'; erwartet = $true  },
    @{ v = '27.0.0';  erwartet = $false }
)
foreach ($c in $cases) {
    $ver = if ($c.v) { [version]$c.v } else { $null }
    $label = if ($c.v) { $c.v } else { 'nicht da' }
    $got = Test-NodeSupported $ver
    Check -Name ("node {0,-8} -> {1}" -f $label, $c.erwartet) -Condition ($got -eq $c.erwartet) -Detail "(bekam $got)"
}

# ------------------------------------------------------- New-RandomPassword ----

Write-Host "`nNew-RandomPassword" -ForegroundColor Cyan
$p1 = New-RandomPassword
$p2 = New-RandomPassword
Check -Name "Standardlaenge 20" -Condition ($p1.Length -eq 20) -Detail "(bekam $($p1.Length))"
Check -Name "zwei Aufrufe unterscheiden sich" -Condition ($p1 -ne $p2)
Check -Name "nur erlaubte Zeichen" -Condition ($p1 -notmatch '[^a-zA-Z0-9!@#%^*_\-]')
Check -Name "Laenge parametrierbar" -Condition ((New-RandomPassword -Length 40).Length -eq 40)

# ---------------------------------------------------------- Get-CommandPath ----

Write-Host "`nGet-CommandPath" -ForegroundColor Cyan
$istWindows = $IsWindows -or $PSVersionTable.PSVersion.Major -le 5
$vorhanden = if ($istWindows) { 'cmd' } else { 'bash' }
Check -Name "findet vorhandenen Befehl ($vorhanden)" -Condition ($null -ne (Get-CommandPath $vorhanden))
Check -Name "liefert null bei unbekanntem Befehl" -Condition ($null -eq (Get-CommandPath 'gibtesnichtxyz123'))

# ----------------------------------------------------------- Invoke-External ----

Write-Host "`nInvoke-External" -ForegroundColor Cyan
if ($istWindows) {
    $shell = 'cmd.exe'
    $argsFehler = @('/c', 'echo hallo& echo problem 1>&2& exit /b 3')
    $argsOk     = @('/c', 'exit /b 0')
} else {
    $shell = 'bash'
    $argsFehler = @('-c', 'echo hallo; echo problem >&2; exit 3')
    $argsOk     = @('-c', 'exit 0')
}

# Regression: npm und winget schreiben auf stderr. Unter ErrorActionPreference
# 'Stop' darf das keine Ausnahme ausloesen, sonst geht der Exitcode verloren.
$threw = $false
$r = $null
try { $r = Invoke-External -File $shell -Arguments $argsFehler -Quiet }
catch { $threw = $true; Write-Host "        Ausnahme: $($_.Exception.Message)" -ForegroundColor DarkRed }

Check -Name "wirft nicht, obwohl stderr beschrieben wird" -Condition (-not $threw)
if (-not $threw) {
    Check -Name "Exitcode wird durchgereicht" -Condition ($r.ExitCode -eq 3) -Detail "(bekam $($r.ExitCode))"
    Check -Name "stdout ist enthalten" -Condition ($r.Output -match 'hallo')
    Check -Name "stderr ist enthalten" -Condition ($r.Output -match 'problem')
}
Check -Name "Exitcode 0 bei Erfolg" -Condition ((Invoke-External -File $shell -Arguments $argsOk -Quiet).ExitCode -eq 0)
Check -Name "ErrorActionPreference des Aufrufers bleibt Stop" -Condition ($ErrorActionPreference -eq 'Stop') -Detail "(ist $ErrorActionPreference)"

# ------------------------------------------------- Find-OmniRouteDesktopApp ----

# Regression: Join-Path wirft bei leerer Basis. ProgramFiles(x86) fehlt auf
# 32-Bit- und ARM-Systemen, alle Basen fehlen ausserhalb von Windows.
Write-Host "`nFind-OmniRouteDesktopApp" -ForegroundColor Cyan
$threw = $false
$app = $null
try { $app = Find-OmniRouteDesktopApp }
catch { $threw = $true; Write-Host "        Ausnahme: $($_.Exception.Message)" -ForegroundColor DarkRed }
Check -Name "wirft nicht bei fehlenden Umgebungsvariablen" -Condition (-not $threw)
if (-not $threw -and -not $istWindows) {
    Check -Name "liefert null, wenn nichts installiert ist" -Condition ($null -eq $app) -Detail "(bekam $app)"
}

# --------------------------------------------------------- Get-PortListener ----

Write-Host "`nGet-PortListener" -ForegroundColor Cyan
$threw = $false
$pids = $null
try { $pids = Get-PortListener }
catch { $threw = $true; Write-Host "        Ausnahme: $($_.Exception.Message)" -ForegroundColor DarkRed }
Check -Name "wirft nicht, auch ohne Get-NetTCPConnection" -Condition (-not $threw)
Check -Name "liefert eine Sammlung" -Condition ($pids -is [array] -or $null -eq $pids)

# ----------------------------------------------------------- Test-Reachable ----

Write-Host "`nTest-OmniRouteReachable" -ForegroundColor Cyan
$threw = $false
$erreichbar = $null
try { $erreichbar = Test-OmniRouteReachable }
catch { $threw = $true; Write-Host "        Ausnahme: $($_.Exception.Message)" -ForegroundColor DarkRed }
Check -Name "wirft nicht, wenn nichts lauscht" -Condition (-not $threw)
Check -Name "liefert einen Wahrheitswert" -Condition ($erreichbar -is [bool])

# ------------------------------------------------------------------ LogDir ----

Write-Host "`nKonstanten" -ForegroundColor Cyan
Check -Name "Port ist 20128" -Condition ($script:Port -eq 20128)
Check -Name "LogDir ist gesetzt" -Condition (-not [string]::IsNullOrWhiteSpace($script:LogDir)) -Detail "($($script:LogDir))"

# -------------------------------------------------------------------- Fazit ----

Write-Host ""
if ($script:Fails -eq 0) {
    Write-Host "Alle Tests bestanden." -ForegroundColor Green
    exit 0
}
Write-Host "$($script:Fails) Test(s) fehlgeschlagen." -ForegroundColor Red
exit 1
