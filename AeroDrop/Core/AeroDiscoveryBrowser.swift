// AeroDiscoveryBrowser.swift — AeroDrop  [Phase 1: Discovery Layer]
// Browses the local network for _aerodrop._tcp services using Network.framework's
// NWBrowser (macOS 10.15+). Publishes live peers as @Published state so the
// DropZoneViewModel can drive the sidebar without polling.
//
// Key design decisions:
// ① Self-filter: NWBrowser discovers ALL _aerodrop._tcp services, including the
//   one this Mac registers. We compare each service name against the Mac's own
//   Bonjour name (Host.current().localizedName) and skip it. Without this, the
//   user's peer list contains "siluna's MacBook Air" alongside Android devices,
//   it gets auto-selected, and every send fails with "TLS handshake failed"
//   because the Mac is connecting to its own AeroServer.
//
// ② Cancel at .preparing (not .ready): we only need the mDNS-resolved IP.
//   At .preparing the DNS query has completed and currentPath.remoteEndpoint
//   already contains the resolved address — the TCP three-way handshake hasn't
//   finished yet. Cancelling here avoids delivering a plain-TCP connection to
//   the peer's TLS server, which would trigger spurious SSLHandshakeExceptions
//   on Android and "unexpected EOF" SSL errors in the Mac's own AeroServer logs.

import Network
import Combine
import Foundation    // Host

@MainActor
final class AeroDiscoveryBrowser: ObservableObject {

    // ── Public state ──────────────────────────────────────────────────────────
    @Published private(set) var peers: [AeroPeerInfo] = []

    // ── Private ───────────────────────────────────────────────────────────────
    private var browser:   NWBrowser?
    private var resolvers: [String: NWConnection] = [:]   // name → active resolver
    private var discovered:[String: AeroPeerInfo] = [:]   // name → resolved peer

    private static let serviceType = "_aerodrop._tcp"
    private static let queue       = DispatchQueue(label: "com.aerodrop.discovery",
                                                   qos: .utility)

    // ① The service instance name this Mac advertises on _aerodrop._tcp.
    //   BonjourService uses `Host.current().localizedName` (e.g. "siluna's MacBook Air").
    //   NWBrowser sees that exact string as the result name. We store it once at
    //   init time and skip any result whose name matches.
    private let localServiceName: String = {
        Host.current().localizedName ?? ""
    }()

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

        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()

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
                resolveResult(result)
            @unknown default:
                break
            }
        }
    }

    // ── Resolve: service endpoint → host + port ────────────────────────────────

    private func resolveResult(_ result: NWBrowser.Result) {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return }

        // ① Self-filter ─────────────────────────────────────────────────────────
        // Skip our own Mac service so it never appears in the peer list.
        if !localServiceName.isEmpty && name == localServiceName {
            print("[AeroDiscovery] Skipping self: \(name)")
            return
        }

        // Avoid double-resolving the same service instance
        if resolvers[name] != nil { return }

        print("[AeroDiscovery] Resolving: \(name).\(type)\(domain)")

        // Use plain NWParameters.tcp so Network.framework performs mDNS resolution.
        // We allow both IPv4 and IPv6 (including link-local fe80::). Android's
        // ServerSocket automatically binds to `::` (any address), so it accepts
        // connections over both v4 and v6 seamlessly.
        let connParams = NWParameters.tcp

        let endpoint = NWEndpoint.service(name: name, type: type,
                                          domain: domain, interface: nil)
        let conn = NWConnection(to: endpoint, using: connParams)

        resolvers[name] = conn

        conn.stateUpdateHandler = { [weak self, weak conn, name] state in
            Task { @MainActor [weak self, weak conn] in
                guard let self else { return }
                switch state {

                case .preparing:
                    // ② Cancel at .preparing ─────────────────────────────────────
                    // At this stage mDNS has resolved the hostname → IP address and
                    // currentPath.remoteEndpoint holds the resolved address, BUT the
                    // TCP three-way handshake has NOT yet completed. Cancelling now:
                    //  • Prevents a live TCP socket from reaching Android's
                    //    SSLServerSocket.accept() and triggering startHandshake().
                    //  • Prevents the Mac's own AeroServer from seeing a plain-TCP
                    //    connection that causes "unexpected EOF" in SSL_accept().
                    if let path = conn?.currentPath, let remote = path.remoteEndpoint {
                        self.extractAndStore(name: name, endpoint: remote)
                        conn?.cancel()
                        self.resolvers[name] = nil
                    }
                    // If the endpoint isn't available yet, fall through to .ready.

                case .ready:
                    // Fallback: connection fully established — extract then tear down.
                    if let path = conn?.currentPath, let remote = path.remoteEndpoint {
                        self.extractAndStore(name: name, endpoint: remote)
                    }
                    conn?.cancel()
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

    // ── Store resolved peer ────────────────────────────────────────────────────

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
            // Keep the full address INCLUDING the %scope-id (e.g. "fe80::1%en0").
            // Stripping it produces an un-routable link-local address — connect()
            // fails with ENETUNREACH because the kernel can't determine which
            // interface to use. AeroServer::sendFile() passes this to getaddrinfo()
            // which correctly parses the scope-id and sets sin6_scope_id.
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
