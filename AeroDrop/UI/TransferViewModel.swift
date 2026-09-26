import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class TransferViewModel: ObservableObject {

    enum ServerState: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var peers: [AeroPeerInfo] = []
    @Published private(set) var queue: [TransferItem] = []
    @Published var selectedPeer: AeroPeerInfo? {
        // Re-selecting a device must resume a queue that stalled while no
        // peer was selected, otherwise pending items never start.
        didSet {
            guard oldValue != selectedPeer else { return }
            // Remember the device so a relaunch reuses it without a click.
            if let id = selectedPeer?.id, !id.isEmpty {
                WidgetBridge.shared.rememberedPeerID = id
            }
            publishWidgetState(force: true)
            advanceQueue()
        }
    }
    @Published var isDropTargeted = false
    @Published private(set) var certFingerprint = ""
    @Published private(set) var serverState: ServerState = .idle
    @Published private(set) var advertisementError: String?
    @Published private(set) var notice: String?

    private let server: BridgeServer = .shared()
    private let bonjour: BonjourService = .shared
    private let browser = AeroDiscoveryBrowser()

    private var peerSub: AnyCancellable?
    private var bonjourSub: AnyCancellable?
    private var noticeWorkItem: DispatchWorkItem?

    private var outgoingMeter = ThroughputMeter()
    private var incomingMeter = ThroughputMeter()
    private var activeOutgoingID: UUID?
    private var incomingID: UUID?
    private var hasStarted = false
    private var widgetPoll: Timer?

    // ── Derived state ──────────────────────────────────────────────────────

    var pendingCount: Int { queue.filter { $0.status == .pending }.count }
    var isTransferring: Bool { queue.contains { $0.status.isRunning } }
    var hasFinishedItems: Bool { queue.contains { $0.status.isTerminal } }

    var activeItem: TransferItem? {
        queue.first { $0.status.isRunning }
    }

    var overallProgress: Double {
        let relevant = queue.filter { $0.direction == .incoming || $0.status == .completed }
            + queue.filter { $0.direction == .outgoing && !$0.status.isTerminal }
        guard !relevant.isEmpty else { return 0 }
        let total = relevant.reduce(0.0) { $0 + Double($1.totalBytes) }
        guard total > 0 else { return 0 }
        let done = relevant.reduce(0.0) { $0 + Double($1.bytesTransferred) }
        return min(1, done / total)
    }

    /// New files may be enqueued at any time; advanceQueue serializes them.
    var canEnqueue: Bool { selectedPeer != nil }

    // ── Lifecycle ───────────────────────────────────────────────────────────

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        certFingerprint = server.certFingerprint()
        installTransferCallbacks()
        subscribeToDiscovery()
        browser.startBrowsing()
        bonjour.startAdvertising()
        startServer()
        startWidgetPolling()
        publishWidgetState(force: true)
    }

    /// The widget extension has no way to signal the app directly, so the
    /// shared container is polled for files dropped onto a widget.
    private func startWidgetPolling() {
        widgetPoll?.invalidate()
        widgetPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainWidgetDrop() }
        }
    }

    private func drainWidgetDrop() {
        let urls = WidgetBridge.shared.takePendingDrop()
        guard !urls.isEmpty else { return }
        guard selectedPeer != nil else {
            presentNotice("Select a device in AeroDrop first")
            return
        }
        enqueue(urls: urls)
    }

    func shutdown() {
        browser.stopBrowsing()
        peerSub?.cancel()
        bonjourSub?.cancel()
        widgetPoll?.invalidate()
        widgetPoll = nil
        server.stop()
        bonjour.stopAdvertising()
        hasStarted = false
    }

    private func startServer() {
        serverState = .starting
        // RSA-4096 key generation on first launch takes up to 30 s and must NOT
        // block the main thread, so the listener is brought up off-actor.
        let server = self.server
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = server.start()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.serverState = ok ? .running : .failed("Could not open port 7770")
            }
        }
    }

    private func installTransferCallbacks() {
        server.incomingProgressHandler = { [weak self] p in
            self?.handleIncomingProgress(p)
        }
        server.incomingCompletionHandler = { [weak self] success, error in
            self?.handleIncomingCompletion(success: success, error: error)
        }
    }

    private func subscribeToDiscovery() {
        peerSub = browser.$peers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newPeers in
                guard let self else { return }
                self.peers = newPeers
                // AirDrop-like default: reuse the device from last time when it's
                // back on the network, otherwise fall back to the first found.
                // Bonjour exposes no distance, so "nearest" is only ever a
                // heuristic — see WidgetBridge.rememberedPeerID.
                let current = self.selectedPeer
                if current == nil || !newPeers.contains(current!) {
                    let remembered = WidgetBridge.shared.rememberedPeerID
                    self.selectedPeer = newPeers.first { $0.id == remembered } ?? newPeers.first
                }
                self.publishWidgetState()
            }

        bonjourSub = bonjour.$registrationError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.advertisementError = error
            }
    }

    // ── Inbound ─────────────────────────────────────────────────────────────

    private func handleIncomingProgress(_ p: AeroTransferProgress) {
        guard p.totalBytes > 0 else { return }
        let throughput = incomingMeter.sample(bytesTransferred: p.bytesTransferred)
        let progress = min(1, Double(p.bytesTransferred) / Double(p.totalBytes))

        if let incomingID, let index = queue.firstIndex(where: { $0.id == incomingID }) {
            queue[index].status = .running(progress: progress, bytesPerSecond: throughput)
        } else {
            incomingMeter.reset()
            // The inbound path doesn't report which device connected, so this
            // must not borrow the selected peer's name.
            let item = TransferItem(
                filename: p.filename,
                totalBytes: p.totalBytes,
                direction: .incoming,
                peerName: "Nearby device",
                status: .running(progress: progress, bytesPerSecond: throughput)
            )
            incomingID = item.id
            // Append, not insert at 0: arrival order is now identical for both
            // directions, so the newest row is always in the same place.
            withAnimation(TransferStyle.structural) {
                queue.append(item)
            }
        }
        publishWidgetState()
    }

    private func handleIncomingCompletion(success: Bool, error: String?) {
        guard let id = incomingID, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].status = success ? .completed : .failed(error ?? "Transfer failed")
        queue[index].finishedAt = Date()
        if success { WidgetBridge.shared.noteSent(queue[index].filename) }
        incomingID = nil
        incomingMeter.reset()
        publishWidgetState(force: true)
    }

    // ── Outbound queue ──────────────────────────────────────────────────────

    func enqueue(urls: [URL]) {
        guard let peer = selectedPeer else {
            presentNotice("Select a device first")
            return
        }

        var items: [TransferItem] = []
        var skipped = 0

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size >= 0 else {
                skipped += 1
                continue
            }
            items.append(TransferItem(
                filename: url.lastPathComponent,
                totalBytes: UInt64(size),
                direction: .outgoing,
                peerName: peer.name,
                sourceURL: url
            ))
        }

        guard !items.isEmpty else {
            presentNotice("Only files can be sent")
            return
        }
        if skipped > 0 {
            presentNotice("Skipped \(skipped) item\(skipped == 1 ? "" : "s") — folders aren’t supported")
        }

        withAnimation(TransferStyle.structural) {
            queue.append(contentsOf: items)
        }
        advanceQueue()
        publishWidgetState(force: true)
    }

    private func advanceQueue() {
        guard activeOutgoingID == nil else { return }
        guard let index = queue.firstIndex(where: { $0.status == .pending && $0.isOutgoing }) else { return }
        guard let peer = selectedPeer else { return }

        let item = queue[index]
        activeOutgoingID = item.id
        outgoingMeter.reset()
        queue[index].startedAt = Date()
        queue[index].status = .running(progress: 0, bytesPerSecond: 0)

        guard let path = item.sourceURL?.path else {
            queue[index].status = .failed("File is no longer available")
            queue[index].finishedAt = Date()
            activeOutgoingID = nil
            advanceQueue()
            return
        }

        let server = self.server
        let host = peer.host
        let port = Int32(peer.port)
        let id = item.id

        server.sendFile(
            atPath: path,
            toHost: host,
            port: port,
            progress: { [weak self] p in
                self?.updateOutgoing(id: id, progress: p)
            },
            completion: { [weak self] success, error in
                // BridgeServer guarantees main-queue delivery, so update the
                // queue synchronously to keep completion → next-item ordering.
                MainActor.assumeIsolated {
                    self?.finishOutgoing(id: id, success: success, error: error)
                }
            }
        )
    }

    private func updateOutgoing(id: UUID, progress p: AeroTransferProgress) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let throughput = outgoingMeter.sample(bytesTransferred: p.bytesTransferred)
        let fraction = p.totalBytes > 0
            ? min(1, Double(p.bytesTransferred) / Double(p.totalBytes))
            : min(1, max(0, p.fraction))
        queue[index].status = .running(progress: fraction, bytesPerSecond: throughput)
        publishWidgetState()
    }

    private func finishOutgoing(id: UUID, success: Bool, error: String?) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].status = success ? .completed : .failed(error ?? "Transfer failed")
        queue[index].finishedAt = Date()
        if success { WidgetBridge.shared.noteSent(queue[index].filename) }
        if activeOutgoingID == id { activeOutgoingID = nil }
        outgoingMeter.reset()
        advanceQueue()
        publishWidgetState(force: true)
    }

    // ── Queue editing ───────────────────────────────────────────────────────

    func remove(_ item: TransferItem) {
        guard item.status == .pending else { return }
        withAnimation(TransferStyle.structural) {
            queue.removeAll { $0.id == item.id }
        }
        publishWidgetState()
    }

    func clearFinished() {
        withAnimation(TransferStyle.structural) {
            queue.removeAll { $0.status.isTerminal }
        }
        publishWidgetState()
    }

    // ── File picker ─────────────────────────────────────────────────────────

    func handleDrop(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = try? await provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else {
            presentNotice("Couldn’t read the dropped item")
            return
        }
        enqueue(urls: urls)
    }

    func openFilePicker() {
        guard selectedPeer != nil else { return }

        // A menu-bar app runs as .accessory and can't put an NSOpenPanel on
        // screen without briefly becoming a regular app. Restore immediately
        // after the panel closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(.accessory) }

        let panel = NSOpenPanel()
        panel.title = "Send to \(selectedPeer?.name ?? "device")"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Send"

        if panel.runModal() == .OK {
            enqueue(urls: panel.urls)
        }
    }

    // ── Widget snapshot ──────────────────────────────────────────────────────

    /// Reduces the full queue to the single most interesting transfer for the
    /// widget: the running one, else the most recently finished.
    private func publishWidgetState(force: Bool = false) {
        let snapshot: AeroWidgetTransfer

        if let active = activeItem {
            let rateMBps = active.status.bytesPerSecond / 1_048_576
            snapshot = AeroWidgetTransfer(
                status: active.direction == .incoming ? .receiving : .sending,
                fileName: active.filename,
                progress: active.status.progress,
                bytesTotal: Int64(active.totalBytes),
                bytesTransferred: Int64(active.bytesTransferred),
                throughputMBps: rateMBps,
                etaSeconds: active.estimatedTimeRemaining ?? 0
            )
        } else if let last = queue.last(where: { $0.status.isTerminal }) {
            var status: AeroWidgetTransfer.Status = .completed
            var message: String?
            switch last.status {
            case .failed(let reason): status = .failed; message = reason
            case .completed: status = .completed
            default: status = .idle
            }
            snapshot = AeroWidgetTransfer(
                status: status,
                fileName: last.filename,
                progress: status == .completed ? 1 : 0,
                bytesTotal: Int64(last.totalBytes),
                bytesTransferred: Int64(last.bytesTransferred),
                throughputMBps: 0,
                etaSeconds: 0,
                errorMessage: message
            )
        } else {
            snapshot = AeroWidgetTransfer()
        }

        WidgetBridge.shared.publish(peerName: selectedPeer?.name, transfer: snapshot, force: force)

        // Keep the menu bar in step with whichever direction is live, so the
        // panel can be dismissed without losing all visibility.
        let activityDirection: TransferItem.Direction = activeItem?.direction ?? .outgoing
        let activityProgress = snapshot.status == .completed ? 1 : snapshot.progress
        let isLive = activeItem != nil
        if isLive || activityProgress > 0 {
            TransferActivity.shared.update(
                isTransferring: isLive,
                progress: isLive ? activityProgress : 0,
                direction: activityDirection
            )
        }
    }

    // ── Notice ──────────────────────────────────────────────────────────────

    private func presentNotice(_ text: String) {
        noticeWorkItem?.cancel()
        notice = text
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func dismissNotice() {
        noticeWorkItem?.cancel()
        notice = nil
    }
}
