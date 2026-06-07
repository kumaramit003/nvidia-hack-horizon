
#!/usr/bin/env bash
#
# Optional: cp env.example env.local  (SANDBOX, NEMOCLAW_ENDPOINT_URL, proxy)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX="${SANDBOX:-my-assistant}"
FS_BASE="${MCP_FS_BASE:-/sandbox/.openclaw/workspace}"
MCPORTER_PREFIX="/sandbox/.local"
NIM_URL="${NEMOCLAW_ENDPOINT_URL:-http://nim-nemotron-nvidia-nims.apps.sng-ai1-ucs.svpod.dc-02.com/v1}"
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

load_env_local() {
  if [[ -f "$SCRIPT_DIR/env.local" ]]; then
    # shellcheck disable=SC1091
    set -a && source "$SCRIPT_DIR/env.local" && set +a
    log "Loaded env.local"
  fi
}

ensure_nemoclaw() {
  local dir
  if command -v nemoclaw >/dev/null 2>&1; then
    return 0
  fi
  for dir in "${NEMOCLAW_BIN_DIR:-}" "$HOME/.local/bin" "$HOME/nemoclaw/bin"; do
    [[ -n "$dir" && -x "$dir/nemoclaw" ]] || continue
    export PATH="$dir:$PATH"
    log "Added to PATH: $dir"
    return 0
  done
  die "nemoclaw not found. Run ./fresh-setup.sh first."
}

nim_host_from_url() {
  python3 - <<PY
from urllib.parse import urlparse
u = urlparse("${NIM_URL}")
print(u.hostname or "")
PY
}

setup_sandbox_env() {
  log "Persist PATH (+ proxy if set) in /sandbox/.local/env.sh"
  cat > "$TMP/sandbox-env.sh" <<'EOF'
# Writable env for NemoClaw sandbox (do not use /sandbox/.profile — read-only).
export PATH="/sandbox/.local/bin:/tmp/npm-global/bin:${PATH:-}"
EOF
  if [[ -n "${NEMOCLAW_PROXY_HOST:-}" ]]; then
    local port="${NEMOCLAW_PROXY_PORT:-3128}"
    local proxy="http://${NEMOCLAW_PROXY_HOST}:${port}"
    cat >> "$TMP/sandbox-env.sh" <<EOF
export HTTP_PROXY="${proxy}"
export HTTPS_PROXY="${proxy}"
EOF
  fi
  run nemoclaw "$SANDBOX" exec -- bash -lc 'mkdir -p /sandbox/.local/bin'
  run openshell sandbox upload "$SANDBOX" "$TMP/sandbox-env.sh" /sandbox/.local/env.sh
  run nemoclaw "$SANDBOX" exec -- bash -lc 'test -r /sandbox/.local/env.sh && echo "OK: /sandbox/.local/env.sh"' \
    || warn "Could not write /sandbox/.local/env.sh"
}

sandbox_path_prefix() {
  printf '%s' 'export PATH="/sandbox/.local/bin:/tmp/npm-global/bin:$PATH"; source /sandbox/.local/env.sh 2>/dev/null || true; '
}

apply_open_network() {
  local preset
  # Open tier + dev tooling (NemoClaw is deny-by-default; layer presets + skill egress).
  local presets=(
    brew npm pypi huggingface openclaw-pricing
    github brave discord slack telegram whatsapp wechat jira outlook local-inference
  )
  log "Network: Open-tier presets"
  for preset in "${presets[@]}"; do
    run nemoclaw "$SANDBOX" policy-add "$preset" --yes 2>/dev/null || \
      warn "preset $preset (may already be applied)"
  done
  log "Network: skill egress bundle (wttr, MCP, GitHub/gh, ArcGIS, NIM)"
  run nemoclaw "$SANDBOX" policy-add --from-file "$TMP/skills-egress.yaml" --yes 2>/dev/null || \
    warn "skills-egress may already be applied"
}

# ---------------------------------------------------------------------------
load_env_local
ensure_nemoclaw
command -v openshell >/dev/null 2>&1 || die "openshell required"

NIM_HOST="$(nim_host_from_url)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "Write skills-egress policy"
cat > "$TMP/skills-egress.yaml" <<EOF
preset:
  name: skills-egress
  description: Broad egress for OpenClaw skills, MCP, wttr, GitHub/gh, ArcGIS, NIM

network_policies:
  skills_egress:
    name: skills_egress
    endpoints:
      - host: wttr.in
        port: 443
        access: full
      - host: wttr.is
        port: 443
        access: full
      - host: govuk-mcp.fly.dev
        port: 443
        access: full
      - host: uk-property-mcp.fly.dev
        port: 443
        access: full
      - host: github.com
        port: 443
        access: full
      - host: api.github.com
        port: 443
        access: full
      - host: codeload.github.com
        port: 443
        access: full
      - host: raw.githubusercontent.com
        port: 443
        access: full
      - host: objects.githubusercontent.com
        port: 443
        access: full
      - host: mapping.cityoflondon.gov.uk
        port: 443
        access: full
EOF

if [[ -n "$NIM_HOST" ]]; then
  cat >> "$TMP/skills-egress.yaml" <<EOF
      - host: ${NIM_HOST}
        port: 443
        access: full
      - host: ${NIM_HOST}
        port: 80
        access: full
EOF
fi

cat >> "$TMP/skills-egress.yaml" <<'EOF'
    binaries:
      - { path: /usr/bin/curl }
      - { path: /usr/bin/wget }
      - { path: /usr/bin/python3 }
      - { path: /usr/local/bin/python3 }
      - { path: /usr/local/bin/node }
      - { path: /usr/local/bin/openclaw }
      - { path: /usr/bin/git }
      - { path: /usr/bin/gh }
      - { path: /sandbox/.local/bin/gh }
      - { path: /sandbox/.local/bin/node }
      - { path: /sandbox/.local/bin/mcporter }
      - { path: /sandbox/.local/bin/npx }
      - { path: /tmp/npm-global/bin/node }
      - { path: /tmp/npm-global/bin/npx }
EOF

cat > "$TMP/patch-openclaw.py" <<PY
import json
from pathlib import Path

CONFIG = Path("/sandbox/.openclaw/openclaw.json")
FS_BASE = "${FS_BASE}"
PATHS = ["/sandbox/.local/bin", "/tmp/npm-global/bin"]

if not CONFIG.is_file():
    raise SystemExit(f"Missing {CONFIG}")

d = json.loads(CONFIG.read_text())
tools = d.setdefault("tools", {})
tools.setdefault("exec", {}).update(
    {"host": "sandbox", "security": "full", "ask": "off", "pathPrepend": PATHS}
)
allow = set(tools.get("allow") or [])
allow.update(["exec", "web_fetch", "read", "group:plugins"])
tools["allow"] = sorted(allow)
tools.setdefault("web", {}).setdefault("fetch", {})["enabled"] = True
tools.setdefault("sandbox", {}).setdefault("tools", {})["allow"] = sorted(allow)

skills = d.setdefault("skills", {})
entries = skills.setdefault("entries", {})
entries["mcporter"] = {"enabled": True}
entries["weather"] = {"enabled": True}

agents = d.setdefault("agents", {})
agent_env = agents.setdefault("defaults", {}).setdefault("env", {})
path_val = ":".join(PATHS + ["/usr/local/bin", "/usr/bin", agent_env.get("PATH", "")]).strip(":")
while "::" in path_val:
    path_val = path_val.replace("::", ":")
agent_env["PATH"] = path_val

mcp = d.setdefault("mcpServers", {})
mcp["govuk"] = {"url": "https://govuk-mcp.fly.dev/mcp", "transport": "http"}
mcp["filesystem"] = {
    "command": "npx",
    "args": ["-y", "@cyanheads/filesystem-mcp-server"],
    "transport": "stdio",
    "cwd": FS_BASE,
    "env": {
        "FS_BASE_DIRECTORY": FS_BASE,
        "MCP_LOG_LEVEL": "warn",
        "MCP_TRANSPORT_TYPE": "stdio",
    },
}

CONFIG.write_text(json.dumps(d, indent=2) + "\n")
print("openclaw.json patched")
PY

apply_open_network

log "Install mcporter"
run nemoclaw "$SANDBOX" exec -- bash -lc "mkdir -p ${MCPORTER_PREFIX}/bin"
run nemoclaw "$SANDBOX" exec -- bash -lc "rm -f ${MCPORTER_PREFIX}/bin/mcporter 2>/dev/null; npm install -g mcporter --prefix ${MCPORTER_PREFIX} || npm install -g mcporter --prefix /tmp/npm-global"
run nemoclaw "$SANDBOX" exec -- bash -lc 'export PATH="/sandbox/.local/bin:/tmp/npm-global/bin:$PATH"; mcporter --version; which mcporter'

log "PATH + workspace"
setup_sandbox_env
run nemoclaw "$SANDBOX" exec -- bash -lc "mkdir -p '${FS_BASE}'"

log "mcporter config: govuk + filesystem"
run nemoclaw "$SANDBOX" exec -- bash -lc "$(sandbox_path_prefix)mcporter config remove govuk 2>/dev/null || true; mcporter config add govuk https://govuk-mcp.fly.dev/mcp --transport http --scope home"
run nemoclaw "$SANDBOX" exec -- bash -lc "$(sandbox_path_prefix)mcporter config remove filesystem 2>/dev/null || true; mcporter config add filesystem --command \"npx -y @cyanheads/filesystem-mcp-server\" --transport stdio --scope home --env FS_BASE_DIRECTORY=${FS_BASE} --env MCP_LOG_LEVEL=warn --env MCP_TRANSPORT_TYPE=stdio"

log "openclaw.json: skills + MCP"
run openshell sandbox upload "$SANDBOX" "$TMP/patch-openclaw.py" /tmp/skills-patch-openclaw.py
run nemoclaw "$SANDBOX" exec -- python3 /tmp/skills-patch-openclaw.py

log "Smoke tests"
run nemoclaw "$SANDBOX" exec -- bash -lc "$(sandbox_path_prefix)mcporter config list; mcporter list govuk --schema 2>&1 | head -20"
run nemoclaw "$SANDBOX" exec -- bash -lc "curl -sf --max-time 20 'https://wttr.in/London?format=3' | head -c 80; echo"

run nemoclaw "$SANDBOX" recover

cat <<EOF

Done. Sandbox: $SANDBOX

Network: Open-tier presets + skills-egress (wttr, MCP, GitHub, ArcGIS${NIM_HOST:+, NIM $NIM_HOST}).

  nemoclaw $SANDBOX policy-list
  mcporter list govuk --schema
  openclaw tui   # new session

Inside sandbox, if mcporter is not on PATH:
  source /sandbox/.local/env.sh

EOF
