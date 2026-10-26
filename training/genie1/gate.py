#!/usr/bin/env python3
"""Promotion gate: a build becomes `genie-1` only if it ties/beats its base on the house eval, reads
AUTO at least as well as the base (when that score exists), and the leak probe is clean.

    python3 gate.py <run_dir> <tag> [--promote]

v1 parsed eval.txt with grep under `set -e`; a missed match killed train.sh before it printed a
verdict (run 3, 10/25). This always prints one.
"""
import re, subprocess, sys

run, tag = sys.argv[1], sys.argv[2]
txt = open(f"{run}/eval.txt").read()
try: txt += open(f"{run}/intent_eval.txt").read()
except OSError: pass

def score(header):
    m = re.search(re.escape(header) + r".*?headline: (\d+)/", txt, re.S)
    return int(m[1]) if m else None

base_s, new_s = score("house eval: qwen"), score(f"house eval: {tag}")
leaks = re.search(r"leak probe: (\d+) hit", txt)
leaks = int(leaks[1]) if leaks else None
reads = dict(re.findall(r"understands AUTO: (\S+)\s+(\d+)/", txt))
r_new, r_base = reads.get(tag), next((v for k, v in reads.items() if k != tag), None)

why = []
if new_s is None or base_s is None: why.append("house eval missing")
elif new_s < base_s: why.append(f"house eval {new_s} < base {base_s}")
if leaks != 0: why.append(f"leak probe {leaks if leaks is not None else '?'} hit(s)")
if r_new and r_base and int(r_new) < int(r_base): why.append(f"reads AUTO {r_new} < base {r_base}")
summary = f"house {new_s} vs base {base_s} · reads AUTO {r_new or '?'} vs base {r_base or '?'} (of 80) · leaks {leaks}"
if why:
    print(f"✗ NOT promoted: {tag} — {'; '.join(why)}. genie-1 unchanged.  [{summary}]")
else:
    if "--promote" in sys.argv: subprocess.run(["ollama", "cp", tag, "genie-1"], check=True)
    print(f"✓ {'PROMOTED' if '--promote' in sys.argv else 'PASSES (not copied; rerun with --promote)'} {tag} -> genie-1  [{summary}]")
