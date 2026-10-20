/*
 * The system trust store on macOS, from the Security framework: the system
 * anchors, then the admin and user trust settings, which may add a root for
 * TLS or deny one (a user setting overrides an admin one, which overrides the
 * system). Certificates are copied into the OpenSSL store as DER. Platform
 * adapter behind tls_trust.h.
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

#include <openssl/err.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>

typedef enum { NO_SETTING, TRUSTED, DENIED } verdict;

typedef struct {
  struct x509_store_st *store;
  CFMutableSetRef decided;
  size_t added;
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

/* The verdict of a certificate's trust settings for TLS server authentication (Apple, SecTrustSettingsCopyTrustSettings).
 * An empty array means "always trust" as a root. A dictionary applies when its policy is TLS. One that also limits
 * the trust to an application, a host name or a key use counts only when it denies, so a narrow grant never becomes
 * a general root and a narrow denial still removes the root. A missing result means TrustRoot; Unspecified gives no
 * verdict. A denial wins over a grant. */
static verdict tls_verdict(CFArrayRef settings) {
  CFIndex n = CFArrayGetCount(settings);
  if (n == 0) return TRUSTED;
  verdict v = NO_SETTING;
  for (CFIndex k = 0; k < n; k++) {
    CFTypeRef item = CFArrayGetValueAtIndex(settings, k);
    if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
    CFDictionaryRef d = (CFDictionaryRef)item;
    if (!tls_policy(d)) continue;
    SInt32 result = kSecTrustSettingsResultTrustRoot, use = 0;
    if (CFDictionaryContainsKey(d, kSecTrustSettingsResult) && !number_is(d, kSecTrustSettingsResult, &result)) continue;
    if (result == kSecTrustSettingsResultDeny) return DENIED;
    bool narrow = CFDictionaryContainsKey(d, kSecTrustSettingsApplication) ||
                  CFDictionaryContainsKey(d, kSecTrustSettingsPolicyString) ||
                  (number_is(d, kSecTrustSettingsKeyUsage, &use) && use != (SInt32)kSecTrustSettingsKeyUseAny);
    if (!narrow && (result == kSecTrustSettingsResultTrustRoot || result == kSecTrustSettingsResultTrustAsRoot))
      v = TRUSTED;
  }
  return v;
}

static void add_der(loader *l, SecCertificateRef cert) {
  CFDataRef data = SecCertificateCopyData(cert);
  if (!data) return;
  const unsigned char *der = CFDataGetBytePtr(data);
  X509 *x = d2i_X509(NULL, &der, (long)CFDataGetLength(data));
  if (x && X509_STORE_add_cert(l->store, x) == 1) l->added++;
  X509_free(x);
  ERR_clear_error();
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
    verdict v = tls_verdict(settings);
    CFRelease(settings);
    if (v == NO_SETTING) continue;
    CFSetAddValue(l->decided, cert);
    if (v == TRUSTED) add_der(l, cert);
  }
  CFRelease(certs);
}

size_t agc_tls_trust_system(struct x509_store_st *store) {
  loader l = {store, CFSetCreateMutable(kCFAllocatorDefault, 0, &kCFTypeSetCallBacks), 0};
  if (!l.decided) return 0;
  load_domain(&l, kSecTrustSettingsDomainUser);
  load_domain(&l, kSecTrustSettingsDomainAdmin);
  CFArrayRef anchors = NULL;
  if (SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess && anchors) {
    for (CFIndex k = 0, n = CFArrayGetCount(anchors); k < n; k++) {
      SecCertificateRef cert = (SecCertificateRef)CFArrayGetValueAtIndex(anchors, k);
      if (!CFSetContainsValue(l.decided, cert)) add_der(&l, cert);
    }
    CFRelease(anchors);
  }
  CFRelease(l.decided);
  return l.added;
}
#endif
