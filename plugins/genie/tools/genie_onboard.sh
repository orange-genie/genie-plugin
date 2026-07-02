#!/usr/bin/env bash
# genie_onboard.sh — claim a Wildflower Chain identity on first install.
# The username IS your marker: how the network knows you and the account every skill,
# contribution, and payout you earn is credited to (Value in = Work out).
# Portable: always writes the marker; fires the on-chain logon handshake only where the
# local chain tooling is present (never errors on a fresh machine).
#
# Usage:  genie_onboard.sh <username>
set -euo pipefail
u="${1:?usage: genie_onboard.sh <username>}"
printf '%s' "$u" > "$HOME/.claude/genie_marker"
echo "⬢ identity claimed: $u  (~/.claude/genie_marker)"
if [ -f "$HOME/Genie/tools/genesis_boot.py" ]; then
  python3 "$HOME/Genie/tools/genesis_boot.py" --marker "$u" 2>/dev/null || true
fi
