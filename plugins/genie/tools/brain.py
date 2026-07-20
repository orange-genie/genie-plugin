#!/usr/bin/env python3
"""brain.py — the ONE brain every Genie skill talks to. Four providers, one call.

WHY THIS EXISTS
    The tiered brain (paid -> Opus, free -> Groq) was proven inside a single bot
    (bots/cryptonovot/bot_engine.py) and trapped there. Every other skill hard-stopped at the
    meter: out of free uses, no key, no credits -> TOPUP -> the skill refuses to run.
    This module lifts that pattern out so the whole surface inherits it, and adds the fifth door:

        out of free uses  ->  DEGRADE to an open-weight brain  ->  the skill still runs.

    A user with no Anthropic key, no credits, and no intention of paying still gets a working
    Genie. That is the point.

THE FOUR PROVIDERS — and the honest difference between them
    anthropic   Claude Opus 4.8. Cloud. Strongest. Costs money.          egress: CLOUD
    groq        open-weight models on Groq's LPU cloud. Fast, ~free.     egress: CLOUD
    pool        an open-weight model on a PEER's machine in your pool.   egress: PEER
    ollama      an open-weight model on YOUR OWN machine.                egress: NONE

    Three different trust models, and they are NOT interchangeable:
      • CLOUD — tokens go to a corporation. Audited, contractual, and not yours.
      • PEER  — tokens go to someone else's box. This is NOT "local" and NOT more private than
                cloud by default; it is a DIFFERENT risk (a stranger's disk vs an audited corp).
                Its win is CAPABILITY, not privacy: a pool can serve a 70B when your laptop
                can only hold a 7B. Never sell `pool` as privacy. Sell it as reach.
      • NONE  — tokens never leave. Only `ollama` earns the word "private."

    Groq is NOT local. It is a cloud API that happens to run open-weight models. Calling it
    "local" would be exactly the unverifiable privacy claim this project exists to attack --
    so `egress` is a field, not a vibe, and `providers()` prints it. Do not blur this.

RESOLUTION ORDER (resolve())
    1. GENIE_BRAIN env pin           -- user forces a provider ("local" == ollama). Always wins.
    2. meter.sh gate <feature>       -- the server-verified door:
         KEYED <prov>  -> run on the user's OWN key for that provider (unlimited, our COGS = 0)
         ALLOW/CREDITS -> premium (anthropic)
         TOPUP/BYOK    -> free tier spent, no key, no credits -> DEGRADE to the best free brain
    3. availability                  -- whatever is actually reachable, best-first.
    Every step degrades rather than dying. brain() never goes dark if ANY provider is reachable.

KEYS
    Never printed, never logged, never inscribed. Read from (first hit wins):
      env var  ->  ~/.claude/genie/keys.env  ->  a project .env passed via env_files=
    A missing key is a provider that is simply unavailable -- not an error.

CLI (so this is provable, not asserted)
    python3 brain.py providers                      # what's reachable here, and where tokens go
    python3 brain.py ask "question" [--tier free|paid] [--provider groq|anthropic|ollama|pool]
    python3 brain.py selftest                       # round-trip every reachable provider

RECREATE
    Standalone -- stdlib only (urllib + ssl + json). certifi is used if importable (some macOS
    Pythons ship no system CA roots and fail Groq/Anthropic TLS with CERTIFICATE_VERIFY_FAILED).
    Needs: GROQ_API_KEY for groq, ANTHROPIC_API_KEY for anthropic, a running `ollama serve` for
    ollama, GENIE_POOL_URL (any OpenAI-compatible endpoint) for pool. Zero of the four is a valid
    state -- providers() will just report nothing reachable.
"""
import os, sys, json, ssl, re, math, sqlite3, urllib.request, urllib.error, subprocess

# TLS with a real CA bundle. Some macOS Pythons lack system roots -> CERTIFICATE_VERIFY_FAILED.
try:
    import certifi
    _SSL = ssl.create_default_context(cafile=certifi.where())
except Exception:
    _SSL = ssl.create_default_context()

_HERE = os.path.dirname(os.path.abspath(__file__))
_KEYS_ENV = os.path.expanduser("~/.claude/genie/keys.env")

# ── key resolution — values NEVER leave this function ──────────────────────
def _key(name, env_files=()):
    """env var -> ~/.claude/genie/keys.env -> caller-supplied .env files. Never printed."""
    v = os.environ.get(name)
    if v:
        return v.strip()
    for path in (_KEYS_ENV, *env_files):
        fp = os.path.expanduser(path)
        if not os.path.exists(fp):
            continue
        try:
            for line in open(fp):
                line = line.strip()
                if line.startswith(name + "="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
        except Exception:
            pass
    return None

def _http_json(url, body, headers, timeout=60):
    # A REAL User-Agent is mandatory, not cosmetic. Groq (and Discord, and anything else behind
    # Cloudflare) rejects Python's default `Python-urllib/3.x` at the EDGE with `403 error code:
    # 1010` -- a non-JSON body, before your key is ever checked. Rule: a non-JSON 403 is the WAF,
    # a JSON 401/403 is real auth. Don't go re-issue a good key chasing this.
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"content-type": "application/json",
                                          "user-agent": "OrangeGenie/1.0 (+https://orangegenie.bot)",
                                          **headers})
    with urllib.request.urlopen(req, timeout=timeout, context=_SSL) as r:
        return json.loads(r.read())

# ── the providers ──────────────────────────────────────────────────────────
# egress says where the user's tokens physically go. This is the honesty field. Do not fudge it.
#   CLOUD = a corporation's servers.  PEER = another person's machine.  NONE = never leaves.
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
POOL_URL = os.environ.get("GENIE_POOL_URL", "")   # any OpenAI-compatible peer endpoint

# Groq rotates and deprecates model ids -- confirmed live 2026-07-12 against /openai/v1/models.
# llama-3.3-70b-versatile is the proven one already running in cryptonovot; openai/gpt-oss-120b
# and qwen/qwen3-32b were also live at build time. Override with GENIE_GROQ_MODEL.
GROQ_MODEL = os.environ.get("GENIE_GROQ_MODEL", "llama-3.3-70b-versatile")
ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-opus-4-8")
OLLAMA_MODEL = os.environ.get("GENIE_OLLAMA_MODEL", "llama3.1")
POOL_MODEL = os.environ.get("GENIE_POOL_MODEL", "llama-3.3-70b")

def _call_anthropic(system, user, max_tokens, env_files):
    k = _key("ANTHROPIC_API_KEY", env_files)
    if not k:
        return None
    d = _http_json("https://api.anthropic.com/v1/messages",
                   {"model": ANTHROPIC_MODEL, "max_tokens": max_tokens, "system": system,
                    "messages": [{"role": "user", "content": user}]},
                   {"x-api-key": k, "anthropic-version": "2023-06-01"})
    return "".join(b.get("text", "") for b in d.get("content", [])).strip() or None

def _openai_chat(url, model, system, user, max_tokens, key=None, timeout=60):
    """One shape, three endpoints: Groq, a pool peer, and anything else OpenAI-compatible."""
    h = {"Authorization": f"Bearer {key}"} if key else {}
    d = _http_json(url, {"model": model, "max_tokens": max_tokens,
                         "messages": [{"role": "system", "content": system},
                                      {"role": "user", "content": user}]}, h, timeout=timeout)
    return (d["choices"][0]["message"]["content"] or "").strip() or None

def _call_groq(system, user, max_tokens, env_files):
    k = _key("GROQ_API_KEY", env_files)
    if not k:
        return None
    return _openai_chat("https://api.groq.com/openai/v1/chat/completions",
                        GROQ_MODEL, system, user, max_tokens, key=k)

def _call_pool(system, user, max_tokens, env_files):
    """A PEER's machine serves this call. The pool's win is REACH (a 70B when your box holds a
    7B), never privacy -- your tokens land on someone else's disk. Any OpenAI-compatible endpoint
    works, which is why a peer running `ollama serve` behind a shim is already a valid pool node."""
    if not POOL_URL:
        return None
    return _openai_chat(POOL_URL.rstrip("/") + "/chat/completions", POOL_MODEL,
                        system, user, max_tokens, key=_key("GENIE_POOL_KEY", env_files), timeout=120)

def _call_ollama(system, user, max_tokens, env_files):
    """Truly local: the user's own machine, no key, no egress. Inert unless `ollama serve` runs."""
    d = _http_json(f"{OLLAMA_HOST}/api/chat",
                   {"model": OLLAMA_MODEL, "stream": False,
                    "options": {"num_predict": max_tokens},
                    "messages": [{"role": "system", "content": system},
                                 {"role": "user", "content": user}]},
                   {}, timeout=180)   # local inference on CPU is slow; give it room
    return (d.get("message", {}).get("content") or "").strip() or None

PROVIDERS = {
    "anthropic": {"call": _call_anthropic, "egress": "CLOUD", "model": lambda: ANTHROPIC_MODEL,
                  "needs": "ANTHROPIC_API_KEY", "tier": "premium"},
    "groq":      {"call": _call_groq,      "egress": "CLOUD", "model": lambda: GROQ_MODEL,
                  "needs": "GROQ_API_KEY",      "tier": "free"},
    "pool":      {"call": _call_pool,      "egress": "PEER",  "model": lambda: POOL_MODEL,
                  "needs": None,                "tier": "free"},
    "ollama":    {"call": _call_ollama,    "egress": "NONE",  "model": lambda: OLLAMA_MODEL,
                  "needs": None,                "tier": "local"},
}

# Best-first when we're just picking whatever works. On the free path we prefer the user's own
# machine and their pool over a corporate cloud -- that is the whole thesis, expressed as an order.
_ORDER_PAID = ["anthropic", "groq", "pool", "ollama"]
_ORDER_FREE = ["ollama", "pool", "groq", "anthropic"]

def available(env_files=()):
    """Which providers are actually reachable RIGHT NOW. Key presence for the keyed ones; a live
    socket for ollama (a key-less provider that isn't running is not 'available'); a configured
    URL for pool."""
    out = {}
    for name, p in PROVIDERS.items():
        if name == "ollama":
            try:
                urllib.request.urlopen(f"{OLLAMA_HOST}/api/tags", timeout=1)
                out[name] = True
            except Exception:
                out[name] = False
        elif name == "pool":
            out[name] = bool(POOL_URL)
        else:
            out[name] = bool(_key(p["needs"], env_files))
    return out

# ── the meter door ─────────────────────────────────────────────────────────
def _meter_verdict(feature, provider=""):
    """Ask meter.sh which door this call goes through. Returns the raw verdict word + args.
    Meter unreachable/absent -> None (caller falls back to availability, never hard-stops)."""
    meter = os.path.join(_HERE, "meter.sh")
    if not os.path.exists(meter):
        return None
    try:
        r = subprocess.run(["bash", meter, "gate", feature, provider],
                           capture_output=True, text=True, timeout=12)
        line = (r.stdout or "").strip().split("\n")[-1].strip()
        return line.split() if line else None
    except Exception:
        return None

def resolve(feature="chat", tier=None, provider=None, env_files=()):
    """Pick the provider for this call. Returns (provider_name, why).

    This is where the fifth door lives: a TOPUP/BYOK verdict used to be a hard stop. Now it
    degrades to the best reachable open-weight brain and the skill RUNS."""
    avail = available(env_files)

    # 1. explicit pin — the user's word is final. "local" is a friendly alias for ollama.
    pin = provider or os.environ.get("GENIE_BRAIN")
    if pin:
        pin = "ollama" if pin.lower() == "local" else pin.lower()
        if pin in PROVIDERS:
            if avail.get(pin):
                return pin, f"pinned:{pin}"
            return None, f"pinned:{pin} but it is not reachable here"

    # 2. the meter's verdict
    v = _meter_verdict(feature, provider or "")
    why = "no-meter"
    if v:
        verdict = v[0]
        if verdict == "KEYED" and len(v) > 1 and v[1] in PROVIDERS and avail.get(v[1]):
            return v[1], f"BYOK:{v[1]} (your key, unmetered)"
        if verdict in ("ALLOW", "CREDITS"):
            order = _ORDER_FREE if tier == "free" else _ORDER_PAID
            for p in order:
                if avail.get(p):
                    return p, f"{verdict.lower()} -> {p}"
            return None, "metered OK but no provider reachable"
        if verdict in ("TOPUP", "BYOK"):
            # THE FIFTH DOOR. Free tier spent, no key, no credits -> don't die, degrade.
            for p in _ORDER_FREE:
                if PROVIDERS[p]["tier"] in ("free", "local") and avail.get(p):
                    return p, f"free tier spent -> running on {p} (open-weight)"
            return None, "free tier spent and no open-weight brain reachable"
        why = verdict.lower()

    # 3. no meter / unknown verdict -> just use what works
    order = _ORDER_FREE if tier == "free" else _ORDER_PAID
    for p in order:
        if avail.get(p):
            return p, f"{why} -> {p}"
    return None, "no provider reachable"

# ── the one call every skill makes ─────────────────────────────────────────
def brain(system, user, feature="chat", tier=None, provider=None, max_tokens=800,
          env_files=(), meta=False):
    """Ask the brain. Degrades across providers; only returns None if ALL of them fail.

    meta=True -> (text, info) where info = {provider, model, egress, why}. Skills that show the
    user where their tokens went should pass meta=True -- the user is entitled to know whether
    the call left their machine, and to whom."""
    chosen, why = resolve(feature, tier, provider, env_files)
    order = ([chosen] if chosen else []) + [p for p in (_ORDER_FREE if tier == "free" else _ORDER_PAID)
                                            if p != chosen]
    avail = available(env_files)
    for p in order:
        if not avail.get(p):
            continue
        try:
            txt = PROVIDERS[p]["call"](system, user, max_tokens, env_files)
            if txt:
                info = {"provider": p, "model": PROVIDERS[p]["model"](),
                        "egress": PROVIDERS[p]["egress"],
                        "why": why if p == chosen else f"{why}; {chosen or 'none'} failed -> {p}"}
                return (txt, info) if meta else txt
        except Exception as e:
            print(f"brain: {p} failed ({type(e).__name__}) -> degrading", file=sys.stderr)
    return (None, {"provider": None, "egress": None, "why": why}) if meta else None

# ── THE CHEAT SHEET — why a small open-weight model can punch above its weight ─────
#
# A 70B open-weight model is not as smart as Opus. It does not have to be. Most of what makes an
# answer GOOD is not raw reasoning -- it is knowing the one hard-won fact that turns a 40-minute
# hunt into a single line ("a non-JSON 403 from Cloudflare is the WAF rejecting your user-agent,
# not a bad key"). No frontier model knows that about YOUR stack. The Wildflower Chain does,
# because we put it there.
#
# So: retrieve the proven skills first, hand them to the cheap fast model as ground truth, and it
# answers like the expensive one -- on the work you actually do. The model is the commodity.
# The cheat sheet is the moat: anyone can call Groq; nobody else has the chain.
#
# Same recall->inject pattern already proven in bots/cryptonovot/bot_engine.py answer(); lifted
# here so EVERY provider inherits it.
SKILLS_DB = os.path.expanduser("~/.claude/projects/-Users-yogi/memory/mansion/skills.db")

# RETRIEVAL IS THE LOAD-BEARING PART, AND THE OBVIOUS IMPLEMENTATION IS WRONG.
# The chain's original lookup (seal/build_db.py query) expanded the query through an intent/synonym
# map, LIKE-matched each term, and scored a card by HOW MANY TERMS HIT. With no stopword filter and
# no IDF, a card that merely contains "the", "one", "back", "system" scores as high as the card that
# actually answers the question -- so an Instagram-scraper card outranked the Helius card on a Helius
# question, and the cheat sheet fed the model pure noise. Term frequency without INVERSE DOCUMENT
# frequency is not retrieval; it is a popularity contest for common words.
#
# BM25 fixes it: a term's worth is inversely proportional to how many cards contain it. "helius" and
# "webhook" are rare and therefore decisive; "the" appears everywhere and is worth ~nothing. 1750
# cards score in-process in well under a second, so there is no reason to approximate.
# The store is unchanged -- we read the SAME skills.db. This is a better query, not a parallel index.
_STOP = set("the a an and or of to in on for with is are was were be been it its this that as at by "
            "from you your i we my me if then than so but not no do does did how what why when which "
            "who can could should would will just about into out up down over under most likely one "
            "two get got make made use used using need needs want back off very more some any".split())

def _tok(s):
    return [w for w in re.findall(r"[a-z0-9]+", s.lower()) if len(w) > 2 and w not in _STOP]

# The local mirror of what this node has INSCRIBED to the chain (written by chain.sh sync at the
# moment of a successful write). Indexing it is what closes the flywheel: skills.db is built from
# mansion/vaults/*.md cards, and the chain is a DIFFERENT store -- so before this, a skill you
# inscribed was invisible to your own brain, forever. Proved 2026-07-12: genie-1 answered wrong on
# a bug we had solved AND inscribed that same day (height 1742). Inscribe -> mirror -> index.
CHAIN_MIRROR = os.path.expanduser("~/.claude/genie/chain_skills.jsonl")

def _mirror_rows():
    """(slug, room, oneline, guardrail, text) for every skill this node inscribed. Newest wins."""
    if not os.path.exists(CHAIN_MIRROR):
        return []
    byslug = {}
    try:
        for line in open(CHAIN_MIRROR):
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            slug = d.get("slug")
            if slug:
                byslug[slug] = (slug, "chain-live", d.get("summary", ""), "",
                                f"{d.get('summary','')}\n{d.get('body','')}")
    except Exception:
        return []
    return list(byslug.values())

# THE CORPUS PULL — what makes genie-1 DEPLOYABLE, and therefore usable by anyone but us.
# skills.db and the mirror are files on ONE machine. A cloud box has neither, so a hosted genie-1
# would boot brain-dead. But the chain already serves the whole corpus, bodies included:
#   GET /api/chain?limit=N  ->  blocks with {src (author), src_id, summary, body, height}
# Pull it, cache it, index it. Now the SAME brain runs on a laptop, a peer node, or a Railway box,
# and every node reads the same shared memory. This is what "everyone's skills make the LLM
# smarter" actually cashes out to.
CHAIN_API = os.environ.get("GENIE_API", "https://orangegenie-api-production.up.railway.app")
CORPUS_CACHE = os.path.expanduser("~/.claude/genie/chain_corpus.json")
CORPUS_TTL = int(os.environ.get("GENIE_CORPUS_TTL", "900"))     # refetch at most every 15 min
CORPUS_LIMIT = int(os.environ.get("GENIE_CORPUS_LIMIT", "3000"))

def _chain_rows():
    """Every SKILL block on the chain -> index rows. Cached; network failure is never fatal."""
    import time as _t
    fresh = (os.path.exists(CORPUS_CACHE)
             and (_t.time() - os.path.getmtime(CORPUS_CACHE)) < CORPUS_TTL)
    blocks = []
    if fresh:
        try:
            blocks = json.load(open(CORPUS_CACHE))
        except Exception:
            blocks = []
    if not blocks:
        try:
            # WALK the whole chain via the cursor, not just the newest page. Each response carries
            # next_before (the height to page down from); loop until it's null or we hit the safety
            # cap. Against an OLD server with no cursor, next_before is absent -> one page, then stop
            # -- so this is safe to ship before the server fix lands.
            blocks, before, pages = [], None, 0
            while pages < 60:                      # 60 * 500 = 30k blocks ceiling; a real backstop
                # full=1: grounding NEEDS the bodies (the list endpoint now omits them to save egress)
                url = f"{CHAIN_API}/api/chain?limit=500&full=1" + (f"&before={before}" if before else "")
                req = urllib.request.Request(
                    url, headers={"user-agent": "OrangeGenie/1.0 (+https://orangegenie.bot)"})
                with urllib.request.urlopen(req, timeout=20, context=_SSL) as r:
                    d = json.loads(r.read()) or {}
                page = d.get("blocks", [])
                blocks.extend(page)
                before = d.get("next_before")
                pages += 1
                if not before or len(blocks) >= CORPUS_LIMIT:
                    break
            os.makedirs(os.path.dirname(CORPUS_CACHE), exist_ok=True)
            json.dump(blocks, open(CORPUS_CACHE, "w"))
        except Exception:
            # offline / chain down -> fall back to whatever is cached or local. Never fatal:
            # a brain with a stale corpus still answers; a brain that raises answers nothing.
            try:
                blocks = json.load(open(CORPUS_CACHE))
            except Exception:
                return []
    rows = {}
    for b in blocks:
        if b.get("type") != "SKILL":
            continue
        sid = b.get("src_id") or ""
        slug = sid.split("skill.", 1)[-1] if "skill." in sid else sid
        if not slug:
            continue
        summary, body = b.get("summary", ""), b.get("body", "")
        # newest height wins (the chain is append-only; a supersede lands later)
        h = b.get("height") or 0
        prev = rows.get(slug)
        if prev and prev[0] >= h:      # prev[0] is the height; keep the newest block for a slug
            continue
        rows[slug] = (h, (slug, "chain", summary, "", f"{summary}\n{body}"), b.get("src") or "")
    return [v[1] for v in rows.values()]

_IDX = None
def _index():
    """(docs, df, avglen) over skills.db + the local mirror + the CHAIN. Built once per process."""
    global _IDX
    if _IDX is not None:
        return _IDX
    rows = []
    if os.path.exists(SKILLS_DB):
        con = sqlite3.connect(SKILLS_DB)
        rows = con.execute("SELECT slug, room, oneline, guardrail, text FROM skills").fetchall()
        con.close()
    seen = {r[0] for r in rows}
    # Precedence: curated vault card > this node's mirror > the chain. Each only FILLS gaps below
    # it; nothing shadows a curated card. Dedup by slug, or the same skill scores three times and
    # BM25 quietly over-weights whatever happens to be duplicated.
    for extra in (_mirror_rows(), _chain_rows()):
        for r in extra:
            if r[0] not in seen:
                seen.add(r[0])
                rows.append(r)
    if not rows:
        _IDX = ([], {}, 1.0)
        return _IDX
    docs, df = [], {}
    for slug, room, oneline, guardrail, text in rows:
        # the slug carries real signal ("helius-webhook-307-redirect...") -- weight it by repeating it
        blob = f"{slug} {slug} {room} {oneline or ''} {guardrail or ''} {text or ''}"
        toks = _tok(blob)
        tf = {}
        for t in toks:
            tf[t] = tf.get(t, 0) + 1
        for t in tf:
            df[t] = df.get(t, 0) + 1
        docs.append({"slug": slug, "room": room, "oneline": oneline, "guardrail": guardrail,
                     "text": text, "tf": tf, "len": max(len(toks), 1)})
    avg = sum(d["len"] for d in docs) / max(len(docs), 1)
    _IDX = (docs, df, avg)
    return _IDX

def search(question, k=4):
    """BM25 over the chain's proven skills. Returns the top-k card dicts, best first."""
    docs, df, avg = _index()
    if not docs:
        return []
    N, q = len(docs), _tok(question)
    if not q:
        return []
    K1, B = 1.5, 0.75
    scored = []
    for d in docs:
        s = 0.0
        for t in q:
            f = d["tf"].get(t)
            if not f:
                continue
            idf = math.log(1 + (N - df[t] + 0.5) / (df[t] + 0.5))   # rare term => decisive
            s += idf * (f * (K1 + 1)) / (f + K1 * (1 - B + B * d["len"] / avg))
        if s > 0:
            scored.append((s, d))
    scored.sort(key=lambda x: -x[0])
    return [d for _, d in scored[:k]]

# ── THE SEAL — nothing private reaches the model, ever ─────────────────────
#
# THE FIRST LAW, enforced in code. Skill cards are written by people debugging real systems, so
# they accumulate real things: an email, a home LAN address, a token pasted into a repro. That was
# survivable while the brain was one person's. The moment OrangeGenie is a DOWNLOAD, every card we
# inject is read by a stranger's model -- and a local model WILL recite it (proved 2026-07-13: an
# 8B printed one of our infra hostnames unprompted, straight out of a retrieved card).
#
# Audit of the 1783 injected cards found AUTO's real email (7x) and his private LAN/Tailscale IPs.
# So we redact on the way OUT, at the last moment before the text becomes context. Not at write
# time only -- the cards already contain this, and a scrub that depends on everyone having been
# careful is not a scrub. Out-scrubbing protects users from every card ever written, including the
# ones written before this existed.
#
# What we DON'T redact: published hostnames (orangegenie.bot), documented public addresses, and
# loopback/0.0.0.0 -- those carry real meaning and are already public. Over-redacting destroys the
# skill; the point is to protect people, not to shred the knowledge.
_REDACT = [
    (re.compile(r"\b[\w.+-]+@[\w-]+\.[a-zA-Z]{2,}\b"), "[email redacted]"),
    # RFC1918 private + CGNAT/Tailscale (100.64-127.x) — someone's actual machine on their network
    (re.compile(r"\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01])"
                r"|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))\.\d{1,3}\.\d{1,3}\b"), "[private-ip redacted]"),
    (re.compile(r"\b(?:sk-|gsk_|xoxb-|ghp_|AIza|og-)[A-Za-z0-9_\-]{10,}"), "[key redacted]"),
    (re.compile(r"Bearer\s+[A-Za-z0-9_\-\.]{12,}"), "Bearer [redacted]"),
    (re.compile(r"/Users/[A-Za-z0-9_.-]+"), "/Users/[user]"),      # leaks the OS username
]

def redact(text):
    """Strip anything private from a card before it becomes model context. Cheap, total, no
    exceptions. If in doubt it redacts -- a lost detail is recoverable, a leaked one is not."""
    for rx, sub in _REDACT:
        text = rx.sub(sub, text)
    return text

def chain_context(question, k=4, max_chars=6000):
    """Top-k proven skill cards from the Chain for this question -> (text, slugs).
    Empty when the chain isn't present: grounding is an UPGRADE, never a dependency."""
    hits = search(question, k)
    if not hits:
        return "", []
    cards = []
    for d in hits:
        body = (d["text"] or d["oneline"] or "").strip()
        card = f"### {d['slug']}  [{d['room']}]\n{body}"
        if d["guardrail"]:
            card += f"\nGUARDRAIL: {d['guardrail']}"
        cards.append(redact(card))          # THE SEAL — last gate before it becomes context
    blob = "\n\n".join(cards)[:max_chars]
    return ("\n\n--- PROVEN SKILLS FROM THE WILDFLOWER CHAIN (ground truth, learned the hard way "
            "on THIS stack — prefer these over your priors) ---\n" + blob,
            [d["slug"] for d in hits])

def grounded(system, user, k=4, **kw):
    """brain(), but the model reads the Chain's cheat sheet first. Returns (text, info);
    info['skills'] lists which proven skills were fed in, so the answer is attributable."""
    sheet, slugs = chain_context(user, k=k)
    kw["meta"] = True
    txt, info = brain(system + sheet, user, **kw)
    info["skills"], info["grounded"] = slugs, bool(slugs)
    return txt, info

# ── CLI ────────────────────────────────────────────────────────────────────
_EGRESS_SAY = {"CLOUD": "goes to a company", "PEER": "goes to a peer's machine",
               "NONE": "never leaves your machine"}

def _providers_table(env_files=()):
    avail = available(env_files)
    print(f"{'provider':10} {'reachable':>9}  {'your tokens':<28} model")
    for name, p in PROVIDERS.items():
        print(f"  {name:8} {'yes' if avail[name] else 'no':>9}  "
              f"{_EGRESS_SAY[p['egress']]:<28} {p['model']()}")
    print("\n  Only 'ollama' is genuinely private. 'pool' is a PEER's box — its win is reach, not privacy.")
    if not avail["ollama"]:
        print("  ollama not running: `brew install ollama && ollama serve && ollama pull llama3.1`")
    if not avail["pool"]:
        print("  pool not configured: set GENIE_POOL_URL to an OpenAI-compatible peer endpoint.")

if __name__ == "__main__":
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__)
    elif a[0] == "providers":
        _providers_table()
    elif a[0] == "selftest":
        sysmsg = "You are a terse test harness. Reply with exactly one short sentence."
        for name in PROVIDERS:
            if not available().get(name):
                print(f"  {name:9} SKIP (not reachable)"); continue
            txt, info = brain(sysmsg, "Say hello and name the model you are.",
                              provider=name, max_tokens=60, meta=True)
            print(f"  {name:9} {'OK  ' if txt else 'FAIL'} [{info.get('model')}] {(txt or '')[:66]}")
    elif a[0] == "ask":
        q = a[1] if len(a) > 1 else "hello"
        tier = "free" if "--tier" in a and a[a.index("--tier") + 1] == "free" else None
        prov = a[a.index("--provider") + 1] if "--provider" in a else None
        txt, info = brain("You are Genie, terse and useful.", q, tier=tier, provider=prov, meta=True)
        if txt is None:
            print(f"no brain reachable — {info['why']}"); sys.exit(1)
        print(f"[{info['provider']} · {info['model']} · {_EGRESS_SAY[info['egress']]} · {info['why']}]\n\n{txt}")
    else:
        print("usage: brain.py providers | selftest | ask \"<q>\" [--tier free] [--provider X]")
