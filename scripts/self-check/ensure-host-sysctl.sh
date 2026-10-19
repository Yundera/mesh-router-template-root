#!/bin/bash
# Host kernel parameters every PCS relies on, persisted in /etc/sysctl.d so they
# hold from the first second of a boot, not only after this script has run.
#
# net.ipv4.ip_nonlocal_bind=1 / net.ipv6.ip_nonlocal_bind=1
#
#   Lets a process bind an address the host does not carry YET. Apps publish ports
#   on a VPN address so they are reachable over the VPN only: Samba on 10.9.0.1
#   (WireGuard Easy - Host) or on a Tailscale 100.x address, Guacamole, ... That
#   address exists only once the VPN app has brought its interface up. At boot
#   Docker restarts every container at once; a container whose published address
#   is missing fails with "failed to bind host port <ip>:<port>/tcp: cannot assign
#   requested address" and is left Exited. Worse, started again later without a
#   recreate (Maison Start, docker start, docker restart) it runs with NO port
#   published, so it looks up and is unreachable. Reproduced on Docker 29.8.
#   With the sysctl, Docker binds the address in advance and the port answers as
#   soon as the VPN interface appears; it also survives the VPN restarting.
#
#   What it does not do: it opens nothing. A socket bound to 10.9.0.1 still only
#   receives traffic addressed to 10.9.0.1, which only arrives over wg0.
#
# Idempotent: rewrites the file only when its content differs, applies it every run
# (a value changed by hand since the last run is put back).

set -e

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping host sysctl setup."
    exit 0
fi

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

SYSCTL_FILE="/etc/sysctl.d/90-yundera-pcs.conf"

read -r -d '' WANT <<'EOF' || true
# Managed by the Yundera mesh self-check (ensure-host-sysctl.sh). Edits are overwritten.
# Allow binding an address before its interface exists (VPN-bound app ports at boot).
net.ipv4.ip_nonlocal_bind = 1
-net.ipv6.ip_nonlocal_bind = 1
EOF

if [ ! -f "$SYSCTL_FILE" ] || [ "$(cat "$SYSCTL_FILE")" != "$WANT" ]; then
    printf '%s\n' "$WANT" > "$SYSCTL_FILE"
    echo "Wrote $SYSCTL_FILE"
fi

# Apply now. At boot systemd-sysctl reads the file itself; the leading "-" on the
# IPv6 key tells it to skip that key quietly when IPv6 is disabled (procps
# `sysctl -p` does not honour the "-", hence the explicit writes here).
sysctl -qw net.ipv4.ip_nonlocal_bind=1
if [ -e /proc/sys/net/ipv6/ip_nonlocal_bind ]; then
    sysctl -qw net.ipv6.ip_nonlocal_bind=1
fi
echo "Host sysctl applied: net.ipv4.ip_nonlocal_bind=$(sysctl -n net.ipv4.ip_nonlocal_bind)"
