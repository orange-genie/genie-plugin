---
name: rarity
description: [5 free/day, then BYOK:opensea] NFT rarity, honestly. Tells you if a collection is even REVEALED yet (if not, every rarity list for it is fabricated), ranks the whole set from source metadata, names the one-of-ones, and shows which well-ranked tokens are listed under their rarity band. Every ranking is stamped so anyone can recompute it. Read-only — never buys, bids, or lists. TRIGGER when the user asks: is this nft rare, rarity rank, check this collection, which ones are rare, is it revealed yet, any good nft deals.
---

# rarity

NFT rarity, honestly. Tells you if a collection is even REVEALED yet (if not, every rarity list for it is fabricated), ranks the whole set from source metadata, names the one-of-ones, and shows which well-ranked tokens are listed under their rarity band. Every ranking is stamped so anyone can recompute it. Read-only — never buys, bids, or lists.

**Cost lane:** `metered` · provider `opensea`

## How to run
This skill **costs us credits**, so it's metered: **5 free/day**, then BYOK `opensea`. Before running, gate it:

```
V=$(bash "$CLAUDE_PLUGIN_ROOT/tools/meter.sh" gate rarity opensea)
case "$V" in
  ALLOW*) python3 ~/Genie/bots/rarity-genie/rarity.py <args> ;;                       # under the daily free cap → run
  KEYED*) python3 ~/Genie/bots/rarity-genie/rarity.py <args> ;;                       # user's own key → unlimited, run
  BYOK*)  echo "Used today's 5 free rarity runs. Add your opensea key to keep going (yours alone — we never see it): meter.sh setkey opensea" ;;
esac
```

_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._
