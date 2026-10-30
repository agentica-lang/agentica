/*
 * The crypto builtins (agc_crypto_builtins): the Digest hashes of bytes (MD5,
 * SHA-1, SHA-256, SHA-512, as bytes and as hex), their HMACs (RFC 2104) and
 * the constant-time HMAC.secure_compare, the SecureRandom draws, Triple DES
 * CBC and AES-256-GCM (Cipher), CMAC, PBKDF2 and scrypt (KDF), and the Base64
 * and Digest.hexencode/hexdecode text forms of bytes in plain C. All but the
 * text forms come from the OpenSSL adapter (digest.h). Service layer. Design:
 * docs/vm/02-reference-behavior.md §2.3; Base64 and hex follow RFC 4648 and
 * Ruby's Base64 module, SecureRandom.uuid RFC 9562 §5.4.
 */
#include "services.h"
#include "digest.h"

#include <stdint.h>
#include <string.h>

/* Ruby's encode64 (pack "m") writes 45 bytes, 60 characters, per line, each line ending in a newline. */
#define B64_LINE 60

/* The alphabets of RFC 4648: §4 (base64) and §5 (base64url). */
static const char b64_standard[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static const char b64_urlsafe[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
static const char hex_digits[] = "0123456789abcdef";

/* The algorithm of a key derivation, for kdf_compute. */
typedef struct {
  bool scrypt;
  uint64_t iterations; /* PBKDF2 */
  uint64_t n, r, p;    /* scrypt */
} kdf_params;

/* The message of a failed hash, by agc_digest_kind. */
static const char *const digest_missing[] = {
  [AGC_DIGEST_MD5] = "MD5 is not available",
  [AGC_DIGEST_SHA1] = "SHA-1 is not available",
  [AGC_DIGEST_SHA256] = "SHA-256 is not available",
  [AGC_DIGEST_SHA512] = "SHA-512 is not available",
};

/* The message of a failed HMAC, by agc_digest_kind. Only the kinds with an HMAC builtin have an entry. */
static const char *const hmac_missing[] = {
  [AGC_DIGEST_SHA256] = "HMAC-SHA256 is not available",
  [AGC_DIGEST_SHA512] = "HMAC-SHA512 is not available",
};

/* A String of len ASCII bytes for the caller to fill before it stores it anywhere, or the run's shared empty String. */
static agc_string *ascii_string(agc_vm *vm, size_t len) {
  return len ? agc_new_string(len, len) : vm->rt->empty_string;
}

/* Base64 of n bytes in the given alphabet. pad writes the '=' of a short last group (RFC 4648 §3.2); lines puts a
   newline after every B64_LINE characters and after the last one, as Ruby's encode64 does (nothing for no bytes). */
static agc_value b64_encode(agc_vm *vm, const uint8_t *in, size_t n, const char *alphabet, bool pad, bool lines) {
  size_t rest = n % 3;
  size_t len = agc_size_add(agc_size_mul(n / 3, 4), rest == 0 ? 0 : pad ? 4 : rest + 1);
  if (lines) len = agc_size_add(len, len / B64_LINE + (len % B64_LINE != 0));
  agc_string *text = ascii_string(vm, len);
  char *out = text->data;
  size_t o = 0, column = 0;
  for (size_t i = 0; i < n; i += 3) {
    uint32_t group = (uint32_t)in[i] << 16;
    if (i + 1 < n) group |= (uint32_t)in[i + 1] << 8;
    if (i + 2 < n) group |= in[i + 2];
    size_t chars = n - i >= 3 ? 4 : n - i + 1;
    for (size_t k = 0; k < 4; k++) {
      if (k < chars) out[o++] = alphabet[(group >> (18 - 6 * k)) & 63];
      else if (pad) out[o++] = '=';
    }
    /* 60 is a multiple of 4, so a line ends only between groups. */
    column += 4;
    if (lines && (column == B64_LINE || n - i <= 3)) {
      out[o++] = '\n';
      column = 0;
    }
  }
  return agc_string_value(text);
}

/* The value of a base64 character, or -1. url also takes the base64url '-' and '_', as Ruby's urlsafe_decode64 does
   (it maps them to '+' and '/', which stay valid too). */
static int b64_digit(uint8_t c, bool url) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+' || (url && c == '-')) return 62;
  if (c == '/' || (url && c == '_')) return 63;
  return -1;
}

/* Ruby's strict_decode64 (unpack "m0" in pack.c): whole groups of four, '=' only as the last one or two characters
   of the text, nothing outside the alphabet, and zero bits after the last byte. out has room for n bytes. Returns
   the number of bytes, or SIZE_MAX for invalid text. */
static size_t b64_strict(const uint8_t *s, size_t n, bool url, uint8_t *out) {
  size_t i = 0, o = 0;
  int a = -1, b = -1, c = 0, d = 0;
  while (i < n) {
    a = b64_digit(s[i++], url);
    if (i >= n || a < 0) return SIZE_MAX;
    b = b64_digit(s[i++], url);
    if (i >= n || b < 0) return SIZE_MAX;
    c = d = -1;
    if (s[i] == '=') {
      if (i + 2 == n && s[i + 1] == '=') break;
      return SIZE_MAX;
    }
    c = b64_digit(s[i++], url);
    if (i >= n || c < 0) return SIZE_MAX;
    if (i + 1 == n && s[i] == '=') break;
    d = b64_digit(s[i++], url);
    if (d < 0) return SIZE_MAX;
    out[o++] = (uint8_t)(a << 2 | b >> 4);
    out[o++] = (uint8_t)(b << 4 | c >> 2);
    out[o++] = (uint8_t)(c << 6 | d);
  }
  if (c < 0) {
    if (b & 0xf) return SIZE_MAX;
    out[o++] = (uint8_t)(a << 2 | b >> 4);
  } else if (d < 0) {
    if (c & 0x3) return SIZE_MAX;
    out[o++] = (uint8_t)(a << 2 | b >> 4);
    out[o++] = (uint8_t)(b << 4 | c >> 2);
  }
  return o;
}

/* Ruby's decode64 (unpack "m" in pack.c), which never fails: a character outside the alphabet is skipped, a '=' in
   the first two places of a group is skipped and one in the last two places ends the text, a last group of two or
   three characters gives one or two bytes (its spare bits are dropped) and a lone last character gives nothing.
   out has room for n bytes. Returns the number of bytes. */
static size_t b64_lenient(const uint8_t *s, size_t n, uint8_t *out) {
  size_t i = 0, o = 0;
  int a = -1, b = -1, c = -1, d = -1;
  while (i < n) {
    a = b = c = d = -1;
    while (i < n && (a = b64_digit(s[i], false)) < 0) i++;
    if (i >= n) break;
    i++;
    while (i < n && (b = b64_digit(s[i], false)) < 0) i++;
    if (i >= n) break;
    i++;
    while (i < n && s[i] != '=' && (c = b64_digit(s[i], false)) < 0) i++;
    if (i >= n || s[i] == '=') break;
    i++;
    while (i < n && s[i] != '=' && (d = b64_digit(s[i], false)) < 0) i++;
    if (i >= n || s[i] == '=') break;
    i++;
    out[o++] = (uint8_t)(a << 2 | b >> 4);
    out[o++] = (uint8_t)(b << 4 | c >> 2);
    out[o++] = (uint8_t)(c << 6 | d);
    a = -1;
  }
  if (a >= 0 && b >= 0) {
    out[o++] = (uint8_t)(a << 2 | b >> 4);
    if (c >= 0) out[o++] = (uint8_t)(b << 4 | c >> 2);
  }
  return o;
}

/* The n bytes at data as a new Bytes, or the empty one. */
static agc_value byte_value(const uint8_t *data, size_t n) { return agc_bytes_value(agc_make_bytes(data, n)); }

/* Base64.encode64(data): RFC 4648 base64 with padding, in lines of 60 characters that each end in a newline. Every
   text-form row charges AGC_COST_SIZE, since the work grows with the argument, and runs without the shared lock, since
   it reads only its argument. */
static agc_value builtin_encode64(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  size_t n;
  const uint8_t *bytes = agc_bytes_data(vm, args[0], &n);
  return b64_encode(vm, bytes, n, b64_standard, true, true);
}

/* Base64.strict_encode64(data): RFC 4648 base64 with padding, on one line with no newline. */
static agc_value builtin_strict_encode64(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  size_t n;
  const uint8_t *bytes = agc_bytes_data(vm, args[0], &n);
  return b64_encode(vm, bytes, n, b64_standard, true, false);
}

/* Base64.urlsafe_encode64(data, padding): the base64url alphabet of RFC 4648 §5, with or without the '=' padding. */
static agc_value builtin_urlsafe_encode64(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  size_t n;
  const uint8_t *bytes = agc_bytes_data(vm, args[0], &n);
  return b64_encode(vm, bytes, n, b64_urlsafe, agc_as_bool(vm, args[1]), false);
}

/* Base64.decode64(text): the bytes of base64 text, read as Ruby's decode64 reads it (b64_lenient); never an error. */
static agc_value builtin_decode64(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  uint8_t *out = agc_alloc_atomic(s->bytes ? s->bytes : 1);
  return byte_value(out, b64_lenient((const uint8_t *)s->data, s->bytes, out));
}

/* Base64.strict_decode64(text): ok(bytes) of padded base64, or error("invalid base64") (b64_strict). */
static agc_value builtin_strict_decode64(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  uint8_t *out = agc_alloc_atomic(s->bytes ? s->bytes : 1);
  size_t n = b64_strict((const uint8_t *)s->data, s->bytes, false, out);
  if (n == SIZE_MAX) return agc_error_value("invalid base64");
  return agc_result_value(true, byte_value(out, n));
}

/* Base64.urlsafe_decode64(text): as in Ruby, text that does not end in '=' and whose length is not a multiple of
   four gets the missing '=' first; then it decodes strictly, in either alphabet. The padded last group is decoded
   from a local copy: strict text has no '=' before its last group, so the whole groups before it decode alone. */
static agc_value builtin_urlsafe_decode64(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  const uint8_t *text = (const uint8_t *)s->data;
  size_t n = s->bytes, rest = n % 4, got;
  uint8_t *out = agc_alloc_atomic(agc_size_add(n, 3));
  /* Ruby counts characters, not bytes; they differ only for text with a non-ASCII byte, which fails either way. */
  if (rest != 0 && text[n - 1] != '=') {
    size_t whole = n - rest;
    uint8_t last[4] = {'=', '=', '=', '='};
    memcpy(last, text + whole, rest);
    got = memchr(text, '=', whole) ? SIZE_MAX : b64_strict(text, whole, true, out);
    size_t tail = got == SIZE_MAX ? SIZE_MAX : b64_strict(last, 4, true, out + got);
    got = tail == SIZE_MAX ? SIZE_MAX : got + tail;
  } else {
    got = b64_strict(text, n, true, out);
  }
  if (got == SIZE_MAX) return agc_error_value("invalid base64");
  return agc_result_value(true, byte_value(out, got));
}

/* Digest.hexencode(data): two lowercase hex digits per byte, as Ruby's Digest.hexencode writes them. Digest.hexdecode
   is Agentica's own inverse: Ruby has no named hex decoder. */
static agc_value hex_text(agc_vm *vm, const uint8_t *bytes, size_t n) {
  agc_string *text = ascii_string(vm, agc_size_mul(n, 2));
  for (size_t k = 0; k < n; k++) {
    text->data[2 * k] = hex_digits[bytes[k] >> 4];
    text->data[2 * k + 1] = hex_digits[bytes[k] & 15];
  }
  return agc_string_value(text);
}

static agc_value builtin_hexencode(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  size_t n;
  const uint8_t *bytes = agc_bytes_data(vm, args[0], &n);
  return hex_text(vm, bytes, n);
}

static int hex_value(uint8_t c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/* Digest.hexdecode(text): ok(bytes) of an even number of hex digits in either case, or error("invalid hex") for an
   odd length or any other character (no spaces, no "0x"). */
static agc_value builtin_hexdecode(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  const uint8_t *text = (const uint8_t *)s->data;
  if (s->bytes % 2) return agc_error_value("invalid hex");
  size_t n = s->bytes / 2;
  uint8_t *out = agc_alloc_atomic(n ? n : 1);
  for (size_t k = 0; k < n; k++) {
    int high = hex_value(text[2 * k]), low = hex_value(text[2 * k + 1]);
    if (high < 0 || low < 0) return agc_error_value("invalid hex");
    out[k] = (uint8_t)(high << 4 | low);
  }
  return agc_result_value(true, byte_value(out, n));
}

/* The calls into libcrypto (digest_compute, hmac_compute, secure_draw, cipher_compute, cmac_compute, gcm_compute and
   kdf_compute below) each have their own out-of-line function whose only callees are the adapter, memset and
   agc_fail. vm/tools/tsan.supp names these seven and nothing else, so a TSan report about OpenSSL's fetch caches is
   suppressed while a race in the VM code around them (such as reading a list another task holds) is still reported.
   TSan unwinds by frame pointers, which libcrypto does not keep, so a report skips the adapter function and shows its
   caller first: these must stay real frames (noinline, and not a tail call). */
static __attribute__((noinline)) size_t digest_compute(agc_vm *vm, agc_digest_kind kind, const uint8_t *bytes, size_t n,
                                                       unsigned char out[AGC_DIGEST_MAX_BYTES], uint32_t span) {
  size_t len = agc_digest(kind, bytes, n, out);
  if (!len) agc_fail(vm, "RUNTIME-INTERNAL", digest_missing[kind], span);
  return len;
}

static __attribute__((noinline)) size_t hmac_compute(agc_vm *vm, agc_digest_kind kind, const uint8_t *key,
                                                     size_t key_n, const uint8_t *data, size_t n,
                                                     unsigned char out[AGC_DIGEST_MAX_BYTES], uint32_t span) {
  size_t len = agc_hmac(kind, key, key_n, data, n, out);
  if (!len) agc_fail(vm, "RUNTIME-INTERNAL", hmac_missing[kind], span);
  return len;
}

/* Digest.<kind>(data) and its _hexdigest form: the digest of the bytes, as bytes (Ruby's Digest::SHA256.digest) or
   as lowercase hex (hexdigest). The work grows with the data, so the rows charge AGC_COST_SIZE
   (docs/vm/10-io-scheduler.md §10.2.1). Like List.sort or String.from_bytes the call is not split: the task yields
   after it once the cost spends its turn. It runs without the shared lock, since it reads only its argument. */
static agc_value digest_value(agc_vm *vm, agc_value *args, uint32_t span, agc_digest_kind kind, bool hex) {
  size_t n;
  const uint8_t *bytes = agc_bytes_data(vm, args[0], &n);
  unsigned char digest[AGC_DIGEST_MAX_BYTES];
  size_t len = digest_compute(vm, kind, bytes, n, digest, span);
  return hex ? hex_text(vm, digest, len) : byte_value(digest, len);
}

/* HMAC.<kind>(key, data) and its _hexdigest form: the HMAC of the data under the key, as bytes (Ruby's
   OpenSSL::HMAC.digest) or as lowercase hex (hexdigest). Cost and lock as digest_value. */
static agc_value hmac_value(agc_vm *vm, agc_value *args, uint32_t span, agc_digest_kind kind, bool hex) {
  size_t key_n, n;
  const uint8_t *key = agc_bytes_data(vm, args[0], &key_n);
  const uint8_t *data = agc_bytes_data(vm, args[1], &n);
  unsigned char mac[AGC_DIGEST_MAX_BYTES];
  size_t len = hmac_compute(vm, kind, key, key_n, data, n, mac, span);
  return hex ? hex_text(vm, mac, len) : byte_value(mac, len);
}

/* Fills the n bytes at out from the secure random source. A failed draw stops the run: it never gives weak, partial
   or zero bytes in place of random ones. One of the libcrypto wrappers that vm/tools/tsan.supp names (see
   digest_compute). */
static __attribute__((noinline)) void secure_draw(agc_vm *vm, uint8_t *out, size_t n, uint32_t span) {
  if (!agc_secure_random(out, n)) agc_fail(vm, "RUNTIME-INTERNAL", "the secure random source failed", span);
}

/* SecureRandom.random_bytes(n) and hex(n) draw at most AGC_MAX_LIST_COUNT bytes (1 MiB), the bound of the other
   builtins that make a list from a count (List#*, Range#to_a, IO.read_bytes). Keys, salts and tokens are 16 to 64
   bytes; the bound makes a wrong count such as 10 ** 12 fail at the argument instead of asking for terabytes of
   memory. Ruby has no bound. */
static size_t secure_count(agc_vm *vm, agc_value arg, const char *bad_count, uint32_t span) {
  int64_t count = agc_as_int(vm, arg);
  if (count < 0 || count > AGC_MAX_LIST_COUNT) agc_fail(vm, "RUNTIME-INVALID-COUNT", bad_count, span + 1);
  return (size_t)count;
}

/* n bytes drawn into a GC-atomic scratch block, for SecureRandom.hex, which copies them into its text. */
static const uint8_t *secure_scratch(agc_vm *vm, size_t n, uint32_t span) {
  uint8_t *out = agc_alloc_atomic(n ? n : 1);
  secure_draw(vm, out, n, span);
  return out;
}

/* SecureRandom.random_bytes(n): n bytes from OpenSSL's CSPRNG (RAND_bytes), unlike the seeded Random. The rows charge
   AGC_COST_SIZE, since the work grows with n (the result's items), and run without the shared lock: OpenSSL 3 keeps
   one generator per thread. */
static agc_value builtin_random_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  size_t n = secure_count(vm, args[0], "SecureRandom.random_bytes needs n between 0 and 1048576", span);
  if (n == 0) return agc_bytes_value(agc_empty_bytes());
  /* Drawn straight into the result, so no second copy of the secret stays behind in a dead block. */
  agc_bytes *b = agc_new_bytes(n);
  secure_draw(vm, b->data, n, span);
  return agc_bytes_value(b);
}

/* SecureRandom.hex(n): n random bytes as 2n lowercase hex digits, as Ruby's. */
static agc_value builtin_random_hex(agc_vm *vm, agc_value *args, uint32_t span) {
  size_t n = secure_count(vm, args[0], "SecureRandom.hex needs n between 0 and 1048576", span);
  return hex_text(vm, secure_scratch(vm, n, span), n);
}

/* SecureRandom.uuid: a version 4 UUID (RFC 9562 §5.4), 122 random bits in the lowercase 8-4-4-4-12 form. */
static agc_value builtin_random_uuid(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  uint8_t b[16];
  secure_draw(vm, b, sizeof b, span);
  b[6] = (uint8_t)((b[6] & 0x0f) | 0x40); /* version 4 in the high nibble of byte 6 */
  b[8] = (uint8_t)((b[8] & 0x3f) | 0x80); /* variant 10xx in the high bits of byte 8 */
  agc_string *text = ascii_string(vm, 36);
  size_t o = 0;
  for (size_t k = 0; k < sizeof b; k++) {
    if (k == 4 || k == 6 || k == 8 || k == 10) text->data[o++] = '-';
    text->data[o++] = hex_digits[b[k] >> 4];
    text->data[o++] = hex_digits[b[k] & 15];
  }
  return agc_string_value(text);
}

/* HMAC.secure_compare(a, b): Ruby's OpenSSL.secure_compare, for checking a received MAC or token against the expected
   one. Like Ruby it compares the SHA-256 digests of the two values in constant time (CRYPTO_memcmp), so values of
   other lengths give false in a time that depends on the lengths only, never on the bytes or on where they differ.
   Equal digests then also need equal bytes, as Ruby's
   `&& a == b` does, so a SHA-256 collision cannot pass; that second compare runs only when the digests match, so its
   branch tells nothing the answer does not. The time grows with the lengths, which the row charges (AGC_COST_SIZE),
   and the call runs without the shared lock, as HMAC does. */
static agc_value builtin_secure_compare(agc_vm *vm, agc_value *args, uint32_t span) {
  size_t a_n, b_n;
  const uint8_t *a = agc_bytes_data(vm, args[0], &a_n);
  const uint8_t *b = agc_bytes_data(vm, args[1], &b_n);
  unsigned char a_digest[AGC_DIGEST_MAX_BYTES], b_digest[AGC_DIGEST_MAX_BYTES];
  size_t len = digest_compute(vm, AGC_DIGEST_SHA256, a, a_n, a_digest, span);
  digest_compute(vm, AGC_DIGEST_SHA256, b, b_n, b_digest, span);
  bool same = agc_secure_equal(a_digest, b_digest, len);
  return agc_bool(same && a_n == b_n && agc_secure_equal(a, b, a_n));
}

/* Runs Triple DES CBC over the n bytes at data into out, whose bytes the caller checked (agc_des_ede3_cbc). A library
   failure stops the run and leaves no partial output: out is cleared first. One of the libcrypto wrappers that
   vm/tools/tsan.supp names (see digest_compute). */
static __attribute__((noinline)) void cipher_compute(agc_vm *vm, bool encrypt, const uint8_t *key, size_t key_n,
                                                     const uint8_t *iv, const uint8_t *data, size_t n, uint8_t *out,
                                                     uint32_t span) {
  if (!agc_des_ede3_cbc(encrypt, key, key_n, iv, data, n, out)) {
    memset(out, 0, n);
    agc_fail(vm, "RUNTIME-INTERNAL", "Triple DES is not available", span);
  }
}

/* Writes the CMAC tag of the n bytes at data into out and returns its length (agc_cmac); the caller checked the key
   size. A library failure stops the run. One of the libcrypto wrappers that vm/tools/tsan.supp names (see
   digest_compute). */
static __attribute__((noinline)) size_t cmac_compute(agc_vm *vm, agc_cmac_cipher cipher, const uint8_t *key,
                                                     size_t key_n, const uint8_t *data, size_t n,
                                                     unsigned char out[AGC_CMAC_MAX_BYTES], uint32_t span) {
  size_t len = agc_cmac(cipher, key, key_n, data, n, out);
  if (!len) agc_fail(vm, "RUNTIME-INTERNAL", "CMAC is not available", span);
  return len;
}

/* Cipher.des_ede3_cbc_encrypt(key, iv, data) and _decrypt: Triple DES (OpenSSL's des-ede3-cbc) with no padding, for
   payment formats that need it, never for new designs. A key that is not 16 (two-key) or 24 bytes, an IV that is not
   8 bytes or data that is not whole 8-byte blocks is an error Result, checked before any work, so there is never
   partial output; a caller pads the data as its scheme says. Cost and lock as digest_value. */
static agc_value des_ede3_cbc_value(agc_vm *vm, agc_value *args, uint32_t span, bool encrypt) {
  size_t key_n, iv_n, n;
  const uint8_t *key = agc_bytes_data(vm, args[0], &key_n);
  const uint8_t *iv = agc_bytes_data(vm, args[1], &iv_n);
  const uint8_t *data = agc_bytes_data(vm, args[2], &n);
  if (key_n != 16 && key_n != 24) return agc_error_value("Triple DES needs a key of 16 or 24 bytes");
  if (iv_n != AGC_DES_BLOCK_BYTES) return agc_error_value("Triple DES CBC needs an iv of 8 bytes");
  if (n % AGC_DES_BLOCK_BYTES != 0) return agc_error_value("Triple DES CBC needs data in whole blocks of 8 bytes");
  if (n == 0) return agc_result_value(true, agc_bytes_value(agc_empty_bytes()));
  agc_bytes *out = agc_new_bytes(n);
  cipher_compute(vm, encrypt, key, key_n, iv, data, n, out->data, span);
  return agc_result_value(true, agc_bytes_value(out));
}

static agc_value builtin_des_ede3_cbc_encrypt(agc_vm *vm, agc_value *args, uint32_t span) {
  return des_ede3_cbc_value(vm, args, span, true);
}

static agc_value builtin_des_ede3_cbc_decrypt(agc_vm *vm, agc_value *args, uint32_t span) {
  return des_ede3_cbc_value(vm, args, span, false);
}

/* CMAC.aes(key, data) and CMAC.des_ede3(key, data): the full CMAC tag (NIST SP 800-38B) of the data, 16 bytes for AES
   (the key size picks AES-128, -192 or -256) and 8 for Triple DES; a caller that needs a shorter MAC takes the first
   bytes, and checks a received tag with HMAC.secure_compare. A wrong key length is an error Result. Cost and lock as
   digest_value. */
static agc_value cmac_value(agc_vm *vm, agc_value *args, uint32_t span, agc_cmac_cipher cipher) {
  size_t key_n, n;
  const uint8_t *key = agc_bytes_data(vm, args[0], &key_n);
  const uint8_t *data = agc_bytes_data(vm, args[1], &n);
  if (cipher == AGC_CMAC_AES && key_n != 16 && key_n != 24 && key_n != 32)
    return agc_error_value("AES needs a key of 16, 24 or 32 bytes");
  if (cipher == AGC_CMAC_DES_EDE3 && key_n != 16 && key_n != 24)
    return agc_error_value("Triple DES needs a key of 16 or 24 bytes");
  unsigned char tag[AGC_CMAC_MAX_BYTES];
  size_t len = cmac_compute(vm, cipher, key, key_n, data, n, tag, span);
  return agc_result_value(true, byte_value(tag, len));
}

static agc_value builtin_cmac_aes(agc_vm *vm, agc_value *args, uint32_t span) {
  return cmac_value(vm, args, span, AGC_CMAC_AES);
}

static agc_value builtin_cmac_des_ede3(agc_vm *vm, agc_value *args, uint32_t span) {
  return cmac_value(vm, args, span, AGC_CMAC_DES_EDE3);
}

/* Runs AES-256-GCM over the n bytes at data into out (agc_aes_256_gcm), whose sizes the caller checked, and returns
   false for a decrypt whose tag does not match; the adapter has then wiped out. A library failure stops the run. One
   of the libcrypto wrappers that vm/tools/tsan.supp names (see digest_compute). */
static __attribute__((noinline)) bool gcm_compute(agc_vm *vm, bool encrypt, const uint8_t *key, const uint8_t *iv,
                                                  const uint8_t *aad, size_t aad_n, const uint8_t *data, size_t n,
                                                  uint8_t *out, unsigned char tag[AGC_GCM_TAG_BYTES], uint32_t span) {
  agc_aead_status status = agc_aes_256_gcm(encrypt, key, iv, aad, aad_n, data, n, out, tag);
  if (status == AGC_AEAD_FAILED) agc_fail(vm, "RUNTIME-INTERNAL", "AES-256-GCM is not available", span);
  return status == AGC_AEAD_DONE;
}

/* Cipher.aes_256_gcm_encrypt(key, iv, data, auth_data) and _decrypt: AES-256-GCM (OpenSSL's aes-256-gcm), the
   authenticated cipher. Encrypting gives the ciphertext with the 16-byte tag appended, the form Python's AESGCM, Go's
   Seal and WebCrypto give, so a caller cannot drop the tag; decrypting takes that form back and gives the plaintext
   only when the tag matches the key, IV, data and auth_data, else an error Result and never partial plaintext. A key
   that is not 32 bytes, an IV that is not 12 bytes, a decrypt input shorter than the tag or more than 2^36 - 32 bytes
   to encrypt is an error Result, checked before any work. Cost and lock as digest_value. */
static agc_value aes_256_gcm_value(agc_vm *vm, agc_value *args, uint32_t span, bool encrypt) {
  size_t key_n, iv_n, n, aad_n;
  const uint8_t *key = agc_bytes_data(vm, args[0], &key_n);
  const uint8_t *iv = agc_bytes_data(vm, args[1], &iv_n);
  const uint8_t *data = agc_bytes_data(vm, args[2], &n);
  const uint8_t *aad = agc_bytes_data(vm, args[3], &aad_n);
  if (key_n != AGC_GCM_KEY_BYTES) return agc_error_value("AES-256-GCM needs a key of 32 bytes");
  if (iv_n != AGC_GCM_IV_BYTES) return agc_error_value("AES-256-GCM needs an iv of 12 bytes");
  if (!encrypt && n < AGC_GCM_TAG_BYTES)
    return agc_error_value("AES-256-GCM needs the ciphertext with its 16-byte tag at the end");
  size_t body = encrypt ? n : n - AGC_GCM_TAG_BYTES;
  if ((uint64_t)body > AGC_GCM_MAX_BYTES) return agc_error_value("AES-256-GCM takes at most 2^36 - 32 bytes per iv");
  if (encrypt) {
    /* The ciphertext and then the tag, written in place. */
    agc_bytes *out = agc_new_bytes(n + AGC_GCM_TAG_BYTES);
    (void)gcm_compute(vm, true, key, iv, aad, aad_n, data, n, out->data, out->data + n, span);
    return agc_result_value(true, agc_bytes_value(out));
  }
  unsigned char tag[AGC_GCM_TAG_BYTES];
  memcpy(tag, data + body, sizeof tag);
  agc_bytes *out = body ? agc_new_bytes(body) : NULL;
  if (!gcm_compute(vm, false, key, iv, aad, aad_n, data, body, out ? out->data : NULL, tag, span))
    return agc_error_value("AES-256-GCM: the tag does not match the key, iv, data and auth_data");
  return agc_result_value(true, agc_bytes_value(out ? out : agc_empty_bytes()));
}

static agc_value builtin_aes_256_gcm_encrypt(agc_vm *vm, agc_value *args, uint32_t span) {
  return aes_256_gcm_value(vm, args, span, true);
}

static agc_value builtin_aes_256_gcm_decrypt(agc_vm *vm, agc_value *args, uint32_t span) {
  return aes_256_gcm_value(vm, args, span, false);
}

/* The most bytes of a KDF password, salt or output: 1 MiB, the cap of the SecureRandom counts. Real ones are tens of
   bytes, and it keeps the int lengths OpenSSL takes for the password and the salt far away. */
#define KDF_MAX_BYTES ((size_t)AGC_MAX_LIST_COUNT)
/* The most memory scrypt may take, 128 * r * (n + p + 2) bytes of native memory outside the GC: the default cap of
   OpenSSL 3's scrypt provider (1025 MiB), which n = 2^20 with r = 8 (RFC 7914 §12, the last vector) fits. */
#define SCRYPT_MAX_MEMORY ((uint64_t)1025 * 1024 * 1024)
/* A KDF runs inside one builtin call on its scheduler, where neither --max-steps nor a signal can stop it, so its work
   is capped before the call, so the worst valid call takes tens of seconds at most on one core: about 80 and 32
   times the OWASP password storage figures (PBKDF2-HMAC-SHA256 with 600000 iterations of one 32-byte block; scrypt
   with n = 2^17, r = 8, p = 1).
   PBKDF2's work is iterations * ceil(length / 32). scrypt's is r * p * (n + 16): each of the p lanes mixes n blocks of
   128 * r bytes, and PBKDF2 makes and reads each lane's block too, which costs about as much as 16 more blocks (a
   call with n = 2 and a large p measured about 9 block-times per lane). */
#define PBKDF2_MAX_WORK ((uint64_t)50000000)
#define SCRYPT_MAX_WORK ((uint64_t)1 << 25)

/* Derives out_n bytes into out (agc_pbkdf2_hmac_sha256 or agc_scrypt), whose parameters the caller checked. A library
   failure stops the run; the adapter has then wiped out. One of the libcrypto wrappers that vm/tools/tsan.supp names
   (see digest_compute). */
static __attribute__((noinline)) void kdf_compute(agc_vm *vm, const kdf_params *kdf, const uint8_t *password,
                                                  size_t password_n, const uint8_t *salt, size_t salt_n, uint8_t *out,
                                                  size_t out_n, uint32_t span) {
  bool done = kdf->scrypt ? agc_scrypt(password, password_n, salt, salt_n, kdf->n, kdf->r, kdf->p, SCRYPT_MAX_MEMORY,
                                       out, out_n)
                          : agc_pbkdf2_hmac_sha256(password, password_n, salt, salt_n, kdf->iterations, out, out_n);
  if (!done)
    agc_fail(vm, "RUNTIME-INTERNAL", kdf->scrypt ? "scrypt is not available" : "PBKDF2 is not available", span);
}

/* The shared end of the KDF builtins: checks the password, salt and length (args 0, 1 and the last, at length_at),
   derives the key and charges the work, which grows with the iterations or the memory, not with the arguments that
   AGC_COST_SIZE counts. work is that work in bytes hashed, saturated. */
static agc_value kdf_value(agc_vm *vm, agc_value *args, size_t length_at, const kdf_params *kdf, uint64_t work,
                           uint32_t span) {
  size_t password_n, salt_n;
  const uint8_t *password = agc_bytes_data(vm, args[0], &password_n);
  const uint8_t *salt = agc_bytes_data(vm, args[1], &salt_n);
  int64_t length = agc_as_int(vm, args[length_at]);
  if (password_n > KDF_MAX_BYTES || salt_n > KDF_MAX_BYTES)
    return agc_error_value("a KDF password and salt have at most 1048576 bytes each");
  if (length < 1 || (uint64_t)length > KDF_MAX_BYTES) return agc_error_value("a KDF length is 1 to 1048576 bytes");
  uint64_t blocks = ((uint64_t)length + AGC_SHA256_BYTES - 1) / AGC_SHA256_BYTES, rounds;
  if (!kdf->scrypt && (__builtin_mul_overflow(kdf->iterations, blocks, &rounds) || rounds > PBKDF2_MAX_WORK))
    return agc_error_value("KDF.pbkdf2_hmac_sha256 needs iterations * ceil(length / 32) of at most 50000000");
  agc_bytes *out = agc_new_bytes((size_t)length);
  kdf_compute(vm, kdf, password, password_n, salt, salt_n, out->data, (size_t)length, span);
  uint64_t total;
  if (__builtin_mul_overflow(work, kdf->scrypt ? 1 : blocks, &total)) total = UINT64_MAX;
  agc_charge(vm, total / AGC_COST_BYTES);
  return agc_result_value(true, agc_bytes_value(out));
}

/* KDF.pbkdf2_hmac_sha256(password, salt, iterations, length): PBKDF2 (RFC 8018 §5.2) with HMAC-SHA256, Ruby's
   OpenSSL::KDF.pbkdf2_hmac with hash "SHA256". iterations below 1, a length outside 1..1048576 or more work than
   PBKDF2_MAX_WORK is an error Result.
   Each iteration of each 32-byte block hashes two 64-byte blocks. No shared lock, as digest_value. */
static agc_value builtin_pbkdf2_hmac_sha256(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t iterations = agc_as_int(vm, args[2]);
  if (iterations < 1) return agc_error_value("KDF.pbkdf2_hmac_sha256 needs at least 1 iteration");
  kdf_params kdf = {.iterations = (uint64_t)iterations};
  uint64_t work;
  if (__builtin_mul_overflow((uint64_t)iterations, (uint64_t)128, &work)) work = UINT64_MAX;
  return kdf_value(vm, args, 3, &kdf, work, span);
}

/* KDF.scrypt(password, salt, n, r, p, length): scrypt (RFC 7914), Ruby's OpenSSL::KDF.scrypt. n is a power of 2
   above 1 and below 2^(16 * r), r and p are at least 1 with r * p below 2^30, r * p * (n + 16) is at most
   SCRYPT_MAX_WORK,
   and the memory 128 * r * (n + p + 2) is at most SCRYPT_MAX_MEMORY; anything else is an error Result, checked
   before any work. The work is about two passes over the n blocks of 128 * r bytes for each of the p lanes. No shared
   lock, as digest_value. */
static agc_value builtin_scrypt(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t n = agc_as_int(vm, args[2]), r = agc_as_int(vm, args[3]), p = agc_as_int(vm, args[4]);
  if (n < 2 || (n & (n - 1)) != 0) return agc_error_value("KDF.scrypt needs n to be a power of 2 above 1");
  if (r < 1 || p < 1) return agc_error_value("KDF.scrypt needs r and p of at least 1");
  if (p > ((1 << 30) - 1) / r) return agc_error_value("KDF.scrypt needs r * p below 2^30");
  /* RFC 7914 §2: n < 2^(128 * r / 8). Only r <= 3 can meet it, since n fits in 63 bits. */
  if (r < 4 && (uint64_t)n >= (uint64_t)1 << (16 * r)) return agc_error_value("KDF.scrypt needs n below 2^(16 * r)");
  uint64_t lanes, memory, work, rounds;
  /* r * p is below 2^30, so only the product with n + 16 can overflow. */
  if (__builtin_add_overflow((uint64_t)n, (uint64_t)16, &rounds) ||
      __builtin_mul_overflow(rounds, (uint64_t)r * (uint64_t)p, &rounds) || rounds > SCRYPT_MAX_WORK)
    return agc_error_value("KDF.scrypt needs r * p * (n + 16) of at most 2^25");
  bool big = __builtin_add_overflow((uint64_t)n, (uint64_t)p + 2, &lanes) ||
             __builtin_mul_overflow(lanes, (uint64_t)r * 128, &memory) || memory > SCRYPT_MAX_MEMORY;
  if (big) return agc_error_value("KDF.scrypt needs 128 * r * (n + p + 2) bytes of memory at most 1025 MiB");
  /* rounds is at most 2^25, so the work fits in 64 bits. */
  work = rounds * 256;
  kdf_params kdf = {.scrypt = true, .n = (uint64_t)n, .r = (uint64_t)r, .p = (uint64_t)p};
  return kdf_value(vm, args, 5, &kdf, work, span);
}

/* The Digest and HMAC entries: one thin function per kind and output (bytes or hex) over digest_value and
   hmac_value. */
static agc_value builtin_md5(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_MD5, false);
}

static agc_value builtin_md5_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_MD5, true);
}

static agc_value builtin_sha1(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA1, false);
}

static agc_value builtin_sha1_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA1, true);
}

static agc_value builtin_sha256(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA256, false);
}

static agc_value builtin_sha256_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA256, true);
}

static agc_value builtin_sha512(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA512, false);
}

static agc_value builtin_sha512_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA512, true);
}

static agc_value builtin_hmac_sha256(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA256, false);
}

static agc_value builtin_hmac_sha256_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA256, true);
}

static agc_value builtin_hmac_sha512(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA512, false);
}

static agc_value builtin_hmac_sha512_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA512, true);
}

const agc_builtin agc_crypto_builtins[] = {
  {"SecureRandom.hex", 1, builtin_random_hex, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"SecureRandom.uuid", 0, builtin_random_uuid, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Digest.md5.bytes", 1, builtin_md5, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.md5_hexdigest.bytes", 1, builtin_md5_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha1.bytes", 1, builtin_sha1, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha1_hexdigest.bytes", 1, builtin_sha1_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha256.bytes", 1, builtin_sha256, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha256_hexdigest.bytes", 1, builtin_sha256_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha512.bytes", 1, builtin_sha512, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha512_hexdigest.bytes", 1, builtin_sha512_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.encode64.bytes", 1, builtin_encode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.strict_encode64.bytes", 1, builtin_strict_encode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.urlsafe_encode64.bytes", 2, builtin_urlsafe_encode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.decode64.bytes", 1, builtin_decode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.strict_decode64.bytes", 1, builtin_strict_decode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.urlsafe_decode64.bytes", 1, builtin_urlsafe_decode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.hexencode.bytes", 1, builtin_hexencode, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.hexdecode.bytes", 1, builtin_hexdecode, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha256.bytes", 2, builtin_hmac_sha256, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha256_hexdigest.bytes", 2, builtin_hmac_sha256_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha512.bytes", 2, builtin_hmac_sha512, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha512_hexdigest.bytes", 2, builtin_hmac_sha512_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"SecureRandom.random_bytes.bytes", 1, builtin_random_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.secure_compare.bytes", 2, builtin_secure_compare, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Cipher.des_ede3_cbc_encrypt", 3, builtin_des_ede3_cbc_encrypt, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Cipher.des_ede3_cbc_decrypt", 3, builtin_des_ede3_cbc_decrypt, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"CMAC.aes", 2, builtin_cmac_aes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"CMAC.des_ede3", 2, builtin_cmac_des_ede3, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Cipher.aes_256_gcm_encrypt", 4, builtin_aes_256_gcm_encrypt, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Cipher.aes_256_gcm_decrypt", 4, builtin_aes_256_gcm_decrypt, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"KDF.pbkdf2_hmac_sha256", 4, builtin_pbkdf2_hmac_sha256, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"KDF.scrypt", 6, builtin_scrypt, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
};

const size_t agc_crypto_builtin_count = sizeof agc_crypto_builtins / sizeof agc_crypto_builtins[0];
