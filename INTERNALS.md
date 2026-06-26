# FanCurve — Internal Architecture

---

## Overview

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

The split exists because SMC reads work without root, but SMC writes on Apple Silicon require root. Rather than running the whole app as root (a security anti-pattern), the app delegates writes to a minimal C daemon that has exactly one job: read the target file and write the value to the SMC.

**IPC protocol — `/tmp/fancurve_target`:**

| Value | Meaning |
|-------|---------|
| `> 0` | Set fans to this RPM |
| `<= 0` (including `-1`) | Return fans to `thermalmonitord` (macOS automatic control) |

The file contains a plain integer followed by a newline. The app writes it atomically. The daemon reads it every 500ms. On app exit, the app writes `-1` to restore automatic control.

---

## `main.swift` — Entry point

The entry point has one job: get `NSApplication` set up on the main thread before anything else touches it.

```swift
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
```

`.accessory` is what makes FanCurve behave like a system utility rather than a normal app — no Dock icon, no app switcher entry, no menu bar takeover. `NSApplication.shared` must be called before `NSApp` is ever referenced; calling it here on the main thread guarantees that. `MainActor.assumeIsolated` constructs `AppDelegate` on the main thread without needing an `async` context, which `main.swift` doesn't have.

---

## `SMC.swift` — Sensor reads and IPC writes

This file is the only place in the app that talks to the SMC or touches the IPC file. Everything else goes through it.

### IOKit connection

```swift
private static let conn: io_connect_t = {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    var c: io_connect_t = 0
    IOServiceOpen(svc, mach_task_self_, 0, &c)
    IOObjectRelease(svc)
    return c
}()
```

A single `io_connect_t` is opened once at first use (lazy static) and reused forever. Opening a connection is cheap but repeated opens waste kernel resources. The SMC is a kernel service named `"AppleSMC"` in the IOKit registry.

### The `SMCData` struct

Every SMC operation uses a fixed 80-byte struct:

```
offset  0: key (4 bytes, big-endian FourCC)
offset  4: vers (6 bytes)
offset 10: pLimit (16 bytes)
offset 26: [2 bytes implicit pad before KeyInfo]
offset 28: infoSize (4 bytes)
offset 32: infoType (4 bytes)
offset 36: infoAttr (1 byte)
offset 37: [3 bytes KeyInfo trailing pad — MUST be present]
offset 40: result (1 byte)
offset 41: status (1 byte)
offset 42: data8 (1 byte) — the command goes here
offset 43: [1 byte pad]
offset 44: data32 (4 bytes)
offset 48: bytes (32 bytes) — payload
```

The 3-byte pad at offset 37 is critical. The C `KeyInfo` struct has `sizeof = 12` due to trailing alignment padding that the Swift compiler won't insert automatically if you flatten the fields. If those 3 bytes are missing, `data8` shifts from offset 42 to 39, the kernel reads the command from the wrong byte, and all SMC calls silently fail.

### Two-call read sequence

Every key read makes two IOKit calls:

1. **`SMC_CMD_READ_KEYINFO` (9)** — set `data8 = 9` and the key FourCC, send to the kernel. Response in `out.infoSize` gives the data size for this key (e.g. 4 bytes for a float).
2. **`SMC_CMD_READ_BYTES` (5)** — set `data8 = 5`, `infoSize` from step 1, same key. Response in `out.bytes` contains the value.

The value is then extracted as a `float` via `memcpy` and returned as `Double`. All Apple Silicon fan keys (`F0Ac`, `F0Mn`, `F0Tg`, etc.) and temperature keys store IEEE 754 float32.

### Temperature keys

**CPU (`cpuTemp()`)** reads a set of package-level thermal sensors (`Tp01`, `Tp05`, `Tp0D`, `Tp0H`, `Tp0L`, `Tp0P`, `Tp0X`, `Tp0b`) and averages whatever is present and in-range (0–120°C). These are distributed across the SoC die and give a stable aggregate temperature. Per-core die temps (`TCMb`) spike on every short CPU burst and would make the fan react to 1-second workloads that don't need cooling — so they're only used as a fallback if none of the package keys respond.

**GPU (`gpuTemp()`)** reads cluster sensors (`Tg04`, `Tg05`, `Tg0K`, `Tg0L`, `Tg0R`, `Tg0S`, `Tg0X`, `Tg0Y`) and takes the **maximum**, not the average. GPU clusters can idle at very different temperatures; the hottest cluster is what drives thermal need.

### Fan keys

| Key | What it returns |
|-----|-----------------|
| `F%dAc` | Actual measured fan speed (RPM) |
| `F%dMn` | Current minimum RPM floor — **dynamic**, rises under thermal load |
| `F%dMx` | Hardware maximum RPM |
| `F%dMd` | Manual mode flag (1 = FanCurve controls, 0 = thermalmonitord controls) |
| `F%dTg` | Target RPM (write to set the fan speed) |
| `Ftst` | Thermal test bit — suppresses thermalmonitord's servo loop |

**Important about `F%dMn`:** This is not a fixed hardware constant. macOS adjusts it dynamically based on current thermal load — it can be ~1200 RPM at idle but rise to ~2300 RPM when the GPU is hot. The app reads it at startup for informational display only and does not use it as a software floor when commanding fan speeds, because a startup-time reading would become stale and lock the target at whatever the floor happened to be when the app launched.

### Fan count detection (`fanCount()`)

```swift
for i in 0..<4 {
    guard readFloat("F\(i)Ac") != nil else { break }
    let mn = readFloat("F\(i)Mn") ?? 1200
    if mn > 0 { n = i + 1 }
}
```

Iterates slots 0–3, stopping at the first absent `F%dAc` key. Each present slot is then checked against `F%dMn`: a minimum RPM of 0 indicates a ghost slot — an SMC entry with no physical fan behind it (seen on some Apple Silicon Pro/Max chips that report two slots but only have one fan). Ghost slots are excluded from the count. If `F%dMn` is absent for a present slot, it defaults to 1200 (assume real fan). Returns 0 for fanless Macs.

### IPC writes

```swift
private static func writeTarget(_ rpm: Double) -> Bool {
    let content = "\(Int(rpm))\n"
    try content.write(toFile: targetFile, atomically: true, encoding: .utf8)
}
```

`atomically: true` writes to a temp file then renames, preventing the daemon from reading a half-written value. `setTargetRPM(_:)` and `resetTargetRPM()` are thin wrappers around this.

---

## `daemon/fancurve-daemon.c` — Root daemon

The daemon runs permanently as root under launchd. Its entire job is to watch the target file and translate its value into SMC writes, including the Apple Silicon unlock sequence that makes manual fan control possible.

### Why a separate daemon?

SMC writes on Apple Silicon require root. Rather than running the GUI app as root, the daemon is a minimal C program (~280 lines) that runs as root and does only one thing. The attack surface is tiny: it reads one file, writes to SMC keys from a hardcoded list, and logs to `/tmp/fancurve-daemon.log`.

### Apple Silicon unlock sequence

On Intel Macs, you could write directly to `F0Tg` and the SMC would honour it. On Apple Silicon, `thermalmonitord` — Apple's thermal management daemon — owns the fans and will reset any manual target within seconds. Three steps are required to take control:

**Step 1 — `Ftst = 1`**

`Ftst` is a "thermal test mode" key. Writing `1` suppresses `thermalmonitord`'s `LifetimeServoController`, which is the subsystem that drives fan targets. The daemon re-asserts this every 500ms loop iteration; if it lapses for ~2 seconds, thermalmonitord wakes up and reclaims the fans.

On M5, the `Ftst` key returns `SMC_ERR_NOT_FOUND (0x84)`. The daemon detects this on the first write, sets a `ftst_exists = 0` flag, and skips the assert in all future iterations.

**Step 2 — `F%dMd = 1` (with polling)**

After asserting `Ftst`, the fan mode write (`F0Md`) initially returns `SMC_ERR_BAD_CMD (0x82)`, meaning thermalmonitord hasn't fully relinquished control yet. The daemon polls with 100ms intervals for up to 10 seconds:

```c
for (int elapsed = 0; elapsed < UNLOCK_TIMEOUT_MS; elapsed += POLL_MS) {
    int r = smcWriteU8(mdKey, 1);
    if (r == 0) return 1;          // success
    if (r == SMC_ERR_NOT_FOUND) return 0;  // key doesn't exist
    usleep(POLL_MS * 1000);        // retry
}
```

This typically succeeds within 3–6 seconds. In subsequent loop iterations, the mode write is attempted directly (fast path: returns 0 immediately once Ftst is active). If thermalmonitord reclaims a fan mid-session (resets the mode bit), the 0x82 response triggers the full polled unlock again.

**Step 3 — `F%dTg = target_rpm`**

Write the target as a 4-byte IEEE 754 float to `F0Tg` (and `F1Tg` if a second fan is present). This repeats every 500ms so the SMC always has a fresh value.

### Main loop

```
while (1) {
    target = readTarget();
    if (target <= 0) {
        // auto mode: release fans
        exitManualMode() each fan
        clearFtst()
        manualMode = 0
    } else {
        // manual mode: assert control and write target
        assertFtst()
        for each fan: smcWriteU8(F%dMd, 1)  // re-assert every iteration
        for each fan: smcWriteFloat(F%dTg, target)
        manualMode = 1
    }
    usleep(500ms)
}
```

`exitManualMode` only sets `F%dMd = 0` — it does not write a new target to `F%dTg`. This means after handing off, thermalmonitord reclaims the fan and sets its own target based on its full thermal model (CPU, GPU, SSD, battery, ambient). This is intentional: when the curve says 0 RPM ("quiet below this temperature"), the app hands off entirely rather than fighting thermalmonitord with a specific target.

### Logging

The daemon appends to `/tmp/fancurve-daemon.log` and logs when fan speed changes or manual/auto mode transitions occur. Useful for debugging:

```bash
tail -f /tmp/fancurve-daemon.log
```

---

## `FanController.swift` — Control loop

`FanController` is the brain of the app. It's a `@MainActor` `ObservableObject` that owns all sensor readings and published state. The UI observes it; the timer drives it.

### Initialisation

```swift
init() {
    fanCount = SMC.fanCount()
    fanMin   = SMC.fanMin(0)
    let hwMax = SMC.fanMax(0)
    fanMax   = hwMax
    store    = ProfileStore(fanMax: hwMax)
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { ... }
}
```

`fanMax` is read from hardware and passed into `ProfileStore` so the built-in curves scale to the actual hardware maximum. `refresh()` is called immediately so sensor values are populated before the first UI render.

### The tick (every 4 seconds)

```swift
func tick() {
    refresh()
    guard !isAutoMode else { return }
    if isMaxFan { writeAllFans(fanMax) } else { applyProfile() }
}
```

`refresh()` reads SMC sensors and updates the EMA. Then, if auto mode is off, either blast all fans to max or evaluate the curve.

### Temperature smoothing (EMA)

Raw SMC temperatures are noisy. A 1-second CPU burst can spike the package temperature by 10–15°C, which would cause an audible fan ramp-up for no real thermal reason.

```swift
smoothedCPU = smoothedCPU.map { alpha * rawCPU + (1 - alpha) * $0 } ?? rawCPU
```

α = 0.25, tick = 4 seconds → **half-life ≈ 16 seconds**. A temperature spike must be sustained for ~16 seconds to move the smoothed value by half the spike amplitude. On first tick, `smoothed` is `nil`, so it initialises to the raw value with no cold-start lag.

CPU and GPU have independent EMA state. When Max Fan mode is disabled, both are reset to `nil` so the next tick takes a fresh reading rather than carrying over whatever stale EMA state accumulated while fans were at max.

### Active temperature

`activeTemp` routes the smoothed sensor values through the user's chosen formula:

| Setting | Formula |
|---------|---------|
| CPU Average | `cpuTemp` |
| GPU Average | `gpuTemp` if > 0, else `cpuTemp` |
| CPU + GPU | `(cpuTemp + gpuTemp) / 2` if GPU present |
| CPU/GPU Max | `max(cpuTemp, gpuTemp)` if GPU present |

GPU presence is checked with `gpuTemp > 0` because the SMC returns 0 for absent or non-responding keys.

### `applyProfile()`

This is the core control logic, called every 4 seconds when in manual mode:

**1. Safety hysteresis**
```swift
if temp >= store.safetyTemp {
    safetyActive = true
} else if safetyActive && temp < store.safetyTemp - 10 {
    safetyActive = false
}
```
Once `safetyActive` latches on, it stays on until temp drops 10°C below the threshold. This prevents the fan from rapidly cycling at the threshold boundary.

**2. Curve evaluation**
```swift
let curveRPM = store.activeProfile.targetRPM(at: temp)
let effectiveCap = store.activeProfile.maxFanSpeed ?? fanMax
let raw = safetyActive ? fanMax : min(curveRPM, effectiveCap)
```
`raw` is the desired fan speed: hardware max during safety override, or the curve value clamped to the per-profile speed cap. The cap is bypassed during safety override.

**3. Target selection**
```swift
let target = raw  // write curve value directly; hardware enforces its own floor
```
The SMC hardware will not let fans go below their physical minimum regardless of what we write, so no software floor is applied. The only special case is `raw == 0`, which means "hand back to thermalmonitord" rather than commanding 0 RPM.

**4. Dead-band filter**
```swift
let delta = raw - commandedRPM
guard safetyActive || abs(delta) > 50 || commandedRPM == 0 || raw == 0 else { return }
```
Writes are skipped unless the target has moved more than 50 RPM from the last commanded value. This prevents the fan from hunting back and forth when the EMA temperature oscillates by a degree or two around a stable point. Bypasses:
- `safetyActive`: always write during emergency override
- `commandedRPM == 0`: always write the first command after startup or returning from auto mode
- `raw == 0`: always write the hand-off to thermalmonitord

**5. Write**
```swift
commandedRPM = raw
if raw == 0 {
    SMC.resetTargetRPM()     // writes -1 → daemon exits manual mode
} else {
    writePermissionOK = SMC.setTargetRPM(raw)
}
```
`commandedRPM` is `@Published` and is what the UI shows as "Target". `writePermissionOK` is set false if the IPC write fails, which triggers a warning in the UI.

### Mode transitions

**Auto mode** (`setAutoMode(true)`): writes `-1` to the IPC, clears `safetyActive`, resets `commandedRPM = 0`. The daemon exits manual mode and thermalmonitord takes over.

**Manual mode** (`setAutoMode(false)`): resets `commandedRPM = 0` before calling `applyProfile()`. The reset is critical — it ensures the dead-band bypass (`commandedRPM == 0`) fires and the first write always goes through, even if the curve value happens to equal whatever `commandedRPM` was before.

**Max Fan** (`setMaxFan(true)`): writes `fanMax` directly every tick via `writeAllFans()`. On disable, resets the EMA (`smoothedCPU = smoothedGPU = nil`) so the next tick reads a fresh temperature rather than ramping down from a potentially stale high value, then calls `applyProfile()`.

---

## `Profile.swift` — Data model and persistence

### `TempSensor`

A `Codable` enum with four cases: `cpuAvg`, `gpuAvg`, `cpuGpuAvg`, `cpuGpuMax`. The raw value is the display string (e.g. `"CPU Average"`), which is also the JSON key for persistence. `CaseIterable` lets the UI iterate all options.

### `CurvePoint`

```swift
struct CurvePoint: Codable, Identifiable, Equatable {
    var id: UUID
    var tempC: Double
    var rpm: Double
    var isLocked: Bool { tempC == 0 || tempC == 105 }
}
```

A single knot on the fan curve. `isLocked` is a computed property — the 0°C and 105°C boundary points can have their RPM changed but not their temperature; this is enforced in the UI by showing them as plain text rather than editable text fields.

### `FanProfile`

```swift
struct FanProfile: Codable, Identifiable {
    var id: UUID
    var name: String
    var points: [CurvePoint]
    var isBuiltIn: Bool = false
    var maxFanSpeed: Double? = nil
}
```

`isBuiltIn: Bool` prevents built-in profiles from being deleted. `maxFanSpeed: Double?` is `nil` by default (no cap); when set, the curve output is clamped to this value in `applyProfile()` and shown as an orange dashed line in the chart editor.

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

Sorts points by temperature (the array isn't required to be sorted — dragging can temporarily reorder it), then does a linear search for the segment containing `temp`. `t` is the normalised position within the segment (0–1). Result is rounded to the nearest integer RPM. Temperatures outside the curve's range clamp to the first or last point's RPM respectively.

### Built-in default curves

`FanProfile.defaults(fanMax:)` generates the four built-in profiles at runtime, using the hardware's actual `fanMax` so the top of each curve scales to the specific Mac rather than a hardcoded constant:

| Profile | Behaviour |
|---------|-----------|
| **Silent** | 0 RPM below 45°C; ramps from 1200 to fanMax between 55–95°C |
| **Balanced** | 0 RPM below 45°C; ramps from 1800 to fanMax between 55–95°C |
| **macOS Default** | Approximates Apple's default thermal curve (0 RPM below 50°C, then gentle ramp) |
| **Performance** | 3000 RPM floor from 0°C; aggressively ramps to fanMax above 85°C |

A curve point with `rpm = 0` means "hand back to thermalmonitord at this temperature."

### `ProfileStore` — persistence

`ProfileStore` manages loading, migration, and saving of all profiles to `~/.config/fancurve/profiles.json`.

**Loading sequence:**

1. Try to decode `profiles.json`. If it fails or is empty, initialise with defaults.
2. **Migration: legacy global cap** — older saves had a single `maxFanSpeed` at the root level. If present, copy it to every profile's `maxFanSpeed` then discard it (it's never written back).
3. **Migration: `isBuiltIn` stamping** — profiles from saves that predate the `isBuiltIn` field have it set to `false`. Any profile whose name matches a built-in name gets the flag set.
4. **Migration: missing built-ins** — if a built-in profile name is absent from the saved list (because it was added in a newer version of the app), append it.
5. **Boundary node enforcement** — every profile must have locked points at exactly 0°C and 105°C. Any profile missing either gets them inserted, inheriting the RPM of the nearest existing point.
6. Call `save()` to flush migrations back to disk.

**`Saved` struct** (the JSON shape):
```swift
struct Saved: Codable {
    var profiles: [FanProfile]
    var activeProfileID: UUID
    var tempSensor: TempSensor = .cpuAvg
    var safetyTemp: Double?    // optional: old saves without this key still decode
    var maxFanSpeed: Double?   // legacy only, migrated on load
}
```

`safetyTemp` is `Double?` rather than `Double` so saves from before that field was added decode successfully (Swift uses `nil` for missing optional keys).

---

## `AppDelegate.swift` — App lifecycle and panels

`AppDelegate` handles everything AppKit: the menu bar item, the two floating panels, the global click monitor, and clean shutdown.

### Startup

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // Duplicate instance guard
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.fancurve")
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty { NSApp.terminate(nil); return }
    ...
}
```

On launch: checks for an existing instance with the same bundle ID and quits immediately if one is found (prevents two copies fighting over the IPC file). Then creates `FanController`, builds the popup panel, creates the status bar item, and subscribes to temperature updates.

**Status bar item:** Uses a monospaced digit font so the temperature number doesn't cause the icon to jump width. `NSImage.SymbolConfiguration` is used to size the fan SF Symbol at 12pt, matching the font size. `button.imagePosition = .imageLeft` puts the icon to the left of the temperature text.

**Temperature updates:** `controller.$cpuTemp.sink { ... }` subscribes via Combine to every `@Published` change on `cpuTemp`. This fires every 4 seconds when the tick runs. The status bar label reads `controller.activeTemp` (not `cpuTemp`) so it shows whichever sensor the user has selected.

**Global event monitor:** `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])` fires for any click that lands outside our app's windows. Used to close the popup and editor when the user clicks elsewhere. Note: clicks _inside_ the app's own windows don't fire this monitor, which is why clicking the editor doesn't close the popup.

### Shutdown

```swift
func applicationWillTerminate(_ notification: Notification) {
    SMC.resetTargetRPM()
    NSEvent.removeMonitor(eventMonitor)
}
```

Writes `-1` to the IPC file before exit so the daemon returns fans to automatic control. Without this, the daemon would keep commanding the last manual RPM after the app is gone.

### Main menu

`setupMainMenu()` installs a minimal `NSMenu` so that standard keyboard shortcuts work in text fields inside the editor (⌘Z, ⌘X, ⌘C, ⌘V, ⌘A). Without an Edit menu, these shortcuts are not wired up by AppKit and text editing in the profile name and point fields breaks.

### Popup panel (`menuPanel`)

```swift
let panel = NSPanel(
    contentRect: ...,
    styleMask: [.borderless, .nonactivatingPanel],
    ...
)
panel.isReleasedWhenClosed = false
```

`.borderless` removes the title bar and window chrome. `.nonactivatingPanel` is critical — without it, clicking the menu bar icon would steal keyboard focus from whatever the user was doing. `isReleasedWhenClosed = false` prevents AppKit from deallocating the panel on `orderOut`, which would crash the next time we try to show it.

**Auto-resizing:** The popup needs to shrink when auto mode hides the profile picker and grow when it returns. This is done by KVO-observing `menuHC.preferredContentSize`:

```swift
sizeObservation = hc.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
    Task { @MainActor [weak self] in self?.fitPanelToContent() }
}
```

`fitPanelToContent()` reads `preferredContentSize.height` and repositions the panel so its top stays pinned below the menu bar while its bottom grows downward.

### Editor panel (`editorPanel`)

```swift
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

A borderless `NSPanel` returns `false` from `canBecomeKey` by default. Without overriding this, `makeKey()` silently fails, SwiftUI never gets the key window it needs, drag gestures in the chart don't work, and text fields can't receive focus.

```swift
private final class FixedSizeHostingController<C: View>: NSHostingController<C> {
    override var preferredContentSize: NSSize {
        get { fixedSize }
        set { }
    }
}
```

`glassEffect` (the Liquid Glass API on macOS 26+) causes `NSHostingController.preferredContentSize` to return an inflated size, which makes `contentViewController`-based windows auto-resize and float off the top of the screen. `FixedSizeHostingController` ignores whatever SwiftUI reports and always returns the fixed 640×490 size.

**Memory management:** `closeEditorPanel()` sets `editorPanel = nil; editorHC = nil`. Without nilling the references, the panel object is kept alive by the strong reference even though it's been ordered out, and the next open creates a new panel — a memory leak that grows with every open/close.

### Panel positioning

The popup is anchored below the status bar button:
```swift
let br = bw.convertToScreen(button.frame)
menuPanel.setFrameTopLeftPoint(NSPoint(x: max(x, 8), y: menuBarBottom))
```

The editor is placed to the right of the popup, clamped to the visible screen frame:
```swift
let x = max(vf.minX + 8, min(menuPanel.frame.maxX + 8, vf.maxX - w - 8))
```

---

## `MenuContentView.swift` — Popup panel UI

The root view of the popup panel. It's a `VStack` that conditionally shows different sections based on `FanController` state.

### Layout structure

```
fanCount == 0 → noFanView (fan icon + "This Mac appears to be fanless." + Quit button)
fanCount > 0  →
  modeToggle          (FanCurve on/off toggle + subtitle)
  ────────────
  statsHeader         (temp, fan RPM(s), target RPM, temperature gauge)
  ────────────
  maxFanRow           (only when !isAutoMode)
  profilePicker       (only when !isAutoMode && !isMaxFan)
  permissionWarning   (only when !writePermissionOK)
  ────────────
  actionRow           (Edit Curves…, Quit FanCurve)
```

### `BlueToggle`

A fully custom animated toggle because `Toggle` with a SwiftUI binding triggers a global re-render (all `@Published` properties refresh) which interrupts in-flight animations.

```swift
@State private var visualOn: Bool = false
```

`visualOn` is a local copy of the binding's value that drives the animation. The capsule and circle animations run on `visualOn`. When the user taps, `visualOn` toggles immediately (smooth animation), then the binding update is deferred by one run-loop cycle via `DispatchQueue.main.async` so it doesn't interfere with the animation:

```swift
.onTapGesture {
    visualOn.toggle()
    let newValue = visualOn
    DispatchQueue.main.async { isOn = newValue }
}
```

`.onChange(of: isOn)` syncs `visualOn` back if the binding is changed externally (e.g. programmatic toggle) — but only if they differ, to avoid triggering a spurious animation.

### `PanelBackground`

```swift
struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
```

Matches the system menu bar panel material — Liquid Glass on macOS 26+ (same as WiFi, Control Centre menus), standard popover material on 14–25. Applied to both the popup and the editor so they feel native.

### Stats header

Shows current temperature (with sensor label), fan RPM(s), and when in manual mode, the `commandedRPM` as "Target". `commandedRPM` is `@Published` so the Target row updates reactively every tick.

The temperature gauge is a `Circle().trim(from: 0, to: fraction)` arc. The fraction maps 30–95°C onto 0–1 (below 30 = 0%, above 95 = 100%). Colour: green below 40%, yellow 40–70%, red above 70%. The arc rotates -90° so it starts at the top.

### Profile picker

The active profile shows `commandedRPM` next to its name. Tapping a row sets `store.activeProfileID`, saves, and calls `controller.applyProfile()` immediately to switch without waiting for the next 4-second tick.

---

## `ProfileEditorView.swift` — Curve editor

A 640×490 fixed-size panel. Left sidebar is 140pt wide; the rest is the editing area.

### State

```swift
@State private var selectedID: UUID        // which profile is being edited
@State private var editingName: Bool       // whether the name field is visible
@State private var draftName: String       // buffer for the name text field
@State private var chartSaveTask: Task<Void, Never>?  // debounced save from dragging
@State private var maxSpeedText: String    // text field buffer for max speed
```

`selectedID` initialises to `store.activeProfileID` so the editor opens on whichever profile is active. `chartSaveTask` holds the debounced save: dragging a point cancels and restarts a 300ms timer, so fast dragging doesn't flood the filesystem with writes.

### Profile list (left sidebar)

Selecting a profile immediately sets `store.activeProfileID` and calls `controller.applyProfile()` — the fan curve takes effect live as you switch profiles.

**`+` button** creates a new custom profile based on the Balanced defaults, names it "Custom N", selects it.

**`−` button** is disabled when the selected profile is built-in (`.isBuiltIn == true`) or it's the last profile. On delete, the adjacent profile is selected before the deletion so no render frame sees `selectedID` pointing to a non-existent profile.

### Control Sensor picker

Shows all four sensor options with their current live readings next to each. Selecting one immediately calls `store.save()` and `controller.applyProfile()` so the sensor change takes effect live.

### Max Speed control

`−` / text field / `+` stepper. The `−` button decrements by 200 RPM clamped to `fanMin`. The `+` button increments by 200 RPM; if the result reaches `fanMax`, it sets `maxFanSpeed = nil` (no cap) instead. The text field uses `@FocusState` — when it loses focus, `commitMaxSpeed()` parses and clamps the value.

The entire `VStack` has `.id(selectedID)`. This forces SwiftUI to destroy and recreate the section when switching profiles, which ensures the text field displays the new profile's value rather than carrying over the old one. Without this, the text field would show stale content because SwiftUI's view diffing reuses the existing `TextField` rather than rebuilding it.

### Safety temperature

Global across all profiles (stored in `ProfileStore.safetyTemp`). Adjustable in 5°C steps between 70°C and 105°C. Saved immediately on change.

### Editor header

The profile name is rendered as two overlapping views: a `Text` label and a `TextField`. Only one is visible at a time (`opacity`/`allowsHitTesting` toggled based on `editingName`). Double-tapping the label switches to the text field. Focus loss (detected via `onChange(of: isNameFieldFocused)`) commits the name.

### Points table

Each row is a `PointRow` view. For locked nodes (0°C and 105°C), the temperature cell is a plain `Text`; for unlocked nodes, it's a `TextField`. The RPM cell is always a `TextField`.

`PointRow` keeps local `@State` copies of the text (`tempText`, `rpmText`) rather than binding directly to `Double` values. This lets the user type partial strings without immediately corrupting the underlying data. On `onSubmit`, the text is parsed and clamped, then written back to the binding. `.onChange` on the point's value syncs the local text if the value changes externally (e.g. from dragging on the chart), but only when that field isn't focused (to avoid overwriting what the user is mid-typing).

Context-menu on each row offers "Delete" for unlocked points. The `+ Add Point` button appends a new point 10°C above the highest existing point, inheriting that point's RPM.

### Chart binding with debounced save

```swift
CurveChart(
    points: Binding(
        get: { store.profiles[selectedIndex].points },
        set: {
            store.profiles[selectedIndex].points = $0
            chartSaveTask?.cancel()
            chartSaveTask = Task {
                try await Task.sleep(nanoseconds: 300_000_000)
                store.save()
            }
        }
    ), ...
)
```

The `set` closure updates the model immediately (so the UI reflects the drag in real time) but debounces the disk write by 300ms. Dragging a point quickly doesn't write a file for every frame.

### Default / Done footer

**Default** resets the current profile's points to the built-in defaults for that profile name. If no match is found (custom profile), falls back to Balanced.

**Done** saves and calls `onDismiss()`, which closes the editor panel and shows the popup panel.

---

## `CurveChart.swift` — Interactive chart

A `VStack` with two parts: the plot area (`GeometryReader`) and the x-axis labels (`Canvas`). The x-axis is in a separate `Canvas` below the `GeometryReader` so it doesn't compete with the chart for vertical space.

### Coordinate system

```swift
func xPos(_ temp: Double, w: CGFloat) -> CGFloat {
    padH + CGFloat((temp - 0) / 105) * (w - 2 * padH)
}
func yPos(_ rpm: Double, h: CGFloat) -> CGFloat {
    h - padV - CGFloat(rpm / fanMax) * (h - 2 * padV)
}
```

`padH = 8` and `padV = 14` inset the usable area from the edges so points at the extremes (0°C, 105°C, 0 RPM, fanMax RPM) don't get clipped. Y is inverted (higher RPM = lower y coordinate = higher on screen).

Inverse functions `tempFromX` and `rpmFromY` convert drag positions back to data values.

### Layer stack (bottom to top)

1. **Grid** (`Canvas`): vertical lines at 25, 50, 75, 100°C; horizontal lines at 2000, 4000, 6000 RPM (only if ≤ fanMax). Y-axis labels at 0, 2k, 4k, 6k, fanMax — deduplicated with a 22pt minimum spacing guard to prevent crowding on Macs with lower fanMax values.

2. **Curve fill** (`Path.fill`): the curve path closed back along the bottom of the chart, filled with accent colour at 12% opacity.

3. **Curve line** (`Path.stroke`): the polyline connecting all sorted curve points, 2pt accent colour.

4. **Red crosshair** (`Canvas`, hit testing disabled): two 0.5pt lines at the current temperature (vertical) and current fan RPM (horizontal). Hit testing is explicitly disabled so this layer doesn't block taps on drag handles behind it.

5. **Orange cap line** (`Canvas`, hit testing disabled): a dashed horizontal line at `maxFanSpeed`, shown only when a cap is set and below `fanMax`. Labelled "cap" at the right edge.

6. **Drag handles** (`ForEach` of `DragPoint` views): one per curve point, positioned at the point's coordinate.

### `DragPoint`

```swift
Circle()
    .fill(isDragging ? Color.white : Color.accentColor)
    .frame(width: isDragging ? 14 : 10, ...)
    .frame(width: 28, height: 28)       // larger invisible hit target
    .contentShape(Circle())
    .position(x: x, y: y)
    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("chart"))...)
```

Two nested `frame` modifiers: the inner one is the visible circle (10×10 normal, 14×14 while dragging), the outer one is the 28×28 invisible hit area. `.contentShape(Circle())` ensures the outer transparent frame registers gestures even though it's clear. `minimumDistance: 0` means a tap without any movement also triggers the gesture.

`coordinateSpace: .named("chart")` matches the `.coordinateSpace(name: "chart")` on the `GeometryReader`, so `drag.location` is always in chart-local coordinates regardless of where on screen the chart lives.

For locked nodes, dragging only updates `rpm` (y-axis), `tempC` is unchanged. For all nodes, RPM snaps to 50 RPM increments: `(rpmFromY(...) / 50).rounded() * 50`.

---

## `helper/smc-fan.c` — Standalone SMC write helper

A minimal setuid-root C program that predates the daemon architecture. It writes directly to SMC fan keys without any unlock sequence.

```
Usage: smc-fan -k <F0Mn|F1Mn|F0Tg|F1Tg> -w <8hexchars>
```

The value is passed as 8 hex characters representing 4 bytes (the IEEE 754 float). For example, to set fan 0 target to 3000 RPM:

```bash
# float 3000.0 = 0x45bb8000
smc-fan -k F0Tg -w 45bb8000
```

The allowed key list is hardcoded to `F0Mn`, `F1Mn`, `F0Tg`, `F1Tg` — it will reject any other key. This limits the damage if the binary is somehow misused.

It's useful for one-off debugging or scripting fan control without the full daemon stack. It does not perform the Ftst/F%dMd unlock sequence, so on Apple Silicon it may not work reliably unless thermalmonitord is already suppressed.

---

## Project structure

```
Sources/FanCurve/
  main.swift               NSApplication init, activation policy, run loop start
  AppDelegate.swift        Menu bar item, popup + editor panel lifecycle, global events
  FanController.swift      4s tick, EMA smoothing, profile evaluation, safety logic
  SMC.swift                IOKit sensor reads, target file IPC writes
  Profile.swift            CurvePoint, FanProfile, ProfileStore, JSON persistence
  MenuContentView.swift    Popup panel UI (BlueToggle, PanelBackground, stats, profiles)
  ProfileEditorView.swift  Curve editor panel (sidebar, chart, points table, footer)
  CurveChart.swift         Interactive drag-handle fan curve chart

daemon/
  fancurve-daemon.c        Root daemon — Apple Silicon unlock sequence, 500ms poll loop
  fancurve-daemon          Compiled daemon binary (installed to /usr/local/bin/)

helper/
  smc-fan.c                Setuid-root standalone SMC write tool (debugging / scripting)
  smc-fan                  Compiled helper binary

Resources/
  AppIcon.icns             Application icon

build.sh                   Always-clean release build, re-sign, copy to ~/Applications, restart
install.sh                 First-time install: compile daemon, install LaunchDaemon, optionally install LaunchAgent
com.local.fancurve-daemon.plist   LaunchDaemon plist (root, persistent, auto-restart)
com.local.fancurve.plist          LaunchAgent plist (login item, optional)
Package.swift              Swift Package Manager manifest
```
