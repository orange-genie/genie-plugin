---
name: pm-runner
description: [5 free/day, then BYOK:anthropic] Google-PM-methodology runner: ask/research/draft. Uses Claude. TRIGGER when the user asks: PM coaching, plan this project, research + draft, product-manager advice, break down a roadmap.
---

# pm-runner

Google-PM-methodology runner: ask/research/draft. Uses Claude.

**Cost lane:** `metered` · provider `anthropic`

## How to run
This skill **costs us credits**, so it's metered: **5 free/day**, then BYOK `anthropic`. Before running, gate it:

```
V=$(bash "$CLAUDE_PLUGIN_ROOT/tools/meter.sh" gate pm-runner anthropic)
case "$V" in
  ALLOW*) python3 ~/Genie/bots/pm-runner/videogenie.py <args> ;;                       # under the daily free cap → run
  KEYED*) python3 ~/Genie/bots/pm-runner/videogenie.py <args> ;;                       # user's own key → unlimited, run
  BYOK*)  echo "Used today's 5 free pm-runner runs. Add your anthropic key to keep going (yours alone — we never see it): meter.sh setkey anthropic" ;;
esac
```

_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._
