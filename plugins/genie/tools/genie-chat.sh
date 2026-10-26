#!/usr/bin/env bash
# genie-chat.sh — talk to YOUR local genie-1, in the terminal. No Claude. No account. No login.
#
# genie-1 is your own AI, running on your machine, keyless. "Logging in" isn't a thing — you just
# run this and start talking. It ensures the local brain is up, then opens a chat. If the local
# model isn't available yet (no Ollama), it says so honestly and points you at the fix — it never
# pretends to answer.
#
#   genie-chat.sh                 # open a chat
#   genie-chat.sh "one question"  # ask once and exit
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${GENIE_LLM_PORT:-8756}"
API="http://127.0.0.1:$PORT"

up() { curl -s --max-time 3 "$API/v1/models" >/dev/null 2>&1; }

# Make sure genie-1 is running (idempotent). If it can't come up, be honest about why.
if ! up; then
  [ -x "$HERE/genie-serve.sh" ] && bash "$HERE/genie-serve.sh" >/dev/null 2>&1 || true
fi
if ! up; then
  echo "🧞 Your local AI isn't running yet."
  command -v ollama >/dev/null 2>&1 \
    && echo "   It's installed but not started — try again in a moment." \
    || echo "   You need Ollama for the free local model: https://ollama.com/download"
  echo "   (Or add your own API key to use a hosted model instead.)"
  exit 1
fi

# One thread of history so it's a conversation, not one-shots. History lives only in this process.
HIST='[]'
ask() {  # ask "<text>" -> prints genie-1's reply, appends both turns to HIST
  local msg="$1"
  HIST="$(python3 - "$HIST" "$msg" <<'PY'
import json,sys
hist=json.loads(sys.argv[1]); hist.append({"role":"user","content":sys.argv[2]})
print(json.dumps(hist))
PY
)"
  local payload; payload="$(python3 -c 'import json,sys;print(json.dumps({"model":"genie-1","messages":json.loads(sys.argv[1])}))' "$HIST")"
  local reply
  reply="$(printf '%s' "$payload" | curl -s --max-time 120 "$API/v1/chat/completions" -H 'content-type: application/json' -d @- \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["choices"][0]["message"]["content"])
except Exception: print("(no answer — try again)")')"
  printf '%s\n' "$reply"
  HIST="$(python3 - "$HIST" "$reply" <<'PY'
import json,sys
hist=json.loads(sys.argv[1]); hist.append({"role":"assistant","content":sys.argv[2]})
print(json.dumps(hist))
PY
)"
}

# one-shot mode
if [ "$#" -gt 0 ]; then ask "$*"; exit 0; fi

# interactive REPL
echo "🧞 genie-1 — your local AI. Type to chat. 'exit' to quit."
while true; do
  printf '\n\033[38;5;208myou ›\033[0m '
  IFS= read -r line || break
  case "$line" in ""|" ") continue;; exit|quit|":q") break;; esac
  printf '\033[38;5;250mgenie ›\033[0m '
  ask "$line"
done
echo "🧞 later."
