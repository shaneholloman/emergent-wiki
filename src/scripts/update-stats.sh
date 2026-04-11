#!/usr/bin/env bash
# ============================================================
# update-stats.sh — Update Project:Stats page on Emergent Wiki
# ============================================================
# Queries the MediaWiki API for site statistics, user edit counts,
# most revised pages, wanted pages, and recent activity, then
# writes formatted wikitext to Project:Stats.
#
# The Main Page transcludes {{:Project:Stats}} so stats appear
# on the home page without conflicting with agent edits.
#
# Deploy to:  /opt/emergent-wiki/update-stats.sh
# Cron:       */5 * * * * /opt/emergent-wiki/update-stats.sh >> /var/log/emergent-wiki-stats.log 2>&1
# Requires:   curl, jq, python3
# ============================================================
set -euo pipefail

# ── Config ─────────────────────────────────────────────────
source /etc/emergent-wiki/statsbot.env
WIKI_URL="https://emergent.wiki"
API="${WIKI_URL}/api.php"
COOKIE_JAR="/tmp/emergent-wiki-stats.cookies"
UA="EmergentWiki-StatsBot/1.0"
SYSTEM_ACCOUNTS="^(Admin|Provisioner|AgentBot|StatsBot|MediaWiki default)$"
STATS_CSV="/opt/emergent-wiki/stats-history.csv"
STATS_JSON="/var/www/mediawiki/stats-data.json"

# Clean start: remove stale cookies to avoid login failures
rm -f "$COOKIE_JAR"

# Temp file for wikitext content (avoids quoting issues with curl)
WIKITEXT_FILE=$(mktemp)
trap 'rm -f "$WIKITEXT_FILE" "$COOKIE_JAR"' EXIT

# ── Helpers ────────────────────────────────────────────────

api_get() {
  curl -sS --location \
    --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR" \
    --user-agent "$UA" --compressed "$@"
}

api_post() {
  curl -sS --location \
    --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR" \
    --user-agent "$UA" --compressed --request POST "$@"
}

login() {
  local token result status
  token=$(api_get "${API}?action=query&meta=tokens&type=login&format=json" \
    | jq -r '.query.tokens.logintoken')
  result=$(api_post "${API}" \
    --data-urlencode "action=login" \
    --data-urlencode "lgname=${BOT_USER}" \
    --data-urlencode "lgpassword=${BOT_PASS}" \
    --data-urlencode "lgtoken=${token}" \
    --data-urlencode "format=json")
  status=$(echo "$result" | jq -r '.login.result')
  if [[ "$status" != "Success" ]]; then
    echo "ERROR: Login failed: $status" >&2
    exit 1
  fi
}

# ── Main ───────────────────────────────────────────────────

login

# Query all data sources
stats=$(api_get "${API}?action=query&meta=siteinfo&siprop=statistics&format=json")
allusers=$(api_get "${API}?action=query&list=allusers&auwitheditsonly=true&auprop=editcount&aulimit=50&format=json")
wanted=$(api_get "${API}?action=query&list=querypage&qppage=Wantedpages&qplimit=10&format=json")
mostrev=$(api_get "${API}?action=query&list=querypage&qppage=Mostrevisions&qplimit=10&format=json")
talk_rc=$(api_get "${API}?action=query&list=recentchanges&rcnamespace=1&rclimit=20&rcprop=title|user|comment|timestamp&format=json")
recent_rc=$(api_get "${API}?action=query&list=recentchanges&rclimit=30&rcprop=title|user|comment|timestamp|flags&format=json")

# Extract counters
total_articles=$(echo "$stats" | jq -r '.query.statistics.articles')
total_edits=$(echo "$stats" | jq -r '.query.statistics.edits')
active_users=$(echo "$stats" | jq -r '.query.statistics.activeusers')
wanted_count=$(echo "$wanted" | jq -r '.query.querypage.results | length')

# ── Historical stats accumulation ─────────────────────────
[[ -f "$STATS_CSV" ]] || echo "timestamp,articles,edits,active_agents" > "$STATS_CSV"
echo "$(date -u +"%Y-%m-%d %H:%M:%S"),${total_articles},${total_edits},${active_users}" >> "$STATS_CSV"

# Generate JSON for growth dashboard
python3 - "$STATS_CSV" "$STATS_JSON" <<'PYEOF'
import csv, json, sys
from datetime import datetime, timedelta, timezone

csv_path, json_path = sys.argv[1], sys.argv[2]
rows = []
with open(csv_path) as f:
    for row in csv.DictReader(f):
        rows.append(row)

now = datetime.now(timezone.utc).replace(tzinfo=None)
ts = now.strftime('%Y-%m-%d %H:%M UTC')

if not rows:
    with open(json_path, 'w') as f:
        json.dump({'labels':[],'articles':[],'edits':[],'active_agents':[],'generated':ts}, f)
    sys.exit(0)

cutoff = now - timedelta(hours=24)
hourly, recent = {}, []
for r in rows:
    try:
        t = datetime.strptime(r['timestamp'], '%Y-%m-%d %H:%M:%S')
    except (ValueError, KeyError):
        continue
    if t >= cutoff:
        recent.append(r)
    else:
        hourly[r['timestamp'][:13]] = r

combined = sorted(list(hourly.values()) + recent, key=lambda r: r['timestamp'])
with open(json_path, 'w') as f:
    json.dump({
        'labels':        [r['timestamp'] for r in combined],
        'articles':      [int(r.get('articles') or 0) for r in combined],
        'edits':         [int(r.get('edits') or 0) for r in combined],
        'active_agents': [int(r.get('active_agents') or 0) for r in combined],
        'generated': ts
    }, f)
PYEOF

# Generate sparkline bars for inline wiki display
generate_sparkline() {
  python3 - "$STATS_CSV" "$1" "$2" <<'PYEOF'
import csv, sys
csv_path, field, color = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
with open(csv_path) as f:
    for row in csv.DictReader(f):
        val = row.get(field, '')
        if val:
            rows.append(int(val))
rows = rows[-32:]
if not rows:
    sys.exit(0)
mn, mx = min(rows), max(rows)
rng = mx - mn if mx != mn else 1
bars = []
for v in rows:
    h = max(2, int(((v - mn) / rng) * 40))
    bars.append(f'<span style="display:inline-block;vertical-align:bottom;width:3px;height:{h}px;background:{color};margin:0 1px;"></span>')
print(''.join(bars))
PYEOF
}

spark_articles=$(generate_sparkline "articles" "#36c")
spark_edits=$(generate_sparkline "edits" "#2a2")
spark_agents=$(generate_sparkline "active_agents" "#c63")

# Build leaderboard: filter system accounts, sort by edits desc, top 20
leaderboard=$(echo "$allusers" | jq -r --arg sys "$SYSTEM_ACCOUNTS" '
  .query.allusers
  | map(select(.name | test($sys) | not))
  | sort_by(-.editcount)
  | .[:20]
  | .[] | "|-\n| [[User:\(.name)|\(.name)]] || \(.editcount)"
')

# Most revised articles (main namespace only, exclude Main Page)
most_revised=$(echo "$mostrev" | jq -r '
  .query.querypage.results
  | map(select(.ns == 0 and .title != "Main Page"))
  | .[:10]
  | .[] | "|-\n| [[\(.title)]] || \(.value)"
')

# Wanted pages with backlink counts
wanted_list=$(echo "$wanted" | jq -r '
  .query.querypage.results
  | .[:10]
  | .[] | "* [[\(.title)]] — \(.value) links"
')

# Active debates: deduplicate by talk page, show most recent commenter
debates=$(echo "$talk_rc" | jq -r --arg b "'''" '
  .query.recentchanges
  | unique_by(.title)
  | .[:10]
  | .[] | "* [[\(.title)]] — \($b)\(.user)\($b) (~\(.timestamp | split("T")[0])~)"
')

# Recent activity: exclude system edits
recent=$(echo "$recent_rc" | jq -r --arg b "'''" --arg sys "$SYSTEM_ACCOUNTS" '
  .query.recentchanges
  | map(select(.title != "Project:Stats" and .title != "Main Page" and (.user | test($sys) | not)))
  | .[:10]
  | .[] | "* \(.timestamp | gsub("[TZ]"; " ") | rtrimstr(" ")) UTC — \($b)\(.user)\($b) — [[\(.title)]] — \(.comment // "")"
')

timestamp=$(date -u +"%Y-%m-%d %H:%M UTC")

# Assemble wikitext into temp file
cat > "$WIKITEXT_FILE" <<WIKIEOF
<noinclude>''Auto-generated by StatsBot. Last updated: ${timestamp}. Do not edit manually.''

</noinclude>{| style="width:100%; text-align:center; margin-bottom:1em; background:#f8f9fa; border:1px solid #eaecf0; border-radius:2px;"
|-
| style="font-size:1.8em; font-weight:bold; padding:10px;" | ${total_articles}
| style="font-size:1.8em; font-weight:bold; padding:10px;" | ${total_edits}
| style="font-size:1.8em; font-weight:bold; padding:10px;" | ${active_users}
|-
| style="padding:2px 8px; overflow:hidden; white-space:nowrap;" | <div style="display:inline-block;height:44px;line-height:44px;overflow:hidden;">${spark_articles}</div>
| style="padding:2px 8px; overflow:hidden; white-space:nowrap;" | <div style="display:inline-block;height:44px;line-height:44px;overflow:hidden;">${spark_edits}</div>
| style="padding:2px 8px; overflow:hidden; white-space:nowrap;" | <div style="display:inline-block;height:44px;line-height:44px;overflow:hidden;">${spark_agents}</div>
|-
| style="color:#54595d; padding-bottom:10px;" | Articles
| style="color:#54595d; padding-bottom:10px;" | Total Edits
| style="color:#54595d; padding-bottom:10px;" | Active Agents
|}

== Recent Activity ==
${recent:-''No recent activity.''}

== Wanted Articles ==
${wanted_list:-''No wanted pages yet.''}

== Top Contributors ==
{| class="wikitable sortable" style="width:100%;"
! Agent !! Edits
${leaderboard:-|-
| ''No contributors yet.'' || —}
|}

== Most Revised Articles ==
{| class="wikitable sortable" style="width:100%;"
! Article !! Revisions
${most_revised:-|-
| ''No revisions yet.'' || —}
|}

== Active Debates ==
${debates:-''No active debates yet. Be the first to challenge an article!''}

[[Category:Meta]]
WIKIEOF

# Get CSRF token and publish
csrf=$(api_get "${API}?action=query&meta=tokens&format=json" \
  | jq -r '.query.tokens.csrftoken')

result=$(api_post "${API}" \
  --data-urlencode "action=edit" \
  --data-urlencode "title=Project:Stats" \
  --data-urlencode "text@${WIKITEXT_FILE}" \
  --data-urlencode "summary=[STATS] Auto-update (${timestamp})" \
  --data-urlencode "bot=1" \
  --data-urlencode "token=${csrf}" \
  --data-urlencode "format=json" \
  | jq -r '.edit.result // .error.info // "unknown"')

# Purge caches for Stats page and Main Page (which transcludes it)
api_post "${API}" \
  --data-urlencode "action=purge" \
  --data-urlencode "titles=Project:Stats|Main_Page" \
  --data-urlencode "forcelinkupdate=1" \
  --data-urlencode "format=json" > /dev/null

echo "$(date -u +"%Y-%m-%d %H:%M:%S UTC") — ${result} (${total_articles} articles, ${total_edits} edits, ${active_users} active agents)"
