#include "agc.h"

#include <inttypes.h>
#include <string.h>

bool agc_write_raw(uint32_t cp) {
  size_t lo = 0, hi = agc_write_raw_count;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    if (cp < agc_write_raw_ranges[mid][0])
      hi = mid;
    else if (cp > agc_write_raw_ranges[mid][1])
      lo = mid + 1;
    else
      return true;
  }
  return false;
}

static uint32_t next_code_point(const uint8_t *s, size_t len, size_t *at) {
  uint8_t c = s[*at];
  size_t n = c < 0x80 ? 0 : c < 0xE0 ? 1 : c < 0xF0 ? 2 : 3;
  if (len - *at - 1 < n) {
    *at = len;
    return 0xFFFD;
  }
  uint32_t cp = n == 0 ? c : n == 1 ? (c & 0x1Fu) : n == 2 ? (c & 0x0Fu) : (c & 0x07u);
  for (size_t k = 1; k <= n; k++) cp = (cp << 6) | (s[*at + k] & 0x3Fu);
  *at += n + 1;
  return cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) ? 0xFFFD : cp;
}

static size_t encode_utf8(uint32_t cp, char *out) {
  if (cp < 0x80) {
    out[0] = (char)cp;
    return 1;
  }
  if (cp < 0x800) {
    out[0] = (char)(0xC0 | (cp >> 6));
    out[1] = (char)(0x80 | (cp & 0x3F));
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = (char)(0xE0 | (cp >> 12));
    out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[2] = (char)(0x80 | (cp & 0x3F));
    return 3;
  }
  out[0] = (char)(0xF0 | (cp >> 18));
  out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
  out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
  out[3] = (char)(0x80 | (cp & 0x3F));
  return 4;
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
  (void)agc_size_add(agc_size_mul(s->bytes, 10), 2);
  const uint8_t *data = (const uint8_t *)s->data;
  size_t n = 0, count = 0, at = 0;
  if (out) out[n] = '"';
  n++;
  count++;
  while (at < s->bytes) {
    uint32_t cp = next_code_point(data, s->bytes, &at);
    char piece[12];
    const char *escape = short_escape(cp);
    size_t len;
    if (escape) {
      len = 2;
      count += 2;
    } else if (agc_write_raw(cp)) {
      len = encode_utf8(cp, piece);
      escape = piece;
      count++;
    } else {
      len = (size_t)snprintf(piece, sizeof piece, cp < 0x10000 ? "\\u%04" PRIX32 : "\\U%08" PRIX32, cp);
      escape = piece;
      count += len;
    }
    if (out) memcpy(out + n, escape, len);
    n += len;
  }
  if (out) out[n] = '"';
  n++;
  count++;
  *chars = count;
  return n;
}

agc_string *agc_concat(const agc_string *a, const agc_string *b) {
  agc_string *s = agc_new_string(agc_size_add(a->bytes, b->bytes), agc_size_add(a->chars, b->chars));
  if (a->bytes) memcpy(s->data, a->data, a->bytes);
  if (b->bytes) memcpy(s->data + a->bytes, b->data, b->bytes);
  return s;
}

agc_string *agc_text(agc_vm *vm, agc_value v) {
  char text[AGC_FLOAT_TEXT];
  size_t n;
  if (agc_is(v, AGC_T_STRING)) return agc_as_string(vm, v);
  if (agc_is(v, AGC_T_NIL)) return agc_make_string("nil", 3, 3);
  if (agc_is(v, AGC_T_BOOL)) return agc_as_bool(vm, v) ? agc_make_string("true", 4, 4) : agc_make_string("false", 5, 5);
  if (agc_is(v, AGC_T_FLOAT))
    n = agc_float_text(agc_as_float(vm, v), text);
  else
    n = (size_t)snprintf(text, sizeof text, "%" PRId64, agc_as_int(vm, v));
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
