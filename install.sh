#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DEST="$HOME/Applications/FanCurve.app"
DAEMON_SRC="$SCRIPT_DIR/daemon/fancurve-daemon"
DAEMON_PLIST="$SCRIPT_DIR/com.local.fancurve-daemon.plist"
AGENT_PLIST="$SCRIPT_DIR/com.local.fancurve.plist"

echo "=== FanCurve Installer ==="

# ── 1. Build daemon if needed ────────────────────────────────────────────
if [ ! -f "$DAEMON_SRC" ]; then
    echo "→ Compiling fancurve-daemon…"
    cc -o "$DAEMON_SRC" "$SCRIPT_DIR/daemon/fancurve-daemon.c" -framework IOKit -lm
fi

# ── 2. Install app ───────────────────────────────────────────────────────
echo "→ Installing FanCurve.app to ~/Applications…"
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
cp -R "$SCRIPT_DIR/FanCurve.app" "$APP_DEST"
echo "  ✓ App installed"

# ── 3. Install root daemon (requires admin password) ─────────────────────
echo ""
echo "→ Installing root daemon (requires admin password)…"
echo "  The daemon runs as root to maintain the M4 fan unlock sequence."
echo ""
sudo cp "$DAEMON_SRC" /usr/local/bin/fancurve-daemon
sudo chown root:wheel /usr/local/bin/fancurve-daemon
sudo chmod 755 /usr/local/bin/fancurve-daemon

# Unload existing daemon if running
sudo launchctl unload /Library/LaunchDaemons/com.local.fancurve-daemon.plist 2>/dev/null || true
sudo cp "$DAEMON_PLIST" /Library/LaunchDaemons/com.local.fancurve-daemon.plist
sudo chown root:wheel /Library/LaunchDaemons/com.local.fancurve-daemon.plist
sudo launchctl load -w /Library/LaunchDaemons/com.local.fancurve-daemon.plist
echo "  ✓ Daemon installed and started"

# ── 4. Test daemon ───────────────────────────────────────────────────────
sleep 2
echo ""
echo "→ Testing fan control (writing 4000 RPM target)…"
echo "4000" > /tmp/fancurve_target
sleep 6  # wait for unlock sequence (can take 3-6 s on M4)
echo "  Fan state after unlock:"
/tmp/smcread 2>/dev/null || true

# Restore auto
echo "0" > /tmp/fancurve_target
echo ""
echo "  ✓ Test complete — restoring auto control"

# ── 5. Install LaunchAgent for GUI app ──────────────────────────────────
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
