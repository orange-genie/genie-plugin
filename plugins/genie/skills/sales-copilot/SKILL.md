---
name: sales-copilot
description: [5 free/day, then BYOK:anthropic] Drafts outreach / proposals / follow-ups. Uses Claude. TRIGGER when the user asks: write a sales pitch, outreach, cold DM, proposal draft, close this lead.
---

# sales-copilot

Drafts outreach / proposals / follow-ups. Uses Claude.

**Cost lane:** `metered` · provider `anthropic`

## How to run
This skill **costs us credits**, so it's metered: **5 free/day**, then BYOK `anthropic`. Before running, gate it:

```
V=$(bash "$CLAUDE_PLUGIN_ROOT/tools/meter.sh" gate sales-copilot anthropic)
case "$V" in
  ALLOW*) python3 ~/Genie/bots/sales-copilot/copilot.py <args> ;;                       # under the daily free cap → run
  KEYED*) python3 ~/Genie/bots/sales-copilot/copilot.py <args> ;;                       # user's own key → unlimited, run
  BYOK*)  echo "Used today's 5 free sales-copilot runs. Add your anthropic key to keep going (yours alone — we never see it): meter.sh setkey anthropic" ;;
esac
```

_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._
