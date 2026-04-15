// AeroDrop-Bridging-Header.h
// Xcode Obj-C bridging header — exposes C and ObjC symbols to Swift.
// Path is set via SWIFT_OBJC_BRIDGING_HEADER in project.pbxproj.

// Phase 1: mDNS / Bonjour discovery
#import "Core/BonjourBridge.h"

// Phase 2: TLS TCP server + cert manager (ObjC++ bridge)
#import "Core/BridgeServer.h"
