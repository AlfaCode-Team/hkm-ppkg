<#
.SYNOPSIS
    Install ppkg for the current user on Windows. No administrator rights.

.DESCRIPTION
    irm https://raw.githubusercontent.com/AlfaCode-Team/hkm-ppkg/main/install.ps1 | iex

    .\install.ps1                                   # the latest release
    .\install.ps1 -Version v0.2.0                   # a specific release
    .\install.ps1 -Archive .\ppkg-windows-x86_64.zip
    $env:PPKG_INSTALL_DIR = 'D:\tools\ppkg'; .\install.ps1

    Installs ppkg.exe into %LOCALAPPDATA%\Programs\ppkg (or PPKG_INSTALL_DIR)
    and adds that directory to your USER Path. Re-running it upgrades in place.

    Every download is checked against the release's SHA256SUMS before anything
    is installed; a mismatch installs nothing.
#>
[CmdletBinding()]
param(
    [string]$Version = $env:PPKG_VERSION,
    [string]$Archive = '',
    [string]$InstallDir = $(if ($env:PPKG_INSTALL_DIR) { $env:PPKG_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\ppkg' }),
    [string]$Repo = $(if ($env:PPKG_REPO) { $env:PPKG_REPO } else { 'AlfaCode-Team/hkm-ppkg' })
)

# Errors THROW rather than `exit`: under `irm | iex` this script runs inside the
# user's own session, and `exit` would close their terminal window.
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 redraws its download progress bar so often that it
# slows Invoke-WebRequest by an order of magnitude.
$ProgressPreference = 'SilentlyContinue'
# 5.1 does not offer TLS 1.2 by default, and github.com accepts nothing older.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Say([string]$m) { Write-Host "> $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "OK $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "! $m" -ForegroundColor Yellow }

# A 32-bit PowerShell on 64-bit Windows reports x86 in PROCESSOR_ARCHITECTURE;
# the machine's real architecture is in PROCESSOR_ARCHITEW6432.
$cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$arch = switch ($cpu) {
    'AMD64' { 'x86_64' }
    'ARM64' { 'aarch64' }
    default { throw "no ppkg build for $cpu - build from source: zig build -Doptimize=ReleaseSafe" }
}
$asset = "ppkg-windows-$arch.zip"

# A bare "0.2.0" is what people type; the tag is "v0.2.0".
if ($Version -and -not $Version.StartsWith('v')) { $Version = "v$Version" }

function Test-Checksum([string]$File, [string]$Name, [string]$Sums) {
    $pattern = '^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($Name) + '$'
    $line = Get-Content -LiteralPath $Sums | Where-Object { $_ -match $pattern } | Select-Object -First 1
    if (-not $line) { throw "$Name is not listed in SHA256SUMS" }
    $want = ($line -split '\s+')[0].ToLowerInvariant()
    $have = (Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash.ToLowerInvariant()
    if ($have -ne $want) { throw "checksum mismatch for $Name - expected $want, got $have. Nothing was installed." }
    Ok 'checksum verified'
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ppkg-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $zip = Join-Path $tmp $asset

    if ($Archive) {
        if (-not (Test-Path -LiteralPath $Archive)) { throw "no such file: $Archive" }
        Say "installing from $Archive"
        Copy-Item -LiteralPath $Archive -Destination $zip
        $sums = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Archive)) 'SHA256SUMS'
        if (Test-Path -LiteralPath $sums) {
            Test-Checksum $zip (Split-Path -Leaf $Archive) $sums
        } else {
            Warn "no SHA256SUMS beside $Archive - the archive is NOT verified"
        }
    } else {
        $base = if ($Version) { "https://github.com/$Repo/releases/download/$Version" } else { "https://github.com/$Repo/releases/latest/download" }
        Say "downloading $asset ($(if ($Version) { $Version } else { 'latest' }))"
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $zip
        Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile (Join-Path $tmp 'SHA256SUMS')
        Test-Checksum $zip $asset (Join-Path $tmp 'SHA256SUMS')
    }

    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x') -Force
    $exe = Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Recurse -Filter 'ppkg.exe' | Select-Object -First 1
    if (-not $exe) { throw "$asset holds no ppkg.exe" }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $target = Join-Path $InstallDir 'ppkg.exe'
    # Staged beside the target and moved over it, so an interrupted install
    # never leaves a half-written ppkg.exe behind.
    Copy-Item -LiteralPath $exe.FullName -Destination "$target.new" -Force
    try {
        Move-Item -LiteralPath "$target.new" -Destination $target -Force
    } catch {
        Remove-Item -LiteralPath "$target.new" -Force -ErrorAction SilentlyContinue
        throw "could not replace $target - is ppkg running? Close it and run the installer again."
    }

    $reported = & $target --version
    Ok "installed $reported -> $target"

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (($userPath -split ';') -contains $InstallDir)) {
        $newPath = if ($userPath) { "$userPath;$InstallDir" } else { $InstallDir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Ok "added $InstallDir to your user Path - new terminals will find ppkg"
    }
    # And this session, so `ppkg` works without opening a new window.
    if (-not (($env:Path -split ';') -contains $InstallDir)) { $env:Path = "$env:Path;$InstallDir" }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
