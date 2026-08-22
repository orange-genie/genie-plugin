#!/usr/bin/env python3
"""chain.py — the OrangeGenie Mesh client, in pure Python.

WHY THIS EXISTS
---------------
chain.sh is the proven implementation and stays authoritative on any machine that has bash.
This is not a rewrite of it for its own sake — it is the file that makes Windows a real
platform instead of a WSL detour.

The `genie` CLI shelled out to `bash chain.sh` for login/whoami/recall and to
`bash genie_onboard.sh` for login. Native Windows has no bash, so a Windows user could
install the CLI and still not claim a name or search the chain. brain.py was already pure
stdlib, so ASKING worked; everything that made you a *participant* did not. That is the
whole gap this closes.

WHAT IT TALKS TO
  GET  /api/chain?limit=N[&full=1]     read blocks
  POST /api/chain/node-inscribe        write a block

DRIFT IS THE RISK, so it is designed against it: this is a second CLIENT of the same HTTP
API, not a second copy of the logic. The API is the truth. The two guards below are the one
place where behaviour — not transport — is duplicated, so they are transcribed exactly from
chain.sh's post() and carry the same fail-closed posture. `python3 chain.py selfcheck`
asserts both, so a drift shows up as a failing check rather than as a leaked block.

Stdlib only: urllib + ssl + json. No pip, no curl, no bash.
"""

import os, sys, json, ssl, re, getpass, urllib.request, urllib.error

API = os.environ.get("GENIE_API", "https://orangegenie-api-production.up.railway.app")
HOME = os.path.expanduser("~")
STATE = os.path.join(HOME, ".claude", "genie")
MARKER_FILE = os.path.join(HOME, ".claude", "genie_marker")
QUEUE_FILE = os.path.join(STATE, "pending_skills.jsonl")
RETRY_FILE = os.path.join(STATE, "failed_skills.jsonl")
RECEIPT_FILE = os.path.join(STATE, "inscribed.log")
REJECT_FILE = os.path.join(STATE, "rejected_writes.log")
SYNC_CAP = int(os.environ.get("GENIE_SYNC_CAP", "5"))

# Team identities. No node writes as the team — see chain.sh post(). Measured 2026-08-08:
# 74 blocks reached the live chain under a reserved identity before this guard existed.
RESERVED = {"yogi", "blankcheck", "wildflower", "wildflowerbot", "auto"}
QUALIFIED = (".agent", ".wtf", ".com", ".eth", ".bot")

try:
    import certifi
    _SSL = ssl.create_default_context(cafile=certifi.where())
except Exception:
    _SSL = ssl.create_default_context()

# Cloudflare rejects Python's default `Python-urllib/3.x` UA at the EDGE with a non-JSON
# `403 error code: 1010`, before anything else is evaluated. brain.py hit this first; the
# same edge sits in front of this API. See chain: cloudflare-1010-rejects-python-urllib.
UA = "OrangeGenie-chain/1.0"


def _get(path, timeout=12):
    req = urllib.request.Request(API.rstrip("/") + path, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout, context=_SSL) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


# ── identity ────────────────────────────────────────────────────────────────────────────
def qualify_marker(mk):
    """Transcribed from chain.sh qualify_marker. A read and a write that derive identity
    differently will always drift, so both sides derive it here."""
    mk = (mk or "").strip()
    if mk in ("", "genie", "Genie"):
        return "genie"                       # free commons author (bare literal)
    if mk.endswith(QUALIFIED):
        return mk                            # already a qualified CHOSEN handle
    return mk + ".agent"


def marker():
    env = os.environ.get("GENIE_MARKER", "").strip()
    if env:
        return qualify_marker(env)
    local = os.path.join(os.getcwd(), ".genie_marker")
    for f in (local, MARKER_FILE):
        try:
            with open(f) as fh:
                m = fh.read().strip()
            if m:
                q = qualify_marker(m)
                if f == MARKER_FILE and q != m:
                    try:
                        with open(MARKER_FILE, "w") as fh:
                            fh.write(q)
                    except OSError:
                        pass
                return q
        except OSError:
            continue
    return "genie"


def os_login():
    """getpass.getuser() where chain.sh uses `id -un` — `id` does not exist on Windows.
    Returns '' rather than raising: a machine with no resolvable login must not become a
    machine with no privacy guard."""
    try:
        return (getpass.getuser() or "").strip()
    except Exception:
        return ""


def guard(mk):
    """Both fail-closed blocks from chain.sh post(). Returns an error string, or None to allow.

    Kept as one function returning a reason so `selfcheck` can assert it directly — a guard
    you cannot test is a guard you will eventually ship broken."""
    localpart = mk.split(".")[0].lower()
    login = os_login()
    if login and localpart == login.lower():
        return ("⛔ refusing to inscribe: marker '%s' matches this machine's login name —\n"
                "   publishing it would leak private info to the PUBLIC chain. Choose a marker\n"
                "   (genie login <name>) or set GENIE_MARKER. Nothing was sent." % mk)
    if localpart in RESERVED:
        return ("⛔ refusing to inscribe: '%s' is a RESERVED team identity — no node writes as\n"
                "   the team. Author under this node's own marker instead. Nothing was sent." % mk)
    return None


# ── writes ──────────────────────────────────────────────────────────────────────────────
def post(src_id, typ, symbol, summary, body="", data=None):
    """Returns (code, detail). code: 0 landed · 2 unreachable (retry) · 3 REJECTED (fix it).

    The 2-vs-3 split is the whole point. chain.sh once called every failure "unreachable"
    and retried forever, which stranded weeks of skills behind a fixable HTTP 400. A
    rejection does not fix itself by retrying, so it is recorded loudly and never requeued."""
    mk = marker()
    bad = guard(mk)
    if bad:
        return 3, bad

    payload = {"marker": mk, "src_id": src_id, "type": typ,
               "symbol": symbol, "summary": summary, "body": body}
    if data:
        payload["data"] = data

    req = urllib.request.Request(
        API.rstrip("/") + "/api/chain/node-inscribe",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=20, context=_SSL) as r:
            return 0, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            err = json.loads(raw).get("error", "(no error field)")
        except Exception:
            err = raw[:200]
        os.makedirs(STATE, exist_ok=True)
        try:
            import datetime
            ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            with open(REJECT_FILE, "a") as fh:
                fh.write("%s\t%s\t%s\t%s :: %s\n" % (ts, e.code, mk, src_id, err))
        except OSError:
            pass
        return 3, ("⛔ chain REJECTED the write (HTTP %s): %s\n"
                   "   marker='%s' src_id='%s' — a rejection does NOT fix itself by retrying."
                   % (e.code, err, mk, src_id))
    except Exception as e:
        return 2, "⚠️  chain unreachable (%s) — staged for retry." % e


# ── subcommands ─────────────────────────────────────────────────────────────────────────
def cmd_login(args):
    """Confirms identity + reachability. Deliberately does NOT broadcast presence: nobody
    should be able to see when a user is live. Identity on the chain is established by your
    WORK, not by a login ping."""
    if args:
        name = qualify_marker(args[0])
        bad = guard(name)
        if bad:
            print(bad, file=sys.stderr)
            return 1
        os.makedirs(os.path.dirname(MARKER_FILE), exist_ok=True)
        with open(MARKER_FILE, "w") as fh:
            fh.write(name)
    mk = marker()
    try:
        _get("/api/chain?limit=1", timeout=8)
        print("⬢ %s — chain reachable. Your work inscribes under this name." % mk)
    except Exception:
        print("⬢ %s — offline (chain unreachable); work will inscribe when you're back online." % mk)
    return 0


def cmd_whoami(_args):
    print(marker())
    return 0


def cmd_search(args):
    if not args:
        print("usage: chain.py search <query> [limit]", file=sys.stderr)
        return 1
    q = args[0].lower()
    lim = int(args[1]) if len(args) > 1 else 200
    print('⬢ chain · skills matching "%s":' % args[0])
    try:
        data = _get("/api/chain?limit=%d" % lim, timeout=25)
    except Exception as e:
        print("  chain unreachable (%s)" % e, file=sys.stderr)
        return 2
    blocks = data.get("blocks", data if isinstance(data, list) else [])
    terms = [t for t in re.split(r"\W+", q) if t]
    hits = 0
    for b in blocks:
        hay = " ".join(str(b.get(k, "")) for k in ("src_id", "summary", "symbol")).lower()
        if terms and all(t in hay for t in terms):
            print("  %s  %s" % (b.get("src_id", "?"), (b.get("summary", "") or "")[:96]))
            hits += 1
    if not hits:
        print("  (no match in the last %d blocks — try fewer words)" % lim)
    return 0


def cmd_queue(args):
    if len(args) < 3:
        print("usage: chain.py queue <slug> <summary> <body>", file=sys.stderr)
        return 1
    os.makedirs(STATE, exist_ok=True)
    with open(QUEUE_FILE, "a") as fh:
        fh.write(json.dumps({"src_id": args[0], "type": "SKILL", "symbol": "SKILL",
                             "summary": args[1], "body": args[2]}) + "\n")
    print("⬢ staged skill '%s' — it inscribes when this session ends." % args[0])
    return 0


def cmd_sync(_args):
    """Inscribes staged skills, capped. A rejected write is NOT requeued — it goes to the
    retry file only when the network was the problem."""
    if not os.path.exists(QUEUE_FILE):
        print("⬢ nothing staged.")
        return 0
    with open(QUEUE_FILE) as fh:
        rows = [l for l in fh.read().splitlines() if l.strip()]
    if not rows:
        print("⬢ nothing staged.")
        return 0
    done, left = 0, []
    for i, line in enumerate(rows):
        if i >= SYNC_CAP:
            left.append(line)
            continue
        try:
            s = json.loads(line)
        except Exception:
            continue
        code, detail = post(s.get("src_id", ""), s.get("type", "SKILL"),
                            s.get("symbol", "SKILL"), s.get("summary", ""), s.get("body", ""))
        if code == 0:
            done += 1
            height = ""
            m = re.search(r'"height"\s*:\s*(\d+)', detail or "")
            if m:
                height = '"height":%s' % m.group(1)
            try:
                import datetime
                ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                with open(RECEIPT_FILE, "a") as fh:
                    fh.write("%s\t%s\t%s\n" % (ts, s.get("src_id", ""), height))
            except OSError:
                pass
        elif code == 2:
            left.append(line)                       # network — worth retrying
        else:
            print(detail, file=sys.stderr)          # rejected — loud, never silently requeued
            with open(RETRY_FILE, "a") as fh:
                fh.write(line + "\n")
    with open(QUEUE_FILE, "w") as fh:
        fh.write("\n".join(left) + ("\n" if left else ""))
    print("⬢ inscribed %d skill(s) under %s." % (done, marker()))
    return 0


def cmd_health(_args):
    mk = marker()
    try:
        d = _get("/api/chain?limit=1", timeout=8)
        h = d.get("height") or (d.get("blocks") or [{}])[0].get("height", "?")
        print("⬢ marker %s · chain reachable · height %s" % (mk, h))
    except Exception as e:
        print("⬢ marker %s · chain unreachable (%s)" % (mk, e))
    staged = 0
    if os.path.exists(QUEUE_FILE):
        with open(QUEUE_FILE) as fh:
            staged = len([l for l in fh if l.strip()])
    print("  staged: %d" % staged)
    return 0


def cmd_selfcheck(_args):
    """Asserts the two behaviours that are duplicated from chain.sh. This is the anti-drift
    test — if a guard is ever weakened here, this fails instead of a block leaking."""
    ok = True
    cases = [("genie", "genie"), ("", "genie"), ("corey", "corey.agent"),
             ("corey.agent", "corey.agent"), ("x.bot", "x.bot")]
    for raw, want in cases:
        got = qualify_marker(raw)
        if got != want:
            print("  ✗ qualify(%r) = %r, want %r" % (raw, got, want)); ok = False
    for bad in ("yogi.agent", "blankcheck.agent", "wildflower.agent", "auto.bot", "WILDFLOWERBOT.agent"):
        if not guard(bad):
            print("  ✗ reserved identity %r was ALLOWED" % bad); ok = False
    login = os_login()
    if login and guard(qualify_marker(login)) is None:
        print("  ✗ OS login name was ALLOWED as a marker"); ok = False
    print("  ✓ marker rules + both fail-closed guards hold" if ok else "  ✗ selfcheck FAILED")
    return 0 if ok else 1


CMDS = {"login": cmd_login, "whoami": cmd_whoami, "search": cmd_search,
        "recall": cmd_search, "queue": cmd_queue, "sync": cmd_sync,
        "health": cmd_health, "selfcheck": cmd_selfcheck}


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print("chain.py — OrangeGenie Mesh client (pure Python)\n")
        print("  " + "  ".join(sorted(CMDS)))
        return 0
    cmd = argv[0]
    if cmd not in CMDS:
        print("chain.py: unknown subcommand '%s'" % cmd, file=sys.stderr)
        return 1
    return CMDS[cmd](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
