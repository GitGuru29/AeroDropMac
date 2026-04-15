#pragma once
// BonjourBridge.h — AeroDrop  [Phase 1: Discovery Layer]
// Pure C interface wrapping dns_sd.h (Apple's mDNS / Bonjour API).
// Importable from Objective-C++, C++, and Swift (via bridging header).
//
// The service is advertised as:
//   type  : _aerodrop._tcp
//   domain: local.
//   port  : 7770

#ifdef __cplusplus
extern "C" {
#endif

// Start advertising the _aerodrop._tcp service on the given port.
// device_name: human-readable instance name (e.g. "MacBook Pro – siluna")
// Returns 0 on success, non-zero (DNSServiceErrorType) on failure.
int  bonjour_register(const char* device_name, unsigned short port);

// Stop advertising the service and release dns_sd resources.
void bonjour_unregister(void);

// Returns 1 if currently registered and confirmed by the daemon, 0 otherwise.
int  bonjour_is_registered(void);

#ifdef __cplusplus
}
#endif
