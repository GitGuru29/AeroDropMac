import Foundation

struct AeroPeerInfo: Identifiable, Hashable {
    let name: String
    let host: String
    let port: Int

    var id: String { name }

    var endpoint: String { "\(host):\(port)" }

    var isLinkLocalIPv6: Bool { host.contains(":") }
}
