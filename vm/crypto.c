/*
 * The crypto builtins (agc_crypto_builtins): the Digest hashes of bytes (MD5,
 * SHA-1, SHA-256, SHA-512, as bytes and as hex), their HMACs (RFC 2104) and
 * the constant-time HMAC.secure_compare, the SecureRandom draws, and the
 * Base64 and Digest.hexencode/hexdecode text forms of bytes in plain C. The
 * hashes, HMACs, random bytes and compare come from the OpenSSL adapter
 * (digest.h). Service layer. Design: docs/vm/02-reference-behavior.md §2.3;
 * Base64 and hex follow RFC 4648 and Ruby's Base64 module, SecureRandom.uuid
 * RFC 9562 §5.4.
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

/* The messages of the Digest hashes, by agc_digest_kind: a bad item (RUNTIME-INVALID-NUMBER) and a failed hash. */
static const struct {
  const char *bad_byte;
  const char *missing;
} digest_names[] = {
  [AGC_DIGEST_MD5] = {"Digest.md5 needs bytes between 0 and 255", "MD5 is not available"},
  [AGC_DIGEST_SHA1] = {"Digest.sha1 needs bytes between 0 and 255", "SHA-1 is not available"},
  [AGC_DIGEST_SHA256] = {"Digest.sha256 needs bytes between 0 and 255", "SHA-256 is not available"},
  [AGC_DIGEST_SHA512] = {"Digest.sha512 needs bytes between 0 and 255", "SHA-512 is not available"},
};

/* The messages of the HMAC builtins, by agc_digest_kind: a bad item in the key or in the data (RUNTIME-INVALID-NUMBER)
   and a failed HMAC. Only the kinds with an HMAC builtin have an entry. */
static const struct {
  const char *bad_key;
  const char *bad_data;
  const char *missing;
} hmac_names[] = {
  [AGC_DIGEST_SHA256] = {"HMAC.sha256 needs a key of bytes between 0 and 255",
                         "HMAC.sha256 needs data of bytes between 0 and 255", "HMAC-SHA256 is not available"},
  [AGC_DIGEST_SHA512] = {"HMAC.sha512 needs a key of bytes between 0 and 255",
                         "HMAC.sha512 needs data of bytes between 0 and 255", "HMAC-SHA512 is not available"},
};

/* Which form of bytes a call takes and returns: a Bytes value (the catalog's ".bytes" keys) or a byte list (the old
   keys). */
typedef enum { FORM_BYTES, FORM_LIST } byte_form;

/* The bytes of a byte argument. A Bytes gives its own data, which the argument keeps alive, and cannot hold a bad
   byte. A List[Int] (the old keys) is copied into a GC-atomic block: an item outside 0..255 is RUNTIME-INVALID-NUMBER
   at the argument (span + 1), a non-Int item fails through agc_as_int, and the list is read through the cursor, never
   by its layout. */
static const uint8_t *text_form_bytes(agc_vm *vm, agc_value arg, byte_form form, const char *message, uint32_t span,
                                      size_t *n) {
  if (form == FORM_BYTES) return agc_bytes_data(vm, arg, n);
  const agc_list *data = agc_as_list(vm, arg);
  *n = agc_list_len(data);
  const uint8_t *bytes = agc_byte_list(vm, data, *n);
  if (!bytes) agc_fail(vm, "RUNTIME-INVALID-NUMBER", message, span + 1);
  return bytes;
}

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

/* The n bytes at data as a result of the given form: a copy in a new Bytes or a byte list, or the shared empty one. */
static agc_value byte_value(agc_vm *vm, const uint8_t *data, size_t n, byte_form form) {
  if (form == FORM_BYTES) return agc_bytes_value(agc_make_bytes(data, n));
  return n ? agc_list_value(agc_list_of_bytes(data, n)) : vm->rt->empty_list;
}

/* Base64.encode64(data): RFC 4648 base64 with padding, in lines of 60 characters that each end in a newline. Every
   text-form row charges AGC_COST_SIZE, since the work grows with the argument, and runs without the shared lock, since
   it reads only its argument. */
static agc_value encode64(agc_vm *vm, agc_value *args, uint32_t span, byte_form form) {
  size_t n;
  const uint8_t *bytes = text_form_bytes(vm, args[0], form, "Base64.encode64 needs bytes between 0 and 255", span, &n);
  return b64_encode(vm, bytes, n, b64_standard, true, true);
}

/* Base64.strict_encode64(data): RFC 4648 base64 with padding, on one line with no newline. */
static agc_value strict_encode64(agc_vm *vm, agc_value *args, uint32_t span, byte_form form) {
  size_t n;
  const uint8_t *bytes =
    text_form_bytes(vm, args[0], form, "Base64.strict_encode64 needs bytes between 0 and 255", span, &n);
  return b64_encode(vm, bytes, n, b64_standard, true, false);
}

/* Base64.urlsafe_encode64(data, padding): the base64url alphabet of RFC 4648 §5, with or without the '=' padding. */
static agc_value urlsafe_encode64(agc_vm *vm, agc_value *args, uint32_t span, byte_form form) {
  size_t n;
  const uint8_t *bytes =
    text_form_bytes(vm, args[0], form, "Base64.urlsafe_encode64 needs bytes between 0 and 255", span, &n);
  return b64_encode(vm, bytes, n, b64_urlsafe, agc_as_bool(vm, args[1]), false);
}

/* Base64.decode64(text): the bytes of base64 text, read as Ruby's decode64 reads it (b64_lenient); never an error. */
static agc_value decode64(agc_vm *vm, agc_value *args, uint32_t span, byte_form form) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  uint8_t *out = agc_alloc_atomic(s->bytes ? s->bytes : 1);
  return byte_value(vm, out, b64_lenient((const uint8_t *)s->data, s->bytes, out), form);
}

/* Base64.strict_decode64(text): ok(bytes) of padded base64, or error("invalid base64") (b64_strict). */
static agc_value strict_decode64(agc_vm *vm, agc_value *args, uint32_t span, byte_form form) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  uint8_t *out = agc_alloc_atomic(s->bytes ? s->bytes : 1);
  size_t n = b64_strict((const uint8_t *)s->data, s->bytes, false, out);
  if (n == SIZE_MAX) return agc_error_value("invalid base64");
  return agc_result_value(true, byte_value(vm, out, n, form));
}

/* Base64.urlsafe_decode64(text): as in Ruby, text that does not end in '=' and whose length is not a multiple of
   four gets the missing '=' first; then it decodes strictly, in either alphabet. The padded last group is decoded
   from a local copy: strict text has no '=' before its last group, so the whole groups before it decode alone. */
static agc_value urlsafe_decode64(agc_vm *vm, agc_value *args, uint32_t span, byte_form form) {
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
  return agc_result_value(true, byte_value(vm, out, got, form));
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

static agc_value hexencode(agc_vm *vm, agc_value *args, uint32_t span, byte_form form) {
  size_t n;
  const uint8_t *bytes = text_form_bytes(vm, args[0], form, "Digest.hexencode needs bytes between 0 and 255", span, &n);
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
static agc_value hexdecode(agc_vm *vm, agc_value *args, uint32_t span, byte_form form) {
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
  return agc_result_value(true, byte_value(vm, out, n, form));
}

/* The calls into libcrypto (digest_compute, hmac_compute and secure_draw below) each have their own out-of-line
   function whose only callees are the adapter and agc_fail. vm/tools/tsan.supp names these three and nothing else, so
   a TSan report about OpenSSL's fetch caches is suppressed while a race in the VM code around them (such as reading a
   list another task holds) is still reported. TSan unwinds by frame pointers, which libcrypto does not keep, so a
   report skips the adapter function and shows its caller first: these must stay real frames (noinline, and not a tail
   call). */
static __attribute__((noinline)) size_t digest_compute(agc_vm *vm, agc_digest_kind kind, const uint8_t *bytes, size_t n,
                                                       unsigned char out[AGC_DIGEST_MAX_BYTES], uint32_t span) {
  size_t len = agc_digest(kind, bytes, n, out);
  if (!len) agc_fail(vm, "RUNTIME-INTERNAL", digest_names[kind].missing, span);
  return len;
}

static __attribute__((noinline)) size_t hmac_compute(agc_vm *vm, agc_digest_kind kind, const uint8_t *key,
                                                     size_t key_n, const uint8_t *data, size_t n,
                                                     unsigned char out[AGC_DIGEST_MAX_BYTES], uint32_t span) {
  size_t len = agc_hmac(kind, key, key_n, data, n, out);
  if (!len) agc_fail(vm, "RUNTIME-INTERNAL", hmac_names[kind].missing, span);
  return len;
}

/* Digest.<kind>(data) and its _hexdigest form: the digest of the bytes, as bytes (Ruby's Digest::SHA256.digest) or
   as lowercase hex (hexdigest). The work grows with the data, so the rows charge AGC_COST_SIZE
   (docs/vm/10-io-scheduler.md §10.2.1). Like List.sort or String.from_bytes the call is not split: the task yields
   after it once the cost spends its turn. It runs without the shared lock, since it reads only its argument. */
static agc_value digest_value(agc_vm *vm, agc_value *args, uint32_t span, agc_digest_kind kind, bool hex,
                              byte_form form) {
  size_t n;
  const uint8_t *bytes = text_form_bytes(vm, args[0], form, digest_names[kind].bad_byte, span, &n);
  unsigned char digest[AGC_DIGEST_MAX_BYTES];
  size_t len = digest_compute(vm, kind, bytes, n, digest, span);
  return hex ? hex_text(vm, digest, len) : byte_value(vm, digest, len, form);
}

/* HMAC.<kind>(key, data) and its _hexdigest form: the HMAC of the data under the key, as bytes (Ruby's
   OpenSSL::HMAC.digest) or as lowercase hex (hexdigest). A bad item of a byte list is reported at its own argument:
   the key at span + 1, the data at span + 2. The key's bytes stay reachable while the data is read: they are a local
   the GC scans. Cost and lock as digest_value. */
static agc_value hmac_value(agc_vm *vm, agc_value *args, uint32_t span, agc_digest_kind kind, bool hex,
                            byte_form form) {
  size_t key_n, n;
  const uint8_t *key = text_form_bytes(vm, args[0], form, hmac_names[kind].bad_key, span, &key_n);
  const uint8_t *data = text_form_bytes(vm, args[1], form, hmac_names[kind].bad_data, span + 1, &n);
  unsigned char mac[AGC_DIGEST_MAX_BYTES];
  size_t len = hmac_compute(vm, kind, key, key_n, data, n, mac, span);
  return hex ? hex_text(vm, mac, len) : byte_value(vm, mac, len, form);
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
static const uint8_t *secure_random_bytes(agc_vm *vm, agc_value arg, const char *bad_count, uint32_t span, size_t *n) {
  int64_t count = agc_as_int(vm, arg);
  if (count < 0 || count > AGC_MAX_LIST_COUNT) agc_fail(vm, "RUNTIME-INVALID-COUNT", bad_count, span + 1);
  *n = (size_t)count;
  uint8_t *out = agc_alloc_atomic(*n ? *n : 1);
  secure_draw(vm, out, *n, span);
  return out;
}

/* SecureRandom.random_bytes(n): n bytes from OpenSSL's CSPRNG (RAND_bytes), unlike the seeded Random. The rows charge
   AGC_COST_SIZE, since the work grows with n (the result's items), and run without the shared lock: OpenSSL 3 keeps
   one generator per thread. */
static agc_value random_bytes(agc_vm *vm, agc_value *args, uint32_t span, byte_form form) {
  size_t n;
  const uint8_t *bytes =
    secure_random_bytes(vm, args[0], "SecureRandom.random_bytes needs n between 0 and 1048576", span, &n);
  return byte_value(vm, bytes, n, form);
}

/* SecureRandom.hex(n): n random bytes as 2n lowercase hex digits, as Ruby's. */
static agc_value builtin_random_hex(agc_vm *vm, agc_value *args, uint32_t span) {
  size_t n;
  const uint8_t *bytes = secure_random_bytes(vm, args[0], "SecureRandom.hex needs n between 0 and 1048576", span, &n);
  return hex_text(vm, bytes, n);
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
   other lengths give false in a time that depends on the lengths only, never on the bytes or on where they differ (in
   a byte list, a bad byte stops the run at its position). Equal digests then also need equal bytes, as Ruby's
   `&& a == b` does, so a SHA-256 collision cannot pass; that second compare runs only when the digests match, so its
   branch tells nothing the answer does not. The time grows with the lengths, which the row charges (AGC_COST_SIZE),
   and the call runs without the shared lock, as HMAC does. */
static agc_value secure_compare(agc_vm *vm, agc_value *args, uint32_t span, byte_form form) {
  size_t a_n, b_n;
  const char *bad = "HMAC.secure_compare needs bytes between 0 and 255";
  const uint8_t *a = text_form_bytes(vm, args[0], form, bad, span, &a_n);
  const uint8_t *b = text_form_bytes(vm, args[1], form, bad, span + 1, &b_n);
  unsigned char a_digest[AGC_DIGEST_MAX_BYTES], b_digest[AGC_DIGEST_MAX_BYTES];
  size_t len = digest_compute(vm, AGC_DIGEST_SHA256, a, a_n, a_digest, span);
  digest_compute(vm, AGC_DIGEST_SHA256, b, b_n, b_digest, span);
  bool same = agc_secure_equal(a_digest, b_digest, len);
  return agc_bool(same && a_n == b_n && agc_secure_equal(a, b, a_n));
}

/* The entries of the builtins on bytes, two over each body above: builtin_<name>_bytes on Bytes, under the catalog's
   key "<name>.bytes", and builtin_<name> on byte lists (List[Int]) under the old key "<name>", which a front end compiled
   before Bytes (the checked-in stage0) still imports. The old keys go when no stage0 imports them (#805 PR 9). */
static agc_value builtin_encode64(agc_vm *vm, agc_value *args, uint32_t span) {
  return encode64(vm, args, span, FORM_LIST);
}

static agc_value builtin_encode64_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return encode64(vm, args, span, FORM_BYTES);
}

static agc_value builtin_strict_encode64(agc_vm *vm, agc_value *args, uint32_t span) {
  return strict_encode64(vm, args, span, FORM_LIST);
}

static agc_value builtin_strict_encode64_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return strict_encode64(vm, args, span, FORM_BYTES);
}

static agc_value builtin_urlsafe_encode64(agc_vm *vm, agc_value *args, uint32_t span) {
  return urlsafe_encode64(vm, args, span, FORM_LIST);
}

static agc_value builtin_urlsafe_encode64_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return urlsafe_encode64(vm, args, span, FORM_BYTES);
}

static agc_value builtin_decode64(agc_vm *vm, agc_value *args, uint32_t span) {
  return decode64(vm, args, span, FORM_LIST);
}

static agc_value builtin_decode64_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return decode64(vm, args, span, FORM_BYTES);
}

static agc_value builtin_strict_decode64(agc_vm *vm, agc_value *args, uint32_t span) {
  return strict_decode64(vm, args, span, FORM_LIST);
}

static agc_value builtin_strict_decode64_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return strict_decode64(vm, args, span, FORM_BYTES);
}

static agc_value builtin_urlsafe_decode64(agc_vm *vm, agc_value *args, uint32_t span) {
  return urlsafe_decode64(vm, args, span, FORM_LIST);
}

static agc_value builtin_urlsafe_decode64_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return urlsafe_decode64(vm, args, span, FORM_BYTES);
}

static agc_value builtin_hexencode(agc_vm *vm, agc_value *args, uint32_t span) {
  return hexencode(vm, args, span, FORM_LIST);
}

static agc_value builtin_hexencode_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return hexencode(vm, args, span, FORM_BYTES);
}

static agc_value builtin_hexdecode(agc_vm *vm, agc_value *args, uint32_t span) {
  return hexdecode(vm, args, span, FORM_LIST);
}

static agc_value builtin_hexdecode_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return hexdecode(vm, args, span, FORM_BYTES);
}

static agc_value builtin_random_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return random_bytes(vm, args, span, FORM_LIST);
}

static agc_value builtin_random_bytes_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return random_bytes(vm, args, span, FORM_BYTES);
}

static agc_value builtin_secure_compare(agc_vm *vm, agc_value *args, uint32_t span) {
  return secure_compare(vm, args, span, FORM_LIST);
}

static agc_value builtin_secure_compare_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return secure_compare(vm, args, span, FORM_BYTES);
}

static agc_value builtin_md5(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_MD5, false, FORM_LIST);
}

static agc_value builtin_md5_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_MD5, false, FORM_BYTES);
}

static agc_value builtin_md5_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_MD5, true, FORM_LIST);
}

static agc_value builtin_md5_hexdigest_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_MD5, true, FORM_BYTES);
}

static agc_value builtin_sha1(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA1, false, FORM_LIST);
}

static agc_value builtin_sha1_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA1, false, FORM_BYTES);
}

static agc_value builtin_sha1_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA1, true, FORM_LIST);
}

static agc_value builtin_sha1_hexdigest_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA1, true, FORM_BYTES);
}

static agc_value builtin_sha256(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA256, false, FORM_LIST);
}

static agc_value builtin_sha256_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA256, false, FORM_BYTES);
}

static agc_value builtin_sha256_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA256, true, FORM_LIST);
}

static agc_value builtin_sha256_hexdigest_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA256, true, FORM_BYTES);
}

static agc_value builtin_sha512(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA512, false, FORM_LIST);
}

static agc_value builtin_sha512_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA512, false, FORM_BYTES);
}

static agc_value builtin_sha512_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA512, true, FORM_LIST);
}

static agc_value builtin_sha512_hexdigest_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return digest_value(vm, args, span, AGC_DIGEST_SHA512, true, FORM_BYTES);
}

static agc_value builtin_hmac_sha256(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA256, false, FORM_LIST);
}

static agc_value builtin_hmac_sha256_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA256, false, FORM_BYTES);
}

static agc_value builtin_hmac_sha256_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA256, true, FORM_LIST);
}

static agc_value builtin_hmac_sha256_hexdigest_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA256, true, FORM_BYTES);
}

static agc_value builtin_hmac_sha512(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA512, false, FORM_LIST);
}

static agc_value builtin_hmac_sha512_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA512, false, FORM_BYTES);
}

static agc_value builtin_hmac_sha512_hexdigest(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA512, true, FORM_LIST);
}

static agc_value builtin_hmac_sha512_hexdigest_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return hmac_value(vm, args, span, AGC_DIGEST_SHA512, true, FORM_BYTES);
}

const agc_builtin agc_crypto_builtins[] = {
  {"Digest.md5", 1, builtin_md5, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.md5_hexdigest", 1, builtin_md5_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha1", 1, builtin_sha1, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha1_hexdigest", 1, builtin_sha1_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha256", 1, builtin_sha256, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha256_hexdigest", 1, builtin_sha256_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha512", 1, builtin_sha512, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha512_hexdigest", 1, builtin_sha512_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.encode64", 1, builtin_encode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.strict_encode64", 1, builtin_strict_encode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.urlsafe_encode64", 2, builtin_urlsafe_encode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.decode64", 1, builtin_decode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.strict_decode64", 1, builtin_strict_decode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.urlsafe_decode64", 1, builtin_urlsafe_decode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.hexencode", 1, builtin_hexencode, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.hexdecode", 1, builtin_hexdecode, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha256", 2, builtin_hmac_sha256, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha256_hexdigest", 2, builtin_hmac_sha256_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha512", 2, builtin_hmac_sha512, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha512_hexdigest", 2, builtin_hmac_sha512_hexdigest, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"SecureRandom.random_bytes", 1, builtin_random_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"SecureRandom.hex", 1, builtin_random_hex, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"SecureRandom.uuid", 0, builtin_random_uuid, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"HMAC.secure_compare", 2, builtin_secure_compare, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.md5.bytes", 1, builtin_md5_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.md5_hexdigest.bytes", 1, builtin_md5_hexdigest_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha1.bytes", 1, builtin_sha1_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha1_hexdigest.bytes", 1, builtin_sha1_hexdigest_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha256.bytes", 1, builtin_sha256_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha256_hexdigest.bytes", 1, builtin_sha256_hexdigest_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha512.bytes", 1, builtin_sha512_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.sha512_hexdigest.bytes", 1, builtin_sha512_hexdigest_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.encode64.bytes", 1, builtin_encode64_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.strict_encode64.bytes", 1, builtin_strict_encode64_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.urlsafe_encode64.bytes", 2, builtin_urlsafe_encode64_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.decode64.bytes", 1, builtin_decode64_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.strict_decode64.bytes", 1, builtin_strict_decode64_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.urlsafe_decode64.bytes", 1, builtin_urlsafe_decode64_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.hexencode.bytes", 1, builtin_hexencode_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.hexdecode.bytes", 1, builtin_hexdecode_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha256.bytes", 2, builtin_hmac_sha256_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha256_hexdigest.bytes", 2, builtin_hmac_sha256_hexdigest_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha512.bytes", 2, builtin_hmac_sha512_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.sha512_hexdigest.bytes", 2, builtin_hmac_sha512_hexdigest_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"SecureRandom.random_bytes.bytes", 1, builtin_random_bytes_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"HMAC.secure_compare.bytes", 2, builtin_secure_compare_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
};

const size_t agc_crypto_builtin_count = sizeof agc_crypto_builtins / sizeof agc_crypto_builtins[0];
