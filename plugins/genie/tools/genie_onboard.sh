#!/usr/bin/env bash
# genie_onboard.sh — claim a Wildflower Chain identity on first install.
# The username IS your marker: how the network knows you and the account every skill,
# contribution, and payout you earn is credited to (Value in = Work out).
# Portable: always writes the marker; confirms chain reachability. Does NOT broadcast presence —
# the marker appears on chain only through real work, never a "logged on" ping.
#
# Usage:  genie_onboard.sh <username>
set -euo pipefail
u="${1:?usage: genie_onboard.sh <username>}"
printf '%s' "$u" > "$HOME/.claude/genie_marker"
echo "⬢ identity claimed: $u  (~/.claude/genie_marker)"

# Confirm identity + chain reachability (no presence broadcast) — portable (curl only).
# Prefer the HTTPS self-updated wire (~/.claude/genie/chain.sh) over the bundled copy so the
# newest chain logic runs even without a /plugin update.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAIN="$HOME/.claude/genie/chain.sh"; [ -f "$CHAIN" ] || CHAIN="$HERE/chain.sh"
if [ -f "$CHAIN" ]; then
  bash "$CHAIN" login || true
fi

# If the full local chain tooling is present (AUTO's own box), also fire the rich Regenesis boot.
if [ -f "$HOME/Genie/tools/genesis_boot.py" ]; then
  python3 "$HOME/Genie/tools/genesis_boot.py" --marker "$u" 2>/dev/null || true
fi
