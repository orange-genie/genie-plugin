#!/usr/bin/env bash
# bot.sh — the Bot Father, over the wire. Hand it a BotFather token; get back a LIVE bot.
#
# WHY THIS EXISTS: the botfactory SKILL.md used to tell an installed Genie to run
# `python3 ~/Genie/bots/botfactory/factory.py` — a path that exists on exactly one machine on
# earth. Every outside /genie:botfactory was a file-not-found. The factory is a real hosting
# service; it just was never exposed. Now it is: this script posts the user's token to the API,
# the server encrypts it and parks it, a supervisor node claims it and runs the poller. The
# user installs nothing.
#
# THE TOKEN IS THE USER'S SECRET. It is sent once, over TLS, and never printed, never logged,
# never written to a file here, never put on the chain. Same bar as our own keys.
#
# Usage:
#   bot.sh new <botfather-token> ["what the bot is for"]   # provision a live bot
#   bot.sh mine                                            # the bots you own
#   bot.sh stop <bot_id>                                   # stop one of yours
set -euo pipefail

API="${GENIE_API:-https://orangegenie-api-production.up.railway.app}"

marker() {
  if [ -f "$HOME/.claude/genie_marker" ]; then cat "$HOME/.claude/genie_marker"
  else echo "$(id -un | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-').agent"; fi
}

jqget() { python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(d.get(sys.argv[1],"") if isinstance(d,dict) else "")' "$1"; }

case "${1:-help}" in
  new)
    TOKEN="${2:?usage: bot.sh new <botfather-token> [purpose]}"
    PURPOSE="${3:-}"
    OUT="$(python3 - "$API" "$(marker)" "$TOKEN" "$PURPOSE" <<'PY'
import json,sys,urllib.request,ssl
try:
    import certifi; ctx=ssl.create_default_context(cafile=certifi.where())
except Exception: ctx=ssl.create_default_context()
api,marker,token,purpose=sys.argv[1:5]
body=json.dumps({"marker":marker,"token":token,"purpose":purpose}).encode()
req=urllib.request.Request(api+"/api/bot/provision",data=body,
                           headers={"Content-Type":"application/json"})
try:
    print(json.dumps(json.loads(urllib.request.urlopen(req,timeout=30,context=ctx).read())))
except urllib.error.HTTPError as e:
    print(json.dumps(json.loads(e.read() or b'{"error":"provision failed"}')))
except Exception as e:
    print(json.dumps({"error":str(e)}))
PY
)"
    ERR="$(printf '%s' "$OUT" | jqget error)"
    if [ -n "$ERR" ]; then echo "⚠ $ERR"; exit 1; fi
    echo "🤖 $(printf '%s' "$OUT" | jqget bot) — $(printf '%s' "$OUT" | jqget message)"
    ;;

  mine)
    curl -fsS --max-time 15 "$API/api/bot/mine?marker=$(marker)" | python3 -c 'import json,sys
d=json.load(sys.stdin)
bots=d.get("bots",[])
if not bots: print("no hosted bots yet — bot.sh new <token>"); raise SystemExit
for b in bots:
    print(f"  🤖 @{b[\"bot_username\"]:<20} {b[\"status\"]:<9} {b.get(\"purpose\") or \"\"}")'
    ;;

  stop)
    BID="${2:?usage: bot.sh stop <bot_id>}"
    curl -fsS --max-time 15 -X POST "$API/api/bot/stop" -H 'Content-Type: application/json' \
      -d "{\"marker\":\"$(marker)\",\"bot_id\":\"$BID\"}" | python3 -c 'import json,sys
d=json.load(sys.stdin); print("🛑 stopped "+d["stopped"] if d.get("ok") else "⚠ "+str(d.get("error")))'
    ;;

  *)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
