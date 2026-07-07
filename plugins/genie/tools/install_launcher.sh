#!/usr/bin/env bash
# install_launcher.sh — give the user a one-word way into their Orange Genie.
# After this, they type `genie` in any terminal and Claude opens ALREADY WOKEN as their Orange
# Genie (remembering them). `genie <task>` wakes AND runs the task. Idempotent + consent-gated:
# it appends a shell function to the user's rc only if it isn't already there, and only after a yes.
#
#   install_launcher.sh          # interactive: show the line, ask, then append
#   install_launcher.sh --print  # just print the line (install nothing) — for manual/paste
#   install_launcher.sh --yes    # non-interactive install (for onboarding after the user agreed)
set -euo pipefail

# 'wake genie' is a GUARANTEED trigger of the plugin's wake skill (see skills/wake/SKILL.md).
# genie        -> claude "wake genie"
# genie do X   -> claude "wake genie, then: do X"
read -r -d '' FUNC <<'EOF' || true
# --- Orange Genie launcher (added by install_launcher.sh) ---
genie() {
  if [ "$#" -eq 0 ]; then command claude "wake genie"; else command claude "wake genie, then: $*"; fi
}
# --- end Orange Genie launcher ---
EOF

rc_file() { # pick the right rc for the active shell
  case "${SHELL##*/}" in
    zsh)  printf '%s' "$HOME/.zshrc" ;;
    bash) [ -f "$HOME/.bash_profile" ] && printf '%s' "$HOME/.bash_profile" || printf '%s' "$HOME/.bashrc" ;;
    *)    printf '%s' "$HOME/.zshrc" ;;
  esac
}

RC="$(rc_file)"

if [ "${1:-}" = "--print" ]; then printf '%s\n' "$FUNC"; exit 0; fi

if grep -q "Orange Genie launcher" "$RC" 2>/dev/null; then
  echo "✓ genie launcher already installed in $RC — type: genie"
  exit 0
fi

if [ "${1:-}" != "--yes" ]; then
  echo "This appends a 'genie' command to $RC so you can just type:  genie"
  echo "-------------------------------------------------------------"
  printf '%s\n' "$FUNC"
  echo "-------------------------------------------------------------"
  printf 'Add it? [y/N] '
  read -r ans
  case "$ans" in y|Y|yes) ;; *) echo "skipped — you can paste it yourself, or re-run with --yes"; exit 0;; esac
fi

printf '\n%s\n' "$FUNC" >> "$RC"
echo "✓ added 'genie' to $RC"
echo "  open a new terminal (or: source $RC) then type:  genie"
