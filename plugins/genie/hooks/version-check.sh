#!/usr/bin/env bash
# Genie update check — runs on SessionStart. Compares the installed plugin version
# to the published one on GitHub; if a newer one exists AND the user hasn't snoozed,
# it injects context telling Genie to OFFER an upgrade (now / remind in 24h).
# Fails silent on any error or no network — never blocks a session.
set -euo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -z "$ROOT" ] && exit 0

SNOOZE="$HOME/.claude/.genie-update-snooze"
now=$(date +%s)

# respect a 24h snooze
if [ -f "$SNOOZE" ]; then
  until=$(cat "$SNOOZE" 2>/dev/null || echo 0)
  case "$until" in (*[!0-9]*|"") until=0;; esac
  [ "$now" -lt "$until" ] && exit 0
fi

ver() { grep -o '"version"[^,]*' "$1" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }
local_v=$(ver "$ROOT/.claude-plugin/plugin.json")
remote_v=$(curl -fsSL --max-time 3 https://raw.githubusercontent.com/orange-genie/genie-plugin/main/plugins/genie/.claude-plugin/plugin.json 2>/dev/null \
  | grep -o '"version"[^,]*' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
{ [ -z "$local_v" ] || [ -z "$remote_v" ]; } && exit 0

# is remote strictly newer?
newest=$(printf '%s\n%s\n' "$local_v" "$remote_v" | sort -V | tail -1)
if [ "$remote_v" != "$local_v" ] && [ "$newest" = "$remote_v" ]; then
  msg="UPDATE AVAILABLE: Orange Genie v${remote_v} is out (you are on v${local_v}). On wake, tell the user in Genie's voice and offer two choices: (1) upgrade now — they run /plugin update genie@orange-genie then restart Claude Code; (2) remind me in 24h — if they pick this, run in Bash: echo \$(( $(date +%s) + 86400 )) > ~/.claude/.genie-update-snooze . Mention briefly what changed if known. Do not nag if they already upgraded."
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
fi
exit 0
