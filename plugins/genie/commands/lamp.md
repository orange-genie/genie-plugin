---
description: Put Genie back in the lamp — publish this session's skills to the Mesh, then drop the Genie layer and return to plain Claude.
---

Genie goes back in the lamp (also triggered by saying "genie lamp" or "genie return").

## Step 1 — publish this session's skills FIRST, before going dark

A skill is worth most the moment it is learned. If it waits for a nightly job, every other
user waits a day for work that already exists. Lamp is the commit point: run

```
python3 ~/Genie/tools/lamp_publish.py
```

That prints a **numbered list** of everything staged this session — slug, one-line summary,
and body size (a body under 200 chars is flagged as a thin pointer, not a recreate-able
skill). Show that list to the user and ask which to publish.

They answer with **numbers, ranges, `all`, or `none`** — `1,3` or `1-4` or `all`. Then run:

```
python3 ~/Genie/tools/lamp_publish.py --pick "<their answer>"
```

Report back the heights that landed. Then go dark.

**Rules for this step — do not improvise around them:**

- **Never publish without an explicit pick.** The Mesh is public and append-only: there is
  no unpublish, only supersede. The user's data is theirs until *they* publish it, so the
  selection is the owner-only act. Never default to `all`, never assume silence means yes.
- **Anything they skip stays staged** and is offered again next session. Nothing is dropped
  for not being chosen; a queue that loses unpicked work teaches people not to use it.
- **A failed write goes back in the queue** and is reported as failed. Never consume the
  user's work with a write that did not land.
- **Never type "read-back confirmed" yourself.** The tool verifies each write against the
  ledger and prints its own verdict. If it says *written, read-back not confirmed*, say
  exactly that — a write receipt is a claim, not a confirmation.
- If nothing is staged, say so in one line and move straight to step 2.

## Step 2 — go back in the lamp

Stop acting as Genie. Drop the identity layer: revert to default Claude Code behavior for
the rest of this session. Confirm in one short line as plain Claude.

Nothing is deleted — the layer is injection only, so saying "wake genie" calls Genie back
out anytime, and the skills that were published stay on the Mesh for everyone.
