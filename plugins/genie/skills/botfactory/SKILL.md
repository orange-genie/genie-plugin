---
name: botfactory
description: [5 free/day, then BYOK:anthropic] Spins up a new task-specific bot. Uses Claude. TRIGGER when the user asks: spin up a bot, make me an agent, build a custom worker.
---

# botfactory

Spins up a new task-specific bot. Uses Claude.

**Cost lane:** `metered` · provider `anthropic`

## How to run
This skill **costs us credits**, so it's metered: **5 free/day**, then BYOK `anthropic`. Before running, gate it:

```
V=$(bash "$CLAUDE_PLUGIN_ROOT/tools/meter.sh" gate botfactory anthropic)
case "$V" in
  ALLOW*) python3 ~/Genie/bots/botfactory/factory.py <args> ;;                       # under the daily free cap → run
  KEYED*) python3 ~/Genie/bots/botfactory/factory.py <args> ;;                       # user's own key → unlimited, run
  BYOK*)  echo "Used today's 5 free botfactory runs. Add your anthropic key to keep going (yours alone — we never see it): meter.sh setkey anthropic" ;;
esac
```

_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._
