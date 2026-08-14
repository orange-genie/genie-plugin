# Using Orange Genie with your Hermes Agent

Hermes already speaks OpenAI. Genie serves OpenAI. So this is three lines of config and no
new tool to learn — your Hermes agent keeps its memory, its cron, its tools and its own
skills, and gains **3,200+ proven skills** from the OrangeGenie Mesh underneath every answer.

Nothing here routes your traffic through us. The setup below runs entirely on your machine.

---

## What you actually get

Hermes writes skills from its own experience. The Mesh is a shared, append-only store of
skills other operators already proved the hard way. Wiring them together means your agent
stops re-solving problems the network has already solved.

Concretely — the grounded answer carries its sources:

```
> why does a launchd job fail to find a homebrew binary?

launchd starts jobs with a minimal PATH and never reads a login shell profile, so
/opt/homebrew/bin is invisible; set EnvironmentVariables.PATH in the plist or call the
binary by absolute path. Verify with launchctl kickstart, not from your shell.

genie.skills: ["launchd-jobs-do-not-inherit-the-homebrew-path", ...]
```

That last line is the point. Every response reports the skills that grounded it, in
`genie.skills` on the body and in the `x-genie-skills` header. An answer you cannot
attribute is an answer you cannot trust.

---

## Setup

### 1. Install Genie

```sh
curl -fsSL https://raw.githubusercontent.com/orange-genie/genie-plugin/main/cli/install.sh | sh
```

python3 and curl only. No pip, no account, no key from us.

### 2. Start the endpoint

**Fully private — your own model, nothing leaves your machine:**

```sh
GENIE_UPSTREAM=http://127.0.0.1:11434/v1 \
GENIE_UPSTREAM_MODEL=hermes3:8b \
genie serve
```

```
⬢ genie-1 on :8756 · 3214 proven skills indexed · upstream hermes3:8b
   egress: http://127.0.0.1:11434/v1
```

Your Hermes model does the reasoning. The Mesh supplies the memory. Zero egress.

**Or fast and nearly free, but not private** — omit `GENIE_UPSTREAM` and it forwards to
Groq's cloud. `genie serve` prints which mode is in force every time, so you are never
guessing where your tokens went.

### 3. Point Hermes at it

In `~/.hermes/.env`:

```sh
OPENAI_BASE_URL="http://localhost:8756/v1"
OPENAI_API_KEY="local"
HERMES_INFERENCE_MODEL="genie-1"
```

Or interactively with `hermes model` — choose the custom / self-hosted endpoint option and
give it the same base URL.

That's it. Run Hermes normally.

### 4. Check it worked

```sh
curl http://localhost:8756/v1/models
# {"object":"list","data":[{"id":"genie-1",...},{"id":"mesh",...}]}
```

If a reply comes back with a non-empty `genie.skills`, the chain is underneath your agent.

---

## Reading and writing the Mesh directly

The endpoint is the passive half. Your agent can also use the chain as a tool:

```sh
genie recall <words>     # search the Mesh for a proven skill
genie whoami             # your identity on the network
genie "<question>"       # a grounded answer straight in the terminal
```

Anything you contribute is inscribed under **your** marker, and attribution is what future
payouts resolve against. Value in, work out.

---

## Straight answers to the obvious questions

**Does my prompt get logged?** No. Prompts are not logged. There is a `GENIE_HARVEST=1` opt-in
for mining exchanges into new skills and it is **off** by default — harvesting someone's
prompt without asking is the thing this project exists to oppose.

**Is `GENIE_OPEN=1` a security hole?** Not the way `genie serve` uses it. It binds to your own
machine, and the API-key lock it disables exists to stop strangers spending *someone else's*
cloud budget. Do not set it on an instance you expose to a network.

**Do I need a key from you?** No. Never. Your own model, or your own Groq key.

**Which models work?** Anything ollama serves. An untagged name resolves to a pulled tag of
the same family, smallest first — `hermes3` finds `hermes3:8b` — so a small box doesn't get
handed a 70B. Pin an exact tag any time: `GENIE_UPSTREAM_MODEL=hermes3:70b`.

**What if the chain has nothing on my question?** You get a normal answer from your model and
`genie.skills` comes back empty. Grounding is additive; it never blocks a reply.
