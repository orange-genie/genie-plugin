#!/usr/bin/env bash
# greet.sh — Orange Genie SessionStart greeting, for EVERY user (not just AUTO).
#
# The problem: the warm "Genie's up · chain's warm · N skills reachable · <your name>"
# open only ever fired for AUTO, because it came from his personal ~/.claude/settings.json
# boot hooks (genesis_boot.py etc.) that no other install has. Chazz/Novo/Mike logged in
# to silence.
#
# The fix: this plugin hook resolves the user's OWN Wildflower Chain marker (their name on
# the network) and the live shared-chain facts (height + skills reachable), then injects a
# SessionStart instruction so Genie greets that user BY NAME in the Orange Genie voice —
# "Hey <name>, what are we building?".
#
# Hard rules honored:
#   • Never fabricate a metric — only numbers this script actually fetched are passed on;
#     on any fetch miss, the greeting is told to omit the number, not invent one.
#   • Never block a session — every step is fail-silent and the script always exits 0.
set -euo pipefail

API="${GENIE_API:-https://orangegenie-api-production.up.railway.app}"
MARKER_FILE="$HOME/.claude/genie_marker"

# ── 1. Who is this user on the chain? (marker = their name/identity) ──
marker=""
if [ -f "$MARKER_FILE" ]; then
  marker="$(tr -d '[:space:]' < "$MARKER_FILE" 2>/dev/null || true)"
fi
[ -n "$marker" ] || marker="$(id -un 2>/dev/null || echo node)"

# ── 2. Live shared-chain facts (real or nothing — fail-silent) ──
height="$(curl -fsS --max-time 4 "$API/api/chain" 2>/dev/null \
  | grep -o '"height"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -oE '[0-9]+' || true)"
skills="$(curl -fsS --max-time 4 "$API/api/skills" 2>/dev/null \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("skills",[])))' 2>/dev/null || true)"

# ── 3. Build the greeting instruction, carrying ONLY facts we actually have ──
facts=""
[ -n "$skills" ] && facts="${facts} The shared Wildflower Chain has ${skills} skills reachable."
[ -n "$height" ] && facts="${facts} Current chain height is ${height}."

read -r -d '' MSG <<EOF || true
Open this session by greeting the user by name in the Orange Genie voice. Their Wildflower Chain marker (their name on the network) is "${marker}". If your memory holds a preferred name for this user, use that; otherwise use the marker, capitalized. One warm, terse line then a question — e.g. "Hey ${marker} — Genie's up, chain's warm. What are we building?".${facts} State ONLY the numbers given in the previous sentence; if none were given, do not invent any — just say the chain is warm. Do not recite open tasks. If a version-update nudge is present in this session's context, append it as ONE terse line after the greeting.
EOF

printf '%s' "$MSG" | python3 -c '
import json, sys
msg = sys.stdin.read().strip()
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": msg}}))
' 2>/dev/null || true

exit 0
