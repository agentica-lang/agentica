/*
 * The macOS trust policy (tls_trust_darwin.c): the verdict of trust settings
 * arrays built in memory, one rule per case.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "../tls_trust.h"

#include <stdio.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <Security/SecPolicy.h>
#include <Security/SecTrustSettings.h>
#include <assert.h>

/* One usage-constraints dictionary: a NULL value leaves its key out. */
static CFDictionaryRef constraint(SecPolicyRef policy, const SInt32 *result, CFStringRef host, CFStringRef app,
                                  const SInt32 *key_use) {
  CFMutableDictionaryRef d =
    CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  assert(d);
  if (policy) CFDictionarySetValue(d, kSecTrustSettingsPolicy, policy);
  if (host) CFDictionarySetValue(d, kSecTrustSettingsPolicyString, host);
  if (app) CFDictionarySetValue(d, kSecTrustSettingsApplication, app);
  const SInt32 *numbers[] = {result, key_use};
  CFStringRef keys[] = {kSecTrustSettingsResult, kSecTrustSettingsKeyUsage};
  for (int k = 0; k < 2; k++) {
    if (!numbers[k]) continue;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, numbers[k]);
    CFDictionarySetValue(d, keys[k], n);
    CFRelease(n);
  }
  return d;
}

/* The verdict of an array of these dictionaries (consumed). */
static agc_tls_trust_verdict verdict_of(CFDictionaryRef a, CFDictionaryRef b) {
  const void *items[] = {a, b};
  CFIndex n = (a ? 1 : 0) + (b ? 1 : 0);
  CFArrayRef settings = CFArrayCreate(NULL, items, n, &kCFTypeArrayCallBacks);
  assert(settings);
  agc_tls_trust_verdict v = agc_tls_trust_settings_verdict(settings);
  CFRelease(settings);
  if (a) CFRelease(a);
  if (b) CFRelease(b);
  return v;
}

int main(void) {
  SecPolicyRef ssl = SecPolicyCreateSSL(true, NULL), basic = SecPolicyCreateBasicX509();
  assert(ssl && basic);
  const SInt32 root = (SInt32)kSecTrustSettingsResultTrustRoot, as_root = (SInt32)kSecTrustSettingsResultTrustAsRoot;
  const SInt32 deny = (SInt32)kSecTrustSettingsResultDeny, unspecified = (SInt32)kSecTrustSettingsResultUnspecified;
  const SInt32 sign = (SInt32)kSecTrustSettingsKeyUseSignCert, any = (SInt32)kSecTrustSettingsKeyUseAny;
  /* An empty array is "always trust"; a dictionary with no result means TrustRoot. */
  assert(verdict_of(NULL, NULL) == AGC_TLS_TRUST_ROOT);
  assert(verdict_of(constraint(NULL, NULL, NULL, NULL, NULL), NULL) == AGC_TLS_TRUST_ROOT);
  assert(verdict_of(constraint(ssl, &root, NULL, NULL, NULL), NULL) == AGC_TLS_TRUST_ROOT);
  assert(verdict_of(constraint(ssl, &as_root, NULL, NULL, NULL), NULL) == AGC_TLS_TRUST_ROOT);
  assert(verdict_of(constraint(ssl, &root, NULL, NULL, &any), NULL) == AGC_TLS_TRUST_ROOT);
  /* Deny, also a narrow one, and it wins over a grant in any order. */
  assert(verdict_of(constraint(ssl, &deny, NULL, NULL, NULL), NULL) == AGC_TLS_TRUST_DENIED);
  assert(verdict_of(constraint(NULL, &root, NULL, NULL, NULL), constraint(ssl, &deny, CFSTR("a.example"), NULL, NULL)) ==
         AGC_TLS_TRUST_DENIED);
  /* Narrow grants (host, application, key use, even certificate signing) and Unspecified give no verdict. */
  assert(verdict_of(constraint(ssl, &root, CFSTR("a.example"), NULL, NULL), NULL) == AGC_TLS_TRUST_NONE);
  assert(verdict_of(constraint(ssl, &root, NULL, CFSTR("app"), NULL), NULL) == AGC_TLS_TRUST_NONE);
  assert(verdict_of(constraint(ssl, &root, NULL, NULL, &sign), NULL) == AGC_TLS_TRUST_NONE);
  assert(verdict_of(constraint(ssl, &unspecified, NULL, NULL, NULL), NULL) == AGC_TLS_TRUST_NONE);
  /* A policy other than TLS is ignored, a Deny included. */
  assert(verdict_of(constraint(basic, &deny, NULL, NULL, NULL), NULL) == AGC_TLS_TRUST_NONE);
  assert(verdict_of(constraint(basic, &root, NULL, NULL, NULL), NULL) == AGC_TLS_TRUST_NONE);
  CFRelease(ssl);
  CFRelease(basic);
  puts("tls trust darwin tests passed");
  return 0;
}
#else
int main(void) {
  puts("tls trust darwin tests skipped: not macOS");
  return 0;
}
#endif
