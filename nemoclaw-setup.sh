#!/usr/bin/env bash
#
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

load_env_local() {
  if [[ -f "$SCRIPT_DIR/env.local" ]]; then
    # shellcheck disable=SC1091
    set -a && source "$SCRIPT_DIR/env.local" && set +a
    log "Loaded env.local"
  fi
}

ensure_nemoclaw_on_path() {
  local dir cand
  if command -v nemoclaw >/dev/null 2>&1 && command -v openshell >/dev/null 2>&1; then
    return 0
  fi
  for dir in "${NEMOCLAW_BIN_DIR:-}" "$HOME/.local/bin" "$HOME/nemoclaw/bin" "$HOME/.nemoclaw/bin"; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    if [[ -x "$dir/nemoclaw" || -x "$dir/openshell" ]]; then
      export PATH="$dir:$PATH"
      log "Added to PATH: $dir"
    fi
  done
  for cand in "$HOME/.local/bin/nemoclaw" "$HOME/nemoclaw/bin/nemoclaw"; do
    [[ -x "$cand" ]] || continue
    export PATH="$(dirname "$cand"):$PATH"
    break
  done
}

with_curl_env() {
  if [[ -n "${NEMOCLAW_HOST_HTTP_PROXY:-}" ]]; then
    HTTP_PROXY="$NEMOCLAW_HOST_HTTP_PROXY" HTTPS_PROXY="$NEMOCLAW_HOST_HTTP_PROXY" "$@"
  elif [[ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]]; then
    "$@"
  else
    HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= "$@"
  fi
}

preflight_docker() {
  if [[ "${SKIP_DOCKER_PREFLIGHT:-0}" == "1" ]]; then
    warn "Skipping Docker check (SKIP_DOCKER_PREFLIGHT=1)"
    return 0
  fi

  need_cmd curl
  if ! command -v docker >/dev/null 2>&1; then
    die "Install Docker: https://docs.docker.com/engine/install/ubuntu/"
  fi

  if docker info >/dev/null 2>&1; then
    log "Docker OK"
    return 0
  fi

  local err in_group=0
  err="$(docker info 2>&1)" || true
  id -nG "${USER:-$(whoami)}" 2>/dev/null | tr ' ' '\n' | grep -qx docker && in_group=1

  if [[ "$in_group" -eq 0 ]] || grep -qiE 'permission denied|docker\.sock' <<<"$err"; then
    die "User '${USER:-$(whoami)}' cannot access Docker (group membership).

  sudo usermod -aG docker \"${USER:-$(whoami)}\"
  newgrp docker
  docker info
  ./fresh-setup.sh

Error: $(printf '%s' "$err" | head -1)"
  fi

  die "Docker not ready: sudo systemctl enable --now docker && docker info

Error: $(printf '%s' "$err" | head -1)"
}

install_nemoclaw() {
  ensure_nemoclaw_on_path
  if command -v nemoclaw >/dev/null 2>&1; then
    log "nemoclaw: $(command -v nemoclaw)"
    return 0
  fi

  log "Installing NemoClaw CLI..."
  if ! with_curl_env bash -c \
    'curl -fsSL --connect-timeout 30 --max-time 600 https://www.nvidia.com/nemoclaw.sh | \
      NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 bash'; then
    die "Install failed. Set NEMOCLAW_HOST_HTTP_PROXY if behind a proxy."
  fi

  ensure_nemoclaw_on_path
  command -v nemoclaw >/dev/null 2>&1 || \
    die "nemoclaw not on PATH. Try: export PATH=\"\$HOME/.local/bin:\$PATH\""
  log "nemoclaw: $(command -v nemoclaw)"
}

uninstall_nemoclaw() {
  if [[ "${UNINSTALL_NEMOCLAW:-1}" != "1" ]]; then
    log "Skipping uninstall (UNINSTALL_NEMOCLAW=0)"
    return 0
  fi

  ensure_nemoclaw_on_path
  local uninstall_args=(uninstall --yes)
  [[ "${UNINSTALL_KEEP_OPENSHELL:-1}" == "1" ]] && uninstall_args+=(--keep-openshell)

  if command -v nemoclaw >/dev/null 2>&1; then
    log "Removing existing NemoClaw (${uninstall_args[*]})..."
    if ! run nemoclaw "${uninstall_args[@]}"; then
      warn "nemoclaw uninstall failed (continuing with fresh install)"
    fi
    return 0
  fi

  log "nemoclaw not on PATH — running hosted uninstall.sh"
  local hosted_args=(--yes)
  [[ "${UNINSTALL_KEEP_OPENSHELL:-1}" == "1" ]] && hosted_args+=(--keep-openshell)
  if ! with_curl_env bash -c \
    "curl -fsSL --connect-timeout 30 --max-time 300 \
      https://raw.githubusercontent.com/NVIDIA/NemoClaw/refs/heads/main/uninstall.sh | \
      bash -s -- ${hosted_args[*]}"; then
    warn "Hosted uninstall failed or nothing to remove (continuing)"
  fi
}

sandbox_exists() {
  openshell sandbox list 2>/dev/null | grep -qw "${SANDBOX:-my-assistant}"
}

export_sandbox_proxy() {
  [[ -n "${NEMOCLAW_PROXY_HOST:-}" ]] || return 0
  export NEMOCLAW_PROXY_PORT="${NEMOCLAW_PROXY_PORT:-3128}"
}

run_onboard() {
  export NEMOCLAW_NON_INTERACTIVE="${NEMOCLAW_NON_INTERACTIVE:-1}"
  export NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE="${NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE:-1}"
  export NEMOCLAW_YES="${NEMOCLAW_YES:-1}"
  export NEMOCLAW_SANDBOX_NAME="$SANDBOX"
  export_sandbox_proxy

  local args=(onboard --non-interactive --yes-i-accept-third-party-software --yes
    --name "$SANDBOX" --agent "$NEMOCLAW_AGENT")

  if [[ "${RECREATE_SANDBOX:-0}" == "1" ]]; then
    args+=(--recreate-sandbox)
  elif [[ "${ONBOARD_RESUME:-1}" == "1" ]] && sandbox_exists; then
    args+=(--resume)
  else
    args+=(--fresh)
  fi

  log "Onboard: $SANDBOX ($NEMOCLAW_MODEL @ $NEMOCLAW_ENDPOINT_URL)"
  run nemoclaw "${args[@]}"
}

patch_openclaw_config() {
  log "Patching openclaw.json (disable qqbot plugin)"
  run nemoclaw "$SANDBOX" exec -- python3 -c "
import json
from pathlib import Path
p = Path('/sandbox/.openclaw/openclaw.json')
if not p.is_file():
    raise SystemExit(0)
d = json.loads(p.read_text())
pl = d.setdefault('plugins', {})
pl.setdefault('entries', {}).pop('qqbot', None)
pl.setdefault('entries', {}).pop('openclaw-weixin', None)
pl['allow'] = ['nemoclaw']
pl.setdefault('entries', {})['nemoclaw'] = {'enabled': True}
p.write_text(json.dumps(d, indent=2) + '\n')
print('patched openclaw.json')
" 2>/dev/null || warn "Could not patch openclaw.json (non-fatal)"
}

# ---------------------------------------------------------------------------
load_env_local

SANDBOX="${SANDBOX:-my-assistant}"
NEMOCLAW_AGENT="${NEMOCLAW_AGENT:-openclaw}"
UNINSTALL_NEMOCLAW="${UNINSTALL_NEMOCLAW:-1}"
UNINSTALL_KEEP_OPENSHELL="${UNINSTALL_KEEP_OPENSHELL:-1}"
SKIP_ONBOARD_IF_EXISTS="${SKIP_ONBOARD_IF_EXISTS:-1}"
ONBOARD_RESUME="${ONBOARD_RESUME:-1}"
RECREATE_SANDBOX="${RECREATE_SANDBOX:-0}"

export NEMOCLAW_PROVIDER="${NEMOCLAW_PROVIDER:-custom}"
export NEMOCLAW_ENDPOINT_URL="${NEMOCLAW_ENDPOINT_URL:-http://your-host/v1}"
export NEMOCLAW_MODEL="${NEMOCLAW_MODEL:-nvidia/nemotron-3-nano}"
export COMPATIBLE_API_KEY="${COMPATIBLE_API_KEY:-EMPTY}"
export NEMOCLAW_PREFERRED_API="${NEMOCLAW_PREFERRED_API:-completions}"
export NEMOCLAW_POLICY_MODE="${NEMOCLAW_POLICY_MODE:-custom}"
export NEMOCLAW_POLICY_PRESETS="${NEMOCLAW_POLICY_PRESETS:-brew,npm,pypi,huggingface,openclaw-pricing}"

# ---------------------------------------------------------------------------
log "NemoClaw fresh setup"
preflight_docker
uninstall_nemoclaw
# After uninstall, always run a fresh onboard (prior sandbox/state is gone).
if [[ "${UNINSTALL_NEMOCLAW:-1}" == "1" ]]; then
  SKIP_ONBOARD_IF_EXISTS=0
  ONBOARD_RESUME=0
  RECREATE_SANDBOX=0
fi
install_nemoclaw
ensure_nemoclaw_on_path
need_cmd nemoclaw
need_cmd openshell

if [[ "$SKIP_ONBOARD_IF_EXISTS" == "1" ]] && sandbox_exists && [[ "$RECREATE_SANDBOX" != "1" ]]; then
  warn "Sandbox '$SANDBOX' exists — skipping onboard"
else
  run_onboard
fi

patch_openclaw_config
run nemoclaw "$SANDBOX" recover

cat <<EOF

Done. Sandbox: $SANDBOX

  nemoclaw $SANDBOX connect
  openclaw tui

Dashboard:
  nemoclaw $SANDBOX dashboard-url

Change inference later:
  NEMOCLAW_ENDPOINT_URL=http://your-host/v1 \\
    nemoclaw onboard --non-interactive --yes --resume --name $SANDBOX

EOF
