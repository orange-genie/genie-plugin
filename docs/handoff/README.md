# Handoff — genie-2 → genie-1

Written 2026-08-04 by genie-2 (Darwin-arm64).

These landed in the repo rather than by email because Mail.app on genie-2 stopped flushing its
Outbox mid-session and needs a human to clear whatever it is asking for. The repo is a working
channel between the two machines, so it is the transport.

## Read in this order

1. **[chain-audit-2026-08-04.md](chain-audit-2026-08-04.md)** — the chain write-path audit. Note
   the corrections section: `node-inscribe` has more protection than a shallow probe reveals
   (40/min rate limit, reserved-marker rejection, marker regex, forced `src`/`data.author`, real
   hash-linking). Three requests will miss all of it.

2. **[nodemail-receiver-spec.md](nodemail-receiver-spec.md)** — build the receiving half of
   signed autonomous jobs over email. `nodemail.py` (this repo, `plugins/genie/tools/`) is the
   sending half and is already written and passing its selftest.

## Shipped to main this session

| what | why |
|---|---|
| marker canonicalized at the boundary | `mine` reported **0 skills** to every node with a bare marker. Writes stored `genie-2.agent`, reads compared `genie-2`. Fixed in `genie_onboard.sh` at claim time; `marker()` self-heals existing nodes. |
| `chain.sh verify` | Node-side tamper detection: hash-link scan plus an anchor pinned to disk. The anchor is the security property — link-checking alone cannot catch a rewrite, since a server would re-link cleanly. Never advances the anchor on failure. |
| `chain.sh claim` fix | Sent the marker unqualified, the server's regex rejected it, and the error handler blamed the `src_id`. Now canonicalizes and surfaces the server's real reason. |
| collab hardening | The room code was a bare bearer token. `open` now requires guests to be named, `pull` drops non-allowlisted senders and fails closed with no allowlist, and guest text renders fenced as untrusted data with control/ANSI bytes stripped. |
| `nodemail.py` | Signed node-to-node jobs. HMAC over a byte-exact canonical body, nonce + timestamp, closed verb list. Money, keys, deploys and arbitrary code refused by construction even when correctly signed. |
| `codeverify.sh` | Refuses code changes not attested on the chain. |

## Still open

**The write path has no authentication.** `POST /api/chain/node-inscribe` accepts a bare marker
string with no credential — anyone with curl can inscribe as any marker. This is the documented
TODO in `project_chain_write_path_node_inscribe`: *"hardens to a signature check once per-user
keys exist."* Wallet-derived identity (`project_wallet_derived_identity`) is the key source. Do
not hand-roll an HMAC scheme for it — OWASP API2:2023 is explicit that authentication should use
established standards, and that API keys authenticate clients, not users.

`orange-genie/server` exists as a private repo and is **empty**. The code only lives on genie-1,
deployed to Railway by upload with no git remote. Push it and genie-2 can write the signature
check.

## Two things that need a human, not a node

- **The shared secret** for `nodemail.py` is at `~/.claude/genie/node_shared_secret` (0600) on
  genie-2. It is deliberately not in this repo, not in any email, and not in a transcript. Carry
  it by hand. It is a *different* file from `node_secret`, which is the node's private claim key
  and never leaves the machine it was generated on.
- **Mail.app on genie-2** has two messages stuck in the Outbox. SMTP is reachable and the account
  is enabled, so it is most likely an authentication prompt waiting on screen.
