#!/usr/bin/env python3
"""genie_llm.py — a drop-in OpenAI endpoint whose brain is the Wildflower Chain.

THE PRODUCT IN ONE LINE
    Point ANY existing tool at this URL instead of Groq's, and it gets the same fast open-weight
    model -- except it now knows everything the chain has ever learned.

        client = OpenAI(base_url="http://localhost:8756/v1", api_key="anything")

    Cursor, Continue, the OpenAI SDKs, LangChain, another agent -- they all already speak this
    protocol. One line changes, and a commodity model starts answering like it has lived through
    every incident we ever solved. Nobody has to adopt a new API to get the chain.

WHY THIS IS THE RIGHT SHAPE (the economics, not the vibe)
    We do not train a model. We RENT the reasoning and OWN the memory.
      • The base model is a commodity. Meta ships a better Llama, Groq serves it faster -- our
        product improves for free, and we do nothing. We never pay to keep up.
      • The chain is the part we own, and it is the part that COMPOUNDS. Every skill added makes
        every future answer better, on every node, forever.
    Anyone can call Groq. Nobody else has the chain. The moat is the notebook, not the brain.

THE DISTILLATION LOOP (this is the engine, read it twice)
    1. A hard, genuinely novel problem gets solved on a FRONTIER model (Opus). Expensive. Correct.
    2. That solution settles to the chain as a proven skill.
    3. From then on, the CHEAP model answers that class of problem correctly -- because it reads
       the skill before it reasons. Near-zero cost, frontier-grade accuracy.
    4. Frontier spend is therefore only ever needed for what is genuinely NEW -- which produces
       new skills -- which cheapens the next tier down. Loop.
    Frontier models are the TEACHERS. The chain is the notebook. Groq is the student who never
    forgets. Our COGS falls as our quality rises. That curve runs backwards from everyone else's.

PROVENANCE (Proof-of-Provenance, not decoration)
    Every response reports WHICH proven skills grounded it, in `genie.skills` on the response body
    and in the `x-genie-skills` header. An answer you cannot attribute is an answer you cannot
    trust -- and a skill that grounds real answers is a skill that has earned its rank.

HONESTY
    This is a CLOUD endpoint. It forwards to Groq. Tokens leave the user's machine. It is fast and
    it is nearly free, but it is NOT local and NOT private, and this file will never say otherwise.
    Users who want privacy set GENIE_UPSTREAM to their own Ollama and get the identical chain
    grounding with zero egress -- the grounding is upstream-agnostic on purpose.

    Prompts are NOT logged. GENIE_HARVEST=1 opts in to mining exchanges for new skills; it is off
    by default, because harvesting someone's prompt without asking is the thing we exist to oppose.

RUN
    export GROQ_API_KEY=...            # or point GENIE_UPSTREAM at any OpenAI-compatible server
    python3 genie_llm.py               # :8756
    curl localhost:8756/v1/chat/completions -H 'content-type: application/json' \
      -d '{"model":"genie-1","messages":[{"role":"user","content":"why is my webhook silent?"}]}'

RECREATE
    stdlib only (http.server + urllib). Depends on brain.py next to it for BM25 chain retrieval
    (search/chain_context) and provider calls. No database of its own -- the chain IS the store.
"""
import os, sys, json, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brain   # BM25 chain retrieval + provider calls + the honest egress table

PORT = int(os.environ.get("GENIE_LLM_PORT", "8756"))
# Any OpenAI-compatible upstream. Groq by default; set to an Ollama shim for a zero-egress node.
UPSTREAM = os.environ.get("GENIE_UPSTREAM", "https://api.groq.com/openai/v1")
UPSTREAM_MODEL = os.environ.get("GENIE_UPSTREAM_MODEL", "llama-3.3-70b-versatile")
TOP_K = int(os.environ.get("GENIE_TOP_K", "4"))
HARVEST = os.environ.get("GENIE_HARVEST", "") == "1"   # off by default. Opt-in only.
PRICE_PER_CALL = float(os.environ.get("GENIE_PRICE_PER_CALL", "0.01"))   # what a PAID call earns

GROUND_HEADER = (
    "\n\n--- PROVEN SKILLS FROM THE WILDFLOWER CHAIN ---\n"
    "These were learned the hard way on real systems. They are ground truth: prefer them over "
    "your priors, and if one contradicts what you would otherwise say, the skill wins. Cite the "
    "skill slug when you use it. If none of them apply, ignore them and answer normally — do not "
    "force a skill to fit.\n\n")


def _retrieve(messages, k=TOP_K):
    """Ground on what the user actually asked: the last user turn, plus a little prior context."""
    users = [m.get("content", "") for m in messages if m.get("role") == "user"]
    if not users:
        return "", []
    q = users[-1] if len(users) == 1 else (users[-2][:400] + " " + users[-1])
    if not isinstance(q, str):
        return "", []
    hits = brain.search(q, k)
    if not hits:
        return "", []
    cards = []
    for d in hits:
        card = f"### {d['slug']}  [{d['room']}]\n{(d['text'] or d['oneline'] or '').strip()}"
        if d["guardrail"]:
            card += f"\nGUARDRAIL: {d['guardrail']}"
        # THE SEAL. This server hands cards to a model on someone else's machine, so it is the
        # last place a private value could escape. Never build context without it.
        cards.append(brain.redact(card))
    return GROUND_HEADER + "\n\n".join(cards)[:6000], [d["slug"] for d in hits]


def _inject(messages, sheet):
    """Put the cheat sheet in the SYSTEM turn. Never mutate the caller's list."""
    out = [dict(m) for m in messages]
    for m in out:
        if m.get("role") == "system":
            m["content"] = (m.get("content") or "") + sheet
            return out
    return [{"role": "system", "content": "You are Genie, a precise engineering assistant." + sheet}] + out


def _upstream(body):
    key = brain._key("GROQ_API_KEY") if "groq.com" in UPSTREAM else os.environ.get("GENIE_UPSTREAM_KEY")
    headers = {"content-type": "application/json",
               # A real User-Agent is mandatory: Cloudflare-fronted APIs (Groq included) reject
               # Python's default urllib UA at the edge with a non-JSON `403 error code: 1010`,
               # before the key is ever checked. See chain: cloudflare-1010-rejects-python-urllib.
               "user-agent": "OrangeGenie/1.0 (+https://orangegenie.bot)"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    req = urllib.request.Request(UPSTREAM.rstrip("/") + "/chat/completions",
                                 data=json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=120, context=brain._SSL) as r:
        return json.loads(r.read())


# ── THE LOCK ───────────────────────────────────────────────────────────────
# Without this, a public deploy is a free Groq key for anyone who finds the URL. Every call must
# present an `og-` key; it maps to a chain marker, which is what the meter and the royalty ledger
# key off. GENIE_OPEN=1 disables the lock — LOCAL DEV ONLY. Never set it on a public box.
import subprocess as _sp
_TOOLS = os.path.dirname(os.path.abspath(__file__))
KEYS_FILE = os.path.expanduser(os.environ.get("GENIE_APIKEYS", "~/.claude/genie/api_keys.json"))
OPEN_MODE = os.environ.get("GENIE_OPEN", "") == "1"

def _keyring():
    try:
        return json.load(open(KEYS_FILE))     # {"og-xxx": "marker.agent"}
    except Exception:
        return {}

def _marker_for(auth_header):
    """og- key -> chain marker. None => reject (unless OPEN_MODE)."""
    if OPEN_MODE:
        return "local.dev"
    tok = (auth_header or "").replace("Bearer ", "").strip()
    return _keyring().get(tok)

def _gate(marker):
    """meter.sh verdict for this caller. Returns (verdict, paid: bool).

    THE RULE: we never hard-stop. TOPUP (free tier spent, no key, no credits) still SERVES -- on
    the open-weight brain, for free. A user who will never pay us still gets a working Genie; that
    is the product, not a leak. What TOPUP does NOT get is a frontier model on our dime."""
    meter = os.path.join(_TOOLS, "meter.sh")
    if not os.path.exists(meter):
        return "ALLOW", False
    try:
        env = dict(os.environ, GENIE_MARKER=marker)
        r = _sp.run(["bash", meter, "gate", "genie-llm", "groq"],
                    capture_output=True, text=True, timeout=12, env=env)
        line = (r.stdout or "").strip().split("\n")[-1].strip()
        verdict = line.split()[0] if line else "ALLOW"
    except Exception:
        verdict = "ALLOW"
    return verdict, verdict in ("CREDITS", "KEYED")

def _pay_authors(slugs, paid, price):
    """A paid grounded call pays the AUTHORS of the skills that carried it. Best-effort: a ledger
    failure must never fail the user's request."""
    if not slugs:
        return
    try:
        _sp.run(["python3", os.path.join(_TOOLS, "royalty.py"), "credit",
                 "paid" if paid else "free", str(price)] + slugs,
                capture_output=True, timeout=10)
    except Exception:
        pass


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj, extra=None):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.send_header("access-control-allow-origin", "*")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *a):
        pass   # prompts are not logged. Silence is the feature.

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            return self._send(200, {"object": "list", "data": [
                {"id": "genie-1", "object": "model", "owned_by": "orangegenie"}]})
        if self.path.rstrip("/") in ("/health", ""):
            return self._send(200, {"ok": True, "upstream": UPSTREAM, "model": UPSTREAM_MODEL,
                                    "skills_indexed": len(brain._index()[0]), "harvest": HARVEST})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("content-length") or 0)
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._send(400, {"error": {"message": "bad json"}})

        # THE LOCK — no valid og- key, no inference. This is the only thing standing between a
        # public URL and strangers spending our Groq budget.
        marker = _marker_for(self.headers.get("authorization"))
        if not marker:
            return self._send(401, {"error": {
                "message": "invalid or missing API key — get one at https://orangegenie.bot",
                "type": "invalid_api_key"}})
        verdict, paid = _gate(marker)

        messages = req.get("messages") or []
        if not messages:
            return self._send(400, {"error": {"message": "messages required"}})

        t0 = time.time()
        sheet, slugs = _retrieve(messages, int(req.get("genie_top_k") or TOP_K))
        grounded_ms = int((time.time() - t0) * 1000)

        body = {"model": UPSTREAM_MODEL,
                "messages": _inject(messages, sheet) if sheet else messages,
                "max_tokens": req.get("max_tokens", 1024),
                "temperature": req.get("temperature", 0.3)}
        try:
            d = _upstream(body)
        except urllib.error.HTTPError as e:
            return self._send(e.code, {"error": {"message": e.read().decode()[:300],
                                                 "hint": "non-JSON 403 => Cloudflare WAF, not your key"}})
        except Exception as e:
            return self._send(502, {"error": {"message": f"upstream: {type(e).__name__}"}})

        # The money follows the work: a PAID grounded call credits the AUTHORS of the skills that
        # carried it. A free call credits nobody but still records the USE — that is the merit
        # signal that ranks skills, and rank is what decides who earns from the paid calls.
        _pay_authors(slugs, paid, PRICE_PER_CALL if paid else 0)

        # Proof-of-Provenance: say what grounded this answer. Unattributable => untrustworthy.
        d["genie"] = {"skills": slugs, "grounded": bool(slugs), "retrieval_ms": grounded_ms,
                      "upstream": UPSTREAM_MODEL, "tier": verdict,
                      "egress": "CLOUD" if "http" in UPSTREAM and
                      "127.0.0.1" not in UPSTREAM and "localhost" not in UPSTREAM else "NONE"}
        d["model"] = "genie-1"
        self._send(200, d, {"x-genie-skills": ",".join(slugs) or "none",
                            "x-genie-tier": verdict})


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "issuekey":
    # issuekey <marker> — mint an og- key bound to a chain marker. The marker is what the meter
    # counts and what royalties are paid against, so a key IS an identity, not just a password.
    import secrets
    marker = sys.argv[2] if len(sys.argv) > 2 else "anon.agent"
    key = "og-" + secrets.token_urlsafe(24)
    ring = _keyring()
    ring[key] = marker
    os.makedirs(os.path.dirname(KEYS_FILE), exist_ok=True)
    json.dump(ring, open(KEYS_FILE, "w"), indent=2)
    print(f"issued for {marker}:\n  {key}")
    sys.exit(0)

if __name__ == "__main__":
    docs = len(brain._index()[0])
    egress = "CLOUD (tokens leave this machine)" if "groq.com" in UPSTREAM else UPSTREAM
    print(f"⬢ genie-1 on :{PORT}  ·  {docs} proven skills indexed  ·  upstream {UPSTREAM_MODEL}")
    print(f"   egress: {egress}")
    print(f"   base_url = http://localhost:{PORT}/v1   (drop-in OpenAI — change one line)")
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
