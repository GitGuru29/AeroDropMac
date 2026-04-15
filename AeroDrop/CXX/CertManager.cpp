// CertManager.cpp — AeroDrop  [Phase 2: Transport Layer]
// RSA-4096 self-signed X.509 certificate generation via OpenSSL EVP API.
// On first run, generates cert.pem + key.pem (mode 0600) in:
//   ~/Library/Application Support/AeroDrop/
// Subsequent launches load the existing files — no re-generation.

#include "CertManager.h"

#include <openssl/rsa.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <openssl/sha.h>
#include <openssl/bn.h>
#include <openssl/rand.h>

#include <sys/stat.h>
#include <unistd.h>
#include <pwd.h>
#include <cstring>
#include <cstdio>
#include <sstream>
#include <iomanip>

// ── Helpers ───────────────────────────────────────────────────────────────────

static std::string homeDirectory() {
    const char* home = getenv("HOME");
    if (home) return home;
    struct passwd* pw = getpwuid(getuid());
    return pw ? pw->pw_dir : "";
}

std::string CertManager::dataDirectory() {
    std::string dir = homeDirectory() + "/Library/Application Support/AeroDrop";
    mkdir(dir.c_str(), 0700); // no-op if already exists
    return dir;
}

std::string CertManager::certPath() { return dataDirectory() + "/cert.pem"; }
std::string CertManager::keyPath()  { return dataDirectory() + "/key.pem";  }

// ── RSA-4096 key generation ───────────────────────────────────────────────────

EVP_PKEY* CertManager::generateRSAKey() {
    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr);
    if (!ctx) return nullptr;

    EVP_PKEY* pkey = nullptr;
    if (EVP_PKEY_keygen_init(ctx) <= 0 ||
        EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, 4096) <= 0 ||
        EVP_PKEY_keygen(ctx, &pkey) <= 0) {
        EVP_PKEY_CTX_free(ctx);
        return nullptr;
    }
    EVP_PKEY_CTX_free(ctx);
    return pkey;
}

// ── X.509 certificate generation ─────────────────────────────────────────────

X509* CertManager::generateCert(EVP_PKEY* pkey) {
    X509* cert = X509_new();
    if (!cert) return nullptr;

    // Serial: 160-bit random bignum (RFC 5280 §4.1.2.2)
    BIGNUM* serial = BN_new();
    BN_rand(serial, 160, BN_RAND_TOP_ANY, BN_RAND_BOTTOM_ANY);
    BN_to_ASN1_INTEGER(serial, X509_get_serialNumber(cert));
    BN_free(serial);

    // Validity: now → +10 years
    X509_gmtime_adj(X509_get_notBefore(cert), 0);
    X509_gmtime_adj(X509_get_notAfter(cert),  10L * 365 * 24 * 3600);

    // Subject / Issuer (self-signed → identical)
    X509_NAME* name = X509_get_subject_name(cert);
    X509_NAME_add_entry_by_txt(name, "O",  MBSTRING_ASC,
        (const unsigned char*)"AeroDrop", -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
        (const unsigned char*)"aerodrop.local", -1, -1, 0);
    X509_set_issuer_name(cert, name);
    X509_set_pubkey(cert, pkey);

    // Extensions
    X509V3_CTX ctx;
    X509V3_set_ctx_nodb(&ctx);
    X509V3_set_ctx(&ctx, cert, cert, nullptr, nullptr, 0);

    auto addExt = [&](int nid, const char* value) {
        X509_EXTENSION* ex = X509V3_EXT_conf_nid(nullptr, &ctx, nid, value);
        if (ex) { X509_add_ext(cert, ex, -1); X509_EXTENSION_free(ex); }
    };
    addExt(NID_basic_constraints,      "critical,CA:FALSE");
    addExt(NID_key_usage,              "critical,digitalSignature,keyEncipherment");
    addExt(NID_subject_key_identifier, "hash");

    // Sign with SHA-256
    if (X509_sign(cert, pkey, EVP_sha256()) == 0) {
        X509_free(cert);
        return nullptr;
    }
    return cert;
}

// ── Persistence ───────────────────────────────────────────────────────────────

bool CertManager::generateSelfSigned() {
    EVP_PKEY* pkey = generateRSAKey();
    if (!pkey) return false;

    X509* cert = generateCert(pkey);
    if (!cert) { EVP_PKEY_free(pkey); return false; }

    bool ok = true;

    // Write private key (mode 0600 — owner-only)
    FILE* kf = fopen(keyPath().c_str(), "wb");
    if (!kf || !PEM_write_PrivateKey(kf, pkey, nullptr, nullptr, 0, nullptr, nullptr))
        ok = false;
    if (kf) { fclose(kf); chmod(keyPath().c_str(), 0600); }

    // Write certificate
    FILE* cf = fopen(certPath().c_str(), "wb");
    if (!cf || !PEM_write_X509(cf, cert)) ok = false;
    if (cf) fclose(cf);

    X509_free(cert);
    EVP_PKEY_free(pkey);
    return ok;
}

bool CertManager::ensureCertExists() {
    auto exists = [](const std::string& p) -> bool {
        struct stat st; return stat(p.c_str(), &st) == 0;
    };
    if (exists(certPath()) && exists(keyPath())) return true;
    return generateSelfSigned();
}

// ── SHA-256 fingerprint ───────────────────────────────────────────────────────

std::string CertManager::fingerprint() {
    FILE* f = fopen(certPath().c_str(), "rb");
    if (!f) return "";
    X509* cert = PEM_read_X509(f, nullptr, nullptr, nullptr);
    fclose(f);
    if (!cert) return "";

    unsigned char buf[EVP_MAX_MD_SIZE];
    unsigned int  len = 0;
    if (!X509_digest(cert, EVP_sha256(), buf, &len)) {
        X509_free(cert); return "";
    }
    X509_free(cert);

    std::ostringstream oss;
    for (unsigned int i = 0; i < len; ++i) {
        if (i > 0) oss << ':';
        oss << std::uppercase << std::hex
            << std::setw(2) << std::setfill('0')
            << static_cast<int>(buf[i]);
    }
    return oss.str();
}

// ── SSL_CTX factories ─────────────────────────────────────────────────────────

static SSL_CTX* baseContext(const SSL_METHOD* method) {
    SSL_CTX* ctx = SSL_CTX_new(method);
    if (!ctx) return nullptr;

    // TLS 1.3 only — no legacy protocol versions
    SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION);

    if (SSL_CTX_use_certificate_file(ctx, CertManager::certPath().c_str(), SSL_FILETYPE_PEM) != 1 ||
        SSL_CTX_use_PrivateKey_file(ctx,  CertManager::keyPath().c_str(),  SSL_FILETYPE_PEM) != 1 ||
        SSL_CTX_check_private_key(ctx)  != 1) {
        SSL_CTX_free(ctx);
        return nullptr;
    }
    return ctx;
}

SSL_CTX* CertManager::createServerContext() {
    if (!ensureCertExists()) return nullptr;
    SSL_CTX* ctx = baseContext(TLS_server_method());
    if (!ctx) return nullptr;

    // Do NOT require a client certificate — Android cannot easily present one.
    // Peer authenticity is established by SHA-256 fingerprint shown in the UI.
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nullptr);
    return ctx;
}

SSL_CTX* CertManager::createClientContext() {
    if (!ensureCertExists()) return nullptr;
    SSL_CTX* ctx = baseContext(TLS_client_method());
    if (!ctx) return nullptr;
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nullptr); // fingerprint auth
    return ctx;
}
