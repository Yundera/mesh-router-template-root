# Mesh Router Installer (Windows/PowerShell)
# Usage: irm https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@main/install.ps1 | iex
# Or:    .\install.ps1 -Provider "https://nsl.sh/router/api,userid,sig" -Domain "alice.nsl.sh"

param(
    [Parameter(Mandatory=$true)]
    [string]$Provider,

    [Parameter(Mandatory=$true)]
    [string]$Domain,

    [string]$Password,
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
    Write-Host "[!!] Docker not found. Please install Docker Desktop from https://www.docker.com/products/docker-desktop/" -ForegroundColor Red
    Write-Host "     After installing, restart this script." -ForegroundColor Red
    exit 1
}

# 2. Auto-detect public IP if not provided
if (-not $PublicIp) {
    Write-Host "[..] Detecting public IP..."
    try {
        $PublicIp = (Invoke-RestMethod -Uri "https://ifconfig.me" -TimeoutSec 5).Trim()
        Write-Host "[OK] Public IP: $PublicIp" -ForegroundColor Green
    } catch {
        $PublicIp = ""
        Write-Host "[!!] Could not detect public IP (direct routing via agent will be disabled)" -ForegroundColor Yellow
    }
} else {
    Write-Host "[OK] Public IP: $PublicIp" -ForegroundColor Green
}

# 3. Generate password if not provided
if (-not $Password) {
    $Password = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    Write-Host "[OK] Generated password: $Password" -ForegroundColor Green
} else {
    Write-Host "[OK] Using provided password" -ForegroundColor Green
}

# 4. Compute derived values
$PublicIpDash = $PublicIp -replace '[.:]', '-'
$Email = "admin@$Domain"

# 5. Create directories (via WSL since paths are Linux-style)
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

# 6. Download docker-compose.yml
Write-Host "[..] Downloading docker-compose.yml..."
$composePath = ($InstallDir -replace '^/c/', 'C:\') -replace '/', '\'
Invoke-RestMethod -Uri "$RepoBase/docker-compose.yml" -OutFile "$composePath\docker-compose.yml"
Write-Host "[OK] docker-compose.yml downloaded" -ForegroundColor Green

# 7. Patch docker-compose.yml for Windows
Write-Host "[..] Patching docker-compose for Windows..."
$composeContent = Get-Content "$composePath\docker-compose.yml" -Raw
# Remove rshared propagation (not supported on Docker Desktop)
$composeContent = $composeContent -replace '(?ms)\s+bind:\s+propagation: rshared', ''
# Add user: 0:0 to casaos service
$composeContent = $composeContent -replace '(container_name: casaos)', "`$1`n    user: `"0:0`""
Set-Content -Path "$composePath\docker-compose.yml" -Value $composeContent -NoNewline
Write-Host "[OK] Windows patches applied" -ForegroundColor Green

# 8. Write .env
Write-Host "[..] Writing .env..."
$envContent = @"
PROVIDER=$Provider
DOMAIN=$Domain
PUBLIC_IP=$PublicIp
PUBLIC_IP_DASH=$PublicIpDash
DATA_ROOT=$DataRoot
DEFAULT_USER=admin
DEFAULT_PASSWORD=$Password
EMAIL=$Email
DEFAULT_SERVICE_HOST=casaos
DEFAULT_SERVICE_PORT=8080
"@
Set-Content -Path "$composePath\.env" -Value $envContent -NoNewline
Write-Host "[OK] .env written" -ForegroundColor Green

# 9. Start containers
Write-Host "[..] Starting containers..."
Push-Location $composePath
docker compose up -d
Pop-Location

Write-Host ""
Write-Host "=== Installation complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Domain:    https://$Domain" -ForegroundColor White
Write-Host "  Password:  $Password" -ForegroundColor White
Write-Host "  Install:   $InstallDir" -ForegroundColor White
Write-Host ""
Write-Host "To update, re-run this command." -ForegroundColor Gray
