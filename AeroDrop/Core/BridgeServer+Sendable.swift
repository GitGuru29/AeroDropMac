import Foundation

// BridgeServer is a dispatch_once singleton that fronts the C++ AeroServer.
// AeroServer owns its transfer threads, guards its running flag with an
// atomic, and marshals every callback back to the main queue, so the handle
// itself is safe to hand to the background queue that performs the blocking
// RSA-4096 keygen in -start.
extension BridgeServer: @unchecked Sendable {}
