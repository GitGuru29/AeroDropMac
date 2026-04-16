// AeroDiscoveryBrowser.swift — AeroDrop  [Phase 1: Discovery Layer]
// Browses the local network for _aerodrop._tcp services using Network.framework's
// NWBrowser (macOS 10.15+). Publishes live peers as @Published state so the
// DropZoneViewModel can drive the sidebar without polling.
//
// Why NWBrowser instead of NetServiceBrowser?
//   NetServiceBrowser is deprecated in macOS 12. NWBrowser supersedes it,
//   handles both IPv4/IPv6, and delivers resolved endpoints automatically.

import Network
import Combine

@MainActor
final class AeroDiscoveryBrowser: ObservableObject {

    // ── Public state ──────────────────────────────────────────────────────────
    @Published private(set) var peers: [AeroPeerInfo] = []

    // ── Private ───────────────────────────────────────────────────────────────
    private var browser:    NWBrowser?
    private var resolvers:  [String: NWConnection] = [:]   // name → active resolver
    private var discovered: [String: AeroPeerInfo] = [:]   // name → resolved peer

    private static let serviceType = "_aerodrop._tcp"
    private static let queue       = DispatchQueue(label: "com.aerodrop.discovery",
                                                   qos: .utility)

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    func startBrowsing() {
        guard browser == nil else { return }

        let params       = NWParameters()
        params.includePeerToPeer = false   // LAN only

        let descriptor   = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type:   Self.serviceType,
            domain: "local."
        )

        let b = NWBrowser(for: descriptor, using: params)

        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    print("[AeroDiscovery] Browser ready")
                case .failed(let err):
                    print("[AeroDiscovery] Browser failed: \(err)")
                    self?.restartBrowsing()
                case .cancelled:
                    print("[AeroDiscovery] Browser cancelled")
                default:
                    break
                }
            }
        }

        b.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                self?.handleBrowseChanges(changes)
            }
        }

        b.start(queue: Self.queue)
        browser = b
        print("[AeroDiscovery] Browsing for \(Self.serviceType)")
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil

        // Cancel and remove all in-flight resolvers
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()

        // Clear state
        discovered.removeAll()
        peers = []
        print("[AeroDiscovery] Stopped")
    }

    // ── Browse result handling ─────────────────────────────────────────────────

    private func handleBrowseChanges(_ changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                resolveResult(result)
            case .removed(let result):
                if case .service(let name, _, _, _) = result.endpoint {
                    removePeer(named: name)
                }
            case .changed(old: _, new: let result, flags: _):
                // Service metadata changed — re-resolve
                resolveResult(result)
            @unknown default:
                break
            }
        }
    }

    // ── Resolve: endpoint → host + port ───────────────────────────────────────

    private func resolveResult(_ result: NWBrowser.Result) {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return }

        // Avoid double-resolving the same service instance
        if resolvers[name] != nil { return }

        print("[AeroDiscovery] Resolving: \(name).\(type)\(domain)")

        let endpoint  = NWEndpoint.service(name: name, type: type,
                                           domain: domain, interface: nil)
        let params    = NWParameters.tcp
        let conn      = NWConnection(to: endpoint, using: params)

        resolvers[name] = conn

        conn.stateUpdateHandler = { [weak self, name] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .preparing:
                    // Network.framework resolves the endpoint during .preparing
                    // — the resolved host/port appear on the path.
                    if let path = self.resolvers[name]?.currentPath,
                       let remote = path.remoteEndpoint {
                        self.extractAndStore(name: name, endpoint: remote)
                    }
                case .ready:
                    // Fully connected — extract resolved address, then tear down
                    if let path = conn.currentPath,
                       let remote = path.remoteEndpoint {
                        self.extractAndStore(name: name, endpoint: remote)
                    }
                    conn.cancel()           // We only needed the resolve
                    self.resolvers[name] = nil
                case .failed(let err):
                    print("[AeroDiscovery] Resolve failed for \(name): \(err)")
                    self.resolvers[name] = nil
                case .cancelled:
                    self.resolvers[name] = nil
                default:
                    break
                }
            }
        }

        conn.start(queue: Self.queue)
    }

    private func extractAndStore(name: String, endpoint: NWEndpoint) {
        switch endpoint {
        case .hostPort(let host, let port):
            let hostStr = hostString(from: host)
            let portInt = Int(port.rawValue)
            guard !hostStr.isEmpty, portInt > 0, portInt != 65535 else { return }

            let peer = AeroPeerInfo(id: UUID(), name: name,
                                    host: hostStr, port: portInt)
            if discovered[name] == peer { return }   // No-op if unchanged
            discovered[name] = peer
            peers = discovered.values.sorted { $0.name < $1.name }
            print("[AeroDiscovery] Peer ready: \(name) @ \(hostStr):\(portInt)")
        default:
            break
        }
    }

    private func removePeer(named name: String) {
        resolvers[name]?.cancel()
        resolvers[name] = nil
        discovered.removeValue(forKey: name)
        peers = discovered.values.sorted { $0.name < $1.name }
        print("[AeroDiscovery] Peer lost: \(name)")
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func hostString(from host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let addr):
            return addr.debugDescription
        case .ipv6(let addr):
            // IMPORTANT: keep the full address INCLUDING the %scope-id (e.g. "fe80::1%en0").
            // Stripping it produces an un-routable link-local address — connect() fails with
            // ENETUNREACH because the kernel can't determine which interface to use.
            // AeroServer::sendFile() passes this directly to getaddrinfo() which correctly
            // parses the scope-id and sets sockaddr_in6.sin6_scope_id via if_nametoindex().
            return addr.debugDescription  // e.g. "fe80::aede:48ff:fe00:1122%en0"
        case .name(let n, _):
            return n
        @unknown default:
            return ""
        }
    }

    private func restartBrowsing() {
        browser?.cancel()
        browser = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.startBrowsing()
        }
    }
}
