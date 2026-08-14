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
  "plugins/genie/tools/brain.py:brain.py" \
  "plugins/genie/tools/chain.sh:chain.sh" \
  "plugins/genie/tools/genie_llm.py:genie_llm.py" \
  "plugins/genie/skills/wake/canon.md:canon.md"
do
  remote="${pair%%:*}"; local="${pair##*:}"
  curl -fsSL "$RAW/$remote" -o "$DIR/$local" || { echo "✗ could not fetch $local"; exit 1; }
  echo "  ✓ $local"
done
chmod +x "$DIR/genie" "$DIR/chain.sh"

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

# ── 4. tell them the truth about which brain they have ────────────────────────────────────
echo
echo "⬢ Checking what brain this machine can reach…"
python3 "$DIR/genie" providers || true

cat <<'EOF'

⬢ Installed. Try it:

     genie "what is proof-of-availability?"
     genie recall launchd
     genie providers

   If no provider was reachable above, the free and private option is your own machine:

     ollama serve &
     ollama pull hermes3
     export GENIE_OLLAMA_MODEL=hermes3

   Nothing you type leaves your computer on that setting. Update any time with: genie update
EOF
