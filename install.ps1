# Mesh Router Installer (Windows/PowerShell)
# Usage: irm https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@stable/install.ps1 | iex
# Or:    .\install.ps1 -Provider "https://nsl.sh/router/api,userid,sig" -Domain "alice.nsl.sh"
#
# Installs track the 'stable' channel by default. Pass -Channel main to use the
# development branch. (Windows installs are one-shot — no nightly auto-update —
# so the channel only affects what this run fetches.)

param(
    [Parameter(Mandatory=$true)]
    [string]$Provider,

    [Parameter(Mandatory=$true)]
    [string]$Domain,

    [string]$Email,
    [string]$PublicIp,
    [string]$DataRoot = "/c/DATA",
    [string]$Channel = "stable"
)

$ErrorActionPreference = "Stop"
$RepoBase = "https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@$Channel"
$InstallDir = "$DataRoot/AppData/mesh"

Write-Host "=== Yundera Mesh Router Installer (Windows) ===" -ForegroundColor Cyan
Write-Host ""

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
$envPath = (($InstallDir -replace '^/c/', 'C:\') -replace '/', '\') + '\.env'
$DefaultPassword = ""
if (Test-Path $envPath) {
    # DEFAULT_PASSWORD is the pre-rename name. Windows installs run no
    # self-check and no template sync, so scripts/migrations/ never reaches
    # them — this fallback is the only thing that carries the secret across the
    # rename. Without it the first re-run mints a new one and every installed
    # app's DB password and admin token stop matching.
    $existing = Select-String -Path $envPath -Pattern '^DEFAULT_PWD=(.*)$' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $existing) {
        $existing = Select-String -Path $envPath -Pattern '^DEFAULT_PASSWORD=(.*)$' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($existing) { $DefaultPassword = $existing.Matches[0].Groups[1].Value }
}
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

# 7. Write .env
Write-Host "[..] Writing .env..."
$envContent = @"
PROVIDER_STR=$Provider
DOMAIN=$Domain
PUBLIC_IP=$PublicIp
PUBLIC_IP_DASH=$PublicIpDash
DATA_ROOT=$DataRoot
DEFAULT_PWD=$DefaultPassword
EMAIL=$Email
DEFAULT_SERVICE_HOST=maison
DEFAULT_SERVICE_PORT=80
PUID=0
PGID=0
UPDATE_URL=https://github.com/yundera/mesh-router-template-root/archive/refs/heads/$Channel.tar.gz
MESH_TEMPLATE_URL=https://github.com/yundera/mesh-router-template-root/archive/refs/heads/$Channel.tar.gz
"@
Set-Content -Path "$composePath\.env" -Value $envContent -NoNewline
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
Write-Host "To update, re-run this command." -ForegroundColor Gray
