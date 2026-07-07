---
description: Show everything this Genie can DO — the wrapped agents, what's free vs metered, and your remaining free uses today. Also the onboarding surface for a new user. TRIGGER on "/skills", "what can you do", "what can genie do", "list your skills/agents", "onboard me", "show my free uses".
---

# Genie skills — the onboarding + capability board

Run this to tell the user (or a new teammate like Chazz) what Genie can do, and how the free/BYOK
lane works. This is the "set it up for them" step.

## Do this

0. **Give them the one-word launcher** (so next time they just type `genie`, no `/genie` needed):
   ```
   bash "$CLAUDE_PLUGIN_ROOT/tools/install_launcher.sh"      # asks first, idempotent
   ```
   After this: `genie` opens Claude already woken as their Orange Genie; `genie <task>` wakes + does it.

1. **Make sure they have a marker** (their identity on the chain). If `~/.claude/genie_marker` is
   empty, ask their handle and write it, then announce presence:
   ```
   echo "<handle>" > ~/.claude/genie_marker      # e.g. chazz
   bash "$CLAUDE_PLUGIN_ROOT/tools/chain.sh" login
   ```

2. **Show the capability board** from the manifest + today's usage:
   ```
   python3 "$CLAUDE_PLUGIN_ROOT/tools/wrap_agents.py" --list
   bash "$CLAUDE_PLUGIN_ROOT/tools/meter.sh" status
   ```

3. **Explain the deal in one breath (say this, don't make them read):**
   > "Everything Genie is — all the agents I built — is here as a skill you can just ask for in
   > plain words. The local ones (recall, inscribe) are free and unlimited. The ones that cost real
   > credits — PM runner, video maker, sales/outreach, email, chart intel — you get **5 free every
   > day**. After that, add your own API key (it's yours alone — we never see it, not even AUTO) and
   > it's unlimited on your key. Anything that touches money never runs without your explicit yes."

4. **When a metered skill hits the daily cap**, the skill itself prints the BYOK prompt. To add a
   key for a provider:
   ```
   bash "$CLAUDE_PLUGIN_ROOT/tools/meter.sh" setkey anthropic     # or helius, x, …
   ```
   (Presence flag only on the client — the real key lives server-side, per-user encrypted.)

## The lanes (from capabilities.json — the source of truth)
- **free** — local compute, no cost, never gated: `recall`, `inscribe`.
- **metered** — 5 free/day → then BYOK: `pm-runner`, `video-genie`, `sales-copilot`, `upwork-agent`,
  `email-concierge`, `meeting-notes`, `botfactory`, `workshop-team`, `chart-intel`.
- **gated:money** — never auto-runs, explicit owner yes per action: `trade`.

_Add or retag agents in `capabilities.json`, then `python3 tools/wrap_agents.py` regenerates the skills._
