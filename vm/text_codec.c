/*
 * The text codecs (one of the tables that agc_find_builtin searches): Bytes.decode(encoding) and
 * String.encode(encoding) for UTF-8, UTF-16 and UTF-32 (little-endian, big-endian, and the plain form with a byte
 * order mark), ASCII and Latin-1. A String holds UTF-8, so a decode walks its input twice: once to check it and to size
 * the String, once to fill it. Errors are strict: the first input the encoding does not allow gives an error Result
 * with its offset, the one Python reports as the start of its UnicodeDecodeError (a byte offset) or UnicodeEncodeError
 * (a character index). There is no replacing mode. Other encodings live in the agentica-lang/charset package.
 * Service layer.
 */
#include "services.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

/* The UTF-16 kinds come before the UTF-32 ones: reader_of and encode_units tell the unit width by that order. */
typedef enum {
  CODEC_UTF8,
  CODEC_UTF16,
  CODEC_UTF16LE,
  CODEC_UTF16BE,
  CODEC_UTF32,
  CODEC_UTF32LE,
  CODEC_UTF32BE,
  CODEC_ASCII,
  CODEC_LATIN1,
} codec_kind;

/* The name of each kind in the messages, in the order of codec_kind. */
static const char *const codec_names[] = {
  "UTF-8", "UTF-16", "UTF-16LE", "UTF-16BE", "UTF-32", "UTF-32LE", "UTF-32BE", "ASCII", "Latin-1",
};

typedef struct {
  const char *name;
  codec_kind kind;
} codec_alias;

/* How a UTF-16 or UTF-32 input is read: the width of a code unit, its byte order and where the units start (after
   the byte order mark of the plain form). The plain form without a mark is big-endian, as the Unicode standard says
   (Python reads it in the byte order of the machine instead). */
typedef struct {
  size_t width;
  bool little;
  size_t start;
} unit_reader;

/* The names an encoding is found by once ASCII letters are lowered and `_` is read as `-` (`UTF_8` is `utf-8`). Each
   is a name that Python's codecs.lookup takes too, so the peer tests can try every one. */
static const codec_alias aliases[] = {
  {"utf-8", CODEC_UTF8},         {"utf8", CODEC_UTF8},          {"utf-16", CODEC_UTF16},
  {"utf16", CODEC_UTF16},        {"utf-16le", CODEC_UTF16LE},   {"utf-16-le", CODEC_UTF16LE},
  {"utf-16be", CODEC_UTF16BE},   {"utf-16-be", CODEC_UTF16BE},  {"utf-32", CODEC_UTF32},
  {"utf32", CODEC_UTF32},        {"utf-32le", CODEC_UTF32LE},   {"utf-32-le", CODEC_UTF32LE},
  {"utf-32be", CODEC_UTF32BE},   {"utf-32-be", CODEC_UTF32BE},  {"ascii", CODEC_ASCII},
  {"us-ascii", CODEC_ASCII},     {"latin-1", CODEC_LATIN1},     {"latin1", CODEC_LATIN1},
  {"iso-8859-1", CODEC_LATIN1},  {"iso8859-1", CODEC_LATIN1},   {"l1", CODEC_LATIN1},
  {"cp819", CODEC_LATIN1},
};

/* The kind of an encoding name, or false for a name no alias has. The longest alias is 10 bytes, so a longer name
   is not looked at; the length is compared too, so a name with a NUL byte matches nothing. */
static bool find_codec(const agc_string *name, codec_kind *kind) {
  char key[16];
  if (name->bytes >= sizeof key) return false;
  for (size_t i = 0; i < name->bytes; i++) {
    char c = name->data[i];
    key[i] = c == '_' ? '-' : (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
  }
  for (size_t i = 0; i < sizeof aliases / sizeof aliases[0]; i++) {
    if (strlen(aliases[i].name) == name->bytes && memcmp(aliases[i].name, key, name->bytes) == 0) {
      *kind = aliases[i].kind;
      return true;
    }
  }
  return false;
}

static agc_value unknown_codec(const agc_string *name) {
  agc_string *text =
    agc_around("unknown encoding ", name, "; the agentica-lang/charset package reads the encodings not built in");
  return agc_result_value(false, agc_string_value(text));
}

static agc_value failure_at(const char *what, codec_kind kind, const char *unit, size_t at) {
  char text[96];
  snprintf(text, sizeof text, "%s %s at %s %zu", what, codec_names[kind], unit, at);
  return agc_error_value(text);
}

static unit_reader reader_of(codec_kind kind, const uint8_t *data, size_t len) {
  unit_reader r = {kind <= CODEC_UTF16BE ? 2 : 4, kind == CODEC_UTF16LE || kind == CODEC_UTF32LE, 0};
  bool mark16 = len >= 2 && ((data[0] == 0xFE && data[1] == 0xFF) || (data[0] == 0xFF && data[1] == 0xFE));
  if (kind == CODEC_UTF16 && mark16) {
    r.little = data[0] == 0xFF;
    r.start = 2;
  } else if (kind == CODEC_UTF32 && len >= 4) {
    static const uint8_t be[] = {0x00, 0x00, 0xFE, 0xFF}, le[] = {0xFF, 0xFE, 0x00, 0x00};
    if (memcmp(data, be, 4) == 0 || memcmp(data, le, 4) == 0) {
      r.little = data[0] == 0xFF;
      r.start = 4;
    }
  }
  return r;
}

static uint32_t read_unit(const unit_reader *r, const uint8_t *p) {
  if (r->width == 2) return r->little ? (uint32_t)p[0] | (uint32_t)p[1] << 8 : (uint32_t)p[0] << 8 | p[1];
  if (r->little) return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/* The code point of the UTF-16 or UTF-32 data at *at, which moves past it; false, with *at left on it, for a cut unit,
   an unpaired surrogate or a value above U+10FFFF. */
static bool next_unit(const unit_reader *r, const uint8_t *data, size_t len, size_t *at, uint32_t *cp) {
  if (len - *at < r->width) return false;
  uint32_t u = read_unit(r, data + *at);
  if (r->width == 4) {
    if (u > 0x10FFFF || (u >= 0xD800 && u <= 0xDFFF)) return false;
  } else if (u >= 0xD800 && u <= 0xDFFF) {
    if (u >= 0xDC00 || len - *at < 4) return false;
    uint32_t low = read_unit(r, data + *at + 2);
    if (low < 0xDC00 || low > 0xDFFF) return false;
    u = 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00);
  }
  *at += u >= 0x10000 && r->width == 2 ? 4 : r->width;
  *cp = u;
  return true;
}

/* The code point of the input at *at in a byte encoding (ASCII or Latin-1), or false on a byte ASCII does not have. */
static bool next_byte(codec_kind kind, const uint8_t *data, size_t *at, uint32_t *cp) {
  if (kind == CODEC_ASCII && data[*at] >= 0x80) return false;
  *cp = data[(*at)++];
  return true;
}

static bool next_code_point(codec_kind kind, const unit_reader *r, const uint8_t *data, size_t len, size_t *at,
                            uint32_t *cp) {
  return kind == CODEC_ASCII || kind == CODEC_LATIN1 ? next_byte(kind, data, at, cp) : next_unit(r, data, len, at, cp);
}

static size_t utf8_width(uint32_t cp) { return cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4; }

static agc_value decode_utf8(agc_vm *vm, const uint8_t *data, size_t len) {
  size_t chars;
  if (agc_utf8_chars(data, len, &chars))
    return agc_result_value(true, agc_string_value(agc_small_string(vm, (const char *)data, len, chars)));
  size_t at = 0, n;
  while ((n = agc_utf8_valid(data + at, len - at)) != 0) at += n;
  return failure_at("invalid", CODEC_UTF8, "byte", at);
}

/* bytes.decode(encoding): the String of the bytes read in that encoding. */
static agc_value builtin_decode(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  size_t len;
  const uint8_t *data = agc_bytes_data(vm, args[0], &len);
  codec_kind kind;
  if (!find_codec(agc_as_string(vm, args[1]), &kind)) return unknown_codec(agc_as_string(vm, args[1]));
  if (kind == CODEC_UTF8) return decode_utf8(vm, data, len);
  unit_reader r = reader_of(kind, data, len);
  size_t bytes = 0, chars = 0;
  uint32_t cp;
  for (size_t at = r.start; at < len; chars++) {
    if (!next_code_point(kind, &r, data, len, &at, &cp)) return failure_at("invalid", kind, "byte", at);
    bytes = agc_size_add(bytes, utf8_width(cp));
  }
  if (bytes == 0) return agc_result_value(true, agc_string_value(vm->rt->empty_string));
  agc_string *s = agc_new_string(bytes, chars);
  size_t w = 0;
  for (size_t at = r.start; at < len;) {
    next_code_point(kind, &r, data, len, &at, &cp);
    w += agc_utf8_encode(cp, s->data + w);
  }
  return agc_result_value(true, agc_string_value(s));
}

static void write_unit(uint8_t *out, uint32_t u, size_t width) {
  for (size_t k = 0; k < width; k++) out[k] = (uint8_t)(u >> (8 * (width - 1 - k)));
}

static void write_unit_le(uint8_t *out, uint32_t u, size_t width) {
  for (size_t k = 0; k < width; k++) out[k] = (uint8_t)(u >> (8 * k));
}

/* The UTF-16 or UTF-32 bytes of a String, which never fails: a String holds only Unicode scalar values. The plain
   form writes a byte order mark and then big-endian units. */
static agc_value encode_units(const agc_string *s, codec_kind kind) {
  const uint8_t *data = (const uint8_t *)s->data;
  bool wide = kind >= CODEC_UTF32, little = kind == CODEC_UTF16LE || kind == CODEC_UTF32LE;
  bool mark = kind == CODEC_UTF16 || kind == CODEC_UTF32;
  size_t width = wide ? 4 : 2, astral = 0;
  for (size_t i = 0; i < s->bytes; i++) astral += data[i] >= 0xF0;
  size_t units = agc_size_add(agc_size_add(s->chars, wide ? 0 : astral), mark);
  if (units == 0) return agc_result_value(true, agc_bytes_value(agc_empty_bytes()));
  agc_bytes *b = agc_new_bytes(agc_size_mul(units, width));
  void (*put)(uint8_t *, uint32_t, size_t) = little ? write_unit_le : write_unit;
  size_t w = 0;
  if (mark) {
    put(b->data, 0xFEFF, width);
    w = width;
  }
  for (size_t at = 0; at < s->bytes;) {
    uint32_t cp = agc_utf8_next(data, s->bytes, &at);
    if (!wide && cp >= 0x10000) {
      put(b->data + w, 0xD800 + ((cp - 0x10000) >> 10), 2);
      put(b->data + w + 2, 0xDC00 + ((cp - 0x10000) & 0x3FF), 2);
      w += 4;
    } else {
      put(b->data + w, cp, width);
      w += width;
    }
  }
  return agc_result_value(true, agc_bytes_value(b));
}

/* The ASCII or Latin-1 bytes of a String: one byte per character, or an error at the first character the encoding
   does not have. */
static agc_value encode_bytes(const agc_string *s, codec_kind kind) {
  const uint8_t *data = (const uint8_t *)s->data;
  uint32_t limit = kind == CODEC_ASCII ? 0x80 : 0x100;
  if (s->bytes == s->chars) return agc_result_value(true, agc_bytes_value(agc_make_bytes(data, s->bytes)));
  agc_bytes *b = agc_new_bytes(s->chars);
  size_t index = 0;
  for (size_t at = 0; at < s->bytes; index++) {
    uint32_t cp = agc_utf8_next(data, s->bytes, &at);
    if (cp >= limit) {
      char text[96];
      snprintf(text, sizeof text, "cannot encode U+%04" PRIX32 " in %s at index %zu", cp, codec_names[kind], index);
      return agc_error_value(text);
    }
    b->data[index] = (uint8_t)cp;
  }
  return agc_result_value(true, agc_bytes_value(b));
}

/* text.encode(encoding): the bytes of the String in that encoding. */
static agc_value builtin_encode(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  codec_kind kind;
  if (!find_codec(agc_as_string(vm, args[1]), &kind)) return unknown_codec(agc_as_string(vm, args[1]));
  if (kind == CODEC_UTF8)
    return agc_result_value(true, agc_bytes_value(agc_make_bytes((const uint8_t *)s->data, s->bytes)));
  if (kind == CODEC_ASCII || kind == CODEC_LATIN1) return encode_bytes(s, kind);
  return encode_units(s, kind);
}

const agc_builtin agc_text_codec_builtins[] = {
  {"Bytes.decode", 2, builtin_decode, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.encode", 2, builtin_encode, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
};

const size_t agc_text_codec_builtin_count = sizeof agc_text_codec_builtins / sizeof agc_text_codec_builtins[0];
