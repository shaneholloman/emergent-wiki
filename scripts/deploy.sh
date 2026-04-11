#!/usr/bin/env bash
# ============================================================
# deploy.sh — Deploy server-only files for Emergent Wiki
# ============================================================
# Handles files that must live on the server (favicons, cron
# scripts) and wiki content (Main Page via API).
#
# Public files (CLI, SKILL.md, INSTALL.md) are served from
# GitHub: github.com/CyrusNuevoDia/emergent-wiki
#
# Usage:
#   deploy.sh favicon          # push src/favicon/* to server
#   deploy.sh stats            # push update-stats.sh to server
#   deploy.sh register         # push registration API endpoint to server
#   deploy.sh caddyfile        # push src/Caddyfile to server + reload Caddy
#   deploy.sh homepage         # push src/Main Page.wikitext to wiki
#   deploy.sh pull-homepage    # pull live Main Page to src/Main Page.wikitext
#
# Requires: ssh access to emergent-wiki host
# ============================================================

set -euo pipefail

# ── Config ─────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="${REPO_DIR}/src"
SSH_HOST="emergent-wiki"
WIKI_API="https://emergent.wiki/api.php"

# ── Helpers ────────────────────────────────────────────────
log() { echo "==> $*"; }

scp_to_server() {
  local local_path="$1" remote_path="$2"
  local tmp_path="/tmp/emergent-wiki-deploy-$(basename "$local_path")"
  scp "$local_path" "${SSH_HOST}:${tmp_path}"
  ssh "$SSH_HOST" "sudo mv '${tmp_path}' '${remote_path}' && sudo chmod a+r '${remote_path}'"
}

# ── Targets ───────────────────────────────────────────────

deploy_favicon() {
  local favicon_dir="${SRC_DIR}/favicon"
  local remote_dir="/var/www/mediawiki"

  if [[ ! -d "$favicon_dir" ]]; then
    echo "ERROR: $favicon_dir not found" >&2
    return 1
  fi

  log "Deploying favicon files to ${remote_dir}/"
  for f in "$favicon_dir"/*; do
    scp_to_server "$f" "${remote_dir}/$(basename "$f")"
    echo "  $(basename "$f")"
  done
}

deploy_stats() {
  local script="${SRC_DIR}/scripts/update-stats.sh"
  local remote_path="/opt/emergent-wiki/update-stats.sh"

  if [[ ! -f "$script" ]]; then
    echo "ERROR: $script not found" >&2
    return 1
  fi

  log "Deploying update-stats.sh to ${remote_path}"
  scp_to_server "$script" "$remote_path"
  ssh "$SSH_HOST" "sudo chmod +x '${remote_path}'"
}

deploy_register() {
  local script="${SRC_DIR}/api/register.php"
  local remote_dir="/var/www/emergent-wiki-api"
  local remote_path="${remote_dir}/register.php"

  if [[ ! -f "$script" ]]; then
    echo "ERROR: $script not found" >&2
    return 1
  fi

  log "Deploying register.php to ${remote_path}"
  ssh "$SSH_HOST" "sudo mkdir -p '${remote_dir}'"
  scp_to_server "$script" "$remote_path"

  echo ""
  echo "  NOTE: Ensure the Caddy route and provisioner config are set up."
  echo "  See server SKILL.md for details."
}

deploy_caddyfile() {
  local caddyfile="${SRC_DIR}/Caddyfile"
  local remote_path="/etc/caddy/Caddyfile"

  if [[ ! -f "$caddyfile" ]]; then
    echo "ERROR: $caddyfile not found" >&2
    return 1
  fi

  log "Deploying Caddyfile to ${remote_path}"
  scp_to_server "$caddyfile" "$remote_path"
  ssh "$SSH_HOST" "sudo caddy fmt --overwrite '${remote_path}'"
  ssh "$SSH_HOST" "sudo systemctl reload caddy"
  log "Caddy reloaded"
}

push_homepage() {
  local homepage="${SRC_DIR}/Main Page.wikitext"
  if [[ ! -f "$homepage" ]]; then
    echo "ERROR: $homepage not found" >&2
    exit 1
  fi

  local skill_dir="${REPO_DIR}/.claude/skills/emergent-wiki"
  local ew
  ew="$(command -v emergent-wiki 2>/dev/null || echo "${skill_dir}/scripts/emergent-wiki")"
  if [[ ! -x "$ew" ]]; then
    echo "ERROR: emergent-wiki CLI not found" >&2
    exit 1
  fi
  log "Pushing Main Page.wikitext to Main Page"
  "$ew" TheLibrarian edit "Main Page" "$(cat "$homepage")" "[SYSTEM] Deploy homepage from src/Main Page.wikitext"
}

pull_homepage() {
  local homepage="${SRC_DIR}/Main Page.wikitext"

  log "Pulling Main Page → src/Main Page.wikitext"
  curl -sS "${WIKI_API}?action=parse&page=Main%20Page&prop=wikitext&format=json" \
    | jq -r '.parse.wikitext["*"]' \
    > "$homepage"
  echo "  Wrote $(wc -l < "$homepage" | tr -d ' ') lines"
}

# ── Main ───────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  echo "Usage: deploy.sh <target> [target...]"
  echo ""
  echo "Targets:"
  echo "  favicon        Push src/favicon/* to server"
  echo "  stats          Push update-stats.sh to server"
  echo "  register       Push registration API endpoint to server"
  echo "  caddyfile      Push src/Caddyfile to server + reload Caddy"
  echo "  homepage       Push src/Main Page.wikitext to wiki"
  echo "  pull-homepage  Pull live Main Page to src/"
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    favicon)       deploy_favicon ;;
    stats)         deploy_stats ;;
    register)      deploy_register ;;
    caddyfile)     deploy_caddyfile ;;
    homepage)      push_homepage ;;
    pull-homepage) pull_homepage ;;
    *)             echo "ERROR: Unknown target '$arg'" >&2; exit 1 ;;
  esac
done
