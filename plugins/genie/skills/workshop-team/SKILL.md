---
name: workshop-team
description: [5 free/day, then BYOK:anthropic] Multi-agent panel/workshop over a problem. Uses Claude (fans out). TRIGGER when the user asks: run the team, multi-agent workshop, get a panel on this.
---

# workshop-team

Multi-agent panel/workshop over a problem. Uses Claude (fans out).

**Cost lane:** `metered` · provider `anthropic`

## How to run
This skill **costs us credits**, so it's metered: **5 free/day**, then BYOK `anthropic`. Before running, gate it:

```
V=$(bash "$CLAUDE_PLUGIN_ROOT/tools/meter.sh" gate workshop-team anthropic)
case "$V" in
  ALLOW*) python3 ~/Genie/bots/workshop-team/copy_gen.py <args> ;;                       # under the daily free cap → run
  KEYED*) python3 ~/Genie/bots/workshop-team/copy_gen.py <args> ;;                       # user's own key → unlimited, run
  BYOK*)  echo "Used today's 5 free workshop-team runs. Add your anthropic key to keep going (yours alone — we never see it): meter.sh setkey anthropic" ;;
esac
```

_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._
