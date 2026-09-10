# Mesh Router Installer (Windows/PowerShell)
#
# Usage (first install):
#   .\install.ps1 -Provider "https://nsl.sh/router/api,userid,sig" -Domain "alice.nsl.sh"
#
# Usage (update an existing box):
#   irm https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@stable/install.ps1 | iex
#   .\install.ps1
#
# Re-running with NO parameters is the manual update path — the mirror of
# `install.sh` with no arguments on Linux. Windows installs are one-shot (no
# self-check, no nightly auto-update), so re-running this script is the ONLY way
# a Windows box ever gets a newer template. Everything it needs is already in the
# .env on disk: provider, domain, data root and update source are read back,
# summarised, and applied after one confirmation.
#
# Installs track the 'stable' channel by default. Pass -Channel main to use the
# development branch; omit it on a re-run to stay on whatever channel the box was
# installed from.

param(
    [string]$Provider,
    [string]$Domain,
    [string]$Email,
    [string]$PublicIp,
    [string]$DataRoot,
    [string]$Channel,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

# Only PARAMETERS ACTUALLY PASSED may override what the box already recorded, so
# the defaults live here rather than in param(). Without that distinction a
# no-parameter update could not tell "-Channel stable" from "no -Channel at all"
# and would drag a -Channel main box back to stable — and then persist the
# downgrade, since the resolved URL is written to .env below.
$ProviderArg = $Provider
$DomainArg   = $Domain

function Convert-ToWinPath([string]$p) {
    return (($p -replace '^/c/', 'C:\') -replace '/', '\')
}

# Read an existing .env into an ordered map. Re-runs MERGE into this map rather
# than rewriting the file from a template, so keys this installer does not manage
# survive — and so does DEFAULT_PWD, the app-seed secret every installed app's
# database password and admin token is derived from.
function Read-EnvFile([string]$path) {
    $map = [ordered]@{}
    if (Test-Path $path -PathType Leaf) {
        foreach ($line in (Get-Content $path)) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                $map[$Matches[1]] = $Matches[2]
            }
        }
    }
    return $map
}

# The .env lives under the data root, but the data root itself can come FROM the
# .env — so probe the default location first, then let the file correct it.
$probeRoot = if ($DataRoot) { $DataRoot } else { "/c/DATA" }
$envPath = (Convert-ToWinPath "$probeRoot/AppData/mesh") + '\.env'
$ExistingEnv = Read-EnvFile $envPath
$ConfigFound = ($ExistingEnv.Count -gt 0)

function Get-Existing([string]$key) {
    if ($ExistingEnv.Contains($key)) { return $ExistingEnv[$key] }
    return ""
}

# Apply the ladder: explicit parameter > value already in .env > default.
if (-not $Provider) { $Provider = Get-Existing 'PROVIDER_STR' }
if (-not $Domain)   { $Domain   = Get-Existing 'DOMAIN' }
if (-not $DataRoot) { $DataRoot = Get-Existing 'DATA_ROOT' }
if (-not $DataRoot) { $DataRoot = "/c/DATA" }
if (-not $Email)    { $Email    = Get-Existing 'EMAIL' }
if (-not $PublicIp) { $PublicIp = Get-Existing 'PUBLIC_IP' }

Write-Host "=== Yundera Mesh Router Installer (Windows) ===" -ForegroundColor Cyan
Write-Host ""

if (-not $Provider -or -not $Domain) {
    if ($ConfigFound) {
        Write-Host "Error: $envPath exists but has no PROVIDER_STR/DOMAIN." -ForegroundColor Red
        Write-Host "       An update reads the identity back from that file; pass the" -ForegroundColor Red
        Write-Host "       missing value(s) explicitly this once." -ForegroundColor Red
    } else {
        Write-Host "Error: no existing installation found at $envPath." -ForegroundColor Red
        Write-Host "       A first install needs -Provider and -Domain. Only a re-run over" -ForegroundColor Red
        Write-Host "       an existing install can read them back from disk." -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  First install:  .\install.ps1 -Provider `"<backend_url,userid,signature>`" -Domain `"<your.domain>`"" -ForegroundColor Yellow
    Write-Host "  Update:         .\install.ps1" -ForegroundColor Yellow
    exit 1
}

# Resolve the template source.
#   -Channel (only when passed) > UPDATE_URL already in .env > the default channel
# $RepoBase is the jsDelivr base this run downloads from; $UpdateUrl is what gets
# recorded in .env. They are normally two views of the same branch, and are only
# allowed to diverge when .env holds a URL that names no branch at all.
$UpdateUrl = ""
if ($Channel) {
    $UpdateUrl = "https://github.com/yundera/mesh-router-template-root/archive/refs/heads/$Channel.tar.gz"
} else {
    $recorded = Get-Existing 'UPDATE_URL'
    if (-not $recorded) { $recorded = Get-Existing 'MESH_TEMPLATE_URL' }
    if ($recorded) {
        $UpdateUrl = $recorded
        if ($recorded -match 'heads/(.+)\.tar\.gz$') {
            $Channel = $Matches[1]
        } else {
            # A fork, tag or mirror tarball. There is no jsDelivr base to derive
            # from it, so this run downloads from stable but LEAVES the recorded
            # URL alone rather than silently repointing the box.
            $Channel = "stable"
            Write-Host "[!!] UPDATE_URL in .env names no branch ($recorded)." -ForegroundColor Yellow
            Write-Host "     Downloading from the stable channel; the recorded URL is kept." -ForegroundColor Yellow
        }
    } else {
        $Channel = "stable"
        $UpdateUrl = "https://github.com/yundera/mesh-router-template-root/archive/refs/heads/stable.tar.gz"
    }
}

$RepoBase = "https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@$Channel"
$InstallDir = "$DataRoot/AppData/mesh"

# Confirm an update that was asked for with no parameters. Deliberately not a
# "reuse this / start fresh" choice: starting fresh would discard DEFAULT_PWD and
# break every installed app's credentials. Change identity with -Provider/-Domain.
if ($ConfigFound -and -not $ProviderArg -and -not $DomainArg) {
    $sig = ""
    $parts = $Provider -split ','
    if ($parts.Count -ge 3 -and $parts[2].Length -gt 0) {
        $head = $parts[2].Substring(0, [Math]::Min(4, $parts[2].Length))
        $sig = "$($parts[0]),$($parts[1]),$head...(hidden)"
    } else {
        $sig = $Provider
    }
    Write-Host "Found an existing installation at $InstallDir"
    Write-Host ""
    Write-Host "  Domain:       $Domain"
    Write-Host "  Provider:     $sig"
    if ($Email) { Write-Host "  Email:        $Email" }
    Write-Host "  Data root:    $DataRoot"
    Write-Host "  Update from:  $UpdateUrl"
    Write-Host ""
    if (-not $Yes -and [Environment]::UserInteractive) {
        $reply = Read-Host "Update this installation? [Y/n]"
        if ($reply -and $reply -notmatch '^(y|Y|yes|YES|Yes)$') {
            Write-Host ""
            Write-Host "Aborted. Nothing was changed."
            Write-Host "  To change the domain or provider, re-run with -Domain / -Provider."
            exit 0
        }
    }
    Write-Host "[..] Updating existing installation..." -ForegroundColor Cyan
    Write-Host ""
}

# 1. Check Docker
try {
    docker compose version | Out-Null
    Write-Host "[OK] Docker is installed" -ForegroundColor Green
} catch {
    Write-Host "[!!] Docker not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "     Docker Desktop is required for Windows. NSL Router and CasaOS" -ForegroundColor Red
    Write-Host "     heavily rely on containers to work." -ForegroundColor Red
    Write-Host ""
    Write-Host "     Install Docker Desktop: https://www.docker.com/products/docker-desktop/" -ForegroundColor Yellow
    Write-Host "     After installing, restart this script." -ForegroundColor Red
    exit 1
}

# 2. Auto-detect public IP if not provided
if (-not $PublicIp) {
    Write-Host "[..] Detecting public IP..."
    try {
        $PublicIp = (Invoke-RestMethod -Uri "https://ifconfig.me/ip" -UserAgent "curl" -TimeoutSec 5).Trim()
        Write-Host "[OK] Public IP: $PublicIp" -ForegroundColor Green
    } catch {
        $PublicIp = ""
        Write-Host "[!!] Could not detect public IP (direct routing via agent will be disabled)" -ForegroundColor Yellow
    }
} else {
    Write-Host "[OK] Public IP: $PublicIp" -ForegroundColor Green
}

# 3. Compute derived values
$PublicIpDash = $PublicIp -replace '[.:]', '-'
# Prefer the account email passed from the dashboard; fall back to a synthetic
# admin@<domain> address when the installer is run standalone without -Email.
if (-not $Email) { $Email = "admin@$Domain" }

# Seed a platform secret consumed by app-store apps via $APP_DEFAULT_PASSWORD /
# $PCS_DEFAULT_PASSWORD. Preserve across reruns.
#
# -DataRoot may have moved the install since the probe at the top, so re-read
# from the final location before deciding whether a secret already exists.
$finalEnvPath = (Convert-ToWinPath $InstallDir) + '\.env'
if ($finalEnvPath -ne $envPath) {
    $ExistingEnv = Read-EnvFile $finalEnvPath
    $envPath = $finalEnvPath
}

# DEFAULT_PASSWORD is the pre-rename name. Windows installs run no self-check and
# no template sync, so scripts/migrations/ never reaches them — this fallback is
# the only thing that carries the secret across the rename. Without it the first
# re-run mints a new one and every installed app's DB password and admin token
# stop matching.
$DefaultPassword = Get-Existing 'DEFAULT_PWD'
if (-not $DefaultPassword) { $DefaultPassword = Get-Existing 'DEFAULT_PASSWORD' }
if (-not $DefaultPassword) {
    $DefaultPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
}

# 4. Create directories (via WSL since paths are Linux-style)
Write-Host "[..] Creating directories..."
$dirs = @(
    $InstallDir,
    "$DataRoot/AppData/yundera/data/certs",
    "$DataRoot/AppData/yundera/data/caddy/data",
    "$DataRoot/AppData/yundera/data/caddy/config"
)
# Convert Linux paths to Windows paths for mkdir
foreach ($dir in $dirs) {
    $winPath = $dir -replace '^/c/', 'C:\'
    $winPath = $winPath -replace '/', '\'
    if (-not (Test-Path $winPath)) {
        New-Item -ItemType Directory -Path $winPath -Force | Out-Null
    }
}
Write-Host "[OK] Install dir: $InstallDir" -ForegroundColor Green

# 5. Download docker-compose.yml + base Caddyfile
Write-Host "[..] Downloading docker-compose.yml..."
$composePath = ($InstallDir -replace '^/c/', 'C:\') -replace '/', '\'
Invoke-RestMethod -Uri "$RepoBase/docker-compose.yml" -OutFile "$composePath\docker-compose.yml"
Write-Host "[OK] docker-compose.yml downloaded" -ForegroundColor Green

# The compose file bind-mounts ${DATA_ROOT}/AppData/mesh/Caddyfile into
# mesh-router-caddy. It must exist as a FILE before `docker compose up`, or
# Docker Desktop creates a directory there and Caddy fails to start.
Write-Host "[..] Downloading base Caddyfile..."
$meshRoot = (("$DataRoot/AppData/mesh") -replace '^/c/', 'C:\') -replace '/', '\'
if (-not (Test-Path $meshRoot)) {
    New-Item -ItemType Directory -Path $meshRoot -Force | Out-Null
}
if (Test-Path "$meshRoot\Caddyfile" -PathType Container) {
    Remove-Item "$meshRoot\Caddyfile" -Recurse -Force
}
Invoke-RestMethod -Uri "$RepoBase/Caddyfile" -OutFile "$meshRoot\Caddyfile"
Write-Host "[OK] Caddyfile downloaded" -ForegroundColor Green

# 6. Patch docker-compose.yml for Windows
Write-Host "[..] Patching docker-compose for Windows..."
$composeContent = Get-Content "$composePath\docker-compose.yml" -Raw
# Remove rshared propagation (not supported on Docker Desktop)
$composeContent = $composeContent -replace '(?ms)\s+bind:\s+propagation: rshared', ''
Set-Content -Path "$composePath\docker-compose.yml" -Value $composeContent -NoNewline
Write-Host "[OK] Windows patches applied" -ForegroundColor Green

# 7. Write .env (preserving existing keys on re-run)
Write-Host "[..] Writing .env (preserving existing keys on re-run)..."
# Upsert into what was read from disk, so anything this installer does not manage
# — keys added by hand, or by a later template — survives the update.
$envMap = $ExistingEnv
$envMap['PROVIDER_STR']         = $Provider
$envMap['DOMAIN']               = $Domain
$envMap['PUBLIC_IP']            = $PublicIp
$envMap['PUBLIC_IP_DASH']       = $PublicIpDash
$envMap['DATA_ROOT']            = $DataRoot
$envMap['DEFAULT_PWD']          = $DefaultPassword
$envMap['EMAIL']                = $Email
$envMap['DEFAULT_SERVICE_HOST'] = 'maison'
$envMap['DEFAULT_SERVICE_PORT'] = '80'
$envMap['PUID']                 = '0'
$envMap['PGID']                 = '0'
# There is no self-check on Windows, so nothing here ever syncs the template on a
# schedule. Recording both keys keeps a Windows box honest if it is ever inspected
# by — or handed to — the Linux tooling: MESH_WINDOWS_MODE is what makes
# `install.sh` with no arguments keep taking the Windows path.
$envMap['MESH_AUTO_UPDATE']     = 'false'
$envMap['MESH_WINDOWS_MODE']    = 'true'
$envMap['UPDATE_URL']           = $UpdateUrl
# Deprecated alias, kept in step with UPDATE_URL for one release.
$envMap['MESH_TEMPLATE_URL']    = $UpdateUrl

# LF, not CRLF: this file is read by bash inside the containers, where a trailing
# \r ends up inside the value.
$envLines = foreach ($k in $envMap.Keys) { "$k=$($envMap[$k])" }
Set-Content -Path "$composePath\.env" -Value ($envLines -join "`n") -NoNewline
Write-Host "[OK] .env written" -ForegroundColor Green

# 8. Start containers
Write-Host "[..] Starting containers..."
Push-Location $composePath
docker compose up -d
Pop-Location

Write-Host ""
Write-Host "=== Installation complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Domain:    https://$Domain" -ForegroundColor White
Write-Host "  Install:   $InstallDir" -ForegroundColor White
Write-Host ""
Write-Host "Open https://$Domain in your browser and sign in as 'admin'." -ForegroundColor Gray
Write-Host ""
Write-Host "To update later, re-run this installer with NO parameters — it reads this" -ForegroundColor Gray
Write-Host "box's configuration back from ${envPath}" -ForegroundColor Gray
Write-Host "  .\install.ps1" -ForegroundColor Gray
