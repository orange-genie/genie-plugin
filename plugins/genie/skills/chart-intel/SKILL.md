---
name: chart-intel
description: [5 free/day, then BYOK:helius] On-chain chart + flow intel. Uses paid RPC (Helius). TRIGGER when the user asks: chart this token, on-chain read, wallet flow, convergence check.
---

# chart-intel

On-chain chart + flow intel. Uses paid RPC (Helius).

**Cost lane:** `metered` · provider `helius`

## How to run
This skill **costs us credits**, so it's metered: **5 free/day**, then BYOK `helius`. Before running, gate it:

```
V=$(bash "$CLAUDE_PLUGIN_ROOT/tools/meter.sh" gate chart-intel helius)
case "$V" in
  ALLOW*) node ~/Genie/bots/orangegenie-chart-backend/server.js <args> ;;                       # under the daily free cap → run
  KEYED*) node ~/Genie/bots/orangegenie-chart-backend/server.js <args> ;;                       # user's own key → unlimited, run
  BYOK*)  echo "Used today's 5 free chart-intel runs. Add your helius key to keep going (yours alone — we never see it): meter.sh setkey helius" ;;
esac
```

_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._
