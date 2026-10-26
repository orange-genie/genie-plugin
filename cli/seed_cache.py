#!/usr/bin/env python3
"""seed_cache.py — pull the Mesh's proven skills onto THIS machine.

WHY THIS EXISTS
---------------
The local model is what makes Genie unlimited. The cheat sheet is what makes it GOOD.

A 3B model running on someone's old laptop does not know why a scheduled job cannot find a
Homebrew binary. The Mesh does — someone hit it, solved it, and inscribed the answer. Feeding
that card to the small model at answer time is what lets it beat a much larger model that has
to guess from training data.

The cache has to be LOCAL. If grounding lives behind our API, then our bad day is every user's
bad day — which is exactly what happened: a database timeout took every install down at once.
Seeded here, a user keeps their grounded brain with the network unplugged.

It writes the file brain.py ALREADY reads (~/.claude/genie/chain_skills.jsonl, consumed by
_mirror_rows as {slug, summary, body}). One store, not a parallel one.

Shared by install.sh and install.ps1 so the logic exists once instead of drifting per platform.

    python3 seed_cache.py [path/to/chain_skills.jsonl]
"""

import json, os, sys, ssl, urllib.request

API = os.environ.get("GENIE_API", "https://orangegenie-api-production.up.railway.app")
PAGES = int(os.environ.get("GENIE_SEED_PAGES", "3"))     # 500 blocks per page
UA = "OrangeGenie-install/1.0"                           # the edge 403s Python's default UA


def default_path():
    return os.path.join(os.path.expanduser("~"), ".claude", "genie", "chain_skills.jsonl")


def fetch(url, timeout=45):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout, context=ssl.create_default_context()) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def main(argv):
    out = argv[0] if argv else default_path()
    os.makedirs(os.path.dirname(out), exist_ok=True)

    # Keep what is already cached. A re-run must never leave the user with LESS than they had —
    # a failed refresh that empties the cheat sheet is worse than no refresh at all.
    seen = {}
    if os.path.exists(out):
        try:
            for line in open(out):
                line = line.strip()
                if line:
                    d = json.loads(line)
                    if d.get("slug"):
                        seen[d["slug"]] = d
        except Exception:
            seen = {}
    had = len(seen)

    before, added = None, 0
    try:
        for _ in range(PAGES):
            url = f"{API}/api/chain?limit=500&full=1" + (f"&before={before}" if before else "")
            data = fetch(url)
            blocks = data.get("blocks", data if isinstance(data, list) else [])
            if not blocks:
                break
            for b in blocks:
                sid = b.get("src_id") or ""
                if not sid:
                    continue
                slug = sid.split(".")[-1]
                if slug not in seen:
                    seen[slug] = {"slug": slug, "summary": b.get("summary", ""),
                                  "body": b.get("body", "")}
                    added += 1
            heights = [b.get("height") for b in blocks if b.get("height") is not None]
            if not heights:
                break
            before = min(heights)
    except Exception as e:
        # Not fatal, and must not read as a failure: an ungrounded local brain still answers,
        # and whatever was already cached is still there.
        if had:
            print(f"  Mesh unreachable ({type(e).__name__}) - keeping {had} cached skills")
        else:
            print(f"  Mesh unreachable ({type(e).__name__}) - genie still answers, ungrounded for now")
        return 0

    # Write once, atomically. A half-written cache is a corrupt cheat sheet on every later boot.
    tmp = out + ".new"
    with open(tmp, "w") as fh:
        for d in seen.values():
            fh.write(json.dumps(d) + "\n")
    os.replace(tmp, out)

    print(f"  {len(seen)} skills cached locally (+{added}) - grounding works with no network")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
