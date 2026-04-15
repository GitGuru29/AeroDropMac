#pragma once
// CertManager.h — AeroDrop  [Phase 2: Transport Layer]
// Generates and persists a self-signed RSA-4096 / X.509 certificate
// for the TLS 1.3 server. On first launch the cert + key are written to
// ~/Library/Application Support/AeroDrop/.
//
// Peer authentication uses SHA-256 fingerprint comparison instead of a CA
// trust chain — identical to how SSH known_hosts works.

#include <string>
#include <openssl/ssl.h>
#include <openssl/evp.h>
#include <openssl/x509.h>

class CertManager {
public:
    // Path to the Application Support directory (created if absent).
    static std::string dataDirectory();

    // Ensures cert.pem + key.pem exist; generates them on first run.
    // Returns true on success.
    static bool ensureCertExists();

    // Absolute path to the current cert / key PEM files.
    static std::string certPath();
    static std::string keyPath();

    // SHA-256 fingerprint of the current cert (hex, colon-separated).
    // Displayed in the UI for peer pairing verification.
    // Example: "AA:BB:CC:DD:..."
    static std::string fingerprint();

    // Create an SSL_CTX configured for TLS 1.3 server use.
    // Caller owns the returned context and must call SSL_CTX_free().
    static SSL_CTX* createServerContext();

    // Create an SSL_CTX configured for TLS 1.3 client use (outbound send).
    static SSL_CTX* createClientContext();

private:
    static bool     generateSelfSigned();
    static EVP_PKEY* generateRSAKey();
    static X509*     generateCert(EVP_PKEY* pkey);
};
