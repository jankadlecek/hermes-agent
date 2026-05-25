# Context for Claude sessions in this repo

This is **jankadlecek/hermes-agent**, a fork of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) kept close to upstream. The fork only adds what's needed to run the agent on Railway with a separate Hindsight memory backend.

## Production topology

- **Railway project:** `hermes-agent` (id `4315fbc2-fc6a-482f-b063-5e22dc7f6605`)
- **Service:** `hermes` (id `85b0185b-a000-46b8-b4e0-17c830f4ef55`)
- **Branch:** `railway-deploy` — auto-deploys on push (not `main`)
- **Build:** [Dockerfile.railway](Dockerfile.railway) extends `nousresearch/hermes-agent:latest`; entrypoint [docker/entrypoint-railway.sh](docker/entrypoint-railway.sh) wraps the upstream one to add Tailscale + Codex auth bootstrap.
- **Volume:** `/opt/data` — Hermes auth store, Codex tokens, Tailscale state.
- **Region:** EU West.

## Network

- **API server:** `:8642`
- **Dashboard:** `:9119`
- Both reachable only over **Tailscale userspace networking** (no Railway public domain). `tailscale serve --bg --https=443 → :9119` and `--https=8642 → :8642`. Dashboard: `https://hermes-1.tailca0c7e.ts.net/`.

## Memory backend: external Hindsight (sibling service)

Hermes' memory provider is `hindsight` in `local_external` mode pointing at the sibling **`hindsight`** Railway service (separate repo: [jankadlecek/hindsight](https://github.com/jankadlecek/hindsight)). The dataplane is reached over the Railway private network at `http://hindsight.railway.internal:9100`.

### Required env vars (on the hermes service)

| Env var | Value |
| --- | --- |
| `HINDSIGHT_MODE` | `local_external` — **not** `local` (that's an alias for `local_embedded`) |
| `HINDSIGHT_API_URL` | `http://hindsight.railway.internal:9100` |
| `HINDSIGHT_BANK_ID` | `hermes` |
| `HINDSIGHT_BUDGET` | `mid` |
| `HINDSIGHT_TIMEOUT` | `120` |
| `TS_AUTHKEY` | Tailscale ephemeral auth key |
| `TS_HOSTNAME` | `hermes` |
| `TS_TAGS` | `tag:default` |

### YAML side

In Hermes config YAML (Dashboard → Config → `<>YAML`), set `memory.provider: hindsight` manually. The dropdown filters out memory providers whose Python deps aren't seen as installed; the value is still honored at runtime.

### Why `hindsight-client` is baked into the image

The upstream Hermes v0.14 lazy-install hook (`tools/lazy_deps.py` → `memory.hindsight`) didn't fire reliably on Railway. The container ended up with `memory.provider=hindsight` in the runtime config but no `hindsight_client` module, so memory tools returned `No module named 'hindsight_client'` and Hermes silently fell back to built-in `MEMORY.md`. [Dockerfile.railway](Dockerfile.railway) pre-installs `hindsight-client==0.6.1` into the upstream venv via `uv pip install` to bypass the lazy installer.

## Known-good baseline

Tag **`v0.1`** marks the first fully-working deploy with the external Hindsight memory loop. Revert here if something later breaks.

## Working on this repo

- This is a fork — try not to drift far from upstream. Add Railway-only changes in `Dockerfile.railway` / `docker/entrypoint-railway.sh` / `railway.toml`, not in the core Hermes source if it can be helped.
- `main` tracks upstream `NousResearch/hermes-agent`. Railway deploys from `railway-deploy`. Rebase `railway-deploy` onto upstream `main` periodically.
- Codex auth bootstrap: the entrypoint decodes `CODEX_AUTH_JSON_B64` (set on first deploy) into `/opt/data/auth.json` so Hermes picks Codex as the inference provider. Once the auth store is persisted, that env var can be sealed/deleted.
- Google Workspace OAuth bootstrap: the entrypoint decodes `GOOGLE_OAUTH_CLIENT_JSON_B64` (base64-encoded Desktop-app `client_secret.json` from Google Cloud Console) into `/opt/data/google_client_secret.json` so the `skills/productivity/google-workspace` setup flow doesn't have to ask for the file path through the chat (and through the LLM). Set `FORCE_GOOGLE_OAUTH_BOOTSTRAP=1` to overwrite an existing file. The user-authorized token lands at `/opt/data/google_token.json` after the OAuth dance and is not in any env var.
