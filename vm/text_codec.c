/*
 * The text codecs (one of the tables that agc_find_builtin searches): Bytes.decode(encoding) and
 * String.encode(encoding) for UTF-8, UTF-16 and UTF-32 (little-endian, big-endian, and the plain form with a byte
 * order mark), ASCII, Latin-1, ISO-8859-15 and Windows-1252. A String holds UTF-8, so a decode walks its input twice:
 * once to check it and to size the String, once to fill it. Errors are strict: the first input the encoding does not
 * allow gives an error Result with its offset, the one Python reports as the start of its UnicodeDecodeError (a byte
 * offset) or UnicodeEncodeError (a character index). There is no replacing mode. Other encodings live in the
 * agentica-lang/charset package.
 * Service layer.
 */
#include "services.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

/* The UTF-16 kinds come before the UTF-32 ones, and the one-byte encodings come last: reader_of and encode_units tell
   the unit width by that order, and byte_codec? the encodings of one byte per character. */
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
  CODEC_LATIN9,
  CODEC_CP1252,
} codec_kind;

/* The name of each kind in the messages, in the order of codec_kind. */
static const char *const codec_names[] = {
  "UTF-8", "UTF-16", "UTF-16LE", "UTF-16BE", "UTF-32", "UTF-32LE", "UTF-32BE", "ASCII", "Latin-1", "ISO-8859-15",
  "Windows-1252",
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

/* A byte of ISO-8859-15 that holds another character than in Latin-1, and that character. */
typedef struct {
  uint8_t byte;
  uint16_t cp;
} byte_change;

/* The code points of the Windows-1252 bytes 0x80 to 0x9F, the only ones where it differs from Latin-1; 0 for the five
   bytes it leaves undefined (0x81, 0x8D, 0x8F, 0x90, 0x9D), which Python's cp1252 refuses too. From the Unicode
   mapping table cp1252.txt (unicode.org, MAPPINGS/VENDORS/MICSFT/WINDOWS); the peer test checks every byte against
   Python. Frozen data, like vm/unicode_data.c. */
static const uint16_t cp1252_high[32] = {
  0x20AC, 0,      0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
  0,      0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E,
  0x0178,
};

/* The eight bytes where ISO-8859-15 (Latin-9) differs from Latin-1 (ISO/IEC 8859-15:1999, the euro sign and the
   letters of French, Finnish and Estonian); every other byte is the Latin-1 character. Frozen data, checked against
   Python by the peer test. */
static const byte_change latin9_changes[8] = {
  {0xA4, 0x20AC}, {0xA6, 0x0160}, {0xA8, 0x0161}, {0xB4, 0x017D},
  {0xB8, 0x017E}, {0xBC, 0x0152}, {0xBD, 0x0153}, {0xBE, 0x0178},
};

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
  {"cp819", CODEC_LATIN1},       {"iso-8859-15", CODEC_LATIN9}, {"iso8859-15", CODEC_LATIN9},
  {"latin9", CODEC_LATIN9},      {"l9", CODEC_LATIN9},          {"cp1252", CODEC_CP1252},
  {"windows-1252", CODEC_CP1252},
};

/* The kind of an encoding name, or false for a name no alias has. The longest alias is 12 bytes, so a longer name
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

static bool byte_codec(codec_kind kind) { return kind >= CODEC_ASCII; }

/* The code point of a byte in an encoding of one byte per character, or -1 for a byte it does not define. All of them
   are ASCII below 0x80. */
static int32_t byte_code_point(codec_kind kind, uint8_t byte) {
  if (byte < 0x80 || kind == CODEC_LATIN1) return byte;
  if (kind == CODEC_ASCII) return -1;
  if (kind == CODEC_CP1252) return byte >= 0xA0 ? byte : cp1252_high[byte - 0x80] ? cp1252_high[byte - 0x80] : -1;
  for (size_t i = 0; i < sizeof latin9_changes / sizeof latin9_changes[0]; i++)
    if (latin9_changes[i].byte == byte) return latin9_changes[i].cp;
  return byte;
}

/* The byte of a code point in an encoding of one byte per character, or -1 when the encoding has no byte for it. */
static int code_point_byte(codec_kind kind, uint32_t cp) {
  if (cp < 0x80) return (int)cp;
  if (kind == CODEC_ASCII) return -1;
  if (kind == CODEC_LATIN1) return cp < 0x100 ? (int)cp : -1;
  if (kind == CODEC_CP1252) {
    if (cp >= 0xA0 && cp < 0x100) return (int)cp;
    for (size_t i = 0; i < 32; i++)
      if (cp1252_high[i] && cp1252_high[i] == cp) return (int)(0x80 + i);
    return -1;
  }
  for (size_t i = 0; i < sizeof latin9_changes / sizeof latin9_changes[0]; i++) {
    if (latin9_changes[i].cp == cp) return latin9_changes[i].byte;
    if (latin9_changes[i].byte == cp) return -1;
  }
  return cp < 0x100 ? (int)cp : -1;
}

/* The code point of the input at *at in an encoding of one byte per character, or false on a byte it does not
   define. */
static bool next_byte(codec_kind kind, const uint8_t *data, size_t *at, uint32_t *cp) {
  int32_t found = byte_code_point(kind, data[*at]);
  if (found < 0) return false;
  *cp = (uint32_t)found;
  (*at)++;
  return true;
}

static bool next_code_point(codec_kind kind, const unit_reader *r, const uint8_t *data, size_t len, size_t *at,
                            uint32_t *cp) {
  return byte_codec(kind) ? next_byte(kind, data, at, cp) : next_unit(r, data, len, at, cp);
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

/* The bytes of a String in an encoding of one byte per character, or an error at the first character the encoding
   does not have. An ASCII String is its own bytes in every one of them. */
static agc_value encode_bytes(const agc_string *s, codec_kind kind) {
  const uint8_t *data = (const uint8_t *)s->data;
  if (s->bytes == s->chars) return agc_result_value(true, agc_bytes_value(agc_make_bytes(data, s->bytes)));
  agc_bytes *b = agc_new_bytes(s->chars);
  size_t index = 0;
  for (size_t at = 0; at < s->bytes; index++) {
    uint32_t cp = agc_utf8_next(data, s->bytes, &at);
    int byte = code_point_byte(kind, cp);
    if (byte < 0) {
      char text[96];
      snprintf(text, sizeof text, "cannot encode U+%04" PRIX32 " in %s at index %zu", cp, codec_names[kind], index);
      return agc_error_value(text);
    }
    b->data[index] = (uint8_t)byte;
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
  if (byte_codec(kind)) return encode_bytes(s, kind);
  return encode_units(s, kind);
}

const agc_builtin agc_text_codec_builtins[] = {
  {"Bytes.decode", 2, builtin_decode, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.encode", 2, builtin_encode, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
};

const size_t agc_text_codec_builtin_count = sizeof agc_text_codec_builtins / sizeof agc_text_codec_builtins[0];
