#!/usr/bin/env bash
# x.sh — X (Twitter) on OUR rails. The node NEVER holds an X key; the server does, and meters
# every call to your marker. This is "use our rails, we charge" — you get X reads without a key.
#
#   x.sh account <handle>   # live X profile (verified tier, avatar, bio, metrics)
#   x.sh tweet <id|url>     # a tweet + author
#   x.sh search <query>     # recent tweets matching a query
#
# Override API base with GENIE_API. Marker resolves from ~/.claude/genie_marker (for metering).
set -euo pipefail
API="${GENIE_API:-https://orangegenie-api-production.up.railway.app}"
marker() { local f="$HOME/.claude/genie_marker"; [ -f "$f" ] && tr -d '[:space:]' <"$f" || printf 'genie'; }
MK="$(marker)"

pretty() { python3 -c 'import json,sys
try: print(json.dumps(json.load(sys.stdin), indent=2, ensure_ascii=False))
except Exception: print(sys.stdin.read())'; }

case "${1:-}" in
  account)
    h="${2:?usage: x.sh account <handle>}"; h="${h#@}"
    curl -fsS --max-time 15 "$API/api/x/account/$h?marker=$MK" 2>/dev/null | pretty
    ;;
  tweet)
    id="${2:?usage: x.sh tweet <id|url>}"; id="$(printf '%s' "$id" | grep -oE '[0-9]{5,}' | tail -1)"
    curl -fsS --max-time 15 "$API/api/x/tweet/$id?marker=$MK" 2>/dev/null | pretty
    ;;
  search)
    q="${2:?usage: x.sh search <query>}"
    curl -fsS --max-time 15 "$API/api/x/search?q=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$q")&marker=$MK" 2>/dev/null | pretty
    ;;
  *)
    echo "usage: x.sh {account <handle> | tweet <id|url> | search <query>}  — X on our rails, no key needed"; exit 1;;
esac
