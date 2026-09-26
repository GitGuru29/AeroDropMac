import Foundation

public struct AeroWidgetPeer: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public init(id: String = "", name: String = "") {
        self.id = id
        self.name = name
    }
}

public struct AeroWidgetTransfer: Codable, Equatable {
    public enum Status: String, Codable {
        case idle, sending, receiving, completed, failed
    }
    public var status: Status
    public var fileName: String
    public var progress: Double // 0...1
    public var bytesTotal: Int64
    public var bytesTransferred: Int64
    public var throughputMBps: Double
    public var etaSeconds: Double
    public var errorMessage: String?
    public init(status: Status = .idle,
                fileName: String = "",
                progress: Double = 0,
                bytesTotal: Int64 = 0,
                bytesTransferred: Int64 = 0,
                throughputMBps: Double = 0,
                etaSeconds: Double = 0,
                errorMessage: String? = nil) {
        self.status = status
        self.fileName = fileName
        self.progress = progress
        self.bytesTotal = bytesTotal
        self.bytesTransferred = bytesTransferred
        self.throughputMBps = throughputMBps
        self.etaSeconds = etaSeconds
        self.errorMessage = errorMessage
    }
}

public struct AeroWidgetPendingDrop: Codable, Equatable {
    public var urls: [String] // file URLs as strings
    public var timestamp: TimeInterval
    public init(urls: [String] = [], timestamp: TimeInterval = 0) {
        self.urls = urls
        self.timestamp = timestamp
    }
}

public struct AeroWidgetState: Codable, Equatable {
    public var peer: AeroWidgetPeer
    public var recents: [String]
    public var lastTransfer: AeroWidgetTransfer
    public var pendingDrop: AeroWidgetPendingDrop?
    public init(peer: AeroWidgetPeer = .init(),
                recents: [String] = [],
                lastTransfer: AeroWidgetTransfer = .init(),
                pendingDrop: AeroWidgetPendingDrop? = nil) {
        self.peer = peer
        self.recents = recents
        self.lastTransfer = lastTransfer
        self.pendingDrop = pendingDrop
    }
}

public enum AeroWidgetStore {
    public static let appGroupID = "group.com.siluna.AeroDrop"

    /// Prefers the App Group container, which is the mechanism to use once a
    /// development team is configured. Until then both processes fall back to a
    /// shared path in Application Support: the app is not sandboxed, so it and
    /// the widget extension can both read and write there without any
    /// entitlement or provisioning profile.
    private static let appGroupURL: URL? = {
        guard let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        // An unprovisioned group still hands back a path, but the container
        // directory is never created, so every write would fail with ENOENT.
        // Only trust it once it really exists on disk.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: c.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return c.appendingPathComponent("aerodrop_widget_state.json")
    }()

    private static let fallbackURL: URL? = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AeroDrop", isDirectory: true)
        guard let base else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("aerodrop_widget_state.json")
    }()

    public static let stateURL: URL? = appGroupURL ?? fallbackURL
    public static func load() -> AeroWidgetState {
        guard let url = stateURL,
              let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AeroWidgetState.self, from: data) else {
            return AeroWidgetState()
        }
        return s
    }
    public static func save(_ state: AeroWidgetState) {
        guard let url = stateURL else { return }
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
