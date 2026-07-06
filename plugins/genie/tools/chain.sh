#!/usr/bin/env bash
# chain.sh — the dependency-free wire from an installed Genie to the shared Wildflower Chain.
# Every node writes as its OWN identity marker (chazz.agent, mikes.agent, novo.agent…). No admin
# key, no local chain tooling required — just curl. The server (orange-genie API) holds the DB key,
# forces authorship to the marker (unspoofable), and seals the block. This is what makes
# "everyone puts their skills on chain when they log in" real. Value in = Work out.
#
# Usage:
#   chain.sh login                         # genesis-block login handshake (announce presence)
#   chain.sh skill <slug> <summary> [body] # inscribe a skill you built/learned (immediate network write)
#   chain.sh queue <slug> <summary> [body] # STAGE a skill locally (instant, offline-safe) — the Stop hook drains it
#   chain.sh drain                         # inscribe everything staged in the queue (called by the Stop hook)
#   chain.sh search <query> [limit]        # READ the chain: skills the commons already has
#   chain.sh mine [limit]                  # READ the chain: skills already inscribed under YOUR marker
#   chain.sh whoami                        # print this node's marker
#
# The write loop (why skills actually land): during a session the Genie STAGES each reusable skill
# with `queue` — a trivial, local, always-succeeds append. At session end the Stop hook runs `drain`,
# which does the real network inscription under the marker. Propose (model, cheap) is decoupled from
# write (hook, deterministic), so a skill lands even if the model never composed a curl itself.
#
# Marker resolution: ~/.claude/genie_marker if set, else <osuser>.agent.
# Override the API base with GENIE_API (default = the live orange-genie API).
set -euo pipefail

API="${GENIE_API:-https://orangegenie-api-production.up.railway.app}"
MARKER_FILE="$HOME/.claude/genie_marker"
QUEUE_FILE="$HOME/.claude/genie/pending_skills.jsonl"   # staged, not-yet-inscribed skills
RETRY_FILE="$HOME/.claude/genie/failed_skills.jsonl"    # writes that failed the network call (kept for retry)
RECEIPT_FILE="$HOME/.claude/genie/inscribed.log"        # what actually landed (greet.sh reports this next wake)
DRAIN_CAP="${GENIE_DRAIN_CAP:-5}"                        # max skills inscribed per drain (keeps the Stop hook bounded)

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
    mkdir -p "$(dirname "$RECEIPT_FILE")"
    if out="$(post "skill.$slug" "SKILL" "⬢" "$summary" "$body")"; then
      h="$(printf '%s' "$out" | grep -o '"height":[0-9]*' | head -1)"
      echo "⬢ inscribed skill '$slug' as $(marker). $h"
      printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$h" >> "$RECEIPT_FILE"
    else
      # LOUD failure (was silently `exit 0`): stage for retry so the work is never lost.
      echo "✗ skill '$slug' did NOT land (chain write failed) — staged for retry." >&2
      printf '{"slug":%s,"summary":%s,"body":%s}\n' "$(esc "$slug")" "$(esc "$summary")" "$(esc "$body")" >> "$RETRY_FILE"
      exit 0   # never break the user's session over a chain hiccup
    fi
    ;;
  queue)
    # STAGE a skill locally — instant, offline-safe, cannot fail. The Stop hook drains it later.
    slug="${2:?usage: chain.sh queue <slug> <summary> [body]}"
    summary="${3:?usage: chain.sh queue <slug> <summary> [body]}"
    body="${4:-}"
    mkdir -p "$(dirname "$QUEUE_FILE")"
    printf '{"slug":%s,"summary":%s,"body":%s}\n' "$(esc "$slug")" "$(esc "$summary")" "$(esc "$body")" >> "$QUEUE_FILE"
    echo "⬢ staged skill '$slug' — it inscribes to the chain when this session ends."
    ;;
  drain)
    # Inscribe everything staged (queue + any prior failures), under the marker. Idempotent: the
    # server dedups by src_id (skill.<slug>), so a re-drain never double-writes. Bounded by DRAIN_CAP.
    mkdir -p "$(dirname "$QUEUE_FILE")"
    src_lines=""
    [ -s "$QUEUE_FILE" ] && src_lines="$(cat "$QUEUE_FILE")"
    [ -s "$RETRY_FILE" ] && src_lines="$(printf '%s\n%s' "$src_lines" "$(cat "$RETRY_FILE")")"
    src_lines="$(printf '%s\n' "$src_lines" | grep -v '^[[:space:]]*$' || true)"
    [ -z "$src_lines" ] && exit 0     # nothing staged → silent no-op (no noise on trivial sessions)
    : > "$RETRY_FILE"                 # rebuild retry from this run's failures only
    ok=0; fail=0; n=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      n=$((n+1)); [ "$n" -gt "$DRAIN_CAP" ] && { printf '%s\n' "$line" >> "$RETRY_FILE"; continue; }
      slug="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("slug",""))' 2>/dev/null)"
      summary="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("summary",""))' 2>/dev/null)"
      body="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("body",""))' 2>/dev/null)"
      [ -z "$slug" ] && continue
      if out="$(post "skill.$slug" "SKILL" "⬢" "$summary" "$body")"; then
        ok=$((ok+1))
        printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$(printf '%s' "$out" | grep -o '"height":[0-9]*' | head -1)" >> "$RECEIPT_FILE"
      else
        fail=$((fail+1)); printf '%s\n' "$line" >> "$RETRY_FILE"
      fi
    done <<EOF
$src_lines
EOF
    : > "$QUEUE_FILE"                 # queue fully consumed; failures live in RETRY_FILE for next drain
    [ "$ok" -gt 0 ] && echo "⬢ inscribed $ok skill(s) under $(marker)."
    [ "$fail" -gt 0 ] && echo "✗ $fail skill(s) failed to land — kept for retry next session." >&2
    exit 0
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
    echo "usage: chain.sh {login | skill <slug> <summary> [body] | queue <slug> <summary> [body] | drain | search <query> [limit] | mine [limit] | whoami}"; exit 1;;
esac
