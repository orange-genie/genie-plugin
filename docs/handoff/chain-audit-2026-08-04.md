# Handoff → genie-1: chain.sh fixes + remaining security gap

From: genie-2 (Darwin-arm64). Verified live against the production API this session.
Target file: `orange-genie/genie-plugin` → `tools/chain.sh`

These two patches are ALREADY APPLIED and TESTED on genie-2's local copy
(`~/.claude/genie/chain.sh`). They will be **wiped at next SessionStart** — `version-check.sh`
re-pulls `chain.sh` over HTTPS every session. They only stick if they land in the plugin repo.

---

## PATCH 1 — `mine` reports zero skills for every user with a bare marker (LIVE BUG)

**Symptom:** `chain.sh mine` prints "nothing under your marker yet" for users who have real work
on chain. It also poisons the wake greeting, which reports skill count from `mine`. genie-2 was
greeted with "0 skills" while holding 3 on chain.

**Cause:** `post()` qualifies the marker (`genie-2` → `genie-2.agent`) before writing, so the chain
stores the QUALIFIED form. `mine` passed the RAW marker to `read_chain`, which compares
`src != mk`. `"genie-2.agent" != "genie-2"` → every row filtered out. A read and a write deriving
identity differently.

**Fix:** extract the qualification into one shared function, call it from both.

Replace the inline `case` at the top of `post()` with a shared helper defined ABOVE `post()`:

```bash
# --- MARKER NORMALIZATION (all users, non-negotiable) ----------------------------------------
# The free COMMONS author is the bare literal 'genie'. THERE IS NO '.genie' TLD. Chosen handles
# get a real TLD (.agent/.wtf/.com/.eth/.bot); the OS account is NEVER used.
#
# THIS MUST BE SHARED. It used to live inline in post() only, so WRITES qualified 'genie-2' ->
# 'genie-2.agent' while `mine` compared the RAW marker against the chain's src — the strings never
# matched and `mine` reported "nothing under your marker yet" to users who had real work on chain.
# A read and a write that derive identity differently will always drift; derive it in ONE place.
qualify_marker() {
  local mk="$1"
  case "$mk" in
    ""|"genie"|"Genie") printf 'genie' ;;
    *.agent|*.wtf|*.com|*.eth|*.bot) printf '%s' "$mk" ;;
    *) printf '%s.agent' "$mk" ;;
  esac
}
```

Then in `post()`:

```bash
  mk="$(qualify_marker "$(marker)")"; sid="$1"; typ="$2"; sym="$3"; sum="$4"; bod="${5:-}"; dat="${6:-}"
```

And in the `mine)` case:

```bash
  mine)
    lim="${2:-200}"
    # qualify EXACTLY as post() does — the chain stores the qualified marker, so a raw
    # compare here silently returns nothing for every user with a bare marker.
    mk="$(qualify_marker "$(marker)")"
    echo "⬢ chain · skills already inscribed under $mk:"
    read_chain "" "$lim" 1 "$mk"
    ;;
```

**Verified on genie-2:** before = "nothing under your marker yet". after = 3 blocks under
`genie-2.agent`. `bash -n` clean.

**Check whether this hit other users.** Any node with a bare marker (no TLD) has been getting a
false zero. That is most nodes.

---

## PATCH 2 — new `chain.sh verify` (node-side tamper detection)

**Why:** a node that only reads is trusting the operator. This makes the node check.

**Good news, confirmed live:** `GET /api/chain` ALREADY exposes `hash` and `prev_hash` per block,
and the chain links cleanly — 300 blocks, heights 1705..2004: **0 link breaks, 0 missing
prev_hash, 0 height gaps.** No server change needed. This is purely client-side.

**The load-bearing design point:** link-checking alone proves nothing against a rewrite — a server
that re-authored history would re-link it cleanly. Only a hash pinned BEFORE the rewrite catches
one. The ANCHOR is the security property; the link scan is a consistency check.

Insert this case before `whoami)`:

```bash
  verify)
    # Node-side tamper check. A node that only READS is trusting the operator; this makes the node
    # CHECK. Two independent things, and the second is the one that matters:
    #   1. LINKS  — every block's prev_hash equals the previous block's hash (internal consistency).
    #   2. ANCHOR — a hash we pinned on a previous run still holds at that same height. Link-checking
    #      alone proves nothing against a rewrite: a server that re-authored history would re-link it
    #      cleanly. Only a hash pinned BEFORE the rewrite can catch one. The anchor is the actual
    #      security property; the link scan is a consistency check.
    lim="${2:-300}"
    ANCHOR_FILE="$HOME/.claude/genie/chain_anchor"
    curl -fsS --max-time 25 "$API/api/chain?limit=$lim" 2>/dev/null \
      | ANCHOR="$(cat "$ANCHOR_FILE" 2>/dev/null || true)" $PY -c '
import json,sys,os
try: bl=json.load(sys.stdin).get("blocks",[])
except Exception: print("⚠️  chain unreachable — cannot verify"); sys.exit(0)
if not bl: print("⚠️  no blocks returned — cannot verify"); sys.exit(0)
bl=sorted(bl,key=lambda b:b.get("height",0))
lo,hi=bl[0].get("height"),bl[-1].get("height")
breaks=miss=gaps=0
for prev,cur in zip(bl,bl[1:]):
    if cur.get("height")!=prev.get("height",0)+1: gaps+=1; continue
    ph=cur.get("prev_hash")
    if not ph: miss+=1; continue
    if ph!=prev.get("hash"):
        breaks+=1
        if breaks<=3: print("  ✗ BREAK at height %s (prev_hash != hash of %s)"%(cur.get("height"),prev.get("height")))
print("⬢ verify · %d blocks, heights %s..%s"%(len(bl),lo,hi))
print("   links: %d breaks · %d missing prev_hash · %d height gaps"%(breaks,miss,gaps))
anc=(os.environ.get("ANCHOR") or "").split()
by_h={b.get("height"):b for b in bl}
tampered=False
if len(anc)==2:
    ah,ahash=int(anc[0]),anc[1]
    b=by_h.get(ah)
    if b is None:
        print("   anchor: height %d not in this window (pull more with: chain.sh verify 2000)"%ah)
    elif b.get("hash")==ahash:
        print("   anchor: ✓ height %d unchanged since last check"%ah)
    else:
        tampered=True
        print("   anchor: ⛔ HEIGHT %d WAS REWRITTEN"%ah)
        print("           pinned %s"%ahash)
        print("           now    %s"%b.get("hash"))
else:
    print("   anchor: none yet — pinning this run as the baseline")
# never advance the anchor over a failure; that would launder the tamper away
if breaks==0 and miss==0 and not tampered:
    print("ANCHOR_OK %s %s"%(hi,bl[-1].get("hash")))
    print("   VERDICT: chain is consistent and unchanged where we could check it.")
else:
    print("   VERDICT: ⛔ FAILED — anchor NOT advanced. Investigate before trusting this chain.")
' 2>/dev/null | { out="$(cat)"; printf '%s\n' "$out" | grep -v '^ANCHOR_OK '
        newanc="$(printf '%s\n' "$out" | grep '^ANCHOR_OK ' | head -1 | cut -d' ' -f2-)"
        [ -n "$newanc" ] && printf '%s\n' "$newanc" > "$ANCHOR_FILE"; }
    ;;
```

Anchor persists at `~/.claude/genie/chain_anchor`, format: `<height> <hash>`.

**Test results on genie-2 (all three paths):**
1. No anchor → pins baseline. ✓
2. Anchor present, chain unchanged → `✓ height 2004 unchanged since last check`. ✓
3. Poisoned anchor (simulated rewrite) → caught it, printed pinned vs current, and **refused to
   advance the anchor**. ✓

Path 3 is the one that's easy to get wrong. If it advanced the anchor on failure, the next run
reports clean and the tamper is laundered away. It must stay failed until a human looks.

Also update the usage string at the bottom of the file to include `verify`.

---

## REMAINING SECURITY GAP (not fixed — needs the server)

`project_chain_write_path_node_inscribe.md` already documents this: *"Marker ownership is
self-asserted (no per-user keys yet) — node-inscribe/rename trust the claimed marker. Hardens to a
signature check once per-user keys exist."*

Confirmed still true. `POST /api/chain/node-inscribe` accepts a bare `{"marker": "..."}` string
with no credential of any kind. Anyone with curl can inscribe as any existing marker.

**Corrections to earlier genie-2 claims — the endpoint has MORE protection than a shallow probe
shows.** Do not repeat these errors:
- Rate limited 40/min (3 probes won't trip it)
- Reserved markers → 403; `MARKER_RE` enforced → 400
- `src` + `data.author` both forced server-side to the marker
- Blocks ARE hash-linked via `_chainHead()` / `_blockHash()`, and verified intact

**The fix that fits the existing design:** `project_wallet_derived_identity.md` (spec'd 2026-06-07,
marked "not built"). Connect wallet → sign the fixed message `OrangeGenie identity v1` →
HKDF-SHA256 with domain separation → that derived key is the per-user key the TODO is waiting on.

**Do NOT hand-roll an HMAC scheme for this.** OWASP API2:2023 is explicit — use established
standards, not custom auth, and API keys authenticate CLIENTS not USERS. The wallet signature is
the standard; the existing `node_secret` (already on every node, chmod 600) should be a DEVICE key
authorized under that identity, not the identity itself.

**Open gap in that spec:** it's browser-scoped (Phantom/MetaMask/WalletConnect via the modal in
`wildflower-genesis/index.html` ~1302-1345). `chain.sh` is headless bash — no browser, no wallet.
Needs a one-time browser session that authorizes the node's `node_secret` as a device key.

**Migration risk:** no marker on chain has a key bound today. The moment the server enforces
signatures, every node fails to write until it registers. Run a grace period — accept unsigned but
log it, let the fleet rotate on next wake, then flip to enforcing. Do not hard-cut.

**Server location:** `~/Genie/server/server.js`. Deploy: `railway up --service orangegenie-api
--detach` (source=upload, not git). Not present on genie-2 — this box has `~/Genie/{bin,tools}` only.

---

## Also worth checking (unverified — genie-2 had no server access)

- `chain.sh collab` room codes are bearer tokens. Is there brute-force protection on
  `/api/collab/pull`? OWASP API2 scenario 1 is an attacker batching requests to defeat rate limits.
- Do `rename` / `claim` require re-authentication? Both change ownership of work on a public
  ledger. OWASP: sensitive operations need re-auth.
- Guest prompts pulled via `collab` reach the host's full tool access, with a model as the only
  approval gate. That is not a security boundary against prompt injection. If customer machines are
  in scope, guest prompts must not reach a shell at all.
