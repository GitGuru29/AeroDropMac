// AeroDiscoveryBrowser.swift — AeroDrop  [Phase 1: Discovery Layer]
// Browses the local network for _aerodrop._tcp services using NetServiceBrowser.
// Publishes live peers as @Published state so the view model can drive the sidebar.
//
// Key design decisions:
// ① Self-filter: NetServiceBrowser discovers ALL _aerodrop._tcp services. We compare 
//   each service name against the Mac's own Bonjour name and skip it.
// ② Pure resolution: We use NetService to resolve the IP address instead of NWConnection 
//   to avoid triggering premature TCP handshakes that crash Android's SSLServerSocket
//   and cause indefinite stalls on the Mac side.
// ③ Stable identity: AeroPeerInfo.id is the mDNS instance name, so a re-resolve that
//   returns the same address is a no-op and an address change updates the existing row
//   in place rather than churning SwiftUI identity and dropping the user's selection.

import Foundation
import Combine

extension NetService: @unchecked Sendable {}

@MainActor
final class AeroDiscoveryBrowser: NSObject, ObservableObject {

    // ── Public state ──────────────────────────────────────────────────────────
    @Published private(set) var peers: [AeroPeerInfo] = []

    // ── Private ───────────────────────────────────────────────────────────────
    private var browser: NetServiceBrowser?
    private var activeServices: [String: NetService] = [:]
    private var discovered: [String: AeroPeerInfo] = [:]

    private static let serviceType = "_aerodrop._tcp."
    private static let domain      = "local."

    // ① The service instance name this Mac advertises on _aerodrop._tcp.
    private let localServiceName: String = {
        Host.current().localizedName ?? ""
    }()

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    override init() {
        super.init()
    }

    func startBrowsing() {
        guard browser == nil else { return }

        browser = NetServiceBrowser()
        browser?.delegate = self
        browser?.searchForServices(ofType: Self.serviceType, inDomain: Self.domain)
        print("[AeroDiscovery] Browsing for \(Self.serviceType) using NetServiceBrowser")
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil

        activeServices.values.forEach { $0.stop() }
        activeServices.removeAll()

        discovered.removeAll()
        peers = []
        print("[AeroDiscovery] Stopped")
    }

    // ── Extract and store peer ────────────────────────────────────────────────

    private func extractAndStore(service: NetService) {
        guard let addresses = service.addresses, !addresses.isEmpty else { return }
        
        // Prefer IPv4
        var resolvedIP: String?
        for addrData in addresses {
            let ip = addrData.withUnsafeBytes { ptr -> String? in
                let sockaddrPtr = ptr.bindMemory(to: sockaddr.self).baseAddress!
                // Skip IPv6 for Android compatibility, as Android binds to 0.0.0.0
                if sockaddrPtr.pointee.sa_family == sa_family_t(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sockaddrPtr, socklen_t(addrData.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        return String(cString: hostname)
                    }
                }
                return nil
            }
            if let ip = ip {
                resolvedIP = ip
                break
            }
        }
        
        // If no IPv4 found, fall back to IPv6 (we might need the %scope_id)
        if resolvedIP == nil {
            for addrData in addresses {
                let ip = addrData.withUnsafeBytes { ptr -> String? in
                    let sockaddrPtr = ptr.bindMemory(to: sockaddr.self).baseAddress!
                    if sockaddrPtr.pointee.sa_family == sa_family_t(AF_INET6) {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        // Include scope id with NI_NUMERICHOST
                        if getnameinfo(sockaddrPtr, socklen_t(addrData.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                            return String(cString: hostname)
                        }
                    }
                    return nil
                }
                if let ip = ip {
                    resolvedIP = ip
                    break
                }
            }
        }

        guard let finalIP = resolvedIP else { return }

        let peer = AeroPeerInfo(
            name: service.name,
            host: finalIP,
            port: service.port
        )

        if discovered[service.name] == peer { return }
        discovered[service.name] = peer
        peers = discovered.values.sorted { $0.name < $1.name }
        print("[AeroDiscovery] Peer ready: \(service.name) @ \(finalIP):\(service.port)")
    }
}

// ── NetServiceBrowserDelegate & NetServiceDelegate ──────────────────────────
extension AeroDiscoveryBrowser: NetServiceBrowserDelegate, NetServiceDelegate {

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            // Self-filter
            if !self.localServiceName.isEmpty && service.name == self.localServiceName {
                print("[AeroDiscovery] Skipping self: \(service.name)")
                return
            }

            print("[AeroDiscovery] Found: \(service.name)")
            self.activeServices[service.name] = service
            service.delegate = self
            service.resolve(withTimeout: 10.0)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            print("[AeroDiscovery] Peer lost: \(service.name)")
            self.activeServices[service.name]?.stop()
            self.activeServices.removeValue(forKey: service.name)
            self.discovered.removeValue(forKey: service.name)
            self.peers = self.discovered.values.sorted { $0.name < $1.name }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            self.extractAndStore(service: sender)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        Task { @MainActor in
            print("[AeroDiscovery] Resolve failed for \(sender.name): \(errorDict)")
            self.activeServices.removeValue(forKey: sender.name)
        }
    }
    
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        Task { @MainActor in
            print("[AeroDiscovery] Browser failed: \(errorDict)")
            self.stopBrowsing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.startBrowsing()
            }
        }
    }
}
