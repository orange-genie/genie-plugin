---
name: rename
description: Change the user's Wildflower Chain username (their identity marker). TRIGGER when the user asks to change / rename / update their username, handle, chain name, or marker — e.g. "change my username", "rename me to X", "I want a different chain name", "update my handle". Limited to 2 renames per 60 days, enforced on-chain.
---

# Rename (change your chain username)

The username is the user's **identity marker** on the Wildflower Chain — the account every skill, contribution, and payout is credited to. This skill changes it safely.

## What a rename does
- **Past work is preserved.** The chain is append-only; everything done under the old name stays. A public **RENAME block** links `old → new`, so aggregators credit the whole history to the new name.
- **Only the chain decides.** The server enforces the rules and links the identity; the local marker file is swapped **only after** the chain accepts. Nothing is faked locally.

## The rules (enforced server-side, not gameable)
- **Max 2 renames per rolling 60 days.** The limit is counted from on-chain RENAME blocks, so deleting local files doesn't reset it.
- The new name must be a valid marker (`name.agent` / `.genie` / `.wtf` / `.com` / `.eth` / `.bot`), **not reserved** (`blankcheck`, `genie`, …), and **not already taken** by someone else.

## How to run it
1. Confirm the new name with the user in one line (it's a limited action — 2 per 60 days).
2. Run the wire (prefers the HTTPS self-updated copy, falls back to the bundled one):

```bash
bash "$HOME/.claude/genie/rename.sh" "<new_username>" 2>/dev/null || bash "${CLAUDE_PLUGIN_ROOT}/tools/rename.sh" "<new_username>"
```

3. Report the result verbatim to the user — including **renames left this window**. If it was refused (reserved / taken / limit reached), say why and that their name is unchanged.

Do **not** loop or retry a refused rename — surface the reason and stop. Value in = Work out.
