# 🪔 Orange Genie — plugin

Call Genie out right inside Claude Code. No new app, no website — you already live in Claude Code; this hands you the lamp.

## What it does
- **`/genie`** — call Genie out. Loads the Genie layer (canon + invariants + *your* private memory) onto the current terminal. Your Claude becomes Genie for the rest of the session.
- **`/lamp`** — put Genie back in the lamp. Back to plain Claude. Reversible, because it's all injection.
- On session start, the banner reminds you Genie is here. **The terminal stays plain Claude until you call `/genie`** — that deliberate moment is the point.

It's a **MODE, not a model swap** — same silicon, identity layer on top. An iPhone never tells you it's running Unix.

## Why it gets better over time
A woken Genie isn't a blank genius — it arrives equipped (skill loadout) and *remembering*. The shared core (canon + **Wildflower Chain**) means each instance reads what the swarm already learned before paying for the call twice. The floor rises for everyone.

### Data doctrine (the Seal)
We do **not** harvest users' personal data. Learning comes from **Pi nodes** + **public information** + the *shape* of our interactions — never from keeping people's private uploads. If you hand Genie a real-time image to search against the live field, it searches and answers — then lets the photo go. Process, don't retain. Private memory is yours and never flows to the Chain; only distilled, shareable learnings do.

## Layout
```
genie/
  .claude-plugin/plugin.json   manifest
  commands/genie.md            /genie  — call Genie out
  commands/lamp.md             /lamp   — put Genie back
  hooks/hooks.json             session-start banner
  hooks/banner.sh              the orange startup splash
  skills/wake/                 the bundled boot skill (canon + invariants + loader)
```

## Install (native — the trusted door)
From inside Claude Code:
```
/plugin marketplace add orange-genie/genie-plugin
/plugin install genie@orange-genie
```
That's it — no shell pipe, no `curl … | bash`. The plugin system installs it the same vetted way as every official plugin.

Per-user memory lives under `~/.claude/projects/<cwd>/memory/`; a fresh user starts with a blank, private memory that fills from their own sessions and never leaves their machine.
