# NemoClaw setup (Care Compass)

Run on your **VM** (Ubuntu + Docker). Three steps:

1. **Install / verify NIM** — inference endpoint reachable from the VM
2. **Onboard NemoClaw** — CLI + OpenClaw sandbox
3. **Configure skills and network** — mcporter, MCP, weather, egress policies

Default sandbox name: **`my-assistant`**

---

## Prerequisites

- Ubuntu VM with Docker (user in `docker` group)
- Nemotron NIM deployed and reachable from the VM

```bash
cd scripts/nemoclaw
```

---

## 1. Install NIM (verify endpoint)

Set your NIM base URL and model (match what NemoClaw will use):

```bash
export NIM_HOST=""
export NIM_KEY="EMPTY"   # or your API key if required
export NIM_MODEL="nvidia/nemotron-3-nano"
```

**List models** (must return JSON):

```bash
curl -sS "${NIM_HOST}/v1/models" \
  -H "Authorization: Bearer ${NIM_KEY}" | head -c 500
echo
```

**Chat completions** (must return HTTP 200):

```bash
curl -sS -w "\nHTTP %{http_code}\n" "${NIM_HOST}/v1/chat/completions" \
  -H "Authorization: Bearer ${NIM_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${NIM_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}],\"max_tokens\":16,\"stream\":false}"
```

Put the same values in `env.local`:

```bash
NEMOCLAW_ENDPOINT_URL=http://YOUR-NIM-HOST/v1
NEMOCLAW_MODEL=nvidia/nemotron-3-nano
COMPATIBLE_API_KEY=EMPTY
```

| Setting | Notes |
| --- | --- |
| `NEMOCLAW_ENDPOINT_URL` | Include **`/v1`** for `nemoclaw-setup.sh` / onboard |
| `NEMOCLAW_MODEL` | Must match `/v1/models` (e.g. `nvidia/nemotron-3-nano`) |
| `COMPATIBLE_API_KEY` | Use `EMPTY` if the NIM accepts any bearer token |

---

## 2. Onboard NemoClaw

Installs the NemoClaw CLI, creates the sandbox, points OpenClaw at your NIM, and runs `recover`.

```bash
chmod +x nemoclaw-setup.sh
./nemoclaw-setup.sh
```

What it does:

- Checks Docker
- Installs NemoClaw (`curl … nemoclaw.sh`) if missing
- Runs non-interactive onboard (`brew`, `npm`, `pypi`, `huggingface`, `openclaw-pricing` presets)
- Patches `openclaw.json` (disables qqbot / weixin plugins)
- `nemoclaw my-assistant recover`

**Connect and chat:**

```bash
nemoclaw my-assistant connect
openclaw tui
```

Browser dashboard:

```bash
nemoclaw my-assistant dashboard-url
```

**Change NIM later** (resume existing sandbox):

```bash
NEMOCLAW_ENDPOINT_URL=http://your-host/v1 \
  nemoclaw onboard --non-interactive --yes --resume --name my-assistant
```

---

## 3. Configure skills and network

Single script after `nemoclaw-setup.sh`: Open-tier egress, mcporter, GOV.UK MCP, filesystem MCP, bundled weather skill.

```bash
chmod +x skills-setup.sh
./skills-setup.sh
```

### Network

NemoClaw is **deny-by-default**. This script applies:

- **Open-tier presets:** `brew`, `npm`, `pypi`, `huggingface`, `github`, `brave`, messaging/productivity presets, `local-inference`
- **Custom `skills-egress`:** wttr.in, fly.dev MCP hosts, GitHub API, City of London ArcGIS, your NIM host (from `NEMOCLAW_ENDPOINT_URL`)

Check policies:

```bash
nemoclaw my-assistant policy-list
```

### Skills / MCP

| Component | Purpose |
| --- | --- |
| **mcporter** | CLI to call MCP servers from exec |
| **govuk** | `https://govuk-mcp.fly.dev/mcp` (GOV.UK search, orgs, postcodes) |
| **filesystem** | Workspace-scoped files under `/sandbox/.openclaw/workspace` |
| **weather** | Bundled OpenClaw weather skill + wttr.in egress |

Smoke tests (inside sandbox after connect):

```bash
source /sandbox/.local/env.sh
mcporter list govuk --schema
curl -sf --max-time 20 'https://wttr.in/London?format=3'
```

Example MCP call:

```bash
mcporter call govuk.govuk_search query="NHS 111" count:2 --output json
```

After setup, start a **new** TUI session so the agent picks up MCP tools:

```bash
nemoclaw my-assistant recover
nemoclaw my-assistant connect
openclaw tui
```

---

## Configuration reference (`env.local`)

```bash
SANDBOX=my-assistant
NEMOCLAW_ENDPOINT_URL=http://your-nim-host/v1
NEMOCLAW_MODEL=nvidia/nemotron-3-nano
COMPATIBLE_API_KEY=EMPTY

# Direct HTTPS from sandbox — leave unset if it works
# NEMOCLAW_PROXY_HOST=10.200.0.1
# NEMOCLAW_PROXY_PORT=3128
```

## Quick reference

```bash
# Full path (fresh VM)
cd scripts/nemoclaw
cp env.example env.local    # edit NIM URL
./nemoclaw-setup.sh
./skills-setup.sh
nemoclaw my-assistant connect && openclaw tui
```
