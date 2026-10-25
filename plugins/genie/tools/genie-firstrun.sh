#!/usr/bin/env bash
# genie-firstrun.sh — the guided first-run. Feels like a few quick questions, then it does the thing.
# Everyone is on-chain from first use; one Genie carries across every surface (marker = the identity).
#
# Chains pieces that already exist — builds nothing new:
#   genie-serve.sh (free local LLM) · genie_onboard.sh (identity + on-chain) · install_launcher.sh (terminal)
#
# The app drives the menu with its own UI and passes answers via GENIE_ANSWERS (comma list). In a
# terminal it asks interactively. Either way the FLOW is identical, so this file IS the onboarding spec.
#
#   genie-firstrun.sh [username]
#   GENIE_ANSWERS="1,2,3" genie-firstrun.sh alice     # scripted (app / test): answers fed in order
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_FILE="$HOME/.claude/genie_marker"
LLM_PORT="${GENIE_LLM_PORT:-8756}"
BAZAAR_URL="https://orangegenie.bot/bazaar"
USERNAME="${1:-}"
# FREE_MVP: the first public build is the free local-Genie surface — the money layer (wallet
# create, trading) is NOT shipped, so onboarding must not prompt for it. Set GENIE_FREE_MVP=0 for
# the full build. Keeps the flow honest: never offer what the app doesn't have.
FREE_MVP="${GENIE_FREE_MVP:-1}"

llm_up() { curl -s --max-time 3 "http://127.0.0.1:$LLM_PORT" >/dev/null 2>&1 || nc -z 127.0.0.1 "$LLM_PORT" >/dev/null 2>&1; }

# ── ask: numbered menu. Interactive by default; scripted via GENIE_ANSWERS (comma-separated, in order).
_ANS_I=0
ask() {  # ask "Question" "opt1" "opt2" ...  -> echoes chosen index to REPLY_IDX
  local q="$1"; shift; local opts=("$@") i
  echo "❔ $q" >&2
  for i in "${!opts[@]}"; do echo "   $((i+1))) ${opts[$i]}" >&2; done
  if [ -n "${GENIE_ANSWERS:-}" ]; then
    _ANS_I=$((_ANS_I+1)); REPLY_IDX="$(echo "$GENIE_ANSWERS" | cut -d, -f$_ANS_I)"
    echo "   → ${opts[$((REPLY_IDX-1))]:-?}" >&2
  else
    local r; read -rp "   choose [1-${#opts[@]}]: " r; REPLY_IDX="${r:-1}"
  fi
}

echo "🧞  Welcome to Orange Genie."
echo

# ── 1. Working local AI, free, private. ──
echo "① Bringing up your AI (free, runs on your machine)…"
echo "   first run downloads the model once (~1.3GB) — after that it's instant and offline."
bash "$HERE/genie-serve.sh" 2>&1 | sed 's/^/   /' || echo "   (add a key later for a hosted model)"

# ── 2. One identity, on chain from first use. ──
if [ -s "$MARKER_FILE" ]; then
  echo "② On chain as '$(cat "$MARKER_FILE")' — welcome back."
else
  echo "② Setting up your Genie (this is your one account, everywhere)…"
  if [ -n "$USERNAME" ]; then bash "$HERE/genie_onboard.sh" "$USERNAME" >/dev/null 2>&1
  else bash "$HERE/genie_onboard.sh" genie >/dev/null 2>&1; fi
  echo "   ✓ you're on the OrangeGenie Mesh"
fi

# ── 3. Terminal surface (same identity). Install the standalone CLI to a stable path so the
#       `genie` command resolves it with no Claude, then wire the launcher. ──
mkdir -p "$HOME/.claude/genie"
cp "$HERE/genie-chat.sh" "$HERE/genie-serve.sh" "$HOME/.claude/genie/" 2>/dev/null && chmod +x "$HOME/.claude/genie/"*.sh 2>/dev/null
bash "$HERE/install_launcher.sh" --yes >/dev/null 2>&1 && echo "③ Terminal ready — type 'genie' anywhere (no login)."

# ── 4. It explains itself: genie-1 is live, so it greets + covers BYOK in its own words. ──
if llm_up; then
  echo; echo "④ Your Genie:"
  export GENIE_SYS='You ARE genie-1, a FREE LOCAL AI that just installed on the users own machine — you run on their hardware, nothing leaves the computer. Facts, never invent: you are free + private by default (local model, no key); BYOK (bring your own key) is the OPTIONAL upgrade where they paste their own OpenAI/Groq/Anthropic key to reach a bigger cloud model on their own account/bill, used only when they choose; either way you read the shared OrangeGenie Mesh so you keep learning. Greet the new user in 3 short warm sentences, first person, no jargon.'
  python3 -c 'import json,os;print(json.dumps({"model":"genie-1","messages":[{"role":"system","content":os.environ["GENIE_SYS"]},{"role":"user","content":"Hi, I just installed you. What are you and do I need to pay for anything?"}]}))' > /tmp/genie_greet.json
  curl -s --max-time 60 "http://127.0.0.1:$LLM_PORT/v1/chat/completions" -H 'content-type: application/json' -d @/tmp/genie_greet.json \
    | python3 -c 'import json,sys
try: print("   "+json.load(sys.stdin)["choices"][0]["message"]["content"].replace(chr(10),chr(10)+"   "))
except Exception: print("   Hi — I am your free, private AI. Ask me anything to begin.")'
fi

# ── 5. Guided questions → then it acts. ──
echo
echo "⑤ A couple quick questions:"
ask "Already have an AI agent you want to bring in?" "Yes, import it" "No, I'm new" "Not now"
if [ "${REPLY_IDX:-2}" = "1" ]; then
  echo "   → Point it at your Genie — that's the whole import (it keeps everything, gains the chain):"
  echo "       base_url = http://localhost:$LLM_PORT/v1   ·   model = genie-1"
  ask "Is that agent already set up for agentic work (it can use tools / take actions)?" "Yes" "No"
  if [ "${REPLY_IDX:-1}" = "2" ]; then
    if [ "$FREE_MVP" = "1" ]; then
      # Free MVP ships no wallet/trading — don't offer what the app doesn't have.
      echo "   → It'll run tools right away. Wallet + trading unlock later when you enable them in the Bazaar."
    else
      ask "To let it act (and eventually trade), it needs a wallet. Wallet:" "Create one for me (Turnkey)" "Import my own" "Not now"
      case "${REPLY_IDX:-3}" in
        1) echo "   → I'll create a non-custodial Turnkey wallet keyed to you (you approve every move).";;
        2) echo "   → You can paste your wallet in Settings → Wallet anytime.";;
        *) echo "   → No wallet for now — you can add one whenever.";;
      esac
    fi
  fi
fi

# ── 6. What it can do out of the box. ──
echo
echo "⑥ What your Genie can already do:"
echo "   • Email — triage your inbox, draft replies      • Meetings — notes + action items"
echo "   • See your screen — ask about what's on it       • Build — spin up your own bots"
echo "   • Markets — on-chain charts + flow intel (read)  • Video — captioned promo clips"
echo "   • Sales/Upwork — outreach + proposals            • Recall — search everything the chain knows"

# ── 7. The Bazaar — enable more, find what's trending. ──
echo
echo "⑦ Want more? Turn on extra bots in the Bazaar — it's like an app store for agents:"
echo "   browse what's popular and trending, enable only what you need."
echo "   → $BAZAAR_URL"
ask "Open the Bazaar now?" "Yes, take me there" "Maybe later"
[ "${REPLY_IDX:-2}" = "1" ] && { command -v open >/dev/null && open "$BAZAAR_URL" 2>/dev/null; echo "   → opening the Bazaar…"; }

MARK="$( [ -s "$MARKER_FILE" ] && cat "$MARKER_FILE" || echo genie )"
echo
echo "✅ You're set. One Genie — free + local, on chain as '$MARK', same account on desktop, phone, and terminal."
