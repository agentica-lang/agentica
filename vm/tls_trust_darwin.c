/*
 * The system trust store on macOS, from the Security framework: the user and
 * admin trust settings first (a user setting overrides an admin one), then
 * the system anchors. A denied certificate is added rejected, so a chain
 * through it fails. Platform adapter behind tls_trust.h.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "tls_trust.h"

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <Security/SecBase.h>
#include <Security/SecCertificate.h>
#include <Security/SecPolicy.h>
#include <Security/SecTrust.h>
#include <Security/SecTrustSettings.h>
#include <stdbool.h>

typedef struct {
  struct x509_store_st *store;
  CFMutableSetRef decided;
} loader;

static bool number_is(CFDictionaryRef d, CFStringRef key, SInt32 *out) {
  CFTypeRef v = CFDictionaryGetValue(d, key);
  return v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, out);
}

/* True when the usage-constraints dictionary names no policy or the TLS policy (kSecPolicyAppleSSL). */
static bool tls_policy(CFDictionaryRef d) {
  CFTypeRef policy = CFDictionaryGetValue(d, kSecTrustSettingsPolicy);
  if (!policy) return true;
  if (CFGetTypeID(policy) != SecPolicyGetTypeID()) return false;
  CFDictionaryRef props = SecPolicyCopyProperties((SecPolicyRef)policy);
  if (!props) return false;
  CFTypeRef oid = CFDictionaryGetValue(props, kSecPolicyOid);
  bool ssl = oid && CFEqual(oid, kSecPolicyAppleSSL);
  CFRelease(props);
  return ssl;
}

/* The verdict of a certificate's trust settings for TLS server authentication (Apple documentation of
 * SecTrustSettingsCopyTrustSettings). An empty array means "always trust". A dictionary applies when its policy is
 * absent or TLS. One that also limits the trust to an application, a host name or a key use counts only when it
 * denies: a narrow grant never becomes a general root (on purpose even when its key uses include certificate
 * signing; a key use that cannot be read counts as narrow), and a narrow denial removes the certificate for every
 * host. A missing result means TrustRoot; Unspecified gives no verdict. Any matching denial wins, which is stricter
 * than Apple's first match and fails closed. A grant on a non-self-signed certificate (TrustAsRoot) has no effect:
 * without X509_V_FLAG_PARTIAL_CHAIN, OpenSSL only ends a chain at a self-signed certificate. */
agc_tls_trust_verdict agc_tls_trust_settings_verdict(CFArrayRef settings) {
  CFIndex n = CFArrayGetCount(settings);
  if (n == 0) return AGC_TLS_TRUST_ROOT;
  agc_tls_trust_verdict v = AGC_TLS_TRUST_NONE;
  for (CFIndex k = 0; k < n; k++) {
    CFTypeRef item = CFArrayGetValueAtIndex(settings, k);
    if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
    CFDictionaryRef d = (CFDictionaryRef)item;
    if (!tls_policy(d)) continue;
    SInt32 result = (SInt32)kSecTrustSettingsResultTrustRoot, use = 0;
    if (CFDictionaryContainsKey(d, kSecTrustSettingsResult) && !number_is(d, kSecTrustSettingsResult, &result))
      continue;
    if (result == (SInt32)kSecTrustSettingsResultDeny) return AGC_TLS_TRUST_DENIED;
    bool narrow = CFDictionaryContainsKey(d, kSecTrustSettingsApplication) ||
                  CFDictionaryContainsKey(d, kSecTrustSettingsPolicyString) ||
                  (CFDictionaryContainsKey(d, kSecTrustSettingsKeyUsage) &&
                   (!number_is(d, kSecTrustSettingsKeyUsage, &use) || use != (SInt32)kSecTrustSettingsKeyUseAny));
    bool grant = result == (SInt32)kSecTrustSettingsResultTrustRoot ||
                 result == (SInt32)kSecTrustSettingsResultTrustAsRoot;
    if (grant && !narrow) v = AGC_TLS_TRUST_ROOT;
  }
  return v;
}

static void add_cert(loader *l, SecCertificateRef cert, bool rejected) {
  CFDataRef data = SecCertificateCopyData(cert);
  if (!data) return;
  (void)agc_tls_trust_add_der(l->store, CFDataGetBytePtr(data), (size_t)CFDataGetLength(data), rejected);
  CFRelease(data);
}

/* The admin or user domain: each certificate with trust settings gets its verdict once, and the first domain that
 * gives one decides it. */
static void load_domain(loader *l, SecTrustSettingsDomain domain) {
  CFArrayRef certs = NULL;
  if (SecTrustSettingsCopyCertificates(domain, &certs) != errSecSuccess || !certs) return;
  for (CFIndex k = 0, n = CFArrayGetCount(certs); k < n; k++) {
    SecCertificateRef cert = (SecCertificateRef)CFArrayGetValueAtIndex(certs, k);
    if (CFSetContainsValue(l->decided, cert)) continue;
    CFArrayRef settings = NULL;
    if (SecTrustSettingsCopyTrustSettings(cert, domain, &settings) != errSecSuccess || !settings) continue;
    agc_tls_trust_verdict v = agc_tls_trust_settings_verdict(settings);
    CFRelease(settings);
    if (v == AGC_TLS_TRUST_NONE) continue;
    CFSetAddValue(l->decided, cert);
    add_cert(l, cert, v == AGC_TLS_TRUST_DENIED);
  }
  CFRelease(certs);
}

/* The domains run before the anchors, so a denied anchor is added rejected first and the store ignores the later
 * copy; a decided certificate is skipped among the anchors anyway. */
void agc_tls_trust_load(struct x509_store_st *store) {
  loader l = {store, CFSetCreateMutable(kCFAllocatorDefault, 0, &kCFTypeSetCallBacks)};
  if (!l.decided) return;
  load_domain(&l, kSecTrustSettingsDomainUser);
  load_domain(&l, kSecTrustSettingsDomainAdmin);
  CFArrayRef anchors = NULL;
  if (SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess && anchors) {
    for (CFIndex k = 0, n = CFArrayGetCount(anchors); k < n; k++) {
      SecCertificateRef cert = (SecCertificateRef)CFArrayGetValueAtIndex(anchors, k);
      if (!CFSetContainsValue(l.decided, cert)) add_cert(&l, cert, false);
    }
    CFRelease(anchors);
  }
  CFRelease(l.decided);
}
#endif
