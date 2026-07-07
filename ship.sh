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
# genie-plugin MUST stay PUBLIC (AUTO, 2026-07-07). The self-update
# (raw.githubusercontent) + `/plugin marketplace add` install path only
# work on a PUBLIC repo. The credit drain that once motivated privacy was
# the Helius Atlas WebSocket, NOT repo scrapers — so there's no cost reason
# to hide it. This snaps it back public if a window ever re-privatizes it.
# The SAUCE stays out of this repo (server/wildflower-genesis/PMBot_v1 are
# separate PRIVATE repos); keep it that way — scrub before committing here.
vis="$(gh repo view orange-genie/genie-plugin --json visibility -q .visibility 2>/dev/null | tr 'A-Z' 'a-z' || echo '?')"
if [ "$vis" != "public" ]; then
  echo "⚠ repo visibility was '$vis' — forcing back to PUBLIC (install needs it)" >&2
  gh repo edit orange-genie/genie-plugin --visibility public --accept-visibility-change-consequences >/dev/null 2>&1 \
    && echo "✓ visibility re-asserted: public" \
    || echo "✗ could not force public — do it by hand" >&2
else
  echo "✓ visibility ok: public"
fi
