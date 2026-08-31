<#
.SYNOPSIS
    Gemeinsame Funktionen fuer die OmniRoute-Skripte in diesem Ordner.

.DESCRIPTION
    Wird von omniroute-setup.ps1, omniroute-desktop.ps1 und omniroute-diagnose.ps1
    per Dot-Sourcing eingebunden. Enthaelt nur Definitionen, fuehrt nichts aus.
#>

# ------------------------------------------------------------- Konstanten ----

$script:Port         = 20128
$script:BaseUrl      = "http://localhost:$($script:Port)/v1"
$script:HealthUrl    = "http://127.0.0.1:$($script:Port)/"
$script:DashboardUrl = "http://localhost:$($script:Port)/dashboard"
# LOCALAPPDATA fehlt ausserhalb von Windows - dann ins Temp-Verzeichnis ausweichen,
# damit sich diese Datei auch zum Testen einbinden laesst.
$script:LogDir = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'OmniRouteInstaller\logs'
} else {
    Join-Path ([IO.Path]::GetTempPath()) 'OmniRouteInstaller-logs'
}

# ---------------------------------------------------------------- Ausgabe ----

function Write-Step  { param($m) Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Info  { param($m) Write-Host "    $m" -ForegroundColor Gray }
function Write-Warn2 { param($m) Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Write-Err2  { param($m) Write-Host "    [x]  $m" -ForegroundColor Red }

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

function Get-OmniRoutePath {
    $omni = Get-CommandPath 'omniroute.cmd'
    if (-not $omni) { $omni = Get-CommandPath 'omniroute' }
    return $omni
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

# ---------------------------------------------------------------- Server ----

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

function Get-PortListener {
    # Liefert die PIDs, die auf dem OmniRoute-Port lauschen. Leeres Array = niemand.
    $pids = @()
    try {
        $conns = Get-NetTCPConnection -LocalPort $script:Port -State Listen -ErrorAction Stop
        $pids = @($conns | ForEach-Object { $_.OwningProcess } | Sort-Object -Unique)
    } catch {
        # Get-NetTCPConnection fehlt auf aelteren Systemen - dann netstat auswerten.
        $netstat = Get-CommandPath 'netstat.exe'
        if ($netstat) {
            $r = Invoke-External -File $netstat -Arguments @('-ano') -Quiet
            foreach ($line in ($r.Output -split "`r?`n")) {
                if ($line -match ":$($script:Port)\s" -and $line -match 'LISTENING\s+(\d+)\s*$') {
                    $pids += [int]$Matches[1]
                }
            }
            $pids = @($pids | Sort-Object -Unique)
        }
    }
    return $pids
}

function Wait-OmniRoute {
    # Wartet, bis der Server antwortet. Liefert $true bei Erfolg.
    param([int]$TimeoutSeconds = 120, [switch]$Quiet)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-OmniRouteReachable) { return $true }
        Start-Sleep -Seconds 2
    }
    if (-not $Quiet) {
        Write-Warn2 "Der Server hat nach $TimeoutSeconds Sekunden nicht geantwortet."
    }
    return $false
}

function Start-OmniRouteServer {
    <#
        Startet den CLI-Server, falls er nicht schon laeuft, und wartet auf ihn.
        Liefert $true, wenn am Ende jemand auf dem Port antwortet.
    #>
    param([string]$Omni, [int]$TimeoutSeconds = 120)

    if (Test-OmniRouteReachable) {
        Write-Ok "OmniRoute laeuft bereits auf Port $($script:Port)."
        return $true
    }

    if (-not $Omni) { $Omni = Get-OmniRoutePath }
    if (-not $Omni) {
        Write-Err2 "omniroute wurde nicht gefunden. Bitte zuerst OmniRoute-Setup.bat ausfuehren."
        return $false
    }

    Write-Info "Starte den Server..."
    Start-Process -FilePath $Omni -WindowStyle Minimized | Out-Null
    Write-Info "Warte darauf, dass Port $($script:Port) antwortet (bis zu $TimeoutSeconds s)..."

    if (Wait-OmniRoute -TimeoutSeconds $TimeoutSeconds) {
        Write-Ok "Server ist erreichbar."
        return $true
    }
    return $false
}

# ------------------------------------------------------------ Desktop-App ----

function Find-OmniRouteDesktopApp {
    <#
        Sucht die installierte Desktop-Anwendung an den ueblichen Orten.
        electron-builder installiert je nach Variante pro Benutzer oder systemweit.
    #>
    # Join-Path wirft, wenn die Basis leer ist - und ProgramFiles(x86) fehlt auf
    # 32-Bit- und ARM-Systemen. Darum jede Basis vorher pruefen.
    $kandidaten = @(
        @{ Basis = $env:LOCALAPPDATA;          Rest = 'Programs\omniroute\OmniRoute.exe' },
        @{ Basis = $env:LOCALAPPDATA;          Rest = 'Programs\OmniRoute\OmniRoute.exe' },
        @{ Basis = $env:ProgramFiles;          Rest = 'OmniRoute\OmniRoute.exe'          },
        @{ Basis = ${env:ProgramFiles(x86)};   Rest = 'OmniRoute\OmniRoute.exe'          }
    )

    foreach ($k in $kandidaten) {
        if ([string]::IsNullOrWhiteSpace($k.Basis)) { continue }
        $pfad = Join-Path $k.Basis $k.Rest
        if (Test-Path $pfad) { return $pfad }
    }

    # Verknuepfungen im Startmenue auswerten
    $startmenues = @($env:APPDATA, $env:ProgramData) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Join-Path $_ 'Microsoft\Windows\Start Menu\Programs' } |
        Where-Object { Test-Path $_ }

    foreach ($sm in $startmenues) {
        $lnks = Get-ChildItem -Path $sm -Filter 'OmniRoute*.lnk' -Recurse -ErrorAction SilentlyContinue
        foreach ($lnk in $lnks) {
            try {
                $shell = New-Object -ComObject WScript.Shell
                $target = $shell.CreateShortcut($lnk.FullName).TargetPath
                [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
                if ($target -and (Test-Path $target) -and $target -like '*.exe') { return $target }
            } catch { }
        }
    }

    return $null
}
