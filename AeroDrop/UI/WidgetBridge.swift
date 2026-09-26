import Foundation
import WidgetKit

/// Bridges the running app and the WidgetKit extension through the shared App
/// Group container.
///
/// Widgets cannot poll, and WidgetKit throttles `reloadAllTimelines`, so the
/// widget only ever renders a snapshot written here by the app. Every write is
/// therefore cheap-but-throttled, and terminal events force a reload.
@MainActor
final class WidgetBridge {

    static let shared = WidgetBridge()

    /// The system throttles reload requests anyway, so a long interval costs
    /// nothing but avoids hammering WidgetCenter during a transfer.
    private static let reloadInterval: TimeInterval = 30
    private static let publishInterval: TimeInterval = 1

    private var lastPublish = Date.distantPast
    private var lastReload = Date.distantPast
    private var lastDrainedDrop: TimeInterval = 0

    private let defaults = UserDefaults.standard
    private static let defaultPeerKey = "AeroDropDefaultPeerID"
    private static let recentsKey = "AeroDropRecentFiles"

    // MARK: - Remembered default device

    /// Bonjour gives no proximity signal, so "nearest" can only mean "the device
    /// you used last". Persisting the selection makes AeroDrop behave like
    /// AirDrop: reopen the app and it already knows where to send.
    var rememberedPeerID: String {
        get { defaults.string(forKey: Self.defaultPeerKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.defaultPeerKey) }
    }

    // MARK: - Recently sent files

    private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []

    func noteSent(_ filename: String) {
        var next = [filename] + recents.filter { $0 != filename }
        next = Array(next.prefix(8))
        recents = next
        defaults.set(next, forKey: Self.recentsKey)
    }

    // MARK: - Publishing

    func publish(peerName: String?, transfer: AeroWidgetTransfer, force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastPublish) < Self.publishInterval { return }
        lastPublish = now

        var state = AeroWidgetStore.load()
        state.peer = AeroWidgetPeer(id: peerName ?? "", name: peerName ?? "")
        state.recents = recents
        state.lastTransfer = transfer
        AeroWidgetStore.save(state)

        if force { reloadNow() }
    }

    func reloadNow() {
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Receiving drops from the widget

    /// Returns the files dropped onto the widget the first time it is seen.
    /// The payload is cleared immediately so a redraw can't resend them.
    func takePendingDrop() -> [URL] {
        var state = AeroWidgetStore.load()
        guard let drop = state.pendingDrop,
              !drop.urls.isEmpty,
              drop.timestamp != lastDrainedDrop else { return [] }
        lastDrainedDrop = drop.timestamp
        state.pendingDrop = nil
        AeroWidgetStore.save(state)
        return drop.urls.compactMap { URL(string: $0) }
    }
}
