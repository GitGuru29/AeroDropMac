// AeroDropApp.swift — AeroDrop  [Phase 3: App Shell]
// Menu bar app entry point — no dock icon, no title bar.
// Uses MenuBarExtra (macOS 13+) with .window style for the popover.
// AppDelegate forces .accessory activation policy as a belt-and-suspenders
// guard in case LSUIElement isn't picked up from Info.plist at launch.

import SwiftUI

@main
struct AeroDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            DropZoneView()
                .frame(width: 560, height: 380)
        } label: {
            Label("AeroDrop", systemImage: "antenna.radiowaves.left.and.right")
                .labelStyle(.iconOnly)
        }
        .menuBarExtraStyle(.window) // Floating panel (not a standard dropdown menu)
    }
}

// ── App Delegate ──────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders: hide dock icon at runtime even if plist isn't
        // read before the first NSApp event.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the process alive with only the menu bar icon visible.
        return false
    }
}
