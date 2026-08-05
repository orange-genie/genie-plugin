#!/usr/bin/env bash
# codeverify.sh — detect unattested changes to the code this node executes.
#
# THE HOLE THIS ADDRESSES
# The ledger is a chain, but the CODE every node runs is fetched from a single GitHub branch
# over HTTPS, unsigned, and executed. Whoever controls that branch controls every node's
# shell. Marker impersonation lets someone write a fake skill; a repo compromise runs
# arbitrary code on every user's machine. The second is strictly worse, and until now nothing
# checked it.
#
# WHAT THIS DOES
#   pin     record the sha256 of each installed tool (trust-on-first-use baseline)
#   check   re-hash them; anything that CHANGED must be attested on the chain or it is refused
#   attest  (publisher) inscribe the current hashes as a RELEASE block under your marker
#
# WHY A PIN AND AN ATTESTATION, NOT JUST ONE
# A pin alone cannot tell a legitimate update from a malicious one -- every real release would
# look like an attack. An attestation alone is only as good as the fetch: a compromised wire
# could serve you both bad code and a matching claim. Together they mean a change is only
# accepted if it was ALSO published to an append-only ledger that `chain.sh verify` can prove
# was not rewritten. An attacker then needs the repo AND a chain write AND to defeat the
# anchor -- instead of just the repo.
#
# HONEST LIMITS -- read these before trusting it
#   * TOFU. The FIRST pin trusts whatever is already on disk. This detects CHANGE, it cannot
#     tell you the code was clean the day you installed it.
#   * Self-reference. A compromised chain.sh could lie about the chain. That is why this file
#     is separate from chain.sh and hashes it as an input -- but this file is fetched over the
#     same wire, so a sufficiently thorough attacker replaces both. Real defence is signing
#     releases with a key that never touches the repo. This is the honest intermediate step.
#   * It refuses; it does not repair. A refusal means stop and look, not "retry until it works".
set -euo pipefail

STATE_DIR="$HOME/.claude/genie"
PIN_FILE="$STATE_DIR/code_pins"          # <sha256>  <path>
TOOLS_DIR="$STATE_DIR"                   # where the wire self-updates tools into
CHAIN="$STATE_DIR/chain.sh"
API="${GENIE_API:-https://orangegenie-api-production.up.railway.app}"

if command -v python3 >/dev/null 2>&1; then PY="python3"
elif command -v python  >/dev/null 2>&1; then PY="python"
elif command -v py      >/dev/null 2>&1; then PY="py -3"
else echo "codeverify.sh: no Python interpreter found" >&2; exit 1
fi

# Loud on a missing hasher. A silent empty hash would mark every file "unchanged" forever,
# which is the worst possible failure for a tool whose whole job is noticing change.
sha256_hex() {
  if   command -v shasum    >/dev/null 2>&1; then shasum -a 256 < "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum     < "$1" | awk '{print $1}'
  elif command -v openssl   >/dev/null 2>&1; then openssl dgst -sha256 < "$1" | awk '{print $NF}'
  else
    echo "codeverify.sh: no sha256 tool (need shasum, sha256sum, or openssl) — cannot verify code" >&2
    exit 1
  fi
}

# The executable surface the wire updates. Anything listed here runs on this machine.
tracked() {
  local f
  for f in chain.sh genie_onboard.sh rename.sh video.sh nodemail.py x.sh; do
    [ -f "$TOOLS_DIR/$f" ] && printf '%s\n' "$TOOLS_DIR/$f"
  done
}

cmd="${1:-}"
case "$cmd" in
  pin)
    mkdir -p "$STATE_DIR"
    : > "$PIN_FILE"; chmod 600 "$PIN_FILE" 2>/dev/null || true
    n=0
    while IFS= read -r f; do
      printf '%s  %s\n' "$(sha256_hex "$f")" "$f" >> "$PIN_FILE"; n=$((n+1))
    done < <(tracked)
    echo "⬢ pinned $n tool(s) → $PIN_FILE"
    echo "   TOFU baseline: this trusts what is on disk NOW. It proves nothing about the past."
    ;;

  check)
    [ -s "$PIN_FILE" ] || { echo "no pins yet — run: codeverify.sh pin"; exit 0; }
    changed=0; missing=0; unpinned=0; refused=0
    # anything pinned that changed or vanished
    while read -r want path; do
      [ -n "${want:-}" ] || continue
      if [ ! -f "$path" ]; then
        echo "  ✗ MISSING  $path (was pinned)"; missing=$((missing+1)); continue
      fi
      have="$(sha256_hex "$path")"
      if [ "$have" != "$want" ]; then
        changed=$((changed+1))
        printf '  ⚠ CHANGED  %s\n      pinned %s\n      now    %s\n' "$path" "$want" "$have"
        # A change is only acceptable if the NEW hash was published to the chain.
        if curl -fsS --max-time 15 "$API/api/chain?limit=400" 2>/dev/null \
             | HASH="$have" $PY -c '
import json,os,sys
h=os.environ["HASH"]
try: blocks=json.load(sys.stdin).get("blocks",[])
except Exception: sys.exit(1)
for b in blocks:
    hay=" ".join(str(x) for x in (b.get("summary"),b.get("body"),json.dumps(b.get("data") or {})))
    if h in hay:
        print("      ✓ attested on chain at height %s by %s"%(b.get("height"),b.get("src")))
        sys.exit(0)
sys.exit(1)'; then
          :
        else
          echo "      ⛔ NOT attested on chain — refusing to treat this as a legitimate update."
          refused=$((refused+1))
        fi
      fi
    done < "$PIN_FILE"
    # anything present that was never pinned (a tool that appeared out of nowhere)
    while IFS= read -r f; do
      grep -q "  $f\$" "$PIN_FILE" 2>/dev/null || { echo "  ⚠ UNPINNED $f (appeared since last pin)"; unpinned=$((unpinned+1)); }
    done < <(tracked)

    echo "⬢ codeverify · changed=$changed missing=$missing unpinned=$unpinned unattested=$refused"
    # An UNPINNED file is NOT an attested file — it is an executable that appeared on this node
    # and was never checked against anything. Folding it into the "attested" branch printed a
    # reassuring verdict for the exact case that deserves suspicion: a dropped binary.
    if [ "$refused" -gt 0 ] || [ "$missing" -gt 0 ]; then
      echo "   VERDICT: ⛔ FAILED — code on this node changed without a matching chain attestation."
      echo "            Do not run it. Compare against the repo, or reinstall from a known-good source."
      exit 1
    elif [ "$unpinned" -gt 0 ]; then
      echo "   VERDICT: ⚠ an executable appeared that was never pinned. Nothing vouches for it."
      echo "            Confirm you installed it deliberately, then: codeverify.sh pin"
      exit 1
    elif [ "$changed" -gt 0 ]; then
      echo "   VERDICT: changed, and every change is attested on chain. Accept with: codeverify.sh pin"
    else
      echo "   VERDICT: every tracked tool matches its pin."
    fi
    ;;

  attest)
    # PUBLISHER side: inscribe the hashes of what is being shipped, so nodes can tell a real
    # release from a repo compromise. Run this from the machine that ships a version.
    ver="${2:?usage: codeverify.sh attest <version>   e.g. 0.1.18}"
    [ -x "$CHAIN" ] || { echo "✗ need chain.sh at $CHAIN to inscribe"; exit 1; }
    body=""
    while IFS= read -r f; do
      body="${body}$(sha256_hex "$f")  $(basename "$f")
"
    done < <(tracked)
    [ -n "$body" ] || { echo "✗ nothing to attest"; exit 1; }
    echo "$body"
    bash "$CHAIN" queue "release-$ver" \
      "sha256 attestation for Genie tools $ver — a node compares its installed code against these before trusting an update." \
      "RELEASE $ver. Every line is '<sha256>  <filename>' for an executable the wire ships. A node that finds a CHANGED tool accepts it only if the new hash appears in a block like this one; otherwise it refuses to treat the change as legitimate. This is what makes a repo compromise insufficient on its own — the attacker would also need a chain write, and chain.sh verify detects a rewritten chain.

$body" >/dev/null
    echo "⬢ staged release attestation for $ver — it inscribes on the next sync."
    ;;

  *)
    echo "usage: codeverify.sh {pin | check | attest <version>}"
    echo
    echo "  pin              record sha256 of every tracked tool (trust-on-first-use)"
    echo "  check            re-hash; unattested changes are REFUSED (exit 1)"
    echo "  attest <ver>     publisher: stage a chain block carrying the shipped hashes"
    exit 1
    ;;
esac
