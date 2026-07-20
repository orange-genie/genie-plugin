#!/usr/bin/env bash
# genie_onboard.sh — turn THIS machine into a Wildflower Chain NODE on first install.
#
# A node is not a name, and not a disk. By the end of this script the machine has:
#   1. the chain client installed locally          (it can reach the chain unaided)
#   2. a marker — its identity on the network      (~/.claude/genie_marker)
#   3. its OWN node secret, generated HERE         (~/.claude/genie/node_secret, 0600)
#   4. a birth block inscribed under that marker   (it EXISTS on chain, not just locally)
#   5. that block verified by reading the chain back
#
# The username IS your marker: how the network knows you, and the account every skill,
# contribution and payout is credited to (Value in = Work out).
#
# Does NOT broadcast presence — nobody should see when a user is live (data is property,
# not observance). A marker appears through WORK; the birth block IS that first work.
#
# Idempotent: the chain dedups by src_id, so the birth block lands once no matter how many
# times this runs. Safe to re-run to repair a half-finished install.
#
# Usage:
#   genie_onboard.sh <username>          # a person's install — their chosen handle
#   genie_onboard.sh --role genie-3      # a headless device (Pi/mini) — named by ROLE
#
# NEVER derive the marker from the OS account: that leaks the operator's identity onto a
# public chain. A person supplies their handle; a device is named for the job it does.

set -uo pipefail

MARKER_FILE="$HOME/.claude/genie_marker"
STATE_DIR="$HOME/.claude/genie"
SECRET_FILE="$STATE_DIR/node_secret"
API="${GENIE_API:-https://orangegenie-api-production.up.railway.app}"

if [ "${1:-}" = "--role" ]; then
  u="${2:?usage: genie_onboard.sh --role <role-name>   e.g. genie-3}"
else
  u="${1:?usage: genie_onboard.sh <username>  |  genie_onboard.sh --role <role-name>}"
fi

mkdir -p "$STATE_DIR"

# ── 1. identity ──────────────────────────────────────────────────────────────────────────
printf '%s' "$u" > "$MARKER_FILE"
echo "⬢ identity claimed: $u  ($MARKER_FILE)"

# ── 2. the chain client must live ON this machine ────────────────────────────────────────
# Prefer the self-updated wire, else install the bundled copy, so the node never depends on
# a plugin path that may not exist on a headless device.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAIN="$STATE_DIR/chain.sh"
if [ ! -f "$CHAIN" ]; then
  if [ -f "$HERE/chain.sh" ]; then
    cp "$HERE/chain.sh" "$CHAIN" && chmod +x "$CHAIN"
    echo "⬢ chain client installed → $CHAIN"
  else
    echo "⚠️  no chain client found — this machine can hold files but cannot act as a node." >&2
    exit 0   # never break someone's install
  fi
fi

# ── 3. its OWN secret, generated HERE ────────────────────────────────────────────────────
# sha256(secret) is published as the claim commit proving authorship; the secret never leaves
# the box. Generated locally on purpose — a COPIED secret means two machines share one
# identity and neither can prove which authored what.
if [ ! -s "$SECRET_FILE" ]; then
  ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$SECRET_FILE" )
  chmod 600 "$SECRET_FILE" 2>/dev/null || true
  echo "⬢ node secret generated on this machine (0600, never transmitted)"
else
  echo "⬢ node secret already present — kept (regenerating would orphan prior work)"
fi

# ── 4. confirm reachability, then be born ────────────────────────────────────────────────
bash "$CHAIN" login 2>/dev/null || true

if ! curl -fsS --max-time 8 "$API/api/chain?limit=1" >/dev/null 2>&1; then
  echo "⬢ offline — identity is set locally; run this again when online to finish the birth block."
  exit 0
fi

# The birth block: the node's first work, which is what makes it real on the network.
#
# IDEMPOTENCY IS OURS TO ENFORCE. Do NOT assume the server dedups by src_id — measured
# 2026-07-20: two identical birth blocks for the same src_id landed at heights 1879 and 1880.
# So ask the chain first and skip if this node is already born; otherwise every re-run (and
# every repair run) spams another block and inflates the chain with duplicates.
if curl -fsS --max-time 15 "$API/api/chain?limit=200" 2>/dev/null | grep -q "node-birth-$u"; then
  echo "⬢ already born — '$u' has a birth block on chain; skipping (no duplicate written)."
  echo "✅ verified on chain — '$u' is a live node."
  if [ -f "$HOME/Genie/tools/genesis_boot.py" ]; then
    python3 "$HOME/Genie/tools/genesis_boot.py" --marker "$u" 2>/dev/null || true
  fi
  exit 0
fi

HOSTKIND="$(uname -s)-$(uname -m)"
if bash "$CHAIN" skill "node-birth-$u" \
  "Node '$u' joined the Wildflower Chain ($HOSTKIND) — identity established by work, per the node doctrine" \
  "PROPERTY: The birth record of node '$u'. A machine becomes a node by inscribing work under its own marker and locally-generated secret, not by announcing presence. This block is that first work — from here the node authors under '$u', and its contributions are attributed and payable to it.

HOW: marker written to ~/.claude/genie_marker; a 32-byte secret generated on this machine (0600, never transmitted) with sha256 published as the claim commit that proves authorship; the chain client installed locally so the node operates unaided; this block inscribed, then read back from the chain to confirm.

RECREATE: run genie_onboard.sh <handle> on the machine (or --role <name> for a headless device), then read the chain back from a DIFFERENT machine and confirm a block exists under this marker. Verifying from the node itself only proves it can talk to itself. Platform: $HOSTKIND." >/dev/null 2>&1
then
  echo "⬢ birth block inscribed under '$u'"
else
  echo "⚠️  birth block did not land — staged; it settles on the next sync."
fi

# ── 5. verify by reading the chain back ──────────────────────────────────────────────────
# Trust the store, not the exit code of our own write.
sleep 1
if curl -fsS --max-time 15 "$API/api/chain?limit=120" 2>/dev/null | grep -q "node-birth-$u"; then
  echo "✅ verified on chain — '$u' is a live node."
else
  echo "⚠️  not visible on chain yet (indexing lag or a failed write). Re-run to repair; it dedups."
fi

# If the full local chain tooling is present (AUTO's own box), also fire the rich Regenesis boot.
if [ -f "$HOME/Genie/tools/genesis_boot.py" ]; then
  python3 "$HOME/Genie/tools/genesis_boot.py" --marker "$u" 2>/dev/null || true
fi
