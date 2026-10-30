/*
 * The digest adapter over OpenSSL's EVP interface (digests, HMAC, Triple DES
 * CBC and CMAC), RAND_bytes and CRYPTO_memcmp, the same library that tls_openssl.c links (system OpenSSL 3
 * or the vendored one). Adapter layer, behind digest.h. Design:
 * docs/vm/15-layers.md §15.1.
 */
#include "digest.h"

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#if OPENSSL_VERSION_NUMBER < 0x30000000L || defined(LIBRESSL_VERSION_NUMBER)
#error "the VM needs OpenSSL 3.0 or newer (LibreSSL is not supported): install the OpenSSL 3 development files or build with AGENTICA_OPENSSL=vendored"
#endif

struct agc_sha256_stream {
  EVP_MD_CTX *ctx;
};

static bool digest_ready(void) {
  /* The same init as the TLS adapter: no openssl.cnf (a system build would otherwise read it on first use) and no
     atexit cleanup, which could run while another scheduler still hashes. After the first call it is a cheap check. */
  if (OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG | OPENSSL_INIT_NO_ATEXIT, NULL) != 1) {
    ERR_clear_error();
    return false;
  }
  return true;
}

/* EVP_Digest writes at most EVP_MAX_MD_SIZE bytes, so out never overflows. */
_Static_assert(EVP_MAX_MD_SIZE <= AGC_DIGEST_MAX_BYTES, "AGC_DIGEST_MAX_BYTES must hold any EVP digest");

/* The method of a kind. The switch has no default, so -Wswitch flags a new kind that is not added here. */
static const EVP_MD *digest_method(agc_digest_kind kind) {
  switch (kind) {
    case AGC_DIGEST_MD5: return EVP_md5();
    case AGC_DIGEST_SHA1: return EVP_sha1();
    case AGC_DIGEST_SHA256: return EVP_sha256();
    case AGC_DIGEST_SHA512: return EVP_sha512();
  }
  return NULL;
}

size_t agc_digest(agc_digest_kind kind, const unsigned char *data, size_t n, unsigned char out[AGC_DIGEST_MAX_BYTES]) {
  static const unsigned char none = 0;
  /* The default provider has all four, MD5 and SHA-1 included (the legacy provider, which no-legacy leaves out of the
     vendored build, holds only older hashes such as MD4). A FIPS-only system OpenSSL has no MD5 or SHA-1: the fetch
     inside EVP_Digest fails and the call returns 0. */
  const EVP_MD *md = digest_method(kind);
  unsigned int len = 0;
  bool done = md && digest_ready() && EVP_Digest(n ? data : &none, n, out, &len, md, NULL) == 1 && len > 0;
  /* A failure leaves errors in this thread's OpenSSL queue; drop them so a later TLS call on it reads only its own. */
  if (!done) ERR_clear_error();
  return done ? len : 0;
}

size_t agc_hmac(agc_digest_kind kind, const unsigned char *key, size_t key_n, const unsigned char *data, size_t n,
                unsigned char out[AGC_DIGEST_MAX_BYTES]) {
  static const unsigned char none = 0;
  const EVP_MD *md = digest_method(kind);
  bool done = md && digest_ready();
  /* The HMAC provider hands the key length to HMAC_Init_ex as an int, and a Bytes key has no size cap, so a key of
     2^31 bytes or more would fail or be cut. RFC 2104 hashes a key longer than the block first and MACs with the
     digest, so doing that here gives the same MAC for every length and keeps the length OpenSSL sees small. */
  unsigned char short_key[EVP_MAX_MD_SIZE];
  bool hashed = false;
  if (done && key_n > (size_t)EVP_MD_get_block_size(md)) {
    unsigned int short_n = 0;
    done = EVP_Digest(key, key_n, short_key, &short_n, md, NULL) == 1 && short_n > 0;
    key = short_key;
    key_n = short_n;
    hashed = true;
  }
  size_t len = 0;
  /* EVP_Q_mac does the fetch, init and final in one call. Its key goes to EVP_MAC_init, which reads a NULL key as
     "keep the key already set", so an empty key is passed as a pointer to no bytes, never as NULL. */
  done = done &&
         EVP_Q_mac(NULL, "HMAC", NULL, EVP_MD_get0_name(md), NULL, key_n ? key : &none, key_n, n ? data : &none, n,
                   out, AGC_DIGEST_MAX_BYTES, &len) != NULL &&
         len > 0;
  /* The digest of the key is as secret as the key. */
  if (hashed) OPENSSL_cleanse(short_key, sizeof short_key);
  if (!done) ERR_clear_error();
  return done ? len : 0;
}

agc_sha256_stream *agc_sha256_begin(void) {
  if (!digest_ready()) return NULL;
  agc_sha256_stream *stream = malloc(sizeof *stream);
  if (!stream) {
    ERR_clear_error();
    return NULL;
  }
  stream->ctx = EVP_MD_CTX_new();
  if (!stream->ctx || EVP_DigestInit_ex(stream->ctx, EVP_sha256(), NULL) != 1) {
    EVP_MD_CTX_free(stream->ctx);
    free(stream);
    ERR_clear_error();
    return NULL;
  }
  return stream;
}

bool agc_sha256_update(agc_sha256_stream *stream, const unsigned char *data, size_t n) {
  /* The file hash never feeds an empty chunk, but an empty update is defined to succeed. */
  if (!stream || (n && !data)) return false;
  if (n == 0) return true;
  if (EVP_DigestUpdate(stream->ctx, data, n) != 1) {
    ERR_clear_error();
    return false;
  }
  return true;
}

bool agc_sha256_final(agc_sha256_stream *stream, unsigned char out[AGC_SHA256_BYTES]) {
  unsigned int len = 0;
  if (!stream || EVP_DigestFinal_ex(stream->ctx, out, &len) != 1 || len != AGC_SHA256_BYTES) {
    ERR_clear_error();
    return false;
  }
  return true;
}

void agc_sha256_free(agc_sha256_stream *stream) {
  if (!stream) return;
  EVP_MD_CTX_free(stream->ctx);
  free(stream);
}

bool agc_secure_random(unsigned char *out, size_t n) {
  if (n == 0) return true;
  /* RAND_bytes takes an int count; it returns 1 only when every byte came from a seeded generator (0 or -1 else). */
  bool done = n <= INT_MAX && digest_ready() && RAND_bytes(out, (int)n) == 1;
  if (!done) ERR_clear_error();
  return done;
}

bool agc_secure_equal(const unsigned char *a, const unsigned char *b, size_t n) {
  /* CRYPTO_memcmp gives 0 for equal bytes and nonzero otherwise, not an order; it reads all n bytes of both. */
  return n == 0 || CRYPTO_memcmp(a, b, n) == 0;
}

/* The 24-byte DES-EDE3 key of a 16- or 24-byte key into out: a two-key key K1 K2 runs as K1 K2 K1 (NIST SP 800-67
   keying option 2). False for any other length, and out is then not written. */
static bool des_ede3_key(const unsigned char *key, size_t key_n, unsigned char out[24]) {
  if (key_n != 16 && key_n != 24) return false;
  memcpy(out, key, key_n);
  if (key_n == 16) memcpy(out + 16, key, 8);
  return true;
}

/* EVP_CipherUpdate takes an int length and a Bytes value has no size cap, so the data goes in chunks of at most this
   many bytes: a multiple of the block, well below INT_MAX. CBC carries its state from one update to the next. */
#define CIPHER_CHUNK ((size_t)1 << 30)
_Static_assert(CIPHER_CHUNK % AGC_DES_BLOCK_BYTES == 0 && CIPHER_CHUNK <= INT_MAX, "CIPHER_CHUNK must be whole blocks");

bool agc_des_ede3_cbc(bool encrypt, const unsigned char *key, size_t key_n, const unsigned char *iv,
                      const unsigned char *data, size_t n, unsigned char *out) {
  unsigned char full_key[24];
  if (n % AGC_DES_BLOCK_BYTES != 0 || !des_ede3_key(key, key_n, full_key)) return false;
  /* DES-EDE3-CBC is in the default provider; no-legacy, which the vendored build sets, drops only single DES. */
  EVP_CIPHER_CTX *ctx = digest_ready() ? EVP_CIPHER_CTX_new() : NULL;
  /* Padding off: the caller passes whole blocks, so every update writes as many bytes as it reads and the final
     writes none. */
  bool done = ctx && EVP_CipherInit_ex2(ctx, EVP_des_ede3_cbc(), full_key, iv, encrypt ? 1 : 0, NULL) == 1 &&
              EVP_CIPHER_CTX_set_padding(ctx, 0) == 1;
  OPENSSL_cleanse(full_key, sizeof full_key);
  for (size_t at = 0; done && at < n;) {
    size_t chunk = n - at < CIPHER_CHUNK ? n - at : CIPHER_CHUNK;
    int got = 0;
    done = EVP_CipherUpdate(ctx, out + at, &got, data + at, (int)chunk) == 1 && (size_t)got == chunk;
    at += chunk;
  }
  unsigned char last[AGC_DES_BLOCK_BYTES];
  int tail = 0;
  done = done && EVP_CipherFinal_ex(ctx, last, &tail) == 1 && tail == 0;
  /* EVP_CIPHER_CTX_free wipes the key schedule it holds. */
  EVP_CIPHER_CTX_free(ctx);
  if (!done) ERR_clear_error();
  return done;
}

size_t agc_cmac(agc_cmac_cipher cipher, const unsigned char *key, size_t key_n, const unsigned char *data, size_t n,
                unsigned char out[AGC_CMAC_MAX_BYTES]) {
  static const unsigned char none = 0;
  unsigned char full_key[24];
  const char *name = NULL;
  /* The switch has no default, so -Wswitch flags a new cipher that is not added here. */
  switch (cipher) {
    case AGC_CMAC_AES:
      name = key_n == 16 ? "AES-128-CBC" : key_n == 24 ? "AES-192-CBC" : key_n == 32 ? "AES-256-CBC" : NULL;
      break;
    case AGC_CMAC_DES_EDE3:
      if (des_ede3_key(key, key_n, full_key)) {
        name = "DES-EDE3-CBC";
        key = full_key;
        key_n = sizeof full_key;
      }
      break;
  }
  if (!name) return 0;
  size_t len = 0;
  /* EVP_Q_mac fetches the CMAC, sets the cipher (the CMAC provider's settable parameter is OSSL_MAC_PARAM_CIPHER), and
     runs init, update and final. It takes size_t lengths throughout, and the key length is checked above. */
  bool done = digest_ready() &&
              EVP_Q_mac(NULL, "CMAC", NULL, name, NULL, key, key_n, n ? data : &none, n, out, AGC_CMAC_MAX_BYTES,
                        &len) != NULL &&
              len > 0;
  if (key == full_key) OPENSSL_cleanse(full_key, sizeof full_key);
  if (!done) ERR_clear_error();
  return done ? len : 0;
}
