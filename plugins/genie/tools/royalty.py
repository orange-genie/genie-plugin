#!/usr/bin/env python3
"""royalty.py — the money follows the skills that actually did the work.

THE ECONOMY THIS CLOSES (AUTO, 2026-07-12)
    Paying users run the frontier models. Free users pay nothing. The nodes whose skills carried
    the answer GET PAID. For that to be real and not a slogan, three things have to be true, and
    this file makes them true:

      1. ATTRIBUTION — we know WHICH skills grounded each answer. genie_llm.py already returns
         that list on every response (`genie.skills`). Payout follows THAT list, not the feature
         name. A skill that grounds many answers earns more; one that grounds nothing earns
         nothing. That is rank-by-proven-merit expressed as money.
      2. AUTHORSHIP — every skill block carries data.author, forced server-side to the node's
         marker by chain.sh (unspoofable; you cannot bill under someone else's name).
      3. CONSERVATION — value in = work out (Markopolos). Money only ever comes from a PAYING
         user's call. Nothing is minted. A free call pays nobody.

    WHERE THE FREE TIER'S MONEY COMES FROM — the honest answer, because "free" always has a payer:
      • The COMPUTE for a free call is paid by the upstream's own free tier (e.g. Groq), not by us
        and not by paying users. It is rate-limited and it is their funnel, not our loss.
      • So a free call costs the treasury ~nothing and therefore owes nobody anything.
      • But it is NOT worthless to the authors: a free call still records a USE. Uses are the
        merit signal that ranks skills, and rank is what decides who earns from the PAID calls.
        Free users pay in signal. That is a real contribution, and it is why they are not
        parasites on the paying users -- they are the grading system.

    NO MONEY MOVES HERE. This is an append-only OWED ledger (the same ~/.claude/genie/owed.json
    meter.sh already writes). Settlement is a separate, explicitly owner-gated act. A ledger that
    can pay itself out is a ledger that can be robbed.

THE ORPHAN PROBLEM — stated, not hidden
    6,101 of 9,579 skill blocks (64%, measured 2026-07-12) carry NO author. They are legacy
    backfills mined from transcripts before chain.sh forced authorship. They pay NOBODY. We log
    every orphan-grounded call to the "__orphan__" bucket so the gap is VISIBLE and quantified
    instead of silently rounding somebody's earnings to zero. If a real author is later proven for
    an orphan, that is a supersede() on the chain -- never an edit to this ledger.

CLI
    royalty.py credit <paid|free> <price> <skill-slug> [<skill-slug> ...]   # record one call
    royalty.py owed [marker]                                                # what is owed, to whom
    royalty.py top [n]                                                      # skills earning the most

RECREATE
    stdlib only. Reads authorship from ~/Genie/wildflower-genesis/genesis.skills.json
    (block.data.author). Writes ~/.claude/genie/owed.json, the SAME ledger meter.sh accrues to --
    one ledger, never a parallel one.
"""
import os, sys, json, collections

CHAIN = os.path.expanduser("~/Genie/wildflower-genesis/genesis.skills.json")
# Overridable so tests never touch the LIVE earnings ledger. A test row in a real payout ledger is
# a fabricated balance, and a fabricated balance is a lie someone eventually gets paid on.
OWED = os.path.expanduser(os.environ.get("GENIE_OWED", "~/.claude/genie/owed.json"))
USES = os.path.expanduser(os.environ.get("GENIE_USES", "~/.claude/genie/skill_uses.json"))
TAKE_RATE = float(os.environ.get("GENIE_TAKE_RATE", "0.2"))   # platform take; rest to authors

_AUTHORS = None
def authors():
    """slug -> author marker. Absent/blank author => orphan (pays nobody, gets logged).

    Resolves CLAIM lineage: a skill inscribed under the shared 'genie' commons is free and pays
    nobody until its real author CLAIMS it (chain.sh claim / the bot on a Discord member's behalf).
    A CLAIM block carries data.{claims_src_id, to}; we overlay it so a claimed skill's royalties
    resolve to the claimer, not to 'genie'. Also honors RENAME (data.{from,to}) so a renamed
    author keeps earning under the new name. Append-only: the overlay reads the chain, never edits.
    """
    global _AUTHORS
    if _AUTHORS is not None:
        return _AUTHORS
    _AUTHORS = {}
    claims = {}   # claims_src_id -> claimer marker
    renames = {}  # old marker -> new marker
    if os.path.exists(CHAIN):
        try:
            d = json.load(open(CHAIN))
            blocks = d if isinstance(d, list) else d.get("blocks", [])
            for b in blocks:
                data = b.get("data") or {}
                btype = (b.get("type") or "").upper()
                if btype == "CLAIM" and data.get("claims_src_id") and data.get("to"):
                    claims[data["claims_src_id"]] = data["to"].strip()      # last claim wins
                    continue
                if btype == "RENAME" and data.get("from") and data.get("to"):
                    renames[data["from"].strip()] = data["to"].strip()
                    continue
                slug = data.get("skill") or b.get("src_id")
                if slug:
                    _AUTHORS[slug] = (data.get("author") or "").strip()
            # overlay: a claimed commons skill now belongs to the claimer (match by the block's src_id)
            for sid, claimer in claims.items():
                if sid in _AUTHORS:
                    _AUTHORS[sid] = claimer
            # follow rename chains so the newest name earns (bounded to avoid a cycle)
            for slug, auth in list(_AUTHORS.items()):
                seen = 0
                while auth in renames and seen < 8:
                    auth = renames[auth]; seen += 1
                _AUTHORS[slug] = auth
        except Exception:
            pass
    return _AUTHORS

def _load(p, default):
    try:
        return json.load(open(p))
    except Exception:
        return default

def _save(p, o):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump(o, open(p, "w"), indent=2)

def credit(paid, price, slugs):
    """Record ONE grounded call.

    paid=False -> pays nobody (the upstream's free tier ate the compute), but records a USE, which
                  is the merit signal that ranks the skill and drives its future PAID earnings.
    paid=True  -> price splits: TAKE_RATE to the platform, the rest EVENLY across the DISTINCT
                  authors of the skills that grounded this answer. Even split, not per-skill: one
                  author contributing three of the four cards should not out-earn a rival 3:1 for
                  a single answer -- we pay for the ANSWER, and each author either helped or did
                  not. Weighting by rank invites gaming the rank.
    """
    a = authors()
    uses = _load(USES, {})
    for s in slugs:                     # uses are recorded for EVERY call, paid or free
        uses[s] = uses.get(s, 0) + 1
    _save(USES, uses)

    if not paid or price <= 0 or not slugs:
        return {"paid": False, "credited": {}, "uses_recorded": len(slugs)}

    owed = _load(OWED, {})
    plat_share = round(price * TAKE_RATE, 6)
    pool = round(price - plat_share, 6)

    known = [a.get(s, "") for s in slugs]
    real = sorted({m for m in known if m})           # distinct real authors
    orphans = [s for s in slugs if not a.get(s, "")]

    credited = {}
    if real:
        each = round(pool / len(real), 6)
        for m in real:
            e = owed.setdefault(m, {"earned": 0.0, "calls": 0, "by": {}})
            e["earned"] = round(e["earned"] + each, 6)
            e["calls"] += 1
            for s in slugs:
                if a.get(s) == m:
                    e["by"][s] = round(e["by"].get(s, 0.0) + each, 6)
            credited[m] = each
    else:
        # every grounding skill was an orphan -> the author pool has no one to pay. Do NOT quietly
        # hand it to the platform; park it, visibly, so the orphan debt is a number we can see.
        o = owed.setdefault("__orphan__", {"earned": 0.0, "calls": 0, "by": {}})
        o["earned"] = round(o["earned"] + pool, 6)
        o["calls"] += 1

    p = owed.setdefault("__platform__", {"earned": 0.0, "calls": 0, "by": {}})
    p["earned"] = round(p["earned"] + plat_share, 6)
    p["calls"] += 1
    _save(OWED, owed)
    return {"paid": True, "price": price, "platform": plat_share, "credited": credited,
            "orphan_skills": orphans}

def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__); return
    if a[0] == "credit":
        if len(a) < 4:
            print("usage: royalty.py credit <paid|free> <price> <slug> [slug ...]"); sys.exit(2)
        r = credit(a[1] == "paid", float(a[2]), a[3:])
        print(json.dumps(r, indent=2))
    elif a[0] == "owed":
        owed = _load(OWED, {})
        if len(a) > 1:
            e = owed.get(a[1], {"earned": 0.0, "calls": 0, "by": {}})
            print(f"💵 owed to {a[1]}: ${e['earned']:.4f}  ({e['calls']} paid calls)")
            for s, amt in sorted(e.get("by", {}).items(), key=lambda x: -x[1])[:12]:
                print(f"     {s[:46]:46} ${amt:.4f}")
            return
        rows = sorted(((m, e) for m, e in owed.items()), key=lambda x: -x[1]["earned"])
        print(f"{'marker':22} {'owed':>10} {'calls':>7}")
        for m, e in rows:
            note = "  ← nobody to pay (legacy, no author)" if m == "__orphan__" else ""
            print(f"  {m:20} ${e['earned']:>8.4f} {e['calls']:>7}{note}")
    elif a[0] == "top":
        n = int(a[1]) if len(a) > 1 else 10
        uses, auth = _load(USES, {}), authors()
        rows = sorted(uses.items(), key=lambda x: -x[1])[:n]
        print(f"{'skill':50} {'uses':>5}  author")
        for s, c in rows:
            print(f"  {s[:48]:48} {c:>5}  {auth.get(s) or '(orphan — pays nobody)'}")
    else:
        print("usage: royalty.py credit|owed|top")

if __name__ == "__main__":
    main()
