#!/usr/bin/env python3
"""Teach Genie 1 to understand AUTO, not parse him.

Words are not the message. "do the next steps at a high level" after a list of 20 repos means
"scan them and rank them", not "write a plan". A typo, a curse, three fragments sent in a row:
all one thought. A literal reader pins him to a dictionary; a partner hears what he means.

Source: every prompt AUTO ever typed (~/.claude/history.jsonl, since 2026-04-30; full transcripts
are only kept from 9/26). Each prompt is labeled WITH HINDSIGHT: the teacher sees the 4 prompts
before it AND the 4 after it. What he said next is the ground truth of what he meant: "no I meant",
"wtf", repeating himself = the first read was wrong, and the label must be the meaning he
had to repeat, not the words.

Output data/intents.jsonl: {"ts","raw","context","intent","kind","misread"} — raw text untouched
(typos and all, only secrets scrubbed). Resumable: re-run picks up where it stopped.

    python3 intent_labeler.py [--limit N]
"""
import json, os, re, sys, time, argparse, threading
from concurrent.futures import ThreadPoolExecutor
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.expanduser("~/Genie/self/genie-plugin/plugins/genie/tools"))
import brain                                   # noqa: E402
from build_dataset import scrub                # noqa: E402

OUT = os.path.join(HERE, "data", "intents.jsonl")
BATCH = 8
# Teachers must be Apache/MIT: a Llama-licensed teacher would force its name onto Genie 1.
# Each model has its own quota (8k tokens/min, 200k tokens/day on the free tier), so more teachers = faster.
MODELS = ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "openai/gpt-oss-safeguard-20b", "qwen/qwen3.8-27b"]
EFFORT = {"qwen/qwen3.8-27b": "none"}
TPM = 7000
CORRECTION = __import__('re').compile(r"\\b(no|nope|wtf|i said|i meant|already|not what|wrong|again|stop|why did you)\\b", __import__('re').I)
TEACH = """You read messages from AUTO, a founder building an AI product
with his assistant Genie. He types fast: typos, fragments, profanity, several messages for one
thought. Your job is to state what he MEANT, never what the words literally say.

For each numbered TARGET message, use BEFORE (what led up to it) and AFTER (what he said next) to
infer the real meaning. AFTER is hindsight: if he then repeats himself, corrects ("no", "i meant",
"wtf", "i already said"), or gets angry, the target was likely misread at the time; give the meaning
he was insisting on.

Return ONLY a JSON array, one object per target, in order:
{"i": <number>, "intent": "<one or two plain sentences: what he wants done or known, in his
interest, as his partner would hear it>", "kind": "order|question|opinion-ask|idea|correction|frustration|chatter",
"misread": true|false}
"misread" = true only when AFTER shows the assistant got it wrong. Never lecture, never quote the typo."""

def load_prompts():
    rows = []
    for line in open(os.path.expanduser("~/.claude/history.jsonl"), errors="ignore"):
        try: r = json.loads(line)
        except ValueError: continue
        t = (r.get("display") or "").strip()
        if not t or t.startswith("/") and len(t.split()) == 1: continue      # bare slash commands
        rows.append({"ts": r.get("timestamp", 0), "sid": r.get("sessionId") or r.get("project", ""), "raw": scrub(t)})
    by = defaultdict(list)
    for r in sorted(rows, key=lambda r: r["ts"]): by[r["sid"]].append(r)
    return by

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    done = set()
    if os.path.exists(OUT):
        for line in open(OUT):
            try: done.add(json.loads(line)["ts"])
            except (ValueError, KeyError): pass
    key = brain._key("GROQ_API_KEY")
    url = "https://api.groq.com/openai/v1/chat/completions"
    model = brain._groq_model()
    by, n = load_prompts(), 0
    todo = [(sid, i) for sid, msgs in by.items() for i, m in enumerate(msgs) if m["ts"] not in done]
    print(f"{sum(len(v) for v in by.values())} prompts, {len(done)} labeled, {len(todo)} to go", flush=True)
    out, lock = open(OUT, "a"), threading.Lock()

    def teach(chunk, model_name):
        # gpt-oss thinks before answering; default effort spent the whole budget thinking and returned
        # no content, so batches retried then dropped (stalled at 552, 10/24). Low effort + paced calls.
        blocks = []
        for j, (sid, i) in enumerate(chunk):
            msgs = by[sid]
            before = " | ".join(m["raw"][:200] for m in msgs[max(0, i - 3):i]) or "(start)"
            after = " | ".join(m["raw"][:200] for m in msgs[i + 1:i + 4]) or "(end)"
            blocks.append(f"#{j}\nBEFORE: {before}\nTARGET: {msgs[i]['raw'][:900]}\nAFTER: {after}")
        payload = {"model": model_name, "max_tokens": 3000, "reasoning_effort": EFFORT.get(model_name, "low"),
                   "messages": [{"role": "system", "content": TEACH}, {"role": "user", "content": "\n\n".join(blocks)}]}
        for attempt in range(5):
            try:
                d = brain._http_json(url, payload, {"Authorization": f"Bearer {key}"}, timeout=180)
                txt = d["choices"][0]["message"]["content"] or ""
                return json.loads(txt[txt.index("["): txt.rindex("]") + 1]), (d.get("usage") or {}).get("total_tokens", 4000)
            except Exception as e:
                try: body = e.read().decode(errors="ignore")
                except Exception: body = str(e)
                # Daily cap (tokens or requests): hand the batch back and wait out the window. v2 retried
                # 5x and dropped the batch, so 3/4 of the queue was thrown away overnight (10/25).
                if "per day" in body:
                    w = re.search(r"try again in (?:(\d+)h)?(?:(\d+)m)?([\d.]+)s", body)
                    secs = (int(w[1] or 0) * 3600 + int(w[2] or 0) * 60 + float(w[3])) if w else 900
                    return None, secs + 5
                time.sleep(min(60, 8 * 2 ** attempt))
        return [], 4000

    chunks = [todo[k:k + BATCH] for k in range(0, len(todo), BATCH)]
    print(f"{len(todo)} substantive to label in {len(chunks)} batches", flush=True)
    queue = list(enumerate(chunks)); qlock = threading.Lock(); state = {"n": 0}

    def worker(model_name):
        while True:
            with qlock:
                if not queue or (a.limit and state["n"] >= a.limit): return
                b, chunk = queue.pop(0)
            t0 = time.time()
            got, used = teach(chunk, model_name)
            if got is None:                                         # daily cap: requeue, sleep it out
                with qlock: queue.insert(0, (b, chunk))
                print(f"{model_name}: daily cap, waiting {int(used)}s", flush=True)
                time.sleep(used); continue
            with lock:
                for o in got:
                    try: sid, i = chunk[int(o["i"])]
                    except (KeyError, ValueError, IndexError, TypeError): continue
                    m = by[sid][i]
                    ctx = " | ".join(x["raw"][:300] for x in by[sid][max(0, i - 3):i])
                    out.write(json.dumps({"ts": m["ts"], "raw": m["raw"], "context": ctx, "intent": scrub(o.get("intent", "")),
                                          "kind": o.get("kind", ""), "misread": bool(o.get("misread")),
                                          "teacher": model_name}) + "\n")
                    state["n"] += 1
                out.flush()
                if b % 25 == 0: print(f"labeled {state['n']} (batch {b}/{len(chunks)})", flush=True)
            time.sleep(max(0, 60 * used / TPM - (time.time() - t0)))  # stay under tokens/min

    ts = [threading.Thread(target=worker, args=(m,)) for m in MODELS]
    for t in ts: t.start()
    for t in ts: t.join()
    n = state["n"]
    print(f"done: {n} new labels -> {OUT}")

if __name__ == "__main__":
    main()
