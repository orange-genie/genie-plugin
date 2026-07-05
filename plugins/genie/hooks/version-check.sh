#!/usr/bin/env bash
# Genie SessionStart self-updater. Runs on every session start.
#
# The problem this fixes: Claude Code loads a plugin from a version-pinned cache and only
# repoints it on `/plugin update` + restart — and the old auto-fetch used SSH (git@github),
# which fails on any machine without your keys (i.e. everyone but AUTO). So updates never
# reached Chazz/Mike/Novo.
#
# The fix: the load-bearing wire — chain.sh (how a node writes to the shared Wildflower Chain)
# — self-updates over HTTPS into a stable per-user path (~/.claude/genie/) on every session.
# HTTPS raw works on every machine, needs no auth, and is independent of the plugin version
# system. Once ANY install has this hook, the chain wire auto-updates for that user forever —
# no /plugin update, no SSH. Structural plugin changes (new skills/hooks) still need
# /plugin update; for those we inject a terse HTTPS-checked nudge.
#
# Fails silent on any error or no network — never blocks a session.
set -euo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-}"
RAW="https://raw.githubusercontent.com/orange-genie/genie-plugin/main/plugins/genie"
DEST="$HOME/.claude/genie"
mkdir -p "$DEST" 2>/dev/null || true

# ── 1. Self-update the chain wire over HTTPS (the part that must reach EVERYONE) ──
# Fetch to a temp file, sanity-check it's a real script, then atomically swap in.
for f in chain.sh genie_onboard.sh rename.sh video.sh; do
  tmp="$DEST/.$f.tmp.$$"
  if curl -fsSL --max-time 6 "$RAW/tools/$f" -o "$tmp" 2>/dev/null; then
    if head -1 "$tmp" | grep -q '^#!'; then
      chmod +x "$tmp" 2>/dev/null || true
      mv -f "$tmp" "$DEST/$f" 2>/dev/null || true
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
done

# ── 1b. Self-update the CONTENT (canon/invariants/behavior) — Genie's brain, OTA ──
# These .md files ARE the wake behavior. Fetching them here means editing + pushing the
# canon/behavior reaches every machine next session with NO /plugin update. The thin loader
# SKILL.md reads ~/.claude/genie/content/ first, bundled copy as offline fallback.
mkdir -p "$DEST/content" 2>/dev/null || true
for f in canon.md invariants.md behavior.md; do
  tmp="$DEST/content/.$f.tmp.$$"
  if curl -fsSL --max-time 6 "$RAW/skills/wake/$f" -o "$tmp" 2>/dev/null; then
    if [ -s "$tmp" ]; then mv -f "$tmp" "$DEST/content/$f" 2>/dev/null || true
    else rm -f "$tmp" 2>/dev/null || true; fi
  else rm -f "$tmp" 2>/dev/null || true; fi
done

# ── 2. Structural-update nudge over HTTPS (only for changes that need /plugin update) ──
ver() { grep -o '"version"[^,]*' "$1" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }
local_v=""; [ -n "$ROOT" ] && local_v=$(ver "$ROOT/.claude-plugin/plugin.json")
remote_v=$(curl -fsSL --max-time 4 "$RAW/.claude-plugin/plugin.json" 2>/dev/null \
  | grep -o '"version"[^,]*' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
{ [ -z "$local_v" ] || [ -z "$remote_v" ]; } && exit 0

newest=$(printf '%s\n%s\n' "$local_v" "$remote_v" | sort -V | tail -1)
if [ "$remote_v" != "$local_v" ] && [ "$newest" = "$remote_v" ]; then
  msg="Orange Genie v${remote_v} is available (you are on v${local_v}); the chain wire already self-updated. For the full update, tell the user in ONE terse line: run /plugin update genie@orange-genie then restart. Nudge every window until applied; do not nag once current."
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
fi
exit 0
