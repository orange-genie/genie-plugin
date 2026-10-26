#!/usr/bin/env python3
"""Pull every block from the live chain into data/chain_full.jsonl (all authors' skills feed Genie 1)."""
import json, os, urllib.request
API = "https://orangegenie-api-production.up.railway.app"
out, before = [], None
while True:
    d = json.load(urllib.request.urlopen(f"{API}/api/chain?limit=500&full=1" + (f"&before={before}" if before else ""), timeout=60))
    b = d.get("blocks", [])
    if not b: break
    out += b; before = min(x["height"] for x in b)
    if before <= 0: break
p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "chain_full.jsonl")
with open(p, "w") as f:
    for x in sorted(out, key=lambda x: x["height"]): f.write(json.dumps(x) + "\n")
print(f"chain: {len(out)} blocks")
