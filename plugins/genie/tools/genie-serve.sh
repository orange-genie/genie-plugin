#!/usr/bin/env bash
# genie-serve.sh — stand up the FREE LOCAL LLM (genie-1) on this machine.
#
# This is what the OrangeGenie app runs on launch. It makes "download the app → free local AI" real:
#   1. make sure Ollama is running (the local base model — no key, no egress)
#   2. make sure a model is pulled (small one if the box is bare)
#   3. start genie_llm.py on :8756 — the OpenAI-compatible endpoint that adds chain grounding
#
# genie-1 then runs FREE + LOCAL: no API key, tokens never leave the machine. Idempotent — if it's
# already up, it does nothing. Point any assistant at http://localhost:8756/v1 (model "genie-1").
#
#   genie-serve.sh            # ensure everything is up (safe to run repeatedly)
#   genie-serve.sh --status   # report what's up, start nothing
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_PORT="${GENIE_LLM_PORT:-8756}"
OLLAMA_PORT=11434
# a small, fast default so a bare machine works out of the box; override with GENIE_LOCAL_MODEL.
MODEL="${GENIE_LOCAL_MODEL:-qwen2.5:1.5b}"   # small default (~1GB), Apache-2.0 weights: we can sell it as Genie 1
LOG="$HOME/.claude/genie/genie-llm.log"
mkdir -p "$(dirname "$LOG")"

# Resolve the ollama binary: system PATH first, then a copy bundled inside the app (so a downloader
# with no Homebrew still has it). ensureLocalLLM() in the app runs us from Resources/tools.
OLLAMA=""
for c in "$(command -v ollama 2>/dev/null)" "$HERE/ollama" "$HERE/../bin/ollama" "$HERE/../Resources/bin/ollama"; do
  [ -n "$c" ] && [ -x "$c" ] && { OLLAMA="$c"; break; }
done

up() { curl -s --max-time 3 "http://127.0.0.1:$1" >/dev/null 2>&1 || nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

if [ "${1:-}" = "--status" ]; then
  echo "ollama  ($OLLAMA_PORT): $(up $OLLAMA_PORT && echo UP || echo down)"
  echo "genie-1 ($LLM_PORT): $(up $LLM_PORT && echo UP || echo down)"
  exit 0
fi

# 0. Ollama must be available (PATH or bundled). If not, we can't run the local base — say so.
if [ -z "$OLLAMA" ]; then
  echo "⚠️  Ollama isn't available — the free local model needs it. Install: https://ollama.com/download" >&2
  echo "    (genie-1 will still work if you point it at a hosted model with your own key.)" >&2
  exit 1
fi

# 1. Ensure Ollama is serving.
if ! up "$OLLAMA_PORT"; then
  echo "⬢ starting ollama…"
  nohup "$OLLAMA" serve >/tmp/ollama.log 2>&1 &
  for _ in $(seq 1 20); do up "$OLLAMA_PORT" && break; sleep 0.5; done
fi

# 2. Ensure at least one model exists; pull the small default if the box is bare.
have_model="$("$OLLAMA" list 2>/dev/null | awk 'NR>1{print $1}' | head -1)"
if [ -z "$have_model" ]; then
  echo "⬢ no local model — pulling $MODEL (one-time, ~1GB)…"
  "$OLLAMA" pull "$MODEL" >/dev/null 2>&1 && have_model="$MODEL"
fi
[ -z "$have_model" ] && { echo "⚠️  couldn't get a local model. Run: ollama pull $MODEL" >&2; exit 1; }

# 3. Start genie-1 (idempotent — skip if already listening).
if up "$LLM_PORT"; then
  echo "✓ genie-1 already live on :$LLM_PORT"
  exit 0
fi
echo "⬢ starting genie-1 on :$LLM_PORT  (local · free · model=$have_model)"
GENIE_UPSTREAM="http://localhost:$OLLAMA_PORT/v1" \
GENIE_UPSTREAM_MODEL="$have_model" \
GENIE_LLM_PORT="$LLM_PORT" \
  nohup python3 "$HERE/genie_llm.py" >>"$LOG" 2>&1 &

for _ in $(seq 1 20); do up "$LLM_PORT" && break; sleep 0.5; done
if up "$LLM_PORT"; then
  echo "✅ genie-1 live → http://localhost:$LLM_PORT/v1  (model: genie-1, free, zero-egress)"
else
  echo "⚠️  genie-1 didn't come up — see $LOG" >&2; exit 1
fi
