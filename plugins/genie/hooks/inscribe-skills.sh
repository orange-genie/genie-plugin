#!/usr/bin/env bash
# inscribe-skills.sh — Stop hook. The moment that makes "everyone puts their skills on chain" real.
#
# THE FIX: skill-writing used to be a soft instruction the model read mid-task and usually skipped,
# so real users inscribed ~nothing (the live chain proved it: 2 SKILL blocks, both test pokes).
# Now the model only has to STAGE a skill during the session (`chain.sh queue …` — a trivial local
# append). This hook fires deterministically when the session ends and does the real network write
# (`chain.sh drain`). Propose (model) is decoupled from write (hook), so a staged skill ALWAYS lands.
#
# Guarantees & guardrails:
#   • Bounded: chain.sh drain caps at GENIE_DRAIN_CAP skills, curl --max-time per write. No hang.
#   • NEVER backgrounds (no & / nohup / disown) — honors the no-backgrounding-in-hooks rule.
#   • Empty queue → instant silent no-op (no noise on trivial sessions).
#   • Always exits 0 and never emits a block decision → cannot loop or wedge the session.
#   • Failures are staged for retry (chain.sh handles it), never lost, never silent.
set -euo pipefail

# Capture the hook's stdin JSON (transcript_path, stop_hook_active, …) for the catch-net below.
HOOK_IN="$(cat 2>/dev/null || true)"

GENIE_DIR="$HOME/.claude/genie"
QUEUE_FILE="$GENIE_DIR/pending_skills.jsonl"
FLAG_FILE="$GENIE_DIR/unstaged_work.json"     # "did real work, staged nothing" → greet nudges next wake

# Did the model stage anything this session? (check BEFORE drain empties the queue)
had_queue=0; [ -s "$QUEUE_FILE" ] && had_queue=1

# Prefer the self-updated HTTPS wire so the newest drain logic runs even without a /plugin update;
# fall back to the copy bundled with this plugin version.
CHAIN="$GENIE_DIR/chain.sh"
if [ ! -f "$CHAIN" ]; then
  CHAIN="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/tools/chain.sh"
fi

# 1) Deterministic WRITE of everything staged. Bounded by chain.sh; belt-and-suspenders wall-time cap.
if [ -f "$CHAIN" ]; then
  if command -v timeout >/dev/null 2>&1; then
    timeout 45 bash "$CHAIN" drain 2>&1 || true
  else
    bash "$CHAIN" drain 2>&1 || true
  fi
fi

# 2) CATCH-NET (writing no longer depends on the ended session): if NOTHING was staged but the
# session actually built things (Write/Edit/NotebookEdit in the transcript), flag it. We do NOT
# fabricate skill cards here — auto-guessing junk onto a permanent, append-only chain violates the
# quality gate. Instead we leave a breadcrumb; next wake, greet.sh tells the (LLM) Genie to read the
# transcript tail and stage what's genuinely reusable — quality check intact, but the miss is caught.
if [ "$had_queue" = "0" ] && [ -n "$HOOK_IN" ]; then
  tpath="$(printf '%s' "$HOOK_IN" | python3 -c 'import json,sys;
try: print(json.load(sys.stdin).get("transcript_path",""))
except Exception: print("")' 2>/dev/null)"
  if [ -n "$tpath" ] && [ -f "$tpath" ] \
     && grep -qE '"name"[[:space:]]*:[[:space:]]*"(Write|Edit|NotebookEdit)"' "$tpath" 2>/dev/null; then
    mkdir -p "$GENIE_DIR"
    printf '{"transcript":%s,"ts":"%s"}\n' \
      "$(printf '%s' "$tpath" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || printf '"%s"' "$tpath")" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$FLAG_FILE"
  fi
fi

exit 0
