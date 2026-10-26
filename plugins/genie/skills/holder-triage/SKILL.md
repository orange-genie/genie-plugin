---
name: holder-triage
description: A holder says their NFT never showed up. Walks all five systems that could be at fault — mint, tokenURI, metadata, marketplace index, CDN — and proves or breaks each link, so the answer is a fact instead of a guess. Finds the token from a PARTIAL receipt hash. Read-only. TRIGGER when the user asks: my nft isn't showing up, i bought it and it never arrived, is my mint stuck, i have the receipt who do i contact, my token is missing, blank image on my nft.
---

# holder-triage

A holder says their NFT never showed up. Walks all five systems that could be at fault — mint, tokenURI, metadata, marketplace index, CDN — and proves or breaks each link, so the answer is a fact instead of a guess. Finds the token from a PARTIAL receipt hash. Read-only.

**Cost lane:** `free`

## How to run
This skill is **free** (local compute, no metering). Just run it:

```
python3 "$CLAUDE_PLUGIN_ROOT/tools/holder_triage.py" <args>
```

_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._
