# OrangeGenie — Filter Contract & Template Spec

OrangeGenie is a **filter platform**. The app is the *runtime*; a **filter** is a small program that watches the user's scoped screen and writes annotations the runtime paints. Every filter is a **shareable template** → the Filter Bazaar.

## 1. The runtime (OrangeGenie.app)
Handles everything a filter shouldn't reinvent:
- **Scope** — Full Screen / Select Window / Select Application (never moves the user's windows).
- **Presence** — Tint / Frame+Dot / Dot / None, with the menu-bar logo glow as the always-on trust floor (photosensitive-safe, no strobe).
- **Render** — polls `/tmp/genie_marks.json` and paints it within the chosen scope.

A filter never draws to the screen itself. It only **produces marks**. That keeps filters tiny, safe, and portable.

## 2. The marks contract (the one interface)
A filter writes a JSON array to `/tmp/genie_marks.json`:
```json
[
  { "x": 200, "y": 320, "w": 440, "h": 46, "label": "✅ your annotation" }
]
```
- Coordinates are **GLOBAL screen points, top-left origin** (CSS-px == AppKit points; no DPR scaling).
- DOM→screen: `x = window.screenX + rect.x`, `y = window.screenY + (outerHeight − innerHeight) + rect.y`.
- `[]` = clear. The runtime gates rendering on the filter being active + (optionally) the target window focused.
- **Re-read each tick to follow scroll** (see `mslearn_track.mjs`); never a one-shot snapshot.

## 3. A filter = a shareable template
A filter is a folder:
```
my-filter/
  filter.json     # manifest
  run.(mjs|py)    # the runner: reads the scoped screen → writes marks
  README.md       # what it does, how to use
```
`filter.json` manifest:
```json
{
  "name": "Prop-Firm Risk Co-pilot",
  "slug": "prop-risk",
  "version": "0.1.0",
  "author": "mike",
  "description": "Watches your trading window; flags position size + drawdown-rule guardrails. You decide every trade.",
  "scopeHint": "window",                // fullscreen | window | app — what the runtime should scope to
  "params": [                           // user-configurable; the install/onboarding fills these
    { "key": "dailyLossLimit", "label": "Daily loss limit ($)", "type": "number" },
    { "key": "maxDrawdown",    "label": "Account max drawdown ($)", "type": "number" }
  ],
  "runner": "node run.mjs",
  "needs": ["screen-recording"],        // TCC perms the runner requires
  "honor": "advisory-only"              // declares it informs the user; never auto-acts (see §5)
}
```

## 4. How filters get built & shared — the living template + royalties
- **Built by Genie** (in the user's terminal): the on-state prompt *"anything you want me to watch?"* → the answer becomes a filter; Genie PMs + writes `run.*` against this contract. No wizard needed yet.
- **One self-improving STARTING TEMPLATE, not a static store.** There's a base filter template everyone starts from; every filter built feeds *validated* improvements back into it, so each newcomer starts stronger and it compounds (the skill/bloom engine — [[project_bloom_as_expertise_engine]]; improvements pass a quality gate like skill_dedup, never blind-merged or the template degrades).
- **Filter royalties — the YouTube Partner model:** you earn from **whoever uses your filter** (usage-attributed). Monetization is **GATED like YouTube**: you must be a **verified creator** AND the filter must cross a **usage threshold (X)** before it earns. Below threshold it still works + improves the template — just not monetized. This scales the payment rails *with* proven demand (no drowning in a million dust payouts) and is the natural fraud/Markopolos gate (only real traction pays). Design the **usage attribution now**; the **payout rides the Phase-2 commons rail** — don't surface "earn $" until that rail pays + a filter crosses X.
- **Mike's prop-risk filter is the first contribution** — once it works for him, it improves the template + is installable (and royalty-eligible later) for any prop trader.

## 5. The honor line (non-negotiable for every filter)
- Filters are **advisory** — they show the user information; **the user decides and clicks.** A filter must never move money, place/cancel orders, or auto-act (canon money-gate). `honor: "advisory-only"`.
- Never built to **evade** a third party's detection or deceive a counterparty (e.g., a prop-firm ToS). Advisory risk/analysis is legitimate; evasion/automation is not — it gets the *user* harmed.
- Privacy by absence: a filter reads the scoped screen in memory only; it persists nothing unless the user explicitly exports (WhisperNotes pattern).

## Reference filters (already against this contract)
- `xbot-follow/mslearn_track.mjs` — live tracker (follows scroll, focus-gated). The canonical runner pattern.
- `xbot-follow/coursera_overlay.mjs` — paints answer marks. (one-shot variant)
