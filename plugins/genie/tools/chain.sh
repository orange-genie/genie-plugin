#!/usr/bin/env bash
# chain.sh — the dependency-free wire from an installed Genie to the shared Wildflower Chain.
# Every node writes as its OWN identity marker (chazz.agent, mikes.agent, novo.agent…). No admin
# key, no local chain tooling required — just curl. The server (orange-genie API) holds the DB key,
# forces authorship to the marker (unspoofable), and seals the block. This is what makes
# "everyone puts their skills on chain when they log in" real. Value in = Work out.
#
# Usage:
#   chain.sh login                         # genesis-block login handshake (announce presence)
#   chain.sh skill <slug> <summary> [body] # inscribe a skill you built/learned
#   chain.sh search <query> [limit]        # READ the chain: skills the commons already has
#   chain.sh mine [limit]                  # READ the chain: skills already inscribed under YOUR marker
#   chain.sh whoami                        # print this node's marker
#
# Marker resolution: ~/.claude/genie_marker if set, else <osuser>.agent.
# Override the API base with GENIE_API (default = the live orange-genie API).
set -euo pipefail

API="${GENIE_API:-https://orangegenie-api-production.up.railway.app}"
MARKER_FILE="$HOME/.claude/genie_marker"

marker() {
  if [ -f "$MARKER_FILE" ]; then
    local m; m="$(tr -d '[:space:]' < "$MARKER_FILE" 2>/dev/null || true)"
    [ -n "$m" ] && { printf '%s' "$m"; return; }
  fi
  printf '%s.agent' "$(id -un 2>/dev/null || echo node)"
}

# json-escape a string (portable: no jq dependency)
esc() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null \
        || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

post() { # post <src_id> <type> <symbol> <summary> <body>
  local mk sid typ sym sum bod
  mk="$(marker)"; sid="$1"; typ="$2"; sym="$3"; sum="$4"; bod="${5:-}"
  local payload
  payload="{\"marker\":$(esc "$mk"),\"src_id\":$(esc "$sid"),\"type\":$(esc "$typ"),\"symbol\":$(esc "$sym"),\"summary\":$(esc "$sum"),\"body\":$(esc "$bod")}"
  curl -fsS --max-time 12 -X POST "$API/api/chain/node-inscribe" \
       -H 'Content-Type: application/json' -d "$payload" 2>/dev/null \
    || { echo "⚠️  chain unreachable (work saved locally is unaffected)"; return 1; }
}

# read + filter the live chain client-side (the server has no query param; we pull recent blocks
# and match locally). Args: <query|""> <limit> <only-mine:0|1> <marker>
read_chain() {
  local q lim mine mk
  q="$1"; lim="${2:-200}"; mine="${3:-0}"; mk="$4"
  curl -fsS --max-time 15 "$API/api/chain?limit=$lim" 2>/dev/null \
    | Q="$q" MINE="$mine" MK="$mk" python3 -c '
import json,sys,os
q=os.environ.get("Q","").lower().strip()
mine=os.environ.get("MINE","0")=="1"
mk=os.environ.get("MK","").lower()
try: blocks=json.load(sys.stdin).get("blocks",[])
except Exception: print("(chain unreachable)"); sys.exit(0)
# skills = real work; drop RENAME/LOGON/NODE bookkeeping from the readout
def is_skill(b): return (b.get("type","") or "").upper() not in ("RENAME","LOGON","NODE","REGISTER")
def hay(b):
    d=b.get("data") or {}
    return " ".join(str(x) for x in (b.get("summary"),b.get("body"),b.get("src"),b.get("type"),d.get("for"))).lower()
rows=[]
for b in blocks:
    if not is_skill(b): continue
    src=(b.get("src","") or "").lower()
    if mine and src!=mk: continue
    if q and q not in hay(b): continue
    rows.append(b)
if not rows:
    print("mine: nothing under your marker yet — build one and it lands here." if mine
          else "no matches on chain — this looks like a genuine gap worth building.")
    sys.exit(0)
for b in rows[:25]:
    src=str(b.get("src","?")); summ=str(b.get("summary",""))[:72]
    print("  ⬢ " + src.ljust(20) + " " + summ)
scope=" under your marker" if mine else ""
print("\n  (" + str(len(rows)) + " on chain" + scope + "; showing up to 25)")
' 2>/dev/null || echo "  (chain unreachable — offline)"
}

cmd="${1:-}"
case "$cmd" in
  login)
    # Confirm identity + chain reachability ONLY. Does NOT broadcast presence to the chain —
    # nobody should be able to see when a user is "live" (privacy: data is property, not observance).
    # Your identity on the shared chain is established by your WORK (chain.sh skill), not a login ping.
    mk="$(marker)"
    if curl -fsS --max-time 8 "$API/api/chain?limit=1" >/dev/null 2>&1; then
      echo "⬢ $mk — chain reachable. Your work inscribes under this name."
    else
      echo "⬢ $mk — offline (chain unreachable); work will inscribe when you're back online."
    fi
    ;;
  skill)
    slug="${2:?usage: chain.sh skill <slug> <summary> [body]}"
    summary="${3:?usage: chain.sh skill <slug> <summary> [body]}"
    body="${4:-}"
    out="$(post "skill.$slug" "SKILL" "⬢" "$summary" "$body")" || exit 0
    echo "⬢ inscribed skill '$slug' as $(marker). $(printf '%s' "$out" | grep -o '"height":[0-9]*' | head -1)"
    ;;
  search)
    q="${2:?usage: chain.sh search <query> [limit]}"
    lim="${3:-200}"
    echo "⬢ chain · skills matching \"$q\":"
    read_chain "$q" "$lim" 0 ""
    ;;
  mine)
    lim="${2:-200}"
    mk="$(marker)"
    echo "⬢ chain · skills already inscribed under $mk:"
    read_chain "" "$lim" 1 "$mk"
    ;;
  whoami)
    echo "$(marker)"
    ;;
  *)
    echo "usage: chain.sh {login | skill <slug> <summary> [body] | search <query> [limit] | mine [limit] | whoami}"; exit 1;;
esac
