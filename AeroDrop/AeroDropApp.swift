// AeroDropApp.swift — AeroDrop
// Menu bar app entry point (no dock icon).
// TODO: Implementation
import SwiftUI

@main
struct AeroDropApp: App {
    var body: some Scene {
        MenuBarExtra("AeroDrop", systemImage: "antenna.radiowaves.left.and.right") {
            Text("AeroDrop")
        }
    }
}
