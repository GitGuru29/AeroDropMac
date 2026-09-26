import Foundation

struct ThroughputMeter {
    private var lastBytes: UInt64 = 0
    private var lastDate: Date?
    private var smoothed: Double = 0

    mutating func reset() {
        lastBytes = 0
        lastDate = nil
        smoothed = 0
    }

    mutating func sample(bytesTransferred: UInt64, at date: Date = Date()) -> Double {
        defer {
            lastBytes = bytesTransferred
            lastDate = date
        }

        guard let lastDate else {
            self.lastDate = date
            lastBytes = bytesTransferred
            return 0
        }

        let elapsed = date.timeIntervalSince(lastDate)
        guard elapsed > 0.05 else { return smoothed }

        let delta = bytesTransferred > lastBytes ? bytesTransferred - lastBytes : 0
        let instant = Double(delta) / elapsed

        smoothed = smoothed == 0 ? instant : smoothed * 0.7 + instant * 0.3
        return smoothed
    }
}

struct TransferItem: Identifiable, Equatable {
    enum Direction: Equatable {
        case outgoing
        case incoming
    }

    enum Status: Equatable {
        case pending
        case running(progress: Double, bytesPerSecond: Double)
        case completed
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .completed, .failed: return true
            case .pending, .running:    return false
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var progress: Double {
            if case .running(let p, _) = self { return p }
            if case .completed = self { return 1 }
            return 0
        }

        var bytesPerSecond: Double {
            if case .running(_, let b) = self { return b }
            return 0
        }
    }

    let id: UUID
    let filename: String
    let totalBytes: UInt64
    let direction: Direction
    let peerName: String
    let sourceURL: URL?
    var status: Status
    var startedAt: Date?
    var finishedAt: Date?

    init(id: UUID = UUID(),
         filename: String,
         totalBytes: UInt64,
         direction: Direction,
         peerName: String,
         sourceURL: URL? = nil,
         status: Status = .pending) {
        self.id = id
        self.filename = filename
        self.totalBytes = totalBytes
        self.direction = direction
        self.peerName = peerName
        self.sourceURL = sourceURL
        self.status = status
    }

    var isOutgoing: Bool { direction == .outgoing }

    var bytesTransferred: UInt64 {
        UInt64(Double(totalBytes) * status.progress)
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var estimatedTimeRemaining: TimeInterval? {
        guard status.isRunning, status.bytesPerSecond > 1, status.progress > 0 else { return nil }
        let remaining = Double(totalBytes) * (1 - status.progress)
        return remaining / status.bytesPerSecond
    }
}
