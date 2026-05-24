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

# ---------------------------------------------------------------------------
# Codex OAuth bootstrap (workaround for OpenAI's broken device-code path).
# ---------------------------------------------------------------------------
# Why this exists:
#   The dashboard's KEYS → OpenAI Codex LOGIN button uses OpenAI's device-code
#   OAuth flow, which requires "Enable device code authorization for Codex"
#   to be toggled on in ChatGPT Settings → Security. As of mid-2026 that
#   toggle is reported as missing / broken across personal and workspace
#   accounts (openai/codex#9253, #9282, #9327, #9418). Local `codex login`
#   uses PKCE with a localhost callback and is unaffected — so we let the
#   operator do that login on their Mac, then ship the resulting tokens to
#   the container as a base64-encoded env var.
#
# What this does (once, on first boot when CODEX_AUTH_JSON_B64 is set):
#   - decode the Codex CLI auth.json into /opt/data/.codex/auth.json
#   - rewrap it into the Hermes auth-store schema with
#     active_provider="openai-codex" at /opt/data/auth.json
#   so Hermes's auto-detect picks Codex as the inference provider and
#   refreshes tokens itself from then on. Subsequent boots see the Hermes
#   auth.json on the volume and skip the bootstrap.
#
# The env var can be deleted / sealed once the bootstrap has run.
HERMES_AUTH_STORE="${HERMES_HOME}/auth.json"
CODEX_HOME_PATH="${CODEX_HOME:-${HERMES_HOME}/.codex}"

# Bootstrap is best-effort: any failure is logged but does NOT stop the
# container. Otherwise a malformed base64 (Railway paste truncation,
# stray whitespace, etc.) would put the container into a crash loop
# instead of letting it boot up with the dashboard reachable so the
# operator can fix the env var. `set -e` is suspended for this block.
set +e
if [ -n "${CODEX_AUTH_JSON_B64:-}" ] && \
   { [ ! -f "${HERMES_AUTH_STORE}" ] || [ "${FORCE_CODEX_BOOTSTRAP:-}" = "1" ]; }; then
    if [ -f "${HERMES_AUTH_STORE}" ]; then
        echo "[entrypoint-railway] FORCE_CODEX_BOOTSTRAP=1 → overwriting existing Hermes auth store."
        rm -f "${HERMES_AUTH_STORE}"
    fi
    echo "[entrypoint-railway] Bootstrapping Codex auth → Hermes auth store."
    mkdir -p "${CODEX_HOME_PATH}"
    if echo "${CODEX_AUTH_JSON_B64}" | base64 -d > "${CODEX_HOME_PATH}/auth.json" 2>/dev/null; then
        chmod 600 "${CODEX_HOME_PATH}/auth.json"
        python3 - "${CODEX_HOME_PATH}/auth.json" "${HERMES_AUTH_STORE}" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone

codex_path, hermes_path = sys.argv[1], sys.argv[2]
try:
    with open(codex_path) as f:
        codex = json.load(f)
except Exception as exc:
    print(f"[entrypoint-railway] WARN: failed to parse decoded Codex auth.json: {exc}")
    print("[entrypoint-railway] WARN: CODEX_AUTH_JSON_B64 is likely truncated or malformed.")
    print("[entrypoint-railway] WARN: container will start without an inference provider — fix the env var and redeploy.")
    sys.exit(0)

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

access_len = len(tokens.get("access_token", "")) if isinstance(tokens.get("access_token"), str) else 0
print(f"[entrypoint-railway] Wrote Hermes auth store ({access_len}-char access_token).")
PYEOF
        # Upstream entrypoint will gosu-drop to the hermes user. Ownership
        # of files we created as root needs to be flipped or hermes won't
        # be able to read them (manifests as "Permission denied" parsing
        # auth.json, and Hermes silently falls back to "no provider").
        if [ -f "${HERMES_AUTH_STORE}" ]; then
            chmod 600 "${HERMES_AUTH_STORE}"
            chown hermes:hermes "${HERMES_AUTH_STORE}" 2>/dev/null || true
        fi
        chown -R hermes:hermes "${CODEX_HOME_PATH}" 2>/dev/null || true
    else
        echo "[entrypoint-railway] WARN: base64 decode of CODEX_AUTH_JSON_B64 failed — env var is corrupted or truncated."
    fi
elif [ -f "${HERMES_AUTH_STORE}" ] && [ -n "${CODEX_AUTH_JSON_B64:-}" ]; then
    echo "[entrypoint-railway] Hermes auth store already exists; ignoring CODEX_AUTH_JSON_B64."
    echo "[entrypoint-railway] (Safe to seal / delete that env var in Railway now.)"
fi
set -e

# Hand off to the upstream entrypoint (gosu drop + Hermes startup).
exec /opt/hermes/docker/entrypoint.sh "$@"
