import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuPanel: NSPanel!
    private var menuHC: NSHostingController<MenuContentView>!
    private var editorPanel: NSPanel?
    private var editorHC: FixedSizeHostingController<ProfileEditorView>?
    private var controller: FanController!
    private var eventMonitor: Any?
    private var sizeObservation: NSKeyValueObservation?
    private var statusCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.fancurve")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil); return }

        setupMainMenu()
        controller = FanController()
        buildPanel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            let img = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeft
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            updateStatusBar()
        }

        // Update status bar label whenever FanController publishes a new temperature.
        statusCancellable = controller.$cpuTemp.sink { [weak self] _ in self?.updateStatusBar() }

        // Global click monitor — don't close if a sheet (profile editor) is active.
        // Note: clicks within our own app windows don't fire this monitor, so the
        // profile editor window doesn't accidentally close the panel.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.editorPanel?.orderOut(nil)
            self?.closePanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SMC.resetTargetRPM()
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
    }

    func applicationDidResignActive(_ notification: Notification) {
        editorPanel?.orderOut(nil)
        closePanel()
    }

    // MARK: - Main menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit FanCurve", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Panel

    private func buildPanel() {
        let hc = NSHostingController(rootView: MenuContentView(
            controller: controller,
            onEditCurves: { [weak self] in self?.showEditorPanel() }
        ))
        menuHC = hc

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hc
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        menuPanel = panel

        // Make the hosting view transparent so the SwiftUI rounded-rect background
        // controls all drawing and the window corners are truly clear.
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = NSColor.clear.cgColor

        // Resize panel whenever SwiftUI changes its preferred content height
        // (e.g. auto-mode toggle shows/hides the profile picker).
        sizeObservation = hc.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.fitPanelToContent() }
        }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if editorPanel?.isVisible == true {
            editorPanel?.orderOut(nil)
        } else if menuPanel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let bw = button.window else { return }
        fitPanelToContent()
        let br = bw.convertToScreen(button.frame)
        // Keep the panel within the visible screen area
        let screenW = bw.screen?.visibleFrame.width ?? 1440
        let x = min(br.minX, screenW - 290 - 8)
        let menuBarBottom = bw.screen?.visibleFrame.maxY ?? bw.frame.minY
        menuPanel.setFrameTopLeftPoint(NSPoint(x: max(x, 8), y: menuBarBottom))
        menuPanel.orderFront(nil)
    }

    private func closePanel() { menuPanel.orderOut(nil) }

    private func fitPanelToContent() {
        let h = max(menuHC.preferredContentSize.height, 100)
        guard h > 10 else { return }
        if menuPanel.isVisible, let button = statusItem.button, let bw = button.window {
            let menuBarBottom = bw.screen?.visibleFrame.maxY ?? bw.frame.minY
            menuPanel.setFrame(
                NSRect(x: menuPanel.frame.minX, y: menuBarBottom - h, width: 290, height: h),
                display: true, animate: false
            )
        } else {
            menuPanel.setContentSize(NSSize(width: 290, height: h))
        }
    }

    // MARK: - Editor panel

    func showEditorPanel() {
        if editorPanel?.isVisible == true { editorPanel?.orderFront(nil); return }

        closePanel()

        let w: CGFloat = 640
        let h: CGFloat = 490

        let hc = FixedSizeHostingController(
            rootView: ProfileEditorView(
                store: controller.store,
                controller: controller,
                onDismiss: { [weak self] in
                    self?.editorPanel?.orderOut(nil)
                    self?.showPanel()
                }
            ),
            fixedSize: NSSize(width: w, height: h)
        )
        editorHC = hc

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hc
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = NSColor.clear.cgColor

        // Position before activation
        let vf = (statusItem?.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? NSScreen.main!.visibleFrame
        let x = max(vf.minX + 8, min(menuPanel.frame.maxX + 8, vf.maxX - w - 8))
        panel.setFrame(NSRect(x: x, y: vf.maxY - h, width: w, height: h), display: false)

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFront(nil)
        panel.makeKey()
        editorPanel = panel
    }

    // MARK: - Status bar

    private func updateStatusBar() {
        guard let button = statusItem?.button else { return }
        button.title = " \(Int(controller.activeTemp))°"
    }
}

// Borderless panels return false from canBecomeKey by default, so makeKey()
// fails and SwiftUI never gets the key window it needs for drag gestures and
// text-field focus. Force it true.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Hosting controller that refuses to report an inflated preferredContentSize.
// glassEffect inflates the fitting size, causing contentViewController-based
// windows to auto-resize and float off the top of the screen.
private final class FixedSizeHostingController<C: View>: NSHostingController<C> {
    private let fixedSize: NSSize
    init(rootView: C, fixedSize: NSSize) {
        self.fixedSize = fixedSize
        super.init(rootView: rootView)
    }
    @objc required dynamic init?(coder: NSCoder) { fatalError() }
    override var preferredContentSize: NSSize {
        get { fixedSize }
        set { }
    }
}
