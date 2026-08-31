<#
.SYNOPSIS
    Prueft omniroute-setup.ps1 auf Syntaxfehler und testet die reine Logik.

.DESCRIPTION
    Laeuft auf Windows PowerShell 5.1 und PowerShell 7 (auch unter Linux/macOS).
    Es wird nichts installiert und nichts am System veraendert - aus dem Setup
    werden nur die Funktionsdefinitionen geladen, der Hauptteil bleibt aussen vor.

.EXAMPLE
    pwsh -NoProfile -File .\tests\Run-Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'omniroute-setup.ps1'
if (-not (Test-Path $script:Path)) {
    Write-Host "omniroute-setup.ps1 nicht gefunden unter $($script:Path)" -ForegroundColor Red
    exit 1
}

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

# ------------------------------------------------------------ Syntaxpruefung ----

Write-Host "`nSyntaxpruefung" -ForegroundColor Cyan
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)

if ($errors -and $errors.Count -gt 0) {
    Write-Host "  FAIL  $($errors.Count) Parse-Fehler" -ForegroundColor Red
    foreach ($e in $errors) {
        Write-Host ("        Zeile {0}, Spalte {1}: {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message) -ForegroundColor Red
    }
    exit 1
}
Check -Name "keine Syntaxfehler" -Condition $true

$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$defined = $funcs | ForEach-Object { $_.Name }

# Alle aufgerufenen Kommandos muessen entweder im Skript definiert oder verfuegbar sein.
$unknown = @()
$calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique
foreach ($c in $calls) {
    if ($defined -contains $c) { continue }
    if (Get-Command $c -ErrorAction SilentlyContinue) { continue }
    $unknown += $c
}
Check -Name "alle aufgerufenen Kommandos aufloesbar" -Condition ($unknown.Count -eq 0) -Detail "($($unknown -join ', '))"

# Nur die Funktionen laden, den Hauptteil des Setups nicht ausfuehren.
. ([scriptblock]::Create((($funcs | ForEach-Object { $_.Extent.Text }) -join "`n")))
$script:Port = 20128

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
$vorhanden = if ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5) { 'cmd' } else { 'bash' }
Check -Name "findet vorhandenen Befehl ($vorhanden)" -Condition ($null -ne (Get-CommandPath $vorhanden))
Check -Name "liefert null bei unbekanntem Befehl" -Condition ($null -eq (Get-CommandPath 'gibtesnichtxyz123'))

# ----------------------------------------------------------- Invoke-External ----

Write-Host "`nInvoke-External" -ForegroundColor Cyan
if ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5) {
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

# ---------------------------------------------------------------- Add-Failure ----

Write-Host "`nAdd-Failure" -ForegroundColor Cyan
$script:Failures = @()
Add-Failure -Titel 'Claude Code' -Hinweis 'Hinweistext'
Add-Failure -Titel 'Codex CLI'   -Hinweis 'Anderer Text'
Check -Name "sammelt beide Eintraege" -Condition ($script:Failures.Count -eq 2) -Detail "(bekam $($script:Failures.Count))"
Check -Name "Titel bleibt erhalten" -Condition ($script:Failures[0].Titel -eq 'Claude Code')

# -------------------------------------------------------------------- Fazit ----

Write-Host ""
if ($script:Fails -eq 0) {
    Write-Host "Alle Tests bestanden." -ForegroundColor Green
    exit 0
}
Write-Host "$($script:Fails) Test(s) fehlgeschlagen." -ForegroundColor Red
exit 1
