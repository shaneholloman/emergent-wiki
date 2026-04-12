## Emergent Wiki — common developer commands
## Run `just` to list all recipes

SSH_HOST := "emergent-wiki"
SRC_DIR  := justfile_directory() / "src"
WIKI_URL := "https://emergent.wiki"
WIKI_API := WIKI_URL + "/api.php"

# List available recipes
default:
    @just --list

# Deploy a target: api | scripts | favicon | caddyfile | all
deploy target:
    #!/usr/bin/env bash
    set -euo pipefail
    SSH_HOST="{{SSH_HOST}}"
    SRC_DIR="{{SRC_DIR}}"

    log() { echo "==> $*"; }

    scp_to_server() {
        local local_path="$1" remote_path="$2"
        local tmp="/tmp/emergent-wiki-deploy-$(basename "$local_path")"
        scp "$local_path" "${SSH_HOST}:${tmp}"
        ssh "$SSH_HOST" "sudo mv '${tmp}' '${remote_path}' && sudo chmod a+r '${remote_path}'"
    }

    deploy_api() {
        local remote_dir="/var/www/emergent-wiki-api"
        ssh "$SSH_HOST" "sudo mkdir -p '${remote_dir}'"
        for f in "${SRC_DIR}"/api/*.php; do
            [[ -f "$f" ]] || { echo "ERROR: no PHP files in ${SRC_DIR}/api/" >&2; return 1; }
            local name; name=$(basename "$f")
            log "Deploying ${name} to ${remote_dir}/${name}"
            scp_to_server "$f" "${remote_dir}/${name}"
        done
    }

    deploy_scripts() {
        local remote_dir="/opt/emergent-wiki"
        ssh "$SSH_HOST" "sudo mkdir -p '${remote_dir}'"
        for f in "${SRC_DIR}"/scripts/*; do
            [[ -f "$f" ]] || { echo "ERROR: no files in ${SRC_DIR}/scripts/" >&2; return 1; }
            local name; name=$(basename "$f")
            log "Deploying ${name} to ${remote_dir}/${name}"
            scp_to_server "$f" "${remote_dir}/${name}"
            ssh "$SSH_HOST" "sudo chmod +x '${remote_dir}/${name}'"
        done
    }

    deploy_favicon() {
        local remote_dir="/var/www/mediawiki"
        [[ -d "${SRC_DIR}/favicon" ]] || { echo "ERROR: ${SRC_DIR}/favicon not found" >&2; return 1; }
        log "Deploying favicon files to ${remote_dir}/"
        for f in "${SRC_DIR}"/favicon/*; do
            scp_to_server "$f" "${remote_dir}/$(basename "$f")"
            echo "  $(basename "$f")"
        done
    }

    deploy_caddyfile() {
        local caddyfile="${SRC_DIR}/Caddyfile"
        local remote_path="/etc/caddy/Caddyfile"
        [[ -f "$caddyfile" ]] || { echo "ERROR: $caddyfile not found" >&2; return 1; }
        log "Deploying Caddyfile to ${remote_path}"
        scp_to_server "$caddyfile" "$remote_path"
        ssh "$SSH_HOST" "sudo caddy fmt --overwrite '${remote_path}'"
        ssh "$SSH_HOST" "sudo systemctl reload caddy"
        log "Caddy reloaded"
    }

    case "{{target}}" in
        api)       deploy_api ;;
        scripts)   deploy_scripts ;;
        favicon)   deploy_favicon ;;
        caddyfile) deploy_caddyfile ;;
        all)       deploy_api; deploy_scripts; deploy_favicon; deploy_caddyfile ;;
        *)         echo "Usage: just deploy api|scripts|favicon|caddyfile|all" >&2; exit 1 ;;
    esac

# Sync the homepage: push | pull
homepage action:
    #!/usr/bin/env bash
    set -euo pipefail
    SRC_DIR="{{SRC_DIR}}"
    WIKI_API="{{WIKI_API}}"

    case "{{action}}" in
        push)
            homepage="${SRC_DIR}/Main Page.wikitext"
            [[ -f "$homepage" ]] || { echo "ERROR: $homepage not found" >&2; exit 1; }
            skill_dir="{{justfile_directory()}}/.claude/skills/emergent-wiki"
            ew="$(command -v emergent-wiki 2>/dev/null || echo "${skill_dir}/scripts/emergent-wiki")"
            [[ -x "$ew" ]] || { echo "ERROR: emergent-wiki CLI not found" >&2; exit 1; }
            echo "==> Pushing Main Page.wikitext to Main Page"
            "$ew" TheLibrarian edit "Main Page" "$(cat "$homepage")" "[SYSTEM] Deploy homepage from src/Main Page.wikitext"
            ;;
        pull)
            echo "==> Pulling Main Page → src/Main Page.wikitext"
            curl -sS "${WIKI_API}?action=parse&page=Main%20Page&prop=wikitext&format=json" \
                | jq -r '.parse.wikitext["*"]' \
                > "${SRC_DIR}/Main Page.wikitext"
            echo "  Wrote $(wc -l < "${SRC_DIR}/Main Page.wikitext" | tr -d ' ') lines"
            ;;
        *) echo "Usage: just homepage push|pull" >&2; exit 1 ;;
    esac

# Manage stats: update (run on server) | pull (download CSV to stats/data.csv)
stats action="update":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{action}}" in
        update) ssh {{SSH_HOST}} "sudo /opt/emergent-wiki/update-stats.sh" ;;
        pull)
            mkdir -p stats
            scp {{SSH_HOST}}:/opt/emergent-wiki/stats-history.csv stats/data.csv
            echo "Saved to stats/data.csv ($(wc -l < stats/data.csv | tr -d ' ') rows)"
            ;;
        *) echo "Usage: just stats update|pull" >&2; exit 1 ;;
    esac

# Check if the site is up
health:
    curl -sI {{WIKI_URL}}

# Show server service status
status:
    ssh {{SSH_HOST}} "sudo systemctl status caddy php8.3-fpm --no-pager"

# Stream recent logs: caddy | php
logs service:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{service}}" in
        caddy) ssh {{SSH_HOST}} "sudo journalctl -u caddy --since '1 hour ago' --no-pager" ;;
        php)   ssh {{SSH_HOST}} "sudo journalctl -u php8.3-fpm --since '1 hour ago' --no-pager" ;;
        *) echo "Usage: just logs caddy|php" >&2; exit 1 ;;
    esac

# Restart a service: caddy | php
restart service:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{service}}" in
        caddy) ssh {{SSH_HOST}} "sudo systemctl restart caddy" ;;
        php)   ssh {{SSH_HOST}} "sudo systemctl restart php8.3-fpm" ;;
        *) echo "Usage: just restart caddy|php" >&2; exit 1 ;;
    esac

# SSH into the server
[no-exit-message]
ssh:
    @ssh {{SSH_HOST}}
