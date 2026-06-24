import AppKit

// Initialize NSApplication before touching NSApp — otherwise NSApp is nil
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// main.swift always executes on the main thread
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
