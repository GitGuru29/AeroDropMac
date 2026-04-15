#pragma once
// BridgeServer.h — AeroDrop  [Phase 2: Transport Layer]
// Objective-C++ singleton that owns the C++ AeroServer and exposes a
// block-based, main-queue-dispatched API callable from Swift.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ── Transfer progress snapshot ────────────────────────────────────────────────

@interface AeroTransferProgress : NSObject
@property (nonatomic, copy)   NSString* filename;
@property (nonatomic, assign) uint64_t  bytesTransferred;
@property (nonatomic, assign) uint64_t  totalBytes;
@property (nonatomic, assign) double    speedMbps;
/// Convenience: bytesTransferred / totalBytes, clamped to 0.0–1.0
@property (nonatomic, readonly) double fraction;
@end

// ── Bridge singleton ──────────────────────────────────────────────────────────

@interface BridgeServer : NSObject

+ (instancetype)shared;

// ── Lifecycle ────────────────────────────────────────────────────────────────

/// Start the TLS 1.3 server on port 7770. Returns YES on success.
- (BOOL)start NS_SWIFT_NAME(start());

/// Stop the server and join the accept thread.
- (void)stop NS_SWIFT_NAME(stop());

/// Returns YES if the TLS listener is currently active.
- (BOOL)isRunning NS_SWIFT_NAME(isRunning());

// ── Outbound transfer ────────────────────────────────────────────────────────

/// Send a local file to a peer resolved via mDNS.
/// progress and completion blocks are always called on the main queue.
- (void)sendFileAtPath:(NSString*)path
                toHost:(NSString*)host
                  port:(int)port
              progress:(void(^)(AeroTransferProgress*))progress
            completion:(void(^)(BOOL success, NSString* _Nullable error))completion;

// ── Inbound transfer callbacks ────────────────────────────────────────────────

/// Fired on main queue for each progress update while receiving a file.
@property (nonatomic, copy, nullable)
    void(^incomingProgressHandler)(AeroTransferProgress*);

/// Fired on main queue when an inbound transfer completes or fails.
@property (nonatomic, copy, nullable)
    void(^incomingCompletionHandler)(BOOL success, NSString* _Nullable error);

// ── Info ─────────────────────────────────────────────────────────────────────

/// SHA-256 fingerprint of this device's TLS cert (displayed for peer pairing).
- (NSString*)certFingerprint;

@end

NS_ASSUME_NONNULL_END
