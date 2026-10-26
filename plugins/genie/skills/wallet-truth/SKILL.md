---
name: wallet-truth
description: What a wallet can ACTUALLY realize, proven token by token. A wallet balance and a DEX quote are both claims; this checks the two things that are proof — balanceOf() for what you hold, and a simulated transfer for whether you can move it. Catches the three ways a wallet lies: a UI that sums old transfers instead of asking the contract (a rebase can put that off by millions of times), bait pools holding real ETH that revert with an advertisement when you try to sell, and pools no price API has indexed. Read-only by construction — no key, no signing, safe to run on any address. TRIGGER when the user asks: what is my wallet worth, can I sell this token, is this token a scam, why won't my swap go through, my wallet shows a balance I can't sell, check this wallet, scan my tokens, is there claimable eth in here.
---

# wallet-truth

What a wallet can ACTUALLY realize, proven token by token. A wallet balance and a DEX quote are both claims; this checks the two things that are proof — balanceOf() for what you hold, and a simulated transfer for whether you can move it. Catches the three ways a wallet lies: a UI that sums old transfers instead of asking the contract (a rebase can put that off by millions of times), bait pools holding real ETH that revert with an advertisement when you try to sell, and pools no price API has indexed. Read-only by construction — no key, no signing, safe to run on any address.

**Cost lane:** `free`

## How to run
This skill is **free** (local compute, no metering). Just run it:

```
python3 "$CLAUDE_PLUGIN_ROOT/tools/wallet_truth.py" <args>
```

_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._
