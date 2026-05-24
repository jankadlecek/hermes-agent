#!/bin/bash
# Railway entrypoint: bring up Tailscale, then hand off to the upstream
# Hermes entrypoint. Nothing else.
#
# Hermes itself (model, providers, platforms, auth) is configured by the
# operator via the Hermes dashboard at https://<host>/ — this script
# only sets up the network path so the dashboard is reachable.
#
# Runs as root; the upstream entrypoint will gosu-drop to hermes.

set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"

if [ -n "${TS_AUTHKEY:-}" ]; then
    mkdir -p /var/run/tailscale /var/lib/tailscale "${HERMES_HOME}/tailscale"

    # Userspace networking — Railway grants no TUN / CAP_NET_ADMIN.
    # State on the volume so the node identity is stable across redeploys.
    tailscaled \
        --tun=userspace-networking \
        --state="${HERMES_HOME}/tailscale/tailscaled.state" \
        --socket=/var/run/tailscale/tailscaled.sock \
        > "${HERMES_HOME}/tailscale/tailscaled.log" 2>&1 &

    for _ in $(seq 1 30); do
        [ -S /var/run/tailscale/tailscaled.sock ] && break
        sleep 1
    done

    tailscale up \
        --authkey="${TS_AUTHKEY}" \
        --hostname="${TS_HOSTNAME:-hermes}" \
        --advertise-tags="${TS_TAGS:-tag:hermes}" \
        --accept-routes=false \
        --accept-dns=false \
        --reset

    echo "[entrypoint-railway] Tailscale up. Tailnet IPv4: $(tailscale ip -4 2>/dev/null || echo unknown)"

    # Reset any prior serve config (left over from older entrypoint
    # versions that used --tcp passthrough) before publishing the
    # current --https config. Without this the old listeners can
    # coexist and shadow the new ones.
    tailscale serve reset || true

    # Dashboard at https://<host>/ (default 443), API server at :8642.
    # Requires HTTPS Certificates enabled in the Tailscale admin
    # (Settings → DNS → HTTPS Certificates).
    tailscale serve --bg --https=443 http://127.0.0.1:9119 || \
        echo "[entrypoint-railway] WARN: failed to publish dashboard via tailscale serve"
    tailscale serve --bg --https=8642 http://127.0.0.1:8642 || \
        echo "[entrypoint-railway] WARN: failed to publish API server via tailscale serve"
else
    echo "[entrypoint-railway] TS_AUTHKEY not set — skipping Tailscale bring-up."
fi

# Hand off to the upstream entrypoint (gosu drop + Hermes startup).
exec /opt/hermes/docker/entrypoint.sh "$@"
