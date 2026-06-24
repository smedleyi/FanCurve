# FanCurve

A macOS menu bar app for custom fan speed control on Apple Silicon Macs. Define per-profile fan curves, set a max speed cap, and let the fans go silent at low temperatures — all without touching macOS's thermal management when you don't need it.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-only-lightgrey)

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
- macOS 26 or later
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

## Architecture

FanCurve is split into two separate processes that communicate through a single file:

```
┌──────────────────────────────────────┐        ┌─────────────────────────────┐
│        FanCurve.app  (user)          │        │  fancurve-daemon  (root)    │
│                                      │        │                             │
│  • Reads SMC sensors via IOKit       │        │  • Runs as root via launchd │
│  • Evaluates fan curve               │  file  │  • Polls target file 2×/s   │
│  • Writes target RPM          ───────┼──────▶ │  • Executes SMC write       │
│  • SwiftUI menu bar UI               │        │    unlock sequence          │
└──────────────────────────────────────┘        └─────────────────────────────┘
                                /tmp/fancurve_target
```

SMC reads (temperature, fan RPM, hardware min/max) do not require root and are performed directly in the app process. SMC writes require root, so the app delegates them to the daemon via the target file.

**IPC protocol:**

| Value in file | Effect |
|---|---|
| `-1` | Return fans to macOS automatic control (`thermalmonitord`) |
| `0` | Set fans to 0 RPM (fans off) |
| `> 0` | Set fans to this RPM |

On clean exit, the app writes `-1` to restore automatic control.

---

## SMC Layer (`SMC.swift`)

The System Management Controller is the chip that manages fans, sensors, and thermal policy. Apple Silicon Macs expose it as an IOKit service (`AppleSMC`).

### Connection

A single `io_connect_t` is opened to the `AppleSMC` IOService at first use via a lazy static and reused for the lifetime of the app. Opening a connection is cheap but creating multiple connections wastes kernel resources.

### IOKit call structure

All SMC communication uses `IOConnectCallStructMethod` with a fixed 80-byte `SMCData` struct. The kernel requires this exact layout — the struct includes 3 bytes of compiler padding after the `KeyInfo` sub-struct that must be preserved, and a pad byte between `data8` and `data32`.

Every SMC operation is two calls:

1. **`SMC_CMD_READ_KEYINFO` (9)** — given a 4-byte FourCC key name, returns the data size and type for that key.
2. **`SMC_CMD_READ_BYTES` (5)** or **`SMC_CMD_WRITE_BYTES` (6)** — performs the actual read or write using the data size from step 1.

Keys are encoded as 4-byte big-endian FourCC integers (`"F0Ac"` → `0x46304163`).

### Temperature sensor keys

Apple Silicon SMC key names are undocumented. FanCurve uses the following:

**CPU temperature** (`cpuTemp()`):

| Key | Description |
|-----|-------------|
| `Tp01`, `Tp05`, `Tp0D`, `Tp0H`, `Tp0L`, `Tp0P`, `Tp0X`, `Tp0b` | Thermally distributed package sensors across the SoC |

All available keys are read and averaged. These package-level sensors are far more stable than per-core die temps (`TCMb`) which spike on every short burst and would cause the fan to react unnecessarily. If none of the package keys respond, the code falls back to the maximum of `TCMb`, `Tex1`, and `Te05`.

**GPU temperature** (`gpuTemp()`):

| Key | Description |
|-----|-------------|
| `Tg04`, `Tg05`, `Tg0K`, `Tg0L`, `Tg0R`, `Tg0S`, `Tg0X`, `Tg0Y` | GPU cluster sensors |

The **maximum** across all responding keys is used (not the average), because GPU clusters can idle at very different temperatures and the hottest one is what matters for thermal management.

**Fan keys:**

| Key | Description |
|-----|-------------|
| `F0Ac`, `F1Ac` | Actual fan speed (RPM), read as float |
| `F0Mn`, `F1Mn` | Hardware minimum RPM |
| `F0Mx`, `F1Mx` | Hardware maximum RPM |
| `F0Md`, `F1Md` | Manual mode flag (write 1 to enable, 0 to disable) |
| `F0Tg`, `F1Tg` | Target RPM (write to set) |
| `Ftst` | Thermal test mode — suppresses `thermalmonitord`'s fan control |

### Reads vs. writes

**Reads** are done directly in the app process without root. All temperature and fan speed reads use `IOConnectCallStructMethod` via the `readFloat(_:)` helper, which deserialises the 4-byte float from the `bytes` field of the output `SMCData`.

**Writes** are not performed by the app. The app calls `SMC.setTargetRPM(_:)`, which writes a plain text number to `/tmp/fancurve_target`. The daemon picks this up and performs the actual SMC writes.

---

## Daemon (`daemon/fancurve-daemon.c`)

The daemon runs permanently as root under launchd. It polls `/tmp/fancurve_target` every 500ms.

### Apple Silicon unlock sequence

On M4 and later, you cannot simply write to `F0Tg` to control fan speed. `thermalmonitord` — Apple's thermal management daemon — owns the fans and resets any manual target within seconds. The unlock sequence must be performed in order:

**Step 1 — Write `Ftst=1`**

`Ftst` is a "thermal test mode" key. Setting it to 1 suppresses `thermalmonitord`'s `LifetimeServoController`, which is the component that controls fan targets. This must be re-asserted every iteration (every 500ms); if it lapses, `thermalmonitord` reclaims the fans within ~2 seconds.

**Step 2 — Poll `F%dMd=1`**

After asserting `Ftst`, the fan mode write (`F0Md`) initially returns `0x82` (SMC_ERR_BAD_CMD), meaning `thermalmonitord` hasn't relinquished control yet. The daemon polls with 100ms intervals for up to 10 seconds until the write succeeds (returns 0). This typically takes 3–6 seconds on M4.

Once in manual mode, the mode write is re-asserted every loop iteration. If `thermalmonitord` reclaims a fan (resets the mode bit), the next iteration detects the `0x82` response and re-runs the polled unlock.

**Step 3 — Write `F%dTg`**

Write the target RPM as a 4-byte float to `F0Tg` (and `F1Tg` if a second fan exists). This is repeated every 500ms loop iteration.

On M5, the `Ftst` key does not exist (returns `SMC_ERR_NOT_FOUND = 0x84`). The daemon detects this and skips the `Ftst` assert, since M5 may not require this unlock step.

### Auto mode restore

When the target file contains `-1`, the daemon writes `F%dMd=0` to exit manual mode on each fan, then writes `Ftst=0` to restore `thermalmonitord`'s control. Fan speed returns to Apple's automatic thermal management.

### Fan detection

At startup the daemon checks for `F0Ac`, `F1Ac`, `F2Ac`, `F3Ac` keys. The highest index that exists determines the fan count. Defaults to 2 if detection fails.

### Logging

The daemon appends to `/tmp/fancurve-daemon.log`. Useful for debugging the unlock sequence timing:

```bash
tail -f /tmp/fancurve-daemon.log
```

---

## Control Loop (`FanController.swift`)

`FanController` is a `@MainActor` `ObservableObject`. It owns all published sensor and state values that the UI observes.

### Tick — every 4 seconds

```
tick()
  ├── refresh()           — read SMC sensors, update EMA
  ├── if isAutoMode       → return (macOS controls fans, nothing to do)
  ├── if isMaxFan         → writeAllFans(fanMax)
  └── else                → applyProfile()
```

### Temperature smoothing (EMA)

Raw SMC temperature values are noisy. A CPU burst for a single frame of a video can spike the package temperature by 10–15°C, which would cause an audible fan ramp-up for no real thermal reason.

FanCurve applies an **Exponential Moving Average**:

```
smoothed = α × raw + (1 − α) × previous_smoothed
```

With α = 0.25 and a 4-second tick interval, the **half-life is approximately 16 seconds** — meaning a temperature spike must be sustained for ~16 seconds to have half its influence on the fan curve. On first tick, `smoothed` is initialised to `raw` (no cold-start lag).

CPU and GPU have independent smoothing state (`smoothedCPU`, `smoothedGPU`). When the user disables Max Fan mode, both are reset to `nil` so the next tick takes an immediate fresh reading rather than carrying over the stale pre-max state.

### Active temperature

The control variable sent to the fan curve is `activeTemp`, which routes to the correct sensor combination based on the per-store `tempSensor` setting:

| Setting | Formula |
|---------|---------|
| CPU Average | `cpuTemp` |
| GPU Average | `gpuTemp` if available, else `cpuTemp` |
| CPU + GPU | `(cpuTemp + gpuTemp) / 2` if GPU present, else `cpuTemp` |
| CPU/GPU Max | `max(cpuTemp, gpuTemp)` if GPU present, else `cpuTemp` |

GPU presence is inferred by checking whether `gpuTemp > 0` (the SMC returns 0 for absent keys).

### `applyProfile()`

1. **Safety check with hysteresis:**
   - If `activeTemp ≥ safetyTemp` → set `safetyActive = true`
   - Else if `safetyActive` and `activeTemp < safetyTemp − 10°C` → clear `safetyActive = false`
   - This 10°C hysteresis prevents the fan from rapidly cycling on/off when temperature hovers near the threshold

2. **Curve evaluation:** call `targetRPM(at: activeTemp)` (linear interpolation, described below)

3. **Cap application:** if the profile has a `maxFanSpeed`, clamp the curve output: `min(curveRPM, maxFanSpeed)`. During a safety override, the cap is ignored and the full hardware maximum is used.

4. **Dead-band filter:** only write a new target if:
   - `safetyActive` is true (always override), or
   - the new target is more than 50 RPM higher than the last commanded RPM, or
   - the new target is more than 200 RPM lower than the last commanded RPM, or
   - `commandedRPM == 0` (first write)

   The asymmetric thresholds (+50/−200) mean the fan ramps up quickly to changes but ramps down more conservatively, reducing hunting.

### Modes

| Mode | Description | What writes |
|------|-------------|-------------|
| Auto | FanCurve hands off to macOS | `SMC.resetTargetRPM()` writes `-1` |
| Max Fan | Immediate full-speed override | `writeAllFans(fanMax)` every tick |
| Profile | Fan curve active | `applyProfile()` every tick |

Switching to auto mode also clears `safetyActive` and resets `commandedRPM` to `fanMin`.

---

## Data Model (`Profile.swift`)

### `CurvePoint`

A single (temperature, RPM) pair on a fan curve.

- `tempC: Double` — temperature in degrees Celsius
- `rpm: Double` — target fan speed
- `isLocked: Bool` — computed; `true` when `tempC == 0` or `tempC == 105`. Locked points represent the boundary conditions of the curve. They can be edited vertically (RPM) but their temperature is fixed.

### `FanProfile`

A named fan curve with settings.

- `points: [CurvePoint]` — the curve knots; must be sorted by `tempC` before interpolation
- `isBuiltIn: Bool` — true for Silent, Balanced, Performance; built-in profiles cannot be deleted
- `maxFanSpeed: Double?` — optional per-profile RPM cap. `nil` means no cap (hardware max applies). When set, shown as an orange dashed line on the chart editor.

### `targetRPM(at:)` — linear interpolation

```swift
func targetRPM(at temp: Double) -> Double {
    let sorted = points.sorted { $0.tempC < $1.tempC }
    if temp <= sorted.first!.tempC { return sorted.first!.rpm }
    if temp >= sorted.last!.tempC  { return sorted.last!.rpm }
    for i in 0 ..< sorted.count - 1 {
        let lo = sorted[i], hi = sorted[i + 1]
        guard temp <= hi.tempC else { continue }
        let t = (temp - lo.tempC) / (hi.tempC - lo.tempC)
        return (lo.rpm + t * (hi.rpm - lo.rpm)).rounded()
    }
    return sorted.last!.rpm
}
```

`t` is the normalised position between two adjacent knots (0–1). The result is rounded to the nearest integer RPM. Temperatures outside the curve's range clamp to the first or last point's RPM.

### Built-in default curves

| Profile | Behaviour |
|---------|-----------|
| **Silent** | 0 RPM below 45°C; ramps from 1200 to 7826 RPM between 55–95°C |
| **Balanced** | 0 RPM below 45°C; ramps from 1800 to 7826 RPM between 55–95°C |
| **Performance** | 3000 RPM floor; aggressively ramps to max above 65°C |

All profiles have locked boundary nodes at 0°C and 105°C.

### `ProfileStore` — persistence

Profiles are persisted to `~/.config/fancurve/profiles.json` as a `Saved` struct with JSON encoding.

**Saved fields:**
- `profiles: [FanProfile]` — all profiles including custom ones
- `activeProfileID: UUID` — which profile is currently selected
- `tempSensor: TempSensor` — global sensor selection
- `safetyTemp: Double?` — optional so old saves without the key decode correctly

**On load, two migrations run:**

1. **Legacy global cap** — older saves had a single `maxFanSpeed` on the root `Saved` struct. If present, it is copied to every profile's `maxFanSpeed`, then discarded (never written back).

2. **Built-in name stamping** — profiles loaded from saves that predate the `isBuiltIn` field get the flag set if their name matches a default profile name.

After migrations, the store ensures every profile has boundary nodes at exactly 0°C and 105°C, inserting them if missing (with the adjacent endpoint's RPM as the default value).

---

## UI Architecture

### `AppDelegate.swift` — app lifecycle and panels

**Startup:**
- Sets activation policy to `.accessory` (no Dock icon, no app switcher entry)
- Guards against duplicate instances using `NSRunningApplication.runningApplications(withBundleIdentifier:)`
- Creates `FanController`, builds the menu bar item and popup panel
- Subscribes to `controller.$cpuTemp` via Combine to update the status bar label on every sensor tick
- Installs a global `NSEvent` monitor for mouse-down events outside the app's windows to close the popup

**Shutdown:**
- Calls `SMC.resetTargetRPM()` — writes `-1` to the target file so the daemon restores auto control before the process exits

**Popup panel (`menuPanel`):**
- `NSPanel` with `.borderless` and `.nonactivatingPanel` style masks — appears without stealing keyboard focus from whatever the user was doing
- Positioned below the status item, clamped to the screen's visible frame
- Height auto-fits via KVO on `NSHostingController.preferredContentSize` — the panel shrinks when Max Fan mode hides the profile picker, grows when it reappears
- `FixedSizeHostingController` is used for the curve editor to suppress `glassEffect`'s inflated fitting size, which would otherwise push the window off the top of the screen

**Curve editor panel (`editorPanel`):**
- `KeyablePanel` — a borderless `NSPanel` subclass that overrides `canBecomeKey` and `canBecomeMain` to return `true`. Without this, SwiftUI drag gestures and text field focus do not work in a borderless panel.
- Positioned to the right of the popup panel, within the screen's visible frame
- Created fresh each time it's opened (no reuse), so SwiftUI state resets cleanly

### `MenuContentView.swift` — popup panel UI

The popup renders different content depending on controller state:

```
No fans detected → noFanView (error state)
Fans present →
  modeToggle          always shown
  ─────────
  statsHeader         always shown (temp gauge, fan RPM, target RPM)
  ─────────
  maxFanRow           only in manual mode
  profilePicker       only in manual mode and not max-fan
  permissionWarning   only if daemon write failed
  ─────────
  actionRow           always shown (Edit Curves, Quit)
```

**`BlueToggle`** is a custom animated toggle. It keeps a `@State private var visualOn` copy of the binding's value so that its spring animation completes smoothly even when the binding update triggers a global re-render of the view tree. Without this, the animation frame is cut short by the re-render.

The temperature gauge is a circular arc drawn with `Circle().trim(from:to:)`. The fraction maps 30–95°C onto 0–1, coloured green below 40%, yellow below 70%, red above.

### `ProfileEditorView.swift` — curve editor

A fixed 640×490 pt panel with a 140pt left sidebar and a main editing area.

**Sidebar (top to bottom):**
1. Scrollable profile list with checkmarks
2. `+` / `−` buttons to add/delete profiles. Built-in profiles cannot be deleted (the `−` button is disabled and shows a tooltip).
3. **Control Sensor** picker — selects which temperature drives the curve; shows live readings next to each option
4. **Max Speed** — `−` / text field / `+` controls. The text field uses `@FocusState` to detect when it loses focus and commit. The entire section has `.id(selectedID)` applied, which forces SwiftUI to destroy and recreate it when switching profiles, ensuring the text field shows the new profile's value rather than carrying over stale state.
5. **Safety** — `−` / value / `+` controls for the safety override temperature (70–105°C, 5°C steps)

**Main area:**
1. Header with editable profile name (double-click to edit), live sensor reading and fan RPM
2. Interactive `CurveChart`
3. Scrollable points table (editable `TextField`s for each knot; locked nodes show temperature as plain text)
4. Footer with **Default** (reset points to built-in defaults) and **Done** buttons

Chart drag interactions debounce saves with a 300ms `Task.sleep` — dragging a point continuously doesn't hammer the filesystem.

Profile name editing uses a `ZStack` overlay trick: a `TextField` and a `Text` are layered with opacity toggling between them. The `Text` responds to double-tap to enter edit mode; the `TextField` captures `onSubmit` and `onExitCommand` to commit or cancel.

### `CurveChart.swift` — interactive chart

Built as a `ZStack` of layered `Canvas` and `View` elements inside a `GeometryReader`:

| Layer | Type | Hit testing |
|-------|------|-------------|
| Grid lines + y-axis labels | `Canvas` | — |
| Curve fill (accent, 12% opacity) | `Path.fill` | — |
| Curve line | `Path.stroke` | — |
| Red crosshair (current temp/RPM) | `Canvas` | disabled |
| Orange cap line (if maxFanSpeed set) | `Canvas` | disabled |
| Drag handles | `DragPoint` views | enabled |

The red crosshair and orange cap Canvases have `.allowsHitTesting(false)` explicitly — without this, the Canvas blocks touch events on nodes behind it.

**Coordinate mapping:**
- X axis: 0–105°C mapped to `[padH, width − padH]` (8pt inset each side)
- Y axis: 0–fanMax RPM mapped to `[height − padV, padV]` (8pt inset; inverted so higher RPM is higher on screen)

**`DragPoint`** — each curve knot is a `DragPoint` view. It uses two stacked `.frame()` modifiers: the inner 10×10pt (14×14 when dragging) is the visible circle; the outer 28×28pt is the hit area. `.contentShape(Circle())` ensures the transparent outer frame registers taps.

`DragGesture` uses `.coordinateSpace(.named("chart"))` so drag coordinates are in the chart's local space regardless of where the gesture starts. For locked (boundary) nodes, only the RPM (y-axis) updates; `tempC` is unchanged. RPM snaps to 50 RPM increments: `(rpmFromY(...) / 50).rounded() * 50`.

The x-axis temperature labels are drawn in a separate `Canvas` below the chart area, outside the `GeometryReader`, so they don't compete for layout space with the chart itself.

---

## Project Structure

```
Sources/FanCurve/
  main.swift               Entry point — NSApplication setup, accessory mode
  AppDelegate.swift        Menu bar item, popup and editor panel lifecycle
  FanController.swift      4s tick loop, EMA, curve evaluation, safety logic
  SMC.swift                IOKit reads, file-based IPC writes
  Profile.swift            Data model, linear interpolation, JSON persistence
  MenuContentView.swift    Popup panel UI (BlueToggle, stats, profile picker)
  ProfileEditorView.swift  Curve editor UI (sidebar, table, footer)
  CurveChart.swift         Interactive drag-handle chart

daemon/
  fancurve-daemon.c        Root daemon — SMC write unlock sequence, poll loop

Resources/
  AppIcon.icns             Application icon

build.sh                   Release build + re-sign + restart
install.sh                 First-time install (daemon + app + optional LaunchAgent)
com.local.fancurve-daemon.plist   LaunchDaemon spec (root)
com.local.fancurve.plist          LaunchAgent spec (login item)
Package.swift              Swift Package Manager manifest
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
