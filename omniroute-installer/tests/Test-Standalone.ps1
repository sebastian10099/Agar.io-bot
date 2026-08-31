<#
.SYNOPSIS
    Prueft die gebaute Alles-in-einem-Datei OmniRoute.bat.

.DESCRIPTION
    Stellt nach, was die Batch-Datei auf einem Windows-Rechner tut: die
    :::-Zeilen einsammeln, aus Base64 dekodieren, das ZIP entpacken und
    schauen, ob alle Skripte da und syntaktisch fehlerfrei sind.

    Zusaetzlich wird die eingebettete PowerShell-Zeile selbst geparst -
    ein Tippfehler darin wuerde sonst erst auf dem Zielrechner auffallen.

.EXAMPLE
    pwsh -NoProfile -File .\tests\Test-Standalone.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$bat  = Join-Path $root 'OmniRoute.bat'

$script:Fails = 0
function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:Fails++ }
}

Write-Host "`nOmniRoute.bat" -ForegroundColor Cyan
if (-not (Test-Path $bat)) {
    Write-Host "  FAIL  Datei fehlt - zuerst tools/Build-Standalone.ps1 ausfuehren" -ForegroundColor Red
    exit 1
}
Check -Name "Datei vorhanden" -Condition $true

$zeilen = Get-Content -LiteralPath $bat -Encoding ASCII

# ------------------------------------------------- Eingebettete PS-Zeile ----

Write-Host "`nEingebettete PowerShell-Zeile" -ForegroundColor Cyan
$psZeile = $zeilen | Where-Object { $_ -like 'powershell -NoProfile*' } | Select-Object -First 1
Check -Name "gefunden" -Condition ($null -ne $psZeile)

if ($psZeile) {
    # Den Teil zwischen den aeusseren Anfuehrungszeichen herausloesen
    $a = $psZeile.IndexOf('"')
    $b = $psZeile.LastIndexOf('"')
    $code = $psZeile.Substring($a + 1, $b - $a - 1)

    # Regression: $ErrorActionPreference wurde beim Bauen einmal ausgewertet
    # statt eingebettet - heraus kam "Stop='Stop'", also ungueltiger Code.
    Check -Name "ErrorActionPreference korrekt eingebettet" `
          -Condition ($code -match [regex]::Escape('$ErrorActionPreference=')) `
          -Detail "(Anfang: $($code.Substring(0, [Math]::Min(40, $code.Length))))"

    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$errors)
    Check -Name "ist gueltiges PowerShell" -Condition (-not $errors -or $errors.Count -eq 0) `
          -Detail "($(($errors | ForEach-Object { $_.Message }) -join '; '))"

    Check -Name "enthaelt keine unmaskierten Prozentzeichen ausser %~f0" `
          -Condition (($code -replace [regex]::Escape('%~f0'), '') -notmatch '%') `
          -Detail "(Batch wuerde die als Variablen deuten)"
}

# ---------------------------------------------------------- Nutzlast ----

Write-Host "`nEingebettetes Archiv" -ForegroundColor Cyan
$b64 = ($zeilen | Where-Object { $_.StartsWith(':::') } | ForEach-Object { $_.Substring(3) }) -join ''
Check -Name "Base64-Zeilen vorhanden" -Condition ($b64.Length -gt 0)

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ortest-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    $zip = Join-Path $tmp 'payload.zip'
    [IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($b64))
    Check -Name "Base64 dekodiert sauber" -Condition $true

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ziel = Join-Path $tmp 'out'
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $ziel)
    Check -Name "Archiv entpackt sich" -Condition $true

    $erwartet = @(
        'omniroute-common.ps1',
        'omniroute-menu.ps1',
        'omniroute-setup.ps1',
        'omniroute-desktop.ps1',
        'omniroute-diagnose.ps1'
    )

    Write-Host "`nEnthaltene Skripte" -ForegroundColor Cyan
    foreach ($d in $erwartet) {
        $p = Join-Path $ziel $d
        if (-not (Test-Path $p)) {
            Check -Name "$d enthalten" -Condition $false
            continue
        }
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errors)
        Check -Name "$d enthalten und fehlerfrei" -Condition (-not $errors -or $errors.Count -eq 0) `
              -Detail "($($errors.Count) Parse-Fehler)"
    }

    # Der Einstiegspunkt muss die anderen neben sich finden koennen.
    Write-Host "`nInhaltliche Pruefung" -ForegroundColor Cyan
    $menu = Get-Content (Join-Path $ziel 'omniroute-menu.ps1') -Raw
    Check -Name "Menue bindet omniroute-common.ps1 ein" -Condition ($menu -match 'omniroute-common\.ps1')
    foreach ($d in @('omniroute-setup.ps1', 'omniroute-desktop.ps1', 'omniroute-diagnose.ps1')) {
        Check -Name "Menue ruft $d auf" -Condition ($menu -match [regex]::Escape($d))
    }

    # Die entpackten Dateien muessen zu den Quelldateien passen.
    Write-Host "`nAktualitaet" -ForegroundColor Cyan
    foreach ($d in $erwartet) {
        $a = (Get-FileHash (Join-Path $ziel $d) -Algorithm SHA256).Hash
        $b = (Get-FileHash (Join-Path $root $d) -Algorithm SHA256).Hash
        Check -Name "$d entspricht der Quelldatei" -Condition ($a -eq $b) `
              -Detail "(Build-Standalone.ps1 erneut ausfuehren)"
    }
}
finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($script:Fails -eq 0) {
    Write-Host "Alle Tests bestanden." -ForegroundColor Green
    exit 0
}
Write-Host "$($script:Fails) Test(s) fehlgeschlagen." -ForegroundColor Red
exit 1
