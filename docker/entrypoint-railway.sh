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
    # `tailscale serve`.
    #
    # We use HTTPS reverse-proxy mode (--https=PORT) rather than --tcp
    # passthrough. Userspace --tcp passthrough degrades on large
    # responses: server returns 200 OK but body bytes stall to ~1 kB/s
    # within ~30 min of uptime (Tailscale window scaling / buffer issue),
    # which makes the dashboard's 1.5 MB JS bundle unloadable in Chrome.
    # --https uses a proper HTTP reverse-proxy code path with TLS
    # termination at the edge, which is well-tested and not affected.
    # Requires HTTPS Certificates to be enabled in the Tailscale admin
    # (Settings → DNS → HTTPS Certificates).
    #
    # Clear any prior --tcp configuration left on the volume's
    # tailscaled.state before publishing the new HTTPS config; otherwise
    # the old --tcp listeners coexist and shadow the HTTPS ones.
    tailscale serve reset || true

    # Dashboard on the default HTTPS port (443) — operator opens
    #   https://hermes.<tailnet>.ts.net   (no port suffix needed)
    tailscale serve --bg --https=443 http://127.0.0.1:9119 || \
        echo "[entrypoint-railway] WARN: failed to publish dashboard (https://...) via tailscale serve"

    # API server on its conventional port (8642), TLS-terminated
    #   https://hermes.<tailnet>.ts.net:8642/v1/...
    tailscale serve --bg --https=8642 http://127.0.0.1:8642 || \
        echo "[entrypoint-railway] WARN: failed to publish API server (https://...:8642) via tailscale serve"

    echo "[entrypoint-railway] tailscale serve status:"
    tailscale serve status || true
else
    echo "[entrypoint-railway] TS_AUTHKEY not set — skipping Tailscale bring-up."
    echo "[entrypoint-railway] Service will only be reachable via Railway public domain."
fi

# ---------------------------------------------------------------------------
# 2. Codex OAuth bootstrap: seed BOTH the Codex CLI auth file AND the
#    Hermes auth store from CODEX_AUTH_JSON_B64 on first boot.
# ---------------------------------------------------------------------------
# Hermes auto-detects the inference provider via /opt/data/auth.json
# (the Hermes auth store), looking for an `active_provider` key with a
# logged-in provider entry. Just dropping the Codex CLI auth file into
# /opt/data/.codex/auth.json is NOT enough — Hermes's auto-detect doesn't
# enumerate OAuth providers without that auth_store entry, so the agent
# init fails with "No inference provider configured" even though tokens
# are on disk.
#
# So on first boot we:
#   1. Decode CODEX_AUTH_JSON_B64 into /opt/data/.codex/auth.json
#      (compat with Codex CLI shared-file path).
#   2. Transform it into the Hermes auth store shape with
#      active_provider="openai-codex" and write /opt/data/auth.json.
# After that, Hermes manages refreshes itself in /opt/data/auth.json;
# subsequent boots leave both files alone.
CODEX_HOME_PATH="${CODEX_HOME:-${HERMES_HOME}/.codex}"
HERMES_AUTH_STORE="${HERMES_HOME}/auth.json"

if [ -n "${CODEX_AUTH_JSON_B64:-}" ] && [ ! -f "${HERMES_AUTH_STORE}" ]; then
    echo "[entrypoint-railway] Bootstrapping Codex auth + Hermes auth store."
    mkdir -p "${CODEX_HOME_PATH}"

    # 1. Codex CLI shared file (used as a fallback read source)
    echo "${CODEX_AUTH_JSON_B64}" | base64 -d > "${CODEX_HOME_PATH}/auth.json"
    chmod 600 "${CODEX_HOME_PATH}/auth.json"

    # 2. Hermes auth store with active_provider + provider state. The Codex
    #    CLI file has {tokens: {...}, last_refresh: ...} at top level;
    #    Hermes wants it nested under providers["openai-codex"] with an
    #    active_provider pointer at the top level.
    python3 - "${CODEX_HOME_PATH}/auth.json" "${HERMES_AUTH_STORE}" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone

codex_path, hermes_path = sys.argv[1], sys.argv[2]
with open(codex_path) as f:
    codex = json.load(f)

tokens = codex.get("tokens") or {}
last_refresh = codex.get("last_refresh") or (
    datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
)

hermes_auth = {
    "active_provider": "openai-codex",
    "providers": {
        "openai-codex": {
            "tokens": tokens,
            "last_refresh": last_refresh,
            "auth_mode": "chatgpt",
        }
    },
}

with open(hermes_path, "w") as f:
    json.dump(hermes_auth, f, indent=2)

print(f"[entrypoint-railway] Wrote Hermes auth store at {hermes_path}")
print(f"[entrypoint-railway] active_provider = openai-codex (tokens len: "
      f"{len(tokens.get('access_token','')) if isinstance(tokens.get('access_token'), str) else 0} chars)")
PYEOF
    chmod 600 "${HERMES_AUTH_STORE}"
elif [ -f "${HERMES_AUTH_STORE}" ]; then
    echo "[entrypoint-railway] Hermes auth store already exists; ignoring CODEX_AUTH_JSON_B64."
    echo "[entrypoint-railway] (Safe to seal CODEX_AUTH_JSON_B64 in Railway.)"
fi

# ---------------------------------------------------------------------------
# 3. Delegate to the upstream entrypoint (gosu drop + Hermes startup).
# ---------------------------------------------------------------------------
exec /opt/hermes/docker/entrypoint.sh "$@"
