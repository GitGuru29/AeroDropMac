// BonjourBridge.mm — AeroDrop  [Phase 1: Discovery Layer]
// Objective-C++ implementation of the pure-C Bonjour registration interface.
// Uses dns_sd.h (part of mDNSResponder — always available on macOS, no deps).
//
// Architecture:
//   bonjour_register() → DNSServiceRegister() → callback sets s_registered = 1
//   bonjourRunLoop()   → detached pthread pumping DNSServiceProcessResult()
//                        via select() with 1s timeout for clean shutdown

#include "BonjourBridge.h"
#include <dns_sd.h>
#include <pthread.h>
#include <unistd.h>
#include <cstring>
#include <cstdio>

// ── Module-level state ────────────────────────────────────────────────────────

static DNSServiceRef  s_service_ref  = nullptr;
static pthread_t      s_run_thread   = 0;
static volatile int   s_registered   = 0;
static volatile int   s_stop_loop    = 0;

// ── DNS-SD registration callback ─────────────────────────────────────────────

static void DNSSD_API registrationCallback(
    DNSServiceRef        sdRef,
    DNSServiceFlags      flags,
    DNSServiceErrorType  errorCode,
    const char*          name,
    const char*          regtype,
    const char*          domain,
    void*                context)
{
    (void)sdRef; (void)flags; (void)context;
    if (errorCode == kDNSServiceErr_NoError) {
        printf("[AeroDrop Bonjour] Registered: %s.%s%s\n", name, regtype, domain);
        s_registered = 1;
    } else {
        fprintf(stderr, "[AeroDrop Bonjour] Registration error: %d\n", errorCode);
        s_registered = 0;
    }
}

// ── Run-loop thread ───────────────────────────────────────────────────────────
// dns_sd requires DNSServiceProcessResult() to be called when the service
// file descriptor becomes readable. We use select() with a 1-second timeout
// to remain responsive to s_stop_loop without burning CPU.

static void* bonjourRunLoop(void* arg) {
    (void)arg;
    while (!s_stop_loop && s_service_ref) {
        int fd = DNSServiceRefSockFD(s_service_ref);
        if (fd < 0) break;

        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);

        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        int ret = select(fd + 1, &fds, nullptr, nullptr, &tv);
        if (ret > 0 && FD_ISSET(fd, &fds)) {
            DNSServiceErrorType err = DNSServiceProcessResult(s_service_ref);
            if (err != kDNSServiceErr_NoError) {
                fprintf(stderr, "[AeroDrop Bonjour] ProcessResult error: %d\n", err);
                break;
            }
        }
    }
    return nullptr;
}

// ── Public API ────────────────────────────────────────────────────────────────

int bonjour_register(const char* device_name, unsigned short port) {
    if (s_service_ref) return 0; // Already registered

    s_stop_loop  = 0;
    s_registered = 0;

    // TXT record: protocol version for forward-compatibility
    const char txt_version[] = "\x09version=1"; // length-prefixed string
    DNSServiceErrorType err = DNSServiceRegister(
        &s_service_ref,
        0,                              // flags
        kDNSServiceInterfaceIndexAny,   // all network interfaces
        device_name,                    // service instance name
        "_aerodrop._tcp",               // service type
        "local.",                       // domain
        nullptr,                        // host (use system default)
        htons(port),                    // port in network byte order
        (uint16_t)(sizeof(txt_version) - 1),
        txt_version,
        registrationCallback,
        nullptr                         // context
    );

    if (err != kDNSServiceErr_NoError) {
        fprintf(stderr, "[AeroDrop Bonjour] DNSServiceRegister failed: %d\n", err);
        s_service_ref = nullptr;
        return (int)err;
    }

    // Spin up the dedicated run-loop thread (detached — we clean up via stop)
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&s_run_thread, &attr, bonjourRunLoop, nullptr);
    pthread_attr_destroy(&attr);

    return 0;
}

void bonjour_unregister(void) {
    s_stop_loop = 1;
    if (s_service_ref) {
        DNSServiceRefDeallocate(s_service_ref);
        s_service_ref = nullptr;
    }
    s_registered = 0;
}

int bonjour_is_registered(void) {
    return s_registered;
}
