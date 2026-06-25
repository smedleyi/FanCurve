# FanCurve

A macOS menu bar app for custom fan speed control on Apple Silicon Macs. Define per-profile fan curves, set a max speed cap, and let the fans go silent at low temperatures — all without touching macOS's thermal management when you don't need it.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-only-lightgrey)

---

## Features

- **Custom fan curves** — drag-and-drop curve editor mapping temperature to RPM
- **Multiple profiles** — Silent, Balanced, Performance, plus any number of custom profiles
- **Per-profile speed cap** — soft ceiling on fan speed, shown as an orange dashed line on the chart
- **Fans off support** — curve points can target 0 RPM for completely silent operation at low temperatures
- **Safety override** — hard fan-max trigger at a configurable temperature; latches on and stays active until temp drops 10°C below the threshold (hysteresis)
- **Max Fan mode** — one-click override to run all fans at hardware maximum
- **Temperature sensor selection** — CPU Average, GPU Average, CPU+GPU Average, or CPU/GPU Max, applied globally across all profiles
- **EMA smoothing** — exponential moving average prevents reacting to brief CPU spikes
- **Status bar readout** — live temperature next to the menu bar icon

---

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 14 (Sonoma) or later
- Admin password for daemon installation (one-time)

---

## Installation

```bash
git clone <repo>
cd FanCurve
bash install.sh
```

The installer will:

1. Compile the root daemon (`daemon/fancurve-daemon.c`) if not already built
2. Copy `FanCurve.app` to `~/Applications`
3. Install and start `fancurve-daemon` as a root LaunchDaemon (requires your admin password)
4. Run a short fan test to verify the unlock sequence works
5. Optionally install a LaunchAgent so FanCurve starts at login

After installation, open `~/Applications/FanCurve.app`. A fan icon with the live temperature appears in the menu bar.

---

## Building from Source

```bash
bash build.sh
```

This performs a release Swift build (`swift build -c release`), copies the binary into `FanCurve.app/Contents/MacOS/`, re-signs the bundle with an ad-hoc signature, syncs it to `~/Applications/FanCurve.app`, and restarts the running app via `pkill`.

The daemon is a plain C file compiled separately:

```bash
cc -o daemon/fancurve-daemon daemon/fancurve-daemon.c -framework IOKit -lm
```

If you recompile the daemon, reinstall it manually:

```bash
sudo cp daemon/fancurve-daemon /usr/local/bin/fancurve-daemon
sudo launchctl unload /Library/LaunchDaemons/com.local.fancurve-daemon.plist
sudo launchctl load -w /Library/LaunchDaemons/com.local.fancurve-daemon.plist
```

---

## Uninstalling

```bash
# Remove daemon
sudo launchctl unload /Library/LaunchDaemons/com.local.fancurve-daemon.plist
sudo rm /Library/LaunchDaemons/com.local.fancurve-daemon.plist
sudo rm /usr/local/bin/fancurve-daemon

# Remove login item (if installed)
launchctl unload ~/Library/LaunchAgents/com.local.fancurve.plist
rm ~/Library/LaunchAgents/com.local.fancurve.plist

# Remove app and settings
rm -rf ~/Applications/FanCurve.app
rm -rf ~/.config/fancurve
```
