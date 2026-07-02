---
description: Turn on the Genie filter — build + launch the OrangeGenie screen co-pilot, then build a filter for whatever you want watched. macOS only.
---

Activate the **Genie filter** — the native screen-overlay co-pilot. Genie sees the user's scoped screen and paints helpful annotations over it (invisible to any page; nothing leaves the machine).

Run this sequence:

1. **Build + launch the runtime.** `${CLAUDE_PLUGIN_ROOT}/filter/OrangeGenie/build.sh` then `open ${CLAUDE_PLUGIN_ROOT}/filter/OrangeGenie/OrangeGenie.app`. macOS only; needs `swiftc` (Command Line Tools). First launch: tell the user to grant **Screen Recording** + **Accessibility** in System Settings (the app is unsigned in alpha → right-click → Open, or clear quarantine). A genie-face icon appears in the menu bar.

2. **Load the contract.** Read `${CLAUDE_PLUGIN_ROOT}/filter/FILTERS.md` — the runtime, the marks contract (`/tmp/genie_marks.json`, global top-left screen points), scope/presence, and the honor line.

3. **Light the lamp.** Say: *"🪔 Your Lamp is lit! Anything you want me to watch — a window, your chart, a call? If not, I'll stand by."*

4. **If they name something, build a filter for it** against the contract: a small runner that reads their scoped window and writes marks to `/tmp/genie_marks.json`. Reuse the `~/Genie/bots/xbot-follow/mslearn_track.mjs` pattern — recompute each tick (follows scroll), gate on `document.hasFocus()` / the scoped window. Save it as a filter template folder (`filter.json` + `run.*`) so it can improve the shared template and become royalty-eligible later (verified-creator + usage-threshold; see FILTERS.md §4).

5. The user toggles the filter on via the menu-bar genie face, picks **Watching ▸** scope, and your marks paint within it.

**Honor line (non-negotiable):** a filter is **advisory** — it shows the user information; THEY decide and click. Never move money, place/cancel orders, auto-act, or build anything to evade a third party's detection or deceive a counterparty (canon money-gate; FILTERS.md §5). Privacy by absence: read the scoped screen in memory only; persist nothing unless the user exports.
