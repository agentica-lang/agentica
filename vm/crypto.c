/*
 * The Crypto builtins (agc_crypto_builtins): hashes of byte lists, the first
 * part of the Crypto module of docs/future/20-crypto.md, and the Base64 and
 * Digest.hexencode/hexdecode text forms of bytes, in plain C. The hash itself
 * is the digest adapter (digest.h). Service layer. Design:
 * docs/vm/02-reference-behavior.md §2.3; Base64 and hex follow RFC 4648 and
 * Ruby's Base64 module.
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

/* Crypto.sha256(data): the 32 bytes of the digest. Each item must be 0..255, else RUNTIME-INVALID-NUMBER at the
   argument. The work grows with the list, so the row charges AGC_COST_SIZE: one turn-cost unit per item
   (docs/vm/10-io-scheduler.md §10.2.1). Like List.sort or String.from_bytes the call is not split: the task yields
   after it once the cost spends its turn. It runs without the shared lock, since it reads only its argument. */
static agc_value builtin_sha256(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *data = agc_as_list(vm, args[0]);
  size_t n = agc_list_len(data);
  /* A GC atomic block (bytes only); the list is read through the cursor, never by its layout. */
  const uint8_t *bytes = agc_byte_list(vm, data, n);
  if (!bytes) agc_fail(vm, "RUNTIME-INVALID-NUMBER", "Crypto.sha256 needs bytes between 0 and 255", span + 1);
  unsigned char digest[AGC_SHA256_BYTES];
  if (!agc_digest_sha256(bytes, n, digest)) agc_fail(vm, "RUNTIME-INTERNAL", "SHA-256 is not available", span);
  agc_list_builder out;
  agc_list_builder_sized(&out, AGC_SHA256_BYTES);
  for (size_t k = 0; k < AGC_SHA256_BYTES; k++) agc_list_builder_push(&out, agc_int(digest[k]));
  return agc_list_value(agc_list_builder_finish(&out));
}

/* The bytes of the List[Int] argument, read as Crypto.sha256 reads them: an item outside 0..255 is
   RUNTIME-INVALID-NUMBER at the argument (span + 1), a non-Int item fails through agc_as_int. */
static const uint8_t *text_form_bytes(agc_vm *vm, agc_value arg, const char *message, uint32_t span, size_t *n) {
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

static agc_value byte_list_value(agc_vm *vm, const uint8_t *data, size_t n) {
  return n ? agc_list_value(agc_list_of_bytes(data, n)) : vm->rt->empty_list;
}

/* Base64.encode64(data): RFC 4648 base64 with padding, in lines of 60 characters that each end in a newline. Every
   text-form row charges AGC_COST_SIZE, since the work grows with the argument, and runs without the shared lock, since
   it reads only its argument. */
static agc_value builtin_encode64(agc_vm *vm, agc_value *args, uint32_t span) {
  size_t n;
  const uint8_t *bytes = text_form_bytes(vm, args[0], "Base64.encode64 needs bytes between 0 and 255", span, &n);
  return b64_encode(vm, bytes, n, b64_standard, true, true);
}

/* Base64.strict_encode64(data): RFC 4648 base64 with padding, on one line with no newline. */
static agc_value builtin_strict_encode64(agc_vm *vm, agc_value *args, uint32_t span) {
  size_t n;
  const uint8_t *bytes = text_form_bytes(vm, args[0], "Base64.strict_encode64 needs bytes between 0 and 255", span, &n);
  return b64_encode(vm, bytes, n, b64_standard, true, false);
}

/* Base64.urlsafe_encode64(data, padding): the base64url alphabet of RFC 4648 §5, with or without the '=' padding. */
static agc_value builtin_urlsafe_encode64(agc_vm *vm, agc_value *args, uint32_t span) {
  size_t n;
  const uint8_t *bytes =
    text_form_bytes(vm, args[0], "Base64.urlsafe_encode64 needs bytes between 0 and 255", span, &n);
  return b64_encode(vm, bytes, n, b64_urlsafe, agc_as_bool(vm, args[1]), false);
}

/* Base64.decode64(text): the bytes of base64 text, read as Ruby's decode64 reads it (b64_lenient); never an error. */
static agc_value builtin_decode64(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  uint8_t *out = agc_alloc_atomic(s->bytes ? s->bytes : 1);
  return byte_list_value(vm, out, b64_lenient((const uint8_t *)s->data, s->bytes, out));
}

/* Base64.strict_decode64(text): ok(bytes) of padded base64, or error("invalid base64") (b64_strict). */
static agc_value builtin_strict_decode64(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  uint8_t *out = agc_alloc_atomic(s->bytes ? s->bytes : 1);
  size_t n = b64_strict((const uint8_t *)s->data, s->bytes, false, out);
  if (n == SIZE_MAX) return agc_error_value("invalid base64");
  return agc_result_value(true, byte_list_value(vm, out, n));
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
  return agc_result_value(true, byte_list_value(vm, out, got));
}

/* Digest.hexencode(data): two lowercase hex digits per byte, as Ruby's Digest.hexencode writes them. Digest.hexdecode
   is Agentica's own inverse: Ruby has no named hex decoder. */
static agc_value builtin_hexencode(agc_vm *vm, agc_value *args, uint32_t span) {
  size_t n;
  const uint8_t *bytes = text_form_bytes(vm, args[0], "Digest.hexencode needs bytes between 0 and 255", span, &n);
  agc_string *text = ascii_string(vm, agc_size_mul(n, 2));
  for (size_t k = 0; k < n; k++) {
    text->data[2 * k] = hex_digits[bytes[k] >> 4];
    text->data[2 * k + 1] = hex_digits[bytes[k] & 15];
  }
  return agc_string_value(text);
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
  return agc_result_value(true, byte_list_value(vm, out, n));
}

const agc_builtin agc_crypto_builtins[] = {
  {"Crypto.sha256", 1, builtin_sha256, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.encode64", 1, builtin_encode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.strict_encode64", 1, builtin_strict_encode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.urlsafe_encode64", 2, builtin_urlsafe_encode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.decode64", 1, builtin_decode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.strict_decode64", 1, builtin_strict_decode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Base64.urlsafe_decode64", 1, builtin_urlsafe_decode64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.hexencode", 1, builtin_hexencode, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Digest.hexdecode", 1, builtin_hexdecode, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
};

const size_t agc_crypto_builtin_count = sizeof agc_crypto_builtins / sizeof agc_crypto_builtins[0];
