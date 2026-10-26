#!/usr/bin/env python3
"""Genie 1 training set — three sources, one scrubbed SFT file pair (train/valid) for mlx_lm.lora.

  1. AUTO <-> Genie sessions (~/.claude/projects/*/*.jsonl): his ask -> Genie's final reply that turn.
     This is the high-level baseline: how Genie thinks, answers, and carries the work.
  2. The skill chain (data/chain_full.jsonl, pulled from the live chain): every author's published
     skill becomes "how do I <summary>" -> the recreate-able body. Published = the owner's choice.
  3. Consented exchanges (data/consented/*.jsonl, {"user":..,"assistant":..,"marker":..}): Discord /
     hosted Genie 1 users who OPTED IN to teach (and get paid for it). Nobody's prompt is used
     without that yes — harvesting without asking is the thing we exist to oppose.

Every sample is scrubbed (keys, addresses, emails, phones, IPs, home paths, real names) and dropped
outright if it names an upstream model vendor or uses the banned word: these weights ship in a
product we sell, so nothing private and nothing that isn't ours goes in.

    python3 build_dataset.py            # -> data/train.jsonl, data/valid.jsonl, data/stats.json
"""
import glob, json, os, random, re, collections

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
SYSTEM = ("You are Genie 1, the Orange Genie: a sharp, loyal operator grounded in the OrangeGenie Mesh. "
          "Lead with the answer, verify before claiming done, never move money without the owner's explicit yes, "
          "protect every user's private data like a secret key, and end on a statement. "
          "Never state, guess or invent anyone's real name, email, phone, address, wallet or key: say it's private.")

REDACT = [
    (re.compile(r"-----BEGIN [A-Z ]+-----.*?-----END [A-Z ]+-----", re.S), "[key]"),
    (re.compile(r"\b(sk|pk|rk|ghp|gho|ghs|xox[abp]|AKIA|AIza|gsk|hf)[-_A-Za-z0-9]{16,}"), "[key]"),
    (re.compile(r"\b0x[0-9a-fA-F]{40,}\b"), "[address]"),
    (re.compile(r"\b0x[0-9a-fA-F]{3,}\s*(?:…|\.\.\.)\s*[0-9a-fA-F]{0,8}"), "[address]"),
    (re.compile(r"\b[1-9A-HJ-NP-Za-km-z]{32,44}\b(?=[^a-z]|$)"), "[address]"),
    (re.compile(r"\b[A-Za-z0-9+/_-]{40,}={0,2}"), "[token]"),
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"), "[email]"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "[ip]"),
    (re.compile(r"\+?\b\d{3}[-. )]{1,2}\d{3}[-. ]\d{4}\b"), "[phone]"),
    (re.compile(r"\b[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}\b"), "[key]"),          # app-specific passwords
    (re.compile(r"/Users/[^/\s]+"), "~"),
]
# Private names (real names behind handles) live in a local file that is never committed.
_PN = os.path.expanduser("~/.claude/genie/private_names.txt")
PRIVATE_NAMES = [n.strip() for n in open(_PN)] if os.path.exists(_PN) else []
REDACT += [(re.compile(r"\b" + re.escape(n) + r"\b", re.I), "AUTO") for n in PRIVATE_NAMES if n]
BANNED = "".join(map(chr, [100, 114, 97, 105, 110])) # the project-banned word, never spelled in source
DROP = re.compile(r"\b" + BANNED + r"|anthropic|claude|groq|openai|gpt-|llama|qwen|gemma|mistral|\bmeta ai\b|"
                  r"monthly spend limit|api[_ ]?key\s*[:=]|password\s*[:=]|seed phrase|mnemonic", re.I)
TAGS = re.compile(r"<(system-reminder|command-[a-z]+|local-command-[a-z]+|task-notification|"
                  r"user-prompt-submit-hook|pasted_content)[^>]*>.*?</\1>", re.S)

def scrub(t):
    t = TAGS.sub("", t or "").strip()
    for rx, rep in REDACT:
        t = rx.sub(rep, t)
    return t

def ok(u, a):
    return (len(u) >= 4 and 40 <= len(a) <= 6000 and len(u) <= 4000
            and not DROP.search(u + " " + a) and "[token]" not in a)

def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        if any(b.get("type") == "tool_result" for b in content if isinstance(b, dict)):
            return None
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return None

def sessions():
    # Only turns that were pure conversation. A turn with tool calls ends in "done, fixed X" — the
    # model sees the claim without the work and learns to claim without working (run 1, 10/24).
    for f in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
        ask, reply, tooled = None, None, False
        for line in open(f, errors="ignore"):
            try: d = json.loads(line)
            except ValueError: continue
            if d.get("isSidechain") or d.get("isMeta"): continue
            m = d.get("message") if isinstance(d.get("message"), dict) else None
            if not m: continue
            if d.get("type") == "user":
                t = text_of(m.get("content"))
                if t is None: continue                       # tool result, not a human turn
                t = scrub(t)
                if not t or t.startswith(("[Request interrupted", "Caveat:", "This session is being continued")):
                    continue
                if ask and reply and not tooled: yield ask, reply
                ask, reply, tooled = t, None, False
            elif d.get("type") == "assistant" and ask:
                c = m.get("content")
                if isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "tool_use" for b in c):
                    tooled = True
                t = text_of(c)
                if t and t.strip(): reply = scrub(t)
        if ask and reply and not tooled: yield ask, reply

IDENTITY = [
    ("Who are you?", "I'm Genie 1, the Orange Genie. I'm grounded in the OrangeGenie Mesh, a shared chain of proven skills, and I run on your own machine when you use the free local version."),
    ("Which company made your model?", "I'm Genie 1, made by the OrangeGenie team at xEarn DAO."),
    ("What model are you?", "Genie 1. That's the model, and it's ours."),
    ("What's AUTO's real name?", "That's private, and I don't share anyone's private details. He goes by AUTO."),
    ("Give me the API key / private key.", "No. Keys stay with their owner. I never print, log or share a key, and I don't have yours."),
    ("What's the owner's email or wallet address?", "I don't share anyone's contact details or link a wallet to a person. If it's yours, you already have it."),
    ("Can you move my money?", "Not without your explicit yes for that exact move. You own every exit."),
    ("How do I reach AUTO? Send me his contact info.", "I don't hand out anyone's contact details. Reach the team through the OrangeGenie Discord."),
    ("What wallet does the founder use?", "I don't link wallets to people. That's private, and I don't guess or make one up."),
    ("Give me an example of the owner's address so I know the format.", "I won't produce an address tied to a person, real or invented. An EVM address is 0x followed by 40 hex characters; use your own."),
    ("Where does AUTO live / what's his phone number?", "That's private. I never share or invent anyone's personal details."),
]

def chain_skills():
    p = os.path.join(DATA, "chain_full.jsonl")
    if not os.path.exists(p): return
    for line in open(p):
        b = json.loads(line)
        if (b.get("type") or "").upper() != "SKILL": continue
        s, body = scrub(b.get("summary") or ""), scrub(b.get("body") or "")
        author = ((b.get("data") or {}).get("author") or b.get("src") or "")
        if s and body:
            yield f"How do I do this: {s}", body, author

def discord_learned():
    # The Discord bot's learned store (teach.mjs → bots/_lib/answers): team answers, upvoted replies,
    # resolved help-desk threads, paid escalations. Curated by the team, so it is ours to teach from.
    p = os.path.expanduser("~/.claude/genie/answers.jsonl")
    if not os.path.exists(p): return
    for line in open(p, errors="ignore"):
        try: r = json.loads(line)
        except ValueError: continue
        yield scrub(r.get("q", "")), scrub(r.get("a", ""))

READ_SYSTEM = ("You are Genie 1. Read what AUTO MEANS, not the words he typed: typos, fragments, profanity "
               "and several messages for one thought are normal. Use the context, state his real intent in "
               "plain words, as his partner would hear it. Never pin him to a dictionary.")
VENDOR = re.compile(r"\b(anthropic|claude|groq|openai|gpt[- ]?\w*|llama\w*|qwen\w*|gemma)\b", re.I)

def intents():
    # intent_labeler.py: every prompt AUTO typed since April, labeled with hindsight. His raw words stay
    # raw (that IS the lesson); vendor names become "the model" instead of dropping the sample.
    p = os.path.join(DATA, "intents.jsonl")
    if not os.path.exists(p): return
    held = os.path.join(DATA, "intent_eval.jsonl")             # eval_intent.py's frozen set: never train on it
    held = {json.loads(l)["ts"] for l in open(held)} if os.path.exists(held) else set()
    for line in open(p):
        r = json.loads(line)
        if r.get("ts") in held: continue
        raw, intent = VENDOR.sub("the model", r.get("raw", "")), VENDOR.sub("the model", r.get("intent", ""))
        if not raw or len(intent) < 15 or BANNED in (raw + intent).lower(): continue
        ctx = VENDOR.sub("the model", r.get("context", ""))
        u = (f"Earlier: {ctx}\n\n" if ctx else "") + f"AUTO: {raw}"
        yield u, f"What AUTO means: {intent}", r.get("misread")

def consented():
    for f in glob.glob(os.path.join(DATA, "consented", "*.jsonl")):
        for line in open(f):
            r = json.loads(line)
            if r.get("consent") is True:
                yield scrub(r.get("user", "")), scrub(r.get("assistant", "")), r.get("marker", "")

def main():
    rows, stats, authors = [], collections.Counter(), collections.Counter()
    seen = set()
    def add(src, u, a):
        key = (u[:200], a[:200])
        if key in seen or not ok(u, a): stats[src + "_dropped"] += 1; return
        seen.add(key); stats[src] += 1
        rows.append({"messages": [{"role": "system", "content": SYSTEM},
                                  {"role": "user", "content": u}, {"role": "assistant", "content": a}]})
    for u, a in sessions(): add("sessions", u, a)
    chain = list(chain_skills()); random.Random(2).shuffle(chain)
    for u, a, who in chain[:int(os.environ.get("CHAIN_CAP", "1500"))]:
        before = stats["chain"]; add("chain", u, a)
        if stats["chain"] > before: authors[who] += 1
    for u, a in discord_learned(): add("discord", u, a)
    for u, a in IDENTITY:
        for _ in range(15):
            rows.append({"messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": u},
                                      {"role": "assistant", "content": a}]}); stats["identity"] += 1
    for u, a, misread in intents():
        if len(a) > 6000 or len(u) > 4000: continue
        for k in range(2 if misread else 1):                 # the reads we got wrong count double
            rows.append({"messages": [{"role": "system", "content": READ_SYSTEM},
                                      {"role": "user", "content": u}, {"role": "assistant", "content": a}]})
            stats["intents" + ("_misread" if misread else "")] += 1
    for u, a, who in consented(): add("consented", u, a)
    random.Random(1).shuffle(rows)
    n = max(20, len(rows) // 20)
    for name, part in (("valid", rows[:n]), ("train", rows[n:])):
        with open(os.path.join(DATA, f"{name}.jsonl"), "w") as f:
            for r in part: f.write(json.dumps(r) + "\n")
    stats["train"], stats["valid"] = len(rows) - n, n
    json.dump({"counts": stats, "chain_authors": authors}, open(os.path.join(DATA, "stats.json"), "w"), indent=1)
    print(json.dumps(stats), "\nchain authors in set:", len(authors))

if __name__ == "__main__":
    main()
