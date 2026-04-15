#pragma once
// AeroServer.h — AeroDrop  [Phase 2: Transport Layer]
// High-performance TLS 1.3 TCP server on macOS.
//
// Features:
//   • OpenSSL TLS 1.3 (no legacy protocols)
//   • 64-byte binary AeroHeader with Adler-32 integrity check
//   • IPv6 dual-stack listener (handles IPv4-mapped addresses too)
//   • Progress callbacks dispatched from worker threads
//   • kernelSendFile() exposes sendfile(2) for unencrypted contexts

#include <string>
#include <functional>
#include <thread>
#include <atomic>
#include <openssl/ssl.h>
#include <openssl/err.h>

// ── Wire protocol header ─────────────────────────────────────────────────────
// Fixed 64-byte structure sent before every file payload.
// Layout MUST match the Android side (AeroHeader.kt) exactly.
//
//  Offset  Size  Field
//  ──────  ────  ─────────────────────────────────────────────────────
//    0      4    magic    — {'A','E','R','O'}
//    4      4    version  — uint32, currently 1
//    8      8    fileSize — uint64, total payload bytes
//   16     44    filename — UTF-8, null-padded
//   60      4    checksum — Adler-32 of filename bytes
//   ──      ─    total: 64 bytes
struct AeroHeader {
    uint8_t  magic[4];
    uint32_t version;
    uint64_t file_size;
    char     filename[44];
    uint32_t checksum;
} __attribute__((packed));
static_assert(sizeof(AeroHeader) == 64, "AeroHeader must be exactly 64 bytes");

// ── Callbacks ────────────────────────────────────────────────────────────────

struct TransferProgress {
    std::string filename;
    uint64_t    bytes_transferred = 0;
    uint64_t    total_bytes       = 0;
    double      speed_mbps        = 0.0;
};

using ProgressCallback   = std::function<void(const TransferProgress&)>;
using CompletionCallback = std::function<void(bool success, const std::string& error)>;

// ── AeroServer ───────────────────────────────────────────────────────────────

class AeroServer {
public:
    AeroServer();
    ~AeroServer();

    // Start the TLS listener on the given port (default 7770).
    bool start(int port = 7770);
    void stop();
    bool isRunning() const { return running_.load(); }

    // Outbound: send a local file to a remote peer (Android device).
    // progress and done are called on a background thread.
    void sendFile(const std::string& filepath,
                  const std::string& peer_ip,
                  int                peer_port,
                  ProgressCallback   progress,
                  CompletionCallback done);

    // Inbound: callbacks fired when Mac is *receiving* a file from Android.
    void setIncomingProgressCallback(ProgressCallback cb)    { incoming_progress_ = cb; }
    void setIncomingCompletionCallback(CompletionCallback cb) { incoming_done_     = cb; }

    // Override the default output directory (~/Downloads).
    void setDownloadDirectory(const std::string& dir) { download_dir_ = dir; }

private:
    void    acceptLoop();
    void    handleIncomingClient(int client_fd, SSL* ssl);
    bool    setupSSLContext();

    // Exposes macOS sendfile(2) for non-encrypted (raw socket) use.
    static int64_t kernelSendFile(int src_fd, int dst_socket, uint64_t file_size);

    int               server_fd_    = -1;
    int               port_         = 7770;
    std::atomic<bool> running_      {false};
    std::thread       accept_thread_;
    SSL_CTX*          ssl_ctx_      = nullptr;
    std::string       download_dir_;
    ProgressCallback  incoming_progress_;
    CompletionCallback incoming_done_;
};
