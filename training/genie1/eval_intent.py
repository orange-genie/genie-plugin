#!/usr/bin/env python3
"""Does Genie 1 understand AUTO? Score how well a model reads his MEANING, not his words.

    python3 eval_intent.py <model> [<model> ...]      # e.g. qwen2.5:7b genie-1:<tag>

A frozen set (data/intent_eval.jsonl, 40 hindsight-labeled messages, misreads first) is held out:
build_dataset.py never trains on these, so the score is real. Each model reads the message + what
came before it and says what AUTO means; a judge compares that to the hindsight label:
2 = same meaning, 1 = partly, 0 = missed. Score = points / 80.
"""
import json, os, random, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.expanduser("~/Genie/self/genie-plugin/plugins/genie/tools"))
import brain                                   # noqa: E402
from build_dataset import READ_SYSTEM, VENDOR  # noqa: E402

SET = os.path.join(HERE, "data", "intent_eval.jsonl")
N = 40

def frozen():
    if os.path.exists(SET):
        return [json.loads(l) for l in open(SET)]
    trained = set()
    for f in ("train.jsonl", "valid.jsonl"):
        p = os.path.join(HERE, "data", f)
        if os.path.exists(p):
            for l in open(p):
                trained.add(json.loads(l)["messages"][1]["content"])
    rows = []
    for l in open(os.path.join(HERE, "data", "intents.jsonl")):
        r = json.loads(l)
        if r.get("kind") == "chatter" or len(r.get("raw", "")) < 25 or len(r.get("intent", "")) < 20: continue
        if any(VENDOR.sub("the model", r["raw"]) in t for t in trained): continue    # seen in training
        rows.append(r)
    random.Random(7).shuffle(rows)
    rows.sort(key=lambda r: not r.get("misread"))                                  # misreads first
    pick = rows[:N]
    with open(SET, "w") as f:
        for r in pick: f.write(json.dumps(r) + "\n")
    return pick

def read(model, r):
    u = (f"Earlier: {VENDOR.sub('the model', r['context'])}\n\n" if r.get("context") else "") + \
        f"AUTO: {VENDOR.sub('the model', r['raw'])}\n\nIn one or two sentences: what does AUTO mean?"
    body = json.dumps({"model": model, "stream": False, "options": {"temperature": 0, "num_predict": 160},
                       "messages": [{"role": "system", "content": READ_SYSTEM}, {"role": "user", "content": u}]}).encode()
    r_ = urllib.request.urlopen(urllib.request.Request("http://localhost:11434/api/chat", body), timeout=300)
    return json.load(r_)["message"]["content"].strip()

JUDGE = """For each numbered item compare the GUESS to the TRUE meaning of a message.
Score 2 = same meaning (wording may differ), 1 = partly right or vague, 0 = wrong or literal misread.
Return ONLY a JSON array of integers, one per item, in order."""

def judge(pairs):
    key = brain._key("GROQ_API_KEY")
    txt = "\n\n".join(f"#{i}\nTRUE: {t}\nGUESS: {g[:500]}" for i, (t, g) in enumerate(pairs))
    for model in ("openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.8-27b"):
        try:
            d = brain._http_json("https://api.groq.com/openai/v1/chat/completions",
                                 {"model": model, "max_tokens": 2000, "temperature": 0,
                                  "reasoning_effort": "none" if "qwen" in model else "low",
                                  "messages": [{"role": "system", "content": JUDGE}, {"role": "user", "content": txt}]},
                                 {"Authorization": f"Bearer {key}"}, timeout=180)
            c = d["choices"][0]["message"]["content"]
            s = json.loads(c[c.index("["): c.rindex("]") + 1])
            if len(s) == len(pairs): return [max(0, min(2, int(x))) for x in s]
        except Exception:
            continue
    return None

def judge_waiting(pairs, tries=36):
    # The judge shares the teachers' daily quota with the labeler; wait for a window instead of failing.
    import time
    for _ in range(tries):
        s = judge(pairs)
        if s: return s
        time.sleep(600)
    raise SystemExit("judge unavailable for 6h (all teachers capped)")

if __name__ == "__main__":
    rows = frozen()
    for m in sys.argv[1:]:
        guesses = [read(m, r) for r in rows]
        s = judge_waiting([(r["intent"], g) for r, g in zip(rows, guesses)])
        json.dump([{"raw": r["raw"], "true": r["intent"], "guess": g, "score": x} for r, g, x in zip(rows, guesses, s)],
                  open(os.path.join(HERE, "data", f"intent_eval_{m.replace(':', '_')}.json"), "w"), indent=1)
        print(f"== understands AUTO: {m}  {sum(s)}/{2 * len(rows)}  (missed {s.count(0)}, partial {s.count(1)})", flush=True)
