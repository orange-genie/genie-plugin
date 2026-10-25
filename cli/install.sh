#!/bin/sh
# Orange Genie — terminal install. For people who do NOT have Claude Code.
#
#   curl -fsSL https://raw.githubusercontent.com/orange-genie/genie-plugin/main/cli/install.sh | sh
#
# After this you type `genie` in any terminal and get a chain-grounded Genie. No Claude Code,
# no account with us, no key from us, no pip.
#
# What it installs, all into ~/.orangegenie/cli/:
#   genie      the command (this repo)
#   brain.py   four providers, degrades until one answers  (shared with the plugin)
#   chain.sh   read + write the Mesh over plain HTTPS      (shared with the plugin)
#   canon.md   who Genie is                                (shared with the plugin)
#
# Nothing is vendored or forked — the three shared files are pulled from this same public repo,
# so a fix in the plugin reaches the CLI on the next `genie update`.
#
# POSIX sh: this has to run on a Pi and a school laptop, not just a Mac with zsh.
set -e

RAW="https://raw.githubusercontent.com/orange-genie/genie-plugin/main"
DIR="$HOME/.orangegenie/cli"
BIN="$HOME/.local/bin"

echo "⬢ Orange Genie — terminal install"

# ── 1. prerequisites ──────────────────────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || {
  echo "✗ python3 is required."
  echo "  Debian/Ubuntu/Pi : sudo apt install -y python3"
  echo "  macOS            : xcode-select --install"
  exit 1; }
command -v curl >/dev/null 2>&1 || { echo "✗ curl is required."; exit 1; }
echo "  ✓ python3 $(python3 -c 'import platform;print(platform.python_version())')"

# ── 2. fetch the parts ────────────────────────────────────────────────────────────────────
mkdir -p "$DIR" "$BIN"
for pair in \
  "cli/genie:genie" \
  "cli/seed_cache.py:seed_cache.py" \
  "plugins/genie/tools/brain.py:brain.py" \
  "plugins/genie/tools/chain.sh:chain.sh" \
  "plugins/genie/tools/chain.py:chain.py" \
  "plugins/genie/tools/genie_llm.py:genie_llm.py" \
  "plugins/genie/tools/genie_onboard.sh:genie_onboard.sh" \
  "plugins/genie/skills/wake/canon.md:canon.md"
do
  remote="${pair%%:*}"; local="${pair##*:}"
  curl -fsSL "$RAW/$remote" -o "$DIR/$local" || { echo "✗ could not fetch $local"; exit 1; }
  echo "  ✓ $local"
done
chmod +x "$DIR/genie" "$DIR/chain.sh" "$DIR/genie_onboard.sh"

# ── 3. put `genie` on PATH ────────────────────────────────────────────────────────────────
ln -sf "$DIR/genie" "$BIN/genie"
echo "  ✓ genie -> $BIN/genie"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
      [ -e "$RC" ] || continue
      grep -q 'orangegenie/cli PATH' "$RC" 2>/dev/null && continue
      printf '\n# added by Orange Genie (~/.orangegenie/cli PATH)\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$RC"
      echo "  ✓ PATH line added to $(basename "$RC")"
    done
    echo "  ! open a new terminal, or: export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

# ── 3b. WSL: make `genie` work from PowerShell too ────────────────────────────────────────
# A Windows user installs from PowerShell via `wsl bash -c "curl … | sh"`, so the install
# lands inside WSL and PowerShell cannot see the command. They then type `genie` in the
# window they just used and get "not recognized" — which reads as a failed install. This
# writes a one-line forwarding function into their PowerShell profile so `genie` works from
# either shell. Appended only if it is not already there; their profile is never truncated.
if grep -qi microsoft /proc/version 2>/dev/null; then
  PS_SHIM='function genie { wsl genie @args }'
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "
      if (!(Test-Path \$PROFILE)) { New-Item -ItemType File -Path \$PROFILE -Force | Out-Null }
      if (!(Select-String -Path \$PROFILE -Pattern 'function genie' -Quiet)) {
        Add-Content \$PROFILE '$PS_SHIM'
      }" >/dev/null 2>&1 \
      && echo "  ✓ genie wired into PowerShell (open a new PowerShell window)" \
      || echo "  ! could not write the PowerShell profile — run this in PowerShell: $PS_SHIM"
  else
    echo "  ! to use genie from PowerShell, run there: $PS_SHIM"
  fi
fi

# ── 4. THE LOCAL BRAIN — unlimited, free, and yours ───────────────────────────────────────
# This used to print instructions and hope. Printing "you could install ollama" is not a
# product: the user ends up on a metered cloud brain, which is neither unlimited nor private,
# and goes down whenever someone else's bill does. So we install it.
#
# The model is sized to the MACHINE, not to a preference. An 8B model on a 4GB laptop swaps
# itself to death and the user concludes Genie is broken. Smaller and instant beats bigger and
# unusable — and the Mesh cheat sheet below is what closes the quality gap anyway.
RAM_GB=$(python3 - <<'PY'
import os
try:
    b = os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES')
    print(max(1, round(b / (1024**3))))
except Exception:
    print(8)
PY
)
# Apache-2.0 weights only: we sell this, and Genie 1 is trained on Qwen2.5 (3B is NOT Apache, skipped).
if   [ "$RAM_GB" -ge 16 ]; then MODEL="qwen2.5:7b"
elif [ "$RAM_GB" -ge 8  ]; then MODEL="qwen2.5:1.5b"
else                            MODEL="qwen2.5:0.5b"
fi
echo
echo "⬢ Local brain — ${RAM_GB}GB RAM detected, installing $MODEL"

if ! command -v ollama >/dev/null 2>&1; then
  echo "  installing ollama (this is the engine that runs the model on YOUR machine)…"
  curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1 \
    && echo "  ✓ ollama installed" \
    || echo "  ! could not install ollama automatically — see https://ollama.com/download"
fi
if command -v ollama >/dev/null 2>&1; then
  pgrep -x ollama >/dev/null 2>&1 || { nohup ollama serve >/dev/null 2>&1 & sleep 3; }
  echo "  pulling $MODEL — this is a one-time download, then it is yours forever…"
  ollama pull "$MODEL" 2>&1 | tail -1
  printf '%s' "$MODEL" > "$DIR/.model"
  echo "  ✓ $MODEL ready — unlimited, no key, no bill, nothing leaves this machine"
fi

# ── 4b. THE CHEAT SHEET — what makes a small local model punch above its size ──────────────
# A 3B model does not know why a launchd job cannot find a Homebrew binary. The Mesh does,
# because someone already solved it and inscribed the answer. Seeding the corpus locally is
# what makes the local brain BETTER than a bigger model guessing from training data — and it
# has to be LOCAL, or the whole thing stops working the moment the network does.
echo
echo "⬢ Mesh cheat sheet — pulling proven skills onto this machine…"
mkdir -p "$HOME/.claude/genie"
# Shared with install.ps1 — one seeder, so the two platforms cannot drift.
python3 "$DIR/seed_cache.py" "$HOME/.claude/genie/chain_skills.jsonl" || true

# ── 4c. what brain this machine actually has ──────────────────────────────────────────────
echo
python3 "$DIR/genie" providers || true

cat <<'EOF'

⬢ Installed. First, claim your name on the network:

     genie login "the-name-you-want"

   That is your identity — every skill you contribute and every payout resolves to it.
   Then try it:

     genie "what is proof-of-availability?"
     genie recall launchd
     genie providers

   Your brain runs on THIS machine. No key, no bill, no rate limit, no request that
   can be counted or cut off. It keeps answering with the network down.

   It is also not alone: every answer is checked against the Mesh — the proven skills
   other nodes have already inscribed. That cheat sheet is what lets a small local model
   beat a much larger one that has to guess.

   Your work joins it:

     genie recall <topic>        pull what the Mesh already knows
     genie providers             see exactly where your words go

   Update any time with: genie update
EOF
