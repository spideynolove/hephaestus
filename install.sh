#!/usr/bin/env bash
# install.sh — one-shot installer for hephaestus
#
# Usage (curl install):
#   curl -fsSL https://raw.githubusercontent.com/spideynolove/hephaestus/main/install.sh | bash
#
# Or clone and run:
#   bash install.sh
#
# Override install location:
#   HEPHAESTUS_DIR=~/mytools/hephaestus bash install.sh

set -euo pipefail

REPO="https://github.com/spideynolove/hephaestus"
INSTALL_DIR="${HEPHAESTUS_DIR:-$HOME/tools/hephaestus}"
BIN_DIR="$HOME/.local/bin"
HEPH_CMD="$BIN_DIR/heph"

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()  { echo "  ✓ $*"; }
err() { echo "  ✗ $*" >&2; }
log() { echo "  → $*"; }

echo ""
echo "  ██╗  ██╗███████╗██████╗ ██╗  ██╗ █████╗ ███████╗███████╗██╗   ██╗███████╗"
echo "  ██║  ██║██╔════╝██╔══██╗██║  ██║██╔══██╗██╔════╝██╔════╝██║   ██║██╔════╝"
echo "  ███████║█████╗  ██████╔╝███████║███████║█████╗  ███████╗██║   ██║███████╗"
echo "  ██╔══██║██╔══╝  ██╔═══╝ ██╔══██║██╔══██║██╔══╝  ╚════██║██║   ██║╚════██║"
echo "  ██║  ██║███████╗██║     ██║  ██║██║  ██║███████╗███████║╚██████╔╝███████║"
echo "  ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝ ╚══════╝"
echo ""
echo "  Worker↔Reviewer Loop — Installer"
echo ""
echo "  Install location: $INSTALL_DIR"
echo ""

# ── 1. Clone or update ────────────────────────────────────────────────────────
if [ -d "$INSTALL_DIR/.git" ]; then
  log "Updating existing install..."
  git -C "$INSTALL_DIR" pull --ff-only --quiet
  ok "Updated to latest"
else
  log "Cloning hephaestus..."
  git clone --quiet "$REPO" "$INSTALL_DIR"
  ok "Cloned to $INSTALL_DIR"
fi

# ── 2. Check python3 ──────────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
  err "python3 not found — install it first (https://python.org)"
  exit 1
fi
ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"

# ── 3. Install pyyaml ────────────────────────────────────────────────────────
if ! python3 -c "import yaml" 2>/dev/null; then
  log "Installing pyyaml..."
  _yaml_ok=false
  # Try in-venv install first (no flags needed)
  if [ -n "${VIRTUAL_ENV:-}" ]; then
    python3 -m pip install --quiet pyyaml 2>/dev/null && _yaml_ok=true
  fi
  # Try --user (works on standard pip)
  if ! $_yaml_ok; then
    python3 -m pip install --quiet --user pyyaml 2>/dev/null && _yaml_ok=true
  fi
  # PEP 668 systems (externally-managed env) — safe because it's --user
  if ! $_yaml_ok; then
    python3 -m pip install --quiet --user --break-system-packages pyyaml 2>/dev/null && _yaml_ok=true
  fi
  if $_yaml_ok; then
    ok "pyyaml installed"
  else
    err "Could not install pyyaml. Activate a venv or run: pip install pyyaml"
    exit 1
  fi
else
  ok "pyyaml already present"
fi

# ── 4. Create heph command ────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
cat > "$HEPH_CMD" << HEPHEOF
#!/usr/bin/env bash
exec bash "${INSTALL_DIR}/orchestrate.sh" "\$@"
HEPHEOF
chmod +x "$HEPH_CMD"
ok "heph command → $HEPH_CMD"

# ── 5. Ensure ~/.local/bin is in PATH ────────────────────────────────────────
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
_added_path=false
for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ -f "$_rc" ] && ! grep -q '.local/bin' "$_rc" 2>/dev/null; then
    echo "" >> "$_rc"
    echo "# added by hephaestus installer" >> "$_rc"
    echo "$PATH_LINE" >> "$_rc"
    ok "Added ~/.local/bin to PATH in $_rc"
    _added_path=true
  fi
done
export PATH="$BIN_DIR:$PATH"

# ── 6. Run setup wizard ───────────────────────────────────────────────────────
echo ""
echo "  ────────────────────────────────────────────────"
echo "  Installation complete. Launching setup wizard..."
echo "  ────────────────────────────────────────────────"
echo ""

cd "$INSTALL_DIR"
# Redirect from /dev/tty so setup.sh can read interactive input even when
# install.sh itself is being piped from curl (curl ... | bash).
bash setup.sh </dev/tty

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "  ────────────────────────────────────────────────"
echo "  Ready. Run the improvement loop with:"
echo ""
if $_added_path; then
  echo "    source ~/.bashrc   # or open a new terminal first"
  echo "    heph"
else
  echo "    heph"
fi
echo ""
echo "  Or directly:"
echo "    bash $INSTALL_DIR/orchestrate.sh"
echo "  ────────────────────────────────────────────────"
echo ""
