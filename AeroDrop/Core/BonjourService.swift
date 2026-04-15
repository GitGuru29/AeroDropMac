// BonjourService.swift — AeroDrop  [Phase 1: Discovery Layer]
// Swift @MainActor wrapper around the C Bonjour registration API.
// Observes bonjour_is_registered() via a poll timer and publishes
// the result as @Published state for SwiftUI reactivity.

import Foundation
import Combine

@MainActor
final class BonjourService: ObservableObject {

    static let shared = BonjourService()

    @Published private(set) var isAdvertising: Bool  = false
    @Published private(set) var registrationError: String? = nil

    private let port: UInt16 = 7770
    private var pollTimer: Timer?

    private init() {}

    // ── Public API ──────────────────────────────────────────────────────────

    func startAdvertising() {
        guard !isAdvertising else { return }

        let deviceName = Host.current().localizedName ?? "AeroDrop Mac"
        let result = bonjour_register(deviceName, port)

        if result != 0 {
            registrationError = "Bonjour registration failed (error \(result))"
            return
        }
        registrationError = nil

        // Poll the C-level flag on a 0.5 s interval.
        // We use a Timer rather than a Swift actor task so the
        // callback runs naturally on the main run loop.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isAdvertising = bonjour_is_registered() == 1
            }
        }
    }

    func stopAdvertising() {
        pollTimer?.invalidate()
        pollTimer = nil
        bonjour_unregister()
        isAdvertising = false
    }

    deinit {
        bonjour_unregister()
    }
}
