// AeroDropApp.swift — AeroDrop  [App Shell]
// Menu bar app with no dock icon and no main window. The visible UI is an
// AeroPanel owned by StatusPanelController, because MenuBarExtra forces a
// fixed content size and AeroDrop needs a resizable panel.

import SwiftUI
import AppKit

@main
struct AeroDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let panelController = StatusPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the dock icon at runtime even if LSUIElement is not honored
        // before the first NSApp event.
        NSApp.setActivationPolicy(.accessory)
        panelController.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the process alive with only the menu bar item visible.
        return false
    }
}
