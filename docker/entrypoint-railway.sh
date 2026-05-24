#!/bin/bash
# Railway entrypoint: bring up Tailscale and bootstrap Codex auth, then hand
# off to the upstream Hermes entrypoint.
#
# Runs as root (the container starts as root so the upstream entrypoint can
# remap UIDs and gosu-drop to the hermes user). Anything that must run as
# root must happen here, BEFORE we exec the upstream entrypoint.

set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"

# ---------------------------------------------------------------------------
# 1. Tailscale: join the tailnet via userspace networking.
# ---------------------------------------------------------------------------
# Userspace mode means no TUN device / no CAP_NET_ADMIN required — Railway
# containers don't grant those. Incoming connections from the tailnet reach
# the API server fine. Outbound HTTP from Hermes still goes via Railway's
# normal egress, NOT through the tailnet — that's what we want.
if [ -n "${TS_AUTHKEY:-}" ]; then
    mkdir -p /var/run/tailscale /var/lib/tailscale "${HERMES_HOME}/tailscale"

    # Persist tailscaled state on the volume so the node identity survives
    # redeploys. With an ephemeral auth key the node deletes itself when
    # offline anyway, but stable state keeps the tailnet uncluttered.
    tailscaled \
        --tun=userspace-networking \
        --state="${HERMES_HOME}/tailscale/tailscaled.state" \
        --socket=/var/run/tailscale/tailscaled.sock \
        > "${HERMES_HOME}/tailscale/tailscaled.log" 2>&1 &

    # Wait for tailscaled socket to appear before calling `tailscale up`.
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

    TS_IP="$(tailscale ip -4 2>/dev/null || echo unknown)"
    echo "[entrypoint-railway] Tailscale up. Tailnet IPv4: ${TS_IP}"

    # In userspace-networking mode tailscaled does NOT forward incoming
    # tailnet connections to listeners on the container's loopback /
    # 0.0.0.0 ports. We have to explicitly publish each service via
    # `tailscale serve` so tailscaled accepts the connection on the
    # tailnet side and proxies it into the local process.
    #
    # We use HTTP reverse-proxy mode rather than raw --tcp passthrough.
    # TCP passthrough breaks browser keep-alive / chunked-transfer flows
    # on larger responses (the React JS bundle stalls mid-download in
    # Chrome even though curl streams it fine), because Tailscale's
    # userspace TCP stack does not reassemble HTTP correctly for raw
    # passthrough. HTTP mode lets tailscaled fully parse and re-emit
    # the request/response, which fixes the stalls.
    tailscale serve --bg --http=8642 http://127.0.0.1:8642 || \
        echo "[entrypoint-railway] WARN: failed to publish API server (8642) via tailscale serve"
    tailscale serve --bg --http=9119 http://127.0.0.1:9119 || \
        echo "[entrypoint-railway] WARN: failed to publish dashboard (9119) via tailscale serve"
    echo "[entrypoint-railway] tailscale serve status:"
    tailscale serve status || true
else
    echo "[entrypoint-railway] TS_AUTHKEY not set — skipping Tailscale bring-up."
    echo "[entrypoint-railway] Service will only be reachable via Railway public domain."
fi

# ---------------------------------------------------------------------------
# 2. Codex OAuth bootstrap: write auth.json from env var if not on volume.
# ---------------------------------------------------------------------------
# Hermes defaults CODEX_HOME to $HOME/.codex, which for the hermes user
# (HOME=/opt/data) resolves to /opt/data/.codex — already on the persistent
# volume. So we only need to seed the file on first boot; subsequent boots
# pick it up from disk and refresh tokens automatically.
CODEX_HOME_PATH="${CODEX_HOME:-${HERMES_HOME}/.codex}"
if [ -n "${CODEX_AUTH_JSON_B64:-}" ]; then
    mkdir -p "${CODEX_HOME_PATH}"
    if [ ! -f "${CODEX_HOME_PATH}/auth.json" ]; then
        echo "[entrypoint-railway] Bootstrapping Codex auth from CODEX_AUTH_JSON_B64."
        echo "${CODEX_AUTH_JSON_B64}" | base64 -d > "${CODEX_HOME_PATH}/auth.json"
        chmod 600 "${CODEX_HOME_PATH}/auth.json"
        # Ownership is fixed by the upstream entrypoint when it chowns the
        # volume to hermes:hermes, so we don't need to chown here.
    else
        echo "[entrypoint-railway] Codex auth.json already on volume; ignoring CODEX_AUTH_JSON_B64."
        echo "[entrypoint-railway] You can now delete the CODEX_AUTH_JSON_B64 env var in Railway."
    fi
fi

# ---------------------------------------------------------------------------
# 3. Delegate to the upstream entrypoint (gosu drop + Hermes startup).
# ---------------------------------------------------------------------------
exec /opt/hermes/docker/entrypoint.sh "$@"
