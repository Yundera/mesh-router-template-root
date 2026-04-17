# Mesh Router Installer (Windows/PowerShell)
# Usage: irm https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@main/install.ps1 | iex
# Or:    .\install.ps1 -Provider "https://nsl.sh/router/api,userid,sig" -Domain "alice.nsl.sh"

param(
    [Parameter(Mandatory=$true)]
    [string]$Provider,

    [Parameter(Mandatory=$true)]
    [string]$Domain,

    [string]$PublicIp,
    [string]$DataRoot = "/c/DATA"
)

$ErrorActionPreference = "Stop"
$RepoBase = "https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@main"
$InstallDir = "$DataRoot/AppData/casaos/apps/mesh"

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
$Email = "admin@$Domain"

# Seed a platform secret consumed by app-store apps via $APP_DEFAULT_PASSWORD /
# $PCS_DEFAULT_PASSWORD. Preserve across reruns.
$envPath = (($InstallDir -replace '^/c/', 'C:\') -replace '/', '\') + '\.env'
$DefaultPassword = ""
if (Test-Path $envPath) {
    $existing = Select-String -Path $envPath -Pattern '^DEFAULT_PASSWORD=(.*)$' -ErrorAction SilentlyContinue | Select-Object -First 1
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

# 5. Download docker-compose.yml
Write-Host "[..] Downloading docker-compose.yml..."
$composePath = ($InstallDir -replace '^/c/', 'C:\') -replace '/', '\'
Invoke-RestMethod -Uri "$RepoBase/docker-compose.yml" -OutFile "$composePath\docker-compose.yml"
Write-Host "[OK] docker-compose.yml downloaded" -ForegroundColor Green

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
PROVIDER=$Provider
DOMAIN=$Domain
PUBLIC_IP=$PublicIp
PUBLIC_IP_DASH=$PublicIpDash
DATA_ROOT=$DataRoot
DEFAULT_PASSWORD=$DefaultPassword
EMAIL=$Email
DEFAULT_SERVICE_HOST=casaos
DEFAULT_SERVICE_PORT=8080
PUID=0
PGID=0
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
Write-Host "Open https://$Domain in your browser to complete CasaOS first-run setup." -ForegroundColor Gray
Write-Host "To update, re-run this command." -ForegroundColor Gray
