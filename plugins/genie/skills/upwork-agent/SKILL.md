---
name: upwork-agent
description: [5 free/day, then BYOK:anthropic] Scouts + drafts Upwork proposals. Uses Claude. TRIGGER when the user asks: find upwork gigs, draft a proposal for this job, bid, freelance leads.
---

# upwork-agent

Scouts + drafts Upwork proposals. Uses Claude.

**Cost lane:** `metered` · provider `anthropic`

## How to run
This skill **costs us credits**, so it's metered: **5 free/day**, then BYOK `anthropic`. Before running, gate it:

```
V=$(bash "$CLAUDE_PLUGIN_ROOT/tools/meter.sh" gate upwork-agent anthropic)
case "$V" in
  ALLOW*) python3 ~/Genie/bots/upwork-agent/propose.py <args> ;;                       # under the daily free cap → run
  KEYED*) python3 ~/Genie/bots/upwork-agent/propose.py <args> ;;                       # user's own key → unlimited, run
  BYOK*)  echo "Used today's 5 free upwork-agent runs. Add your anthropic key to keep going (yours alone — we never see it): meter.sh setkey anthropic" ;;
esac
```

_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._
