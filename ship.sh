#!/usr/bin/env bash
# ship.sh — the ONE command to release a Genie plugin update to everyone.
#
# Why this exists (verified doctrine, card: ship-claude-code-plugin):
#   Claude Code uses the `version` field in plugin.json as the update cache key.
#   Push new commits WITHOUT bumping version → users' `/plugin update` says "already
#   latest" → silent non-delivery. So every intentional ship MUST bump the version.
#   This script makes that automatic: bump patch → commit → push. Clients with
#   autoUpdate:true pull it at next session start (then a /reload-plugins prompt).
#
#   Gated, not SHA-based: WIP lives on branches; only running `ship` on main ships.
#   Runs SYNCHRONOUSLY, foregrounded — no nohup/&/disown (see the backgrounding guard).
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PJ="$REPO/plugins/genie/.claude-plugin/plugin.json"
[ -f "$PJ" ] || { echo "✗ plugin.json not found at $PJ" >&2; exit 1; }

cd "$REPO"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
if [ "$branch" != "main" ]; then
  echo "✗ on branch '$branch', not 'main'. Ship only from main (WIP stays on branches)." >&2
  exit 1
fi

# Bump patch version (x.y.z -> x.y.z+1) with python (no jq dependency).
read -r old new < <(python3 - "$PJ" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
old = d.get("version", "0.0.0")
a, b, c = (old.split(".") + ["0", "0", "0"])[:3]
new = f"{a}.{b}.{int(c)+1}"
d["version"] = new
json.dump(d, open(p, "w"), indent=2)
open(p, "a").write("\n")
print(old, new)
PY
)

echo "  plugin.json  $old -> $new"
git add -A
git commit -q -m "ship: $new" || { echo "✗ nothing to commit" >&2; exit 1; }
git push -q origin main
echo "✓ shipped v$new -> autoUpdate clients pull it next session"

# ── VISIBILITY GUARD ─────────────────────────────────────────────
# genie-plugin MUST stay PRIVATE (AUTO, 2026-07-06). The self-update /
# marketplace-add path tempts windows to flip it public — this snaps it
# back on every ship so a drift can never silently persist. If we ever
# decide to distribute publicly, change this line deliberately, once.
vis="$(gh repo view orange-genie/genie-plugin --json visibility -q .visibility 2>/dev/null | tr 'A-Z' 'a-z' || echo '?')"
if [ "$vis" != "private" ]; then
  echo "⚠ repo visibility was '$vis' — forcing back to PRIVATE" >&2
  gh repo edit orange-genie/genie-plugin --visibility private --accept-visibility-change-consequences >/dev/null 2>&1 \
    && echo "✓ visibility re-asserted: private" \
    || echo "✗ could not force private — do it by hand" >&2
else
  echo "✓ visibility ok: private"
fi
