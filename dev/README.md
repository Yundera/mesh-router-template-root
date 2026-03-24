# Install Script Dev Environment

Docker-based test environment for the mesh-router install script.

## Quick Start

```bash
# Build and start the test container
docker compose up -d --build

# Exec into the container
docker exec -it mesh-install-test bash

# Run the install script (uses local files, not CDN)
bash /tmp/install.sh \
  --provider "https://nsl.sh/router/api,testuid,testsig" \
  --domain test.nsl.sh

# Inspect generated files
cat /DATA/AppData/casaos/apps/mesh/.env
cat /DATA/AppData/casaos/apps/mesh/docker-compose.yml

# Stop
docker compose down
```

## What it tests

- Argument parsing and validation
- Docker detection (Docker CLI is installed via socket mount)
- Public IP auto-detection
- Password generation
- `.env` file generation
- `docker-compose.yml` download from CDN
- `docker compose up -d` (runs real containers via socket mount)

## Notes

- The Docker socket is mounted, so `docker compose up -d` will create real containers on your host.
- The install script downloads `docker-compose.yml` from jsdelivr CDN by default. To test local changes before pushing, copy the file manually:

```bash
# Inside the container, override with local template
cp /tmp/docker-compose.yml /DATA/AppData/casaos/apps/mesh/docker-compose.yml
```
