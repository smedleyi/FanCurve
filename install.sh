#!/bin/bash
set -e

REPO="https://github.com/smedleyi/FanCurve.git"

# ── If running via curl (no local files), clone the repo first ────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo "")"
if [ ! -d "$SCRIPT_DIR/daemon" ]; then
    echo "=== FanCurve Installer ==="
    echo "→ Downloading FanCurve…"
    TMP=$(mktemp -d)
    git clone --depth 1 "$REPO" "$TMP/FanCurve"
    bash "$TMP/FanCurve/install.sh"
    rm -rf "$TMP"
    exit 0
fi

APP_DEST="$HOME/Applications/FanCurve.app"
DAEMON_SRC="/tmp/fancurve-daemon-build"
DAEMON_C="$SCRIPT_DIR/daemon/fancurve-daemon.c"

DAEMON_PLIST="$SCRIPT_DIR/com.local.fancurve-daemon.plist"
AGENT_PLIST="$SCRIPT_DIR/com.local.fancurve.plist"

echo "=== FanCurve Installer ==="

# ── 1. Compile daemon ─────────────────────────────────────────────────────
echo "→ Compiling fancurve-daemon…"
if ! cc -o "$DAEMON_SRC" "$DAEMON_C" -framework IOKit -lm 2>&1; then
    echo ""
    echo "  ✗ Compilation failed. Install Xcode Command Line Tools and try again:"
    echo "    xcode-select --install"
    exit 1
fi
echo "  ✓ Daemon compiled"

# ── 2. Install app ────────────────────────────────────────────────────────
echo "→ Installing FanCurve.app to ~/Applications…"
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
cp -R "$SCRIPT_DIR/FanCurve.app" "$APP_DEST"
echo "  ✓ App installed"

# ── 3. Install root daemon (requires admin password) ──────────────────────
echo ""
echo "→ Installing root daemon (requires admin password)…"
echo "  The daemon runs as root to maintain the Apple Silicon fan unlock sequence."
echo ""
sudo mkdir -p /usr/local/bin
sudo cp "$DAEMON_SRC" /usr/local/bin/fancurve-daemon
sudo chown root:wheel /usr/local/bin/fancurve-daemon
sudo chmod 755 /usr/local/bin/fancurve-daemon

sudo launchctl unload /Library/LaunchDaemons/com.local.fancurve-daemon.plist 2>/dev/null || true
sudo cp "$DAEMON_PLIST" /Library/LaunchDaemons/com.local.fancurve-daemon.plist
sudo chown root:wheel /Library/LaunchDaemons/com.local.fancurve-daemon.plist
sudo launchctl load -w /Library/LaunchDaemons/com.local.fancurve-daemon.plist
echo "  ✓ Daemon installed and started"

# ── 4. Install LaunchAgent for GUI app ───────────────────────────────────
echo ""
read -r -p "→ Launch FanCurve at login? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    launchctl unload "$HOME/Library/LaunchAgents/com.local.fancurve.plist" 2>/dev/null || true
    cp "$AGENT_PLIST" "$HOME/Library/LaunchAgents/"
    launchctl load -w "$HOME/Library/LaunchAgents/com.local.fancurve.plist"
    echo "  ✓ FanCurve will start at login"
fi

echo ""
echo "=== Done! ==="
echo "Daemon log: tail -f /tmp/fancurve-daemon.log"
echo "Open ~/Applications/FanCurve.app to start the menu bar app."
