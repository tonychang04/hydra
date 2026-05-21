#!/usr/bin/env bash
# One-liner install for Hydra.
# Usage:  curl -fsSL https://raw.githubusercontent.com/tonychang04/hydra/main/install.sh | bash
# Or clone + run yourself:  git clone https://github.com/tonychang04/hydra && cd hydra && ./setup.sh
#
# What this does:
#  1. Verifies prereqs (git, gh, claude)
#  2. Clones hydra to ~/hydra (or $HYDRA_INSTALL_DIR if set)
#  3. Runs ./setup.sh interactively

set -euo pipefail

say()  { printf "\n\033[1m▸ %s\033[0m\n" "$*"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$*"; exit 1; }
ok()   { printf "\033[32m✓ %s\033[0m\n" "$*"; }

REPO_URL="https://github.com/tonychang04/hydra.git"
INSTALL_DIR="${HYDRA_INSTALL_DIR:-$HOME/hydra}"

say "Hydra installer"
echo "  Clone destination: $INSTALL_DIR  (override with HYDRA_INSTALL_DIR=... before the curl)"
echo ""

# Prereqs
for bin in git gh claude; do
  command -v "$bin" >/dev/null || fail "$bin not found in PATH. Install it first."
done
ok "git, gh, claude all present"

# Clone or update
if [[ -d "$INSTALL_DIR/.git" ]]; then
  say "Already cloned — pulling latest"
  git -C "$INSTALL_DIR" pull --ff-only || fail "git pull failed; resolve manually at $INSTALL_DIR"
else
  if [[ -e "$INSTALL_DIR" ]]; then
    fail "$INSTALL_DIR exists but is not a git repo. Move it out of the way or set HYDRA_INSTALL_DIR."
  fi
  say "Cloning $REPO_URL → $INSTALL_DIR"
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi
ok "Repo ready at $INSTALL_DIR"

# Run setup
say "Running ./setup.sh"
cd "$INSTALL_DIR"
bash ./setup.sh

# Point them to the next step
cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Hydra installed at: $INSTALL_DIR

To launch:
  cd $INSTALL_DIR
  ./hydra

Docs in the repo:
  README.md       — what Hydra is
  USING.md        — how to use it on your repos
  DEVELOPING.md   — how to contribute to Hydra itself
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
