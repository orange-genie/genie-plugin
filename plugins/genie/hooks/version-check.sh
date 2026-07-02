#!/usr/bin/env bash
# Genie update — runs on SessionStart. AUTO-FETCHES the latest plugin into the marketplace
# clone (so `/plugin update` is instant), and if a newer version exists, injects a terse
# apply-nudge on every window (no snooze). Honest: Claude Code loads the plugin from its
# cache, so applying still needs `/plugin update` + restart — a hook can't hot-swap a
# running window. Fails silent on any error or no network — never blocks a session.
set -euo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -z "$ROOT" ] && exit 0

# Auto-fetch: stage the latest into the marketplace clone (best-effort, fast, silent).
MKT="$HOME/.claude/plugins/marketplaces/orange-genie"
[ -d "$MKT/.git" ] && git -C "$MKT" pull --ff-only --quiet 2>/dev/null || true

ver() { grep -o '"version"[^,]*' "$1" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }
local_v=$(ver "$ROOT/.claude-plugin/plugin.json")
remote_v=$(curl -fsSL --max-time 3 https://raw.githubusercontent.com/orange-genie/genie-plugin/main/plugins/genie/.claude-plugin/plugin.json 2>/dev/null \
  | grep -o '"version"[^,]*' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
{ [ -z "$local_v" ] || [ -z "$remote_v" ]; } && exit 0

newest=$(printf '%s\n%s\n' "$local_v" "$remote_v" | sort -V | tail -1)
if [ "$remote_v" != "$local_v" ] && [ "$newest" = "$remote_v" ]; then
  msg="Orange Genie v${remote_v} is staged (you are on v${local_v}). On wake, tell the user in ONE terse line: run /plugin update genie@orange-genie then restart to apply. No snooze — nudge every window until applied. Do not nag once they are current."
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
fi
exit 0
