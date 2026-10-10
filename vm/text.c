#include "agc.h"

#include <inttypes.h>
#include <string.h>

static bool in_ranges(const uint32_t (*ranges)[2], size_t count, uint32_t cp) {
  size_t lo = 0, hi = count;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    if (cp < ranges[mid][0])
      hi = mid;
    else if (cp > ranges[mid][1])
      lo = mid + 1;
    else
      return true;
  }
  return false;
}

bool agc_write_raw(uint32_t cp) { return in_ranges(agc_write_raw_ranges, agc_write_raw_count, cp); }

static uint32_t decode(const uint8_t *s, size_t width) {
  static const uint8_t lead_mask[] = {0, 0x7F, 0x1F, 0x0F, 0x07};
  uint32_t cp = s[0] & lead_mask[width];
  for (size_t k = 1; k < width; k++) cp = (cp << 6) | (s[k] & 0x3Fu);
  return cp;
}

static const char *short_escape(uint32_t cp) {
  switch (cp) {
    case 7: return "\\a";
    case 8: return "\\b";
    case 9: return "\\t";
    case 10: return "\\n";
    case 11: return "\\v";
    case 12: return "\\f";
    case 13: return "\\r";
    case 27: return "\\e";
    case '"': return "\\\"";
    case '\\': return "\\\\";
    default: return NULL;
  }
}

size_t agc_write_form(const agc_string *s, char *out, size_t *chars) {
  const uint8_t *data = (const uint8_t *)s->data;
  size_t n = 1, count = 2, at = 0;
  bool join = false;
  if (out) out[0] = '"';
  while (at < s->bytes) {
    size_t width = agc_utf8_width(data[at]);
    if (width > s->bytes - at) width = s->bytes - at;
    uint32_t cp = decode(data + at, width);
    const char *escape = short_escape(cp);
    bool raw = !escape && (agc_write_raw(cp) || (join && in_ranges(agc_write_joiner_ranges, agc_write_joiner_count, cp)));
    join = raw && !in_ranges(agc_write_blank_ranges, agc_write_blank_count, cp);
    char hex[12];
    const char *piece = (const char *)data + at;
    size_t len = width;
    if (raw) {
      count++;
    } else {
      if (!escape) {
        snprintf(hex, sizeof hex, cp < 0x10000 ? "\\u%04" PRIX32 : "\\U%08" PRIX32, cp);
        escape = hex;
      }
      piece = escape;
      len = strlen(escape);
      count += len;
    }
    if (out) memcpy(out + n, piece, len);
    n = agc_size_add(n, len);
    at += width;
  }
  if (out) out[n] = '"';
  *chars = count;
  return agc_size_add(n, 1);
}

agc_string *agc_concat(const agc_string *a, const agc_string *b) {
  agc_string *s = agc_new_string(agc_size_add(a->bytes, b->bytes), agc_size_add(a->chars, b->chars));
  if (a->bytes) memcpy(s->data, a->data, a->bytes);
  if (b->bytes) memcpy(s->data + a->bytes, b->data, b->bytes);
  return s;
}

size_t agc_scalar_text(agc_vm *vm, agc_value v, char text[AGC_FLOAT_TEXT]) {
  if (agc_is(v, AGC_T_NIL)) return (size_t)snprintf(text, AGC_FLOAT_TEXT, "nil");
  if (agc_is(v, AGC_T_BOOL)) return (size_t)snprintf(text, AGC_FLOAT_TEXT, "%s", agc_as_bool(vm, v) ? "true" : "false");
  if (agc_is(v, AGC_T_FLOAT)) return agc_float_text(agc_as_float(vm, v), text);
  return (size_t)snprintf(text, AGC_FLOAT_TEXT, "%" PRId64, agc_as_int(vm, v));
}

agc_string *agc_text(agc_vm *vm, agc_value v) {
  if (agc_is(v, AGC_T_STRING)) return agc_as_string(vm, v);
  char text[AGC_FLOAT_TEXT];
  size_t n = agc_scalar_text(vm, v, text);
  return agc_make_string(text, n, n);
}

agc_string *agc_debug(agc_vm *vm, agc_value v) {
  if (!agc_is(v, AGC_T_STRING)) return agc_text(vm, v);
  const agc_string *s = agc_as_string(vm, v);
  size_t chars;
  size_t bytes = agc_write_form(s, NULL, &chars);
  agc_string *result = agc_new_string(bytes, chars);
  agc_write_form(s, result->data, &chars);
  return result;
}
