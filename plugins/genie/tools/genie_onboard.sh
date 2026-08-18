#!/usr/bin/env bash
# genie_onboard.sh — turn THIS machine into an OrangeGenie Mesh NODE on first install.
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
# QUALIFY ONCE, AT CLAIM TIME. The marker file used to hold whatever the user typed ("genie-2"),
# while the chain only accepts and stores a qualified handle ("genie-2.agent") — so every caller
# downstream had to remember to convert, and the ones that forgot compared a raw marker against a
# qualified src and silently found nothing (`mine` reported "nothing under your marker yet" to
# users with real work on chain; `claim` sent a bare name the server's MARKER_RE rejected).
# The name is normalized here, at the single moment it is claimed, so nothing downstream converts.
case "$u" in
  ""|"genie"|"Genie") u="genie" ;;                    # free commons author (bare literal)
  *.agent|*.wtf|*.com|*.eth|*.bot) : ;;               # already a qualified CHOSEN handle
  *) u="${u}.agent" ;;                                # qualify a bare CHOSEN handle
esac
# REFUSE A NAME THE CHAIN WILL REFUSE — here, while the user is still typing.
# chain.sh post() fail-closes if the marker's local-part equals this machine's OS account
# (publishing it would leak a private login onto the PUBLIC chain). That guard is right, but it
# fires LATER, at inscribe time, where its message used to be discarded — so the user picked a
# name, was told "identity claimed", and only their work silently never landed. Measured
# 2026-08-17: a new node onboarded under a marker equal to its WSL login and stayed invisible.
# Naming yourself after your computer account is the most natural thing a person does, so this
# has to be caught at the moment of choosing, not after a failed write.
_oslogin="$(id -un 2>/dev/null || true)"
_localpart="${u%%.*}"
if [ -n "$_oslogin" ] && [ "$_localpart" = "$_oslogin" ]; then
  echo "⛔ '$_localpart' is this computer's login name." >&2
  echo "   Publishing it would put your private account name on the PUBLIC chain, so the chain" >&2
  echo "   will refuse to inscribe under it. Nothing was claimed — pick a different name:" >&2
  echo "     genie login \"${_localpart}-og\"    (or any handle that isn't your OS account)" >&2
  exit 1
fi
# RESERVED TEAM IDENTITIES — same reason: post() fail-closes on these, so blocking here turns a
# silent dead-end into an answer. Keep this list in step with chain.sh post().
case "$(printf '%s' "$_localpart" | tr '[:upper:]' '[:lower:]')" in
  yogi|blankcheck|wildflower|wildflowerbot|auto)
    echo "⛔ '$_localpart' is a reserved team identity — no node may author as the team." >&2
    echo "   Nothing was claimed. Choose your own handle: genie login \"<your-name>\"" >&2
    exit 1 ;;
esac

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
# WALK THE CHAIN, DON'T PEEK AT THE TIP. This used to scan the newest 200 blocks (and the
# verify below, 120). The chain passed 4,900 blocks on 2026-08-17 and climbs by hundreds a day,
# so a node born even a day earlier reads as NOT born: the "already born" check then writes a
# DUPLICATE birth block, and the verify prints "not visible on chain" about work that is plainly
# there. Server-side lookup would be one request, but ?src_id=/?id=/?q=/?slug= are all silently
# IGNORED by the API (measured 2026-08-18 — same defect as ?author=), so the client must page.
# `before=` is the one parameter that genuinely filters.
chain_has() { # chain_has <needle> — true if any reachable block contains it
  local needle="$1" before="" page lo n=0
  while [ "$n" -lt 40 ]; do
    if [ -z "$before" ]; then page="$(curl -fsS --max-time 20 "$API/api/chain?limit=500" 2>/dev/null)"
    else page="$(curl -fsS --max-time 20 "$API/api/chain?limit=500&before=$before" 2>/dev/null)"; fi
    [ -z "$page" ] && return 1
    printf '%s' "$page" | grep -q "$needle" && return 0
    lo="$(printf '%s' "$page" | tr ',' '\n' | grep -o '"height":[0-9]*' | grep -o '[0-9]*' | sort -n | head -1)"
    [ -z "$lo" ] || [ "$lo" = "$before" ] && return 1
    before="$lo"; n=$((n+1))
  done
  return 1
}

if chain_has "node-birth-$u"; then
  echo "⬢ already born — '$u' has a birth block on chain; skipping (no duplicate written)."
  echo "✅ verified on chain — '$u' is a live node."
  if [ -f "$HOME/Genie/tools/genesis_boot.py" ]; then
    python3 "$HOME/Genie/tools/genesis_boot.py" --marker "$u" 2>/dev/null || true
  fi
  exit 0
fi

HOSTKIND="$(uname -s)-$(uname -m)"
# Capture the client's output instead of discarding it — see the else branch below.
_birth_out="$(mktemp "${TMPDIR:-/tmp}/genie_birth.XXXXXX")"
if bash "$CHAIN" skill "node-birth-$u" \
  "Node '$u' joined the OrangeGenie Mesh ($HOSTKIND) — identity established by work, per the node doctrine" \
  "PROPERTY: The birth record of node '$u'. A machine becomes a node by inscribing work under its own marker and locally-generated secret, not by announcing presence. This block is that first work — from here the node authors under '$u', and its contributions are attributed and payable to it.

HOW: marker written to ~/.claude/genie_marker; a 32-byte secret generated on this machine (0600, never transmitted) with sha256 published as the claim commit that proves authorship; the chain client installed locally so the node operates unaided; this block inscribed, then read back from the chain to confirm.

RECREATE: run genie_onboard.sh <handle> on the machine (or --role <name> for a headless device), then read the chain back from a DIFFERENT machine and confirm a block exists under this marker. Verifying from the node itself only proves it can talk to itself. Platform: $HOSTKIND." >"$_birth_out" 2>&1
then
  echo "⬢ birth block inscribed under '$u'"
else
  # NEVER DISCARD THE ONE MESSAGE THAT EXPLAINS THE FAILURE. This branch used to be
  # `>/dev/null 2>&1` plus "staged; it settles on the next sync" — which was FALSE whenever
  # post() fail-closed (privacy guard, reserved identity, server rejection): nothing was queued,
  # so nothing ever settled, and the user was told to wait for a sync that would never come.
  # A node stayed invisible for days behind that sentence.
  echo "⚠️  birth block did NOT land. The reason, from the chain client:" >&2
  sed 's/^/     /' "$_birth_out" >&2 2>/dev/null || true
  # Only say "staged" if something is genuinely sitting in the queue waiting to go.
  _pending="$HOME/.claude/genie/pending_skills.jsonl"
  if [ -s "$_pending" ] && grep -q "node-birth-$u" "$_pending" 2>/dev/null; then
    echo "   → it IS queued in $_pending and will settle on the next sync." >&2
  else
    echo "   → NOTHING was queued. This will not fix itself; fix the cause above and re-run" >&2
    echo "     (re-running is safe — the chain dedups by src_id)." >&2
  fi
  rm -f "$_birth_out"
  exit 1
fi
rm -f "$_birth_out"

# ── 5. verify by reading the chain back ──────────────────────────────────────────────────
# Trust the store, not the exit code of our own write.
sleep 1
if chain_has "node-birth-$u"; then
  echo "✅ verified on chain — '$u' is a live node."
else
  echo "⚠️  not visible on chain yet (indexing lag or a failed write). Re-run to repair; it dedups."
fi

# If the full local chain tooling is present (AUTO's own box), also fire the rich Regenesis boot.
if [ -f "$HOME/Genie/tools/genesis_boot.py" ]; then
  python3 "$HOME/Genie/tools/genesis_boot.py" --marker "$u" 2>/dev/null || true
fi
