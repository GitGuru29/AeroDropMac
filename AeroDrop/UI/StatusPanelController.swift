import SwiftUI
import AppKit

final class AeroPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?

    private static let defaultSize = NSSize(width: 640, height: 540)
    private static let minSize     = NSSize(width: 460, height: 340)
    private static let sizeKey    = "AeroDropPanelSize"
    private static let seenKey    = "AeroDropHasLaunchedBefore"

    // ── Setup ───────────────────────────────────────────────────────────────

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "antenna.radiowaves.left.and.right",
            accessibilityDescription: "AeroDrop"
        )
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "AeroDrop"
        statusItem = item

        let panel = AeroPanel(
            contentRect: NSRect(origin: .zero, size: restoredSize()),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "AeroDrop"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.minSize = Self.minSize
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: RootView())
        self.panel = panel

        // A menu bar app has no window of its own, so on first run the panel is
        // opened once to make the app discoverable instead of leaving the user
        // wondering why nothing happened.
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: Self.seenKey)
        if isFirstLaunch {
            UserDefaults.standard.set(true, forKey: Self.seenKey)
            DispatchQueue.main.async { [weak self] in self?.show() }
        }
    }

    // ── Toggling ────────────────────────────────────────────────────────────

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
            return
        }
        isVisible ? hide() : show()
    }

    func show() {
        guard let panel else { return }
        position(panel)
        panel.orderFrontRegardless()
        installOutsideClickMonitor()
    }

    func hide() {
        // Dismissal usually happens via outside click or the status item, which
        // never reaches -windowWillClose, so persist here rather than there.
        persistSize()
        panel?.orderOut(nil)
        outsideClickMonitor.map { NSEvent.removeMonitor($0) }
        outsideClickMonitor = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    // ── Context menu ────────────────────────────────────────────────────────

    private func showContextMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let openItem = NSMenuItem(
            title: isVisible ? "Hide AeroDrop" : "Open AeroDrop",
            action: #selector(toggleFromMenu),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit AeroDrop",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem?.button?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.button?.menu = nil
    }

    @objc private func toggleFromMenu() {
        toggle()
    }

    // ── Geometry ────────────────────────────────────────────────────────────

    private func position(_ panel: NSPanel) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 8,
                                     y: visible.maxY - size.height - 8))
    }

    /// The menu bar item lives in the right half of the menu bar strip. Status
    /// item buttons don't expose usable screen geometry (their window is a
    /// zero-height placeholder), so dismissal uses this region instead.
    private func isClickOnStatusItem() -> Bool {
        guard let visible = NSScreen.main?.visibleFrame else { return false }
        let mouse = NSEvent.mouseLocation
        let strip = CGRect(x: visible.midX, y: visible.maxY - 32,
                            width: visible.width / 2, height: 32)
        return strip.contains(mouse)
    }

    private func restoredSize() -> NSSize {
        let saved = UserDefaults.standard.object(forKey: Self.sizeKey) as? [String: CGFloat]
        let width  = saved?["width"]  ?? Self.defaultSize.width
        let height = saved?["height"] ?? Self.defaultSize.height
        return NSSize(width: max(Self.minSize.width, width),
                      height: max(Self.minSize.height, height))
    }

    private func persistSize() {
        guard let panel else { return }
        UserDefaults.standard.set(
            ["width": panel.frame.width, "height": panel.frame.height],
            forKey: Self.sizeKey
        )
    }

    // ── Outside click dismissal ─────────────────────────────────────────────

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil, panel != nil else { return }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfClickIsOutside() }
        }
    }

    private func dismissIfClickIsOutside() {
        guard let panel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation

        if panel.frame.contains(mouse) { return }

        // A click on our own status item must be left to the toggle action,
        // otherwise the panel would hide and immediately reopen.
        if isClickOnStatusItem() { return }

        hide()
    }

    // ── NSWindowDelegate ────────────────────────────────────────────────────

    func windowWillClose(_ notification: Notification) {
        hide()
    }
}
