// BridgeServer.mm — AeroDrop  [Phase 2: Transport Layer]
// Objective-C++ implementation of BridgeServer.
// Owns the C++ AeroServer via unique_ptr and exposes a block-based Swift API.
// All callbacks are dispatched on the main queue.

#import "BridgeServer.h"
#include "../CXX/AeroServer.h"
#include "../CXX/CertManager.h"
#include <memory>
#include <string>

// ── AeroTransferProgress ──────────────────────────────────────────────────────

@implementation AeroTransferProgress
- (double)fraction {
    if (_totalBytes == 0) return 0.0;
    return (double)_bytesTransferred / (double)_totalBytes;
}
@end

static AeroTransferProgress* makeProgress(const TransferProgress& p) {
    AeroTransferProgress* obj = [AeroTransferProgress new];
    obj.filename         = @(p.filename.c_str());
    obj.bytesTransferred = p.bytes_transferred;
    obj.totalBytes       = p.total_bytes;
    obj.speedMbps        = p.speed_mbps;
    return obj;
}

// ── BridgeServer ──────────────────────────────────────────────────────────────

@interface BridgeServer () {
    std::unique_ptr<AeroServer> _server;
}
@end

@implementation BridgeServer

+ (instancetype)shared {
    static BridgeServer* instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[BridgeServer alloc] init]; });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _server = std::make_unique<AeroServer>();

        __weak typeof(self) weak = self;

        _server->setIncomingProgressCallback([weak](const TransferProgress& p) {
            if (!weak || !weak.incomingProgressHandler) return;
            AeroTransferProgress* obj = makeProgress(p);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weak.incomingProgressHandler)
                    weak.incomingProgressHandler(obj);
            });
        });

        _server->setIncomingCompletionCallback([weak](bool ok, const std::string& err) {
            if (!weak || !weak.incomingCompletionHandler) return;
            NSString* nsErr = ok ? nil : @(err.c_str());
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weak.incomingCompletionHandler)
                    weak.incomingCompletionHandler(ok, nsErr);
            });
        });
    }
    return self;
}

- (BOOL)start   { return (BOOL)_server->start(7770); }
- (void)stop    { _server->stop(); }
- (BOOL)isRunning { return (BOOL)_server->isRunning(); }

- (void)sendFileAtPath:(NSString*)path
                toHost:(NSString*)host
                  port:(int)port
              progress:(void(^)(AeroTransferProgress*))progress
            completion:(void(^)(BOOL, NSString* _Nullable))completion {

    _server->sendFile(
        path.UTF8String,
        host.UTF8String,
        port,
        [progress](const TransferProgress& p) {
            if (!progress) return;
            AeroTransferProgress* obj = makeProgress(p);
            dispatch_async(dispatch_get_main_queue(), ^{ progress(obj); });
        },
        [completion](bool ok, const std::string& err) {
            if (!completion) return;
            NSString* nsErr = ok ? nil : @(err.c_str());
            dispatch_async(dispatch_get_main_queue(), ^{ completion((BOOL)ok, nsErr); });
        }
    );
}

- (NSString*)certFingerprint {
    std::string fp = CertManager::fingerprint();
    return fp.empty() ? @"(cert not generated)" : @(fp.c_str());
}

@end
