// AeroServer.cpp — AeroDrop  [Phase 2: Transport Layer]
// TLS 1.3 TCP server with OpenSSL.
// Receives files from Android via the 64-byte AeroHeader binary protocol.
// Sends files to Android via a high-throughput read→SSL_write loop.
// Note on zero-copy: sendfile(2) cannot pass data through OpenSSL's encryption
// layer. kernelSendFile() is exposed for future unencrypted local-pipe use.
// AES-NI on Apple Silicon makes the SSL_write path negligible on LAN.

#include "AeroServer.h"
#include "CertManager.h"

#include <sys/socket.h>
#include <sys/types.h>
#include <sys/uio.h>          // macOS sendfile(2) — NOT <sys/sendfile.h> (Linux)
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <cstdio>
#include <chrono>
#include <filesystem>
#include <pwd.h>
#include <netdb.h>           // getaddrinfo / freeaddrinfo

namespace fs = std::filesystem;

// ── Adler-32 checksum ─────────────────────────────────────────────────────────
// Used to guard the filename field in AeroHeader against corruption.
// Must match the Android implementation (AeroHeader.kt).

static uint32_t adler32(const uint8_t* data, size_t len) {
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < len; ++i) {
        a = (a + data[i]) % 65521;
        b = (b + a)        % 65521;
    }
    return (b << 16) | a;
}

// ── Constructor / Destructor ──────────────────────────────────────────────────

AeroServer::AeroServer() {
    // OpenSSL global init (idempotent in OpenSSL 1.1+)
    SSL_library_init();
    OpenSSL_add_all_algorithms();
    SSL_load_error_strings();

    // Default output directory: ~/Downloads via passwd entry.
    // The real path is overridden from ObjC++ using setDownloadDir()
    // to let NSFileManager resolve the correct path even in edge cases.
    const char* home = getenv("HOME");
    if (!home) {
        struct passwd* pw = getpwuid(getuid());
        home = pw ? pw->pw_dir : "/tmp";
    }
    download_dir_ = std::string(home) + "/Downloads";
}

AeroServer::~AeroServer() {
    stop();
    if (ssl_ctx_) { SSL_CTX_free(ssl_ctx_); ssl_ctx_ = nullptr; }
}

// ── SSL context setup ─────────────────────────────────────────────────────────

bool AeroServer::setupSSLContext() {
    ssl_ctx_ = CertManager::createServerContext();
    return ssl_ctx_ != nullptr;
}

// ── Server lifecycle ──────────────────────────────────────────────────────────

bool AeroServer::start(int port) {
    if (running_.load()) return true;
    port_ = port;

    if (!setupSSLContext()) {
        fprintf(stderr, "[AeroServer] Failed to initialise SSL context\n");
        return false;
    }

    // IPv6 dual-stack socket — handles IPv4-mapped-v6 addresses too
    server_fd_ = socket(AF_INET6, SOCK_STREAM, 0);
    if (server_fd_ < 0) { perror("[AeroServer] socket"); return false; }

    int yes = 1, no = 0;
    setsockopt(server_fd_, SOL_SOCKET,   SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(server_fd_, SOL_SOCKET,   SO_REUSEPORT, &yes, sizeof(yes));
    setsockopt(server_fd_, IPPROTO_TCP,  TCP_NODELAY,  &yes, sizeof(yes));
    setsockopt(server_fd_, IPPROTO_IPV6, IPV6_V6ONLY,  &no,  sizeof(no));
    int sndbuf = 4 * 1024 * 1024; // 4 MB send buffer
    int rcvbuf = 4 * 1024 * 1024; // 4 MB recv buffer — large files
    setsockopt(server_fd_, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    setsockopt(server_fd_, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    sockaddr_in6 addr{};
    addr.sin6_family = AF_INET6;
    addr.sin6_addr   = in6addr_any;
    addr.sin6_port   = htons(port_);

    if (bind(server_fd_, (sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("[AeroServer] bind");
        close(server_fd_); server_fd_ = -1; return false;
    }
    if (listen(server_fd_, 8) < 0) {
        perror("[AeroServer] listen");
        close(server_fd_); server_fd_ = -1; return false;
    }

    running_ = true;
    accept_thread_ = std::thread(&AeroServer::acceptLoop, this);
    printf("[AeroServer] Listening on [::]:%d (TLS 1.3)\n", port_);
    return true;
}

void AeroServer::stop() {
    if (!running_.exchange(false)) return;
    if (server_fd_ >= 0) {
        shutdown(server_fd_, SHUT_RDWR);
        close(server_fd_);
        server_fd_ = -1;
    }
    if (accept_thread_.joinable()) accept_thread_.join();
}

// ── Accept loop ───────────────────────────────────────────────────────────────

void AeroServer::acceptLoop() {
    while (running_.load()) {
        sockaddr_in6 peer_addr{};
        socklen_t    peer_len = sizeof(peer_addr);
        int client_fd = accept(server_fd_, (sockaddr*)&peer_addr, &peer_len);
        if (client_fd < 0) {
            if (running_.load()) perror("[AeroServer] accept");
            break;
        }

        char peer_ip[INET6_ADDRSTRLEN];
        inet_ntop(AF_INET6, &peer_addr.sin6_addr, peer_ip, sizeof(peer_ip));
        printf("[AeroServer] Inbound connection from %s\n", peer_ip);

        // Spawn a thread per connection so the accept loop stays hot
        std::thread([this, client_fd]() {
            int no_sigpipe = 1;
            setsockopt(client_fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));

            // ── Null-check: SSL_new can fail if memory is exhausted ──────────
            SSL* ssl = SSL_new(ssl_ctx_);
            if (!ssl) {
                fprintf(stderr, "[AeroServer] SSL_new failed — skipping connection\n");
                close(client_fd); return;
            }
            SSL_set_fd(ssl, client_fd);
            if (SSL_accept(ssl) != 1) {
                ERR_print_errors_fp(stderr);
                SSL_free(ssl);
                close(client_fd);
                return;
            }
            handleIncomingClient(client_fd, ssl);
            SSL_shutdown(ssl);
            SSL_free(ssl);
            close(client_fd);
        }).detach();
    }
}

// ── Incoming file handler ─────────────────────────────────────────────────────

void AeroServer::handleIncomingClient(int /*client_fd*/, SSL* ssl) {
    // 1. Read exactly 64 bytes of AeroHeader.
    //    SSL_read may return less than requested (one TLS record at a time),
    //    so we loop until we have the full header.
    AeroHeader hdr{};
    {
        uint8_t* ptr   = reinterpret_cast<uint8_t*>(&hdr);
        size_t   need  = sizeof(hdr);
        size_t   got   = 0;
        while (got < need) {
            int n = SSL_read(ssl, ptr + got, (int)(need - got));
            if (n <= 0) {
                fprintf(stderr, "[AeroServer] Header read failed after %zu/%zu bytes\n",
                        got, need);
                return;
            }
            got += (size_t)n;
        }
    }

    // 2. Validate magic bytes
    if (memcmp(hdr.magic, "AERO", 4) != 0) {
        fprintf(stderr, "[AeroServer] Invalid magic — not an AeroDrop client\n"); return;
    }

    // 3. Validate filename checksum
    size_t   fname_len    = strnlen(hdr.filename, sizeof(hdr.filename));
    uint32_t expected_crc = adler32(reinterpret_cast<const uint8_t*>(hdr.filename), fname_len);
    if (hdr.checksum != expected_crc) {
        fprintf(stderr, "[AeroServer] Filename checksum mismatch\n"); return;
    }

    // 4. Sanitize filename (strip path traversal)
    std::string filename(hdr.filename, fname_len);
    filename = fs::path(filename).filename().string();
    if (filename.empty()) filename = "aerodrop_received";

    uint64_t file_size = hdr.file_size;
    printf("[AeroServer] Receiving: '%s' (%llu bytes)\n",
           filename.c_str(), (unsigned long long)file_size);

    // 5. Open output file
    std::string out_path = download_dir_ + "/" + filename;
    FILE* out_f = fopen(out_path.c_str(), "wb");
    if (!out_f) { perror("[AeroServer] fopen output"); return; }

    // 6. Stream payload — heap-allocated 512 KiB buffer (avoids any stack risk
    //    on threads with non-default stack sizes)
    auto     buf     = std::make_unique<uint8_t[]>(524288);
    uint64_t received = 0;
    auto     t_start  = std::chrono::steady_clock::now();

    while (received < file_size) {
        uint64_t remaining = file_size - received;
        int to_read = (int)std::min(remaining, (uint64_t)524288);
        int n = SSL_read(ssl, buf.get(), to_read);
        if (n <= 0) {
            int ssl_err = SSL_get_error(ssl, n);
            fprintf(stderr, "[AeroServer] SSL_read error %d after %llu/%llu bytes\n",
                    ssl_err, (unsigned long long)received, (unsigned long long)file_size);
            break;
        }
        if (fwrite(buf.get(), 1, (size_t)n, out_f) != (size_t)n) {
            perror("[AeroServer] fwrite"); break;
        }
        received += (uint64_t)n;

        if (incoming_progress_) {
            auto   now = std::chrono::steady_clock::now();
            double sec = std::chrono::duration<double>(now - t_start).count();
            incoming_progress_({ filename, received, file_size,
                                   sec > 0.0 ? (received / 1e6) / sec : 0.0 });
        }
    }
    fflush(out_f);
    fclose(out_f);

    bool ok = (received == file_size);
    printf("[AeroServer] Transfer %s: %llu/%llu bytes → %s\n",
           ok ? "complete" : "INCOMPLETE",
           (unsigned long long)received,
           (unsigned long long)file_size,
           out_path.c_str());

    if (incoming_done_) incoming_done_(ok, ok ? "" : "Transfer incomplete");
}

// ── Zero-copy sendfile (raw socket, non-TLS contexts) ────────────────────────
// macOS sendfile(2):
//   int sendfile(int fd, int s, off_t offset, off_t *len,
//                struct sf_hdtr *hdtr, int flags);
// *len is in/out: pass max bytes to send; kernel writes bytes actually sent.

int64_t AeroServer::kernelSendFile(int src_fd, int dst_socket, uint64_t file_size) {
    off_t    offset     = 0;
    uint64_t total_sent = 0;

    while (total_sent < file_size) {
        off_t chunk = (off_t)std::min((uint64_t)(8 * 1024 * 1024), // 8 MB
                                       file_size - total_sent);
        int ret = sendfile(src_fd, dst_socket, offset, &chunk, nullptr, 0);
        if (chunk > 0) { total_sent += (uint64_t)chunk; offset += chunk; }
        if (ret < 0) {
            if (errno == EAGAIN || errno == EINTR) continue;
            perror("[AeroServer] sendfile"); return -1;
        }
        if (chunk == 0) break;
    }
    return (int64_t)total_sent;
}

// ── Outbound file send ────────────────────────────────────────────────────────

void AeroServer::sendFile(const std::string& filepath,
                          const std::string& peer_host,
                          int                peer_port,
                          ProgressCallback   progress,
                          CompletionCallback done) {
    std::thread([=]() {
        // ── Open source file ──────────────────────────────────────────────────
        int src_fd = open(filepath.c_str(), O_RDONLY);
        if (src_fd < 0) {
            if (done) done(false, std::string("Cannot open: ") + strerror(errno));
            return;
        }
        uint64_t    file_size = (uint64_t)lseek(src_fd, 0, SEEK_END);
        lseek(src_fd, 0, SEEK_SET);
        std::string filename  = fs::path(filepath).filename().string();

        // ── Resolve + connect via getaddrinfo ─────────────────────────────────
        // getaddrinfo handles ALL address types on macOS:
        //   • "192.168.1.x"           → plain IPv4
        //   • "2001:db8::1"           → global IPv6
        //   • "fe80::1%en0"           → link-local IPv6 with interface scope-id
        //   • "phone.local."          → mDNS hostname
        // The %scope-id is preserved by AeroDiscoveryBrowser so macOS can
        // properly set sockaddr_in6.sin6_scope_id for link-local routing.
        struct addrinfo hints{}, *res = nullptr;
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_flags    = AI_NUMERICSERV;   // port is numeric, skip /etc/services
        std::string port_str = std::to_string(peer_port);

        int gai_err = getaddrinfo(peer_host.c_str(), port_str.c_str(), &hints, &res);
        if (gai_err != 0) {
            fprintf(stderr, "[AeroServer] getaddrinfo('%s'): %s\n",
                    peer_host.c_str(), gai_strerror(gai_err));
            close(src_fd);
            if (done) done(false, std::string("DNS resolution failed: ") + gai_strerror(gai_err));
            return;
        }

        int sock = -1;
        for (struct addrinfo* rp = res; rp && sock < 0; rp = rp->ai_next) {
            int s = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
            if (s < 0) continue;
            int nb = 1;
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &nb, sizeof(nb));
            int no_sigpipe = 1;
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));

            int sndbuf = 4 * 1024 * 1024;
            setsockopt(s, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
            if (connect(s, rp->ai_addr, rp->ai_addrlen) == 0) {
                sock = s;
            } else {
                fprintf(stderr, "[AeroServer] connect attempt failed: %s\n", strerror(errno));
                close(s);
            }
        }
        freeaddrinfo(res);

        if (sock < 0) {
            close(src_fd);
            if (done) done(false, "Cannot connect to " + peer_host + ":" + port_str);
            return;
        }

        // ── TLS handshake (client mode) ───────────────────────────────────────
        SSL_CTX* cli_ctx = CertManager::createClientContext();
        SSL*     ssl     = SSL_new(cli_ctx);
        if (!ssl) {
            close(src_fd); close(sock); SSL_CTX_free(cli_ctx);
            if (done) done(false, "SSL_new failed");
            return;
        }
        SSL_set_fd(ssl, sock);
        if (SSL_connect(ssl) != 1) {
            ERR_print_errors_fp(stderr);
            SSL_free(ssl); SSL_CTX_free(cli_ctx);
            close(src_fd); close(sock);
            if (done) done(false, "TLS handshake failed");
            return;
        }

        // ── Build and send AeroHeader ─────────────────────────────────────────
        AeroHeader hdr{};
        memcpy(hdr.magic, "AERO", 4);
        hdr.version   = 1;
        hdr.file_size = file_size;
        size_t fname_len = std::min(filename.size(), sizeof(hdr.filename) - 1);
        memcpy(hdr.filename, filename.c_str(), fname_len);
        hdr.checksum = adler32(reinterpret_cast<const uint8_t*>(hdr.filename), fname_len);

        if (SSL_write(ssl, &hdr, sizeof(hdr)) != (int)sizeof(hdr)) {
            if (done) done(false, "Header write failed");
            SSL_shutdown(ssl); SSL_free(ssl); SSL_CTX_free(cli_ctx);
            close(src_fd); close(sock);
            return;
        }

        // ── Stream payload (read file → SSL_write) ───────────────────────────
        auto     buf     = std::make_unique<uint8_t[]>(524288); // 512 KiB heap
        auto     t_start = std::chrono::steady_clock::now();
        uint64_t sent    = 0;

        while (sent < file_size) {
            ssize_t rd = read(src_fd, buf.get(), 524288);
            if (rd <= 0) break;
            int wr = SSL_write(ssl, buf.get(), (int)rd);
            if (wr != (int)rd) {
                fprintf(stderr, "[AeroServer] SSL_write short write\n"); break;
            }
            sent += (uint64_t)wr;
            if (progress) {
                auto   now = std::chrono::steady_clock::now();
                double sec = std::chrono::duration<double>(now - t_start).count();
                progress({ filename, sent, file_size,
                            sec > 0.0 ? (sent / 1e6) / sec : 0.0 });
            }
        }

        bool ok = (sent == file_size);
        printf("[AeroServer] Send %s: %llu/%llu bytes\n",
               ok ? "complete" : "INCOMPLETE",
               (unsigned long long)sent, (unsigned long long)file_size);
        if (done) done(ok, ok ? "" : "Incomplete transfer");

        SSL_shutdown(ssl);
        SSL_free(ssl);
        SSL_CTX_free(cli_ctx);
        close(src_fd);
        close(sock);
    }).detach();
}
