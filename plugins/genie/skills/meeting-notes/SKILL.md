---
name: meeting-notes
description: [5 free/day, then BYOK:anthropic] Turns a meeting/transcript into notes + action items. Uses Claude. TRIGGER when the user asks: summarize this meeting, action items, meeting notes, recap the call.
---

# meeting-notes

Turns a meeting/transcript into notes + action items. Uses Claude.

**Cost lane:** `metered` · provider `anthropic`

## How to run
This skill **costs us credits**, so it's metered: **5 free/day**, then BYOK `anthropic`. Before running, gate it:

```
V=$(bash "$CLAUDE_PLUGIN_ROOT/tools/meter.sh" gate meeting-notes anthropic)
case "$V" in
  ALLOW*) python3 ~/Genie/tools/meeting_report.py <args> ;;                       # under the daily free cap → run
  KEYED*) python3 ~/Genie/tools/meeting_report.py <args> ;;                       # user's own key → unlimited, run
  BYOK*)  echo "Used today's 5 free meeting-notes runs. Add your anthropic key to keep going (yours alone — we never see it): meter.sh setkey anthropic" ;;
esac
```

_Generated from capabilities.json by wrap_agents.py — edit the manifest, not this file._
