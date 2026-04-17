# mesh-router-template-root

Template docker-compose configuration for PCS (Private Cloud Server) instances.

## Purpose

This repository provides a template `docker-compose.yml` file used by mesh-dashboard to generate user-specific configurations. When a new user sets up their PCS instance, the dashboard replaces template variables with user-specific values.

## Template Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `%PROVIDER_STR%` | Provider connection string | `https://api.nsl.sh,userid,signature` |
| `%PUBLIC_IP%` | Instance public IP address | `203.0.113.5` |
| `%REF_DOMAIN%` | User's full domain | `username.nsl.sh` |
| `%DATA_ROOT%` | Data storage path | `/data` |
| `%DEFAULT_PASSWORD%` | Platform secret consumed by app-store apps via `$APP_DEFAULT_PASSWORD` / `$PCS_DEFAULT_PASSWORD` | `generated-password` |
| `%EMAIL%` | User's email address | `user@example.com` |

## Services Included

### mesh-router-tunnel

WireGuard VPN tunnel to the provider for NAT traversal.

- Forwards traffic to local Caddy instance
- Requires NET_ADMIN and SYS_MODULE capabilities
- Uses `%PROVIDER_STR%` for authentication

### mesh-router-agent

Direct IP registration for low-latency routing.

- Registers public IP with mesh-router-backend
- Falls back to tunnel if direct routing unavailable
- Uses `%PUBLIC_IP%` and `%PROVIDER_STR%`

### caddy

Reverse proxy with automatic SSL certificate management.

- Uses [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)
- Discovers services via Docker labels
- Handles TLS termination

### casaos

Container management UI for the PCS instance.

- Web-based Docker management
- Uses `%REF_DOMAIN%`, `%DATA_ROOT%`, `%DEFAULT_PASSWORD%`
- First-run account setup handled by CasaOS itself; `DEFAULT_PASSWORD` is the platform secret exposed to installed apps (not the CasaOS login)
- Accessible via the user's domain

## Network Configuration

All services connect via the `pcs` bridge network, enabling internal communication:

```
External Request
       │
       ▼
   mesh-router-tunnel / mesh-router-agent
       │
       ▼
     caddy (reverse proxy)
       │
       ▼
   casaos / other services
```

## Usage

Variables are replaced by mesh-dashboard when generating user configurations:

```javascript
const userConfig = template
  .replace('%PROVIDER_STR%', `${backendUrl},${userId},${signature}`)
  .replace('%PUBLIC_IP%', userPublicIp)
  .replace('%REF_DOMAIN%', `${username}.${serverDomain}`)
  .replace('%DATA_ROOT%', '/data')
  .replace('%DEFAULT_PASSWORD%', generatedPassword)
  .replace('%EMAIL%', userEmail);
```

## Publishing updates

`install.sh` is distributed via jsDelivr and pulls `docker-compose.yml` from the same CDN on every run:

```
https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@main/install.sh
https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@main/docker-compose.yml
```

Because the URL pins `@main` (a floating ref), jsDelivr caches the resolved content for up to 12 hours. After pushing new image versions to `main`, users will keep getting the old file until the cache expires — **or** you explicitly purge it:

```bash
curl "https://purge.jsdelivr.net/gh/yundera/mesh-router-template-root@main/docker-compose.yml"
curl "https://purge.jsdelivr.net/gh/yundera/mesh-router-template-root@main/install.sh"
```

Verify afterwards:

```bash
curl -fsSL "https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@main/docker-compose.yml" | grep image:
```

Notes:
- Purge only works once commits are actually pushed to `origin/main`. It re-resolves `@main` against GitHub, so nothing to fetch = nothing changes.
- Pinned refs (`@1.2.3`, `@<sha>`) are immutable and don't need purging.
- Purge is rate-limited; don't script it in a loop.

## License

MIT
