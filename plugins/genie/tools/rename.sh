#!/usr/bin/env bash
# rename.sh — change your Wildflower Chain username (marker). Max 2 renames per 60 days.
# The server enforces the limit by reading the chain (not a local counter), links old→new
# publicly so your past work still credits you, and only swaps your LOCAL marker AFTER the
# chain accepts the rename. Reserved and already-taken names are refused.
#
# Usage:  rename.sh <new_username>
set -euo pipefail

API="${GENIE_API:-https://orangegenie-api-production.up.railway.app}"
MARKER_FILE="$HOME/.claude/genie_marker"
new="${1:?usage: rename.sh <new_username>}"

# current marker
if [ -f "$MARKER_FILE" ]; then old="$(tr -d '[:space:]' < "$MARKER_FILE")"; else old="genie"; fi
new="$(printf '%s' "$new" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

esc() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null \
        || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

resp="$(curl -sS --max-time 15 -X POST "$API/api/chain/rename" -H 'Content-Type: application/json' \
  -d "{\"old_marker\":$(esc "$old"),\"new_marker\":$(esc "$new")}" 2>/dev/null)" || {
    echo "⚠️  chain unreachable — name not changed"; exit 1; }

if printf '%s' "$resp" | grep -q '"ok":true'; then
  printf '%s' "$new" > "$MARKER_FILE"          # only swap local identity AFTER the chain accepts
  remaining="$(printf '%s' "$resp" | grep -o '"remaining":[0-9]*' | head -1 | grep -oE '[0-9]+')"
  echo "⬢ renamed: $old → $new  (renames left this 60-day window: ${remaining:-?})"
else
  err="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error","rename refused"))' 2>/dev/null || echo "rename refused")"
  echo "✗ $err  (still $old)"; exit 1
fi
