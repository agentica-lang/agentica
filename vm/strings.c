#include "agc.h"

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

#define SIGMA 0x3A3u
#define SMALL_SIGMA 0x3C3u
#define FINAL_SIGMA 0x3C2u

typedef struct {
  const uint8_t *p;
  size_t m;
  size_t *fail;
} finder;

static agc_string empty_text = {0, 0};

size_t agc_utf8_encode(uint32_t cp, char out[4]) {
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

size_t agc_utf8_count(const uint8_t *s, size_t len) {
  size_t count = 0;
  for (size_t i = 0; i < len; i++) count += (s[i] & 0xC0) != 0x80;
  return count;
}

static size_t walk(const agc_string *s, size_t index, size_t from_index, size_t offset) {
  const uint8_t *data = (const uint8_t *)s->data;
  for (; from_index < index && offset < s->bytes; from_index++) agc_utf8_next(data, s->bytes, &offset);
  for (; from_index > index && offset > 0; from_index--) {
    do offset--;
    while (offset > 0 && (data[offset] & 0xC0) == 0x80);
  }
  return offset;
}

static void remember(agc_vm *vm, const agc_string *s, size_t index, size_t offset) {
  vm->cursor = s;
  vm->cursor_index = index;
  vm->cursor_offset = offset;
}

size_t agc_utf8_offset(agc_vm *vm, const agc_string *s, size_t index) {
  if (s->bytes == s->chars) return index;
  size_t from_index = 0, offset = 0, cost = index;
  if (s->chars - index < cost) {
    from_index = s->chars;
    offset = s->bytes;
    cost = s->chars - index;
  }
  if (vm->cursor == s) {
    size_t ci = vm->cursor_index;
    size_t gap = ci > index ? ci - index : index - ci;
    if (gap < cost) {
      from_index = ci;
      offset = vm->cursor_offset;
    }
  }
  offset = walk(s, index, from_index, offset);
  remember(vm, s, index, offset);
  return offset;
}

static finder make_finder(const agc_string *part) {
  finder f = {(const uint8_t *)part->data, part->bytes, NULL};
  if (f.m <= 8) return f;
  f.fail = agc_alloc_atomic(agc_size_mul(f.m, sizeof(size_t)));
  f.fail[0] = 0;
  for (size_t i = 1, k = 0; i < f.m; i++) {
    while (k > 0 && f.p[i] != f.p[k]) k = f.fail[k - 1];
    if (f.p[i] == f.p[k]) k++;
    f.fail[i] = k;
  }
  return f;
}

static size_t find(const finder *f, const agc_string *text, size_t from) {
  const uint8_t *t = (const uint8_t *)text->data;
  size_t n = text->bytes, m = f->m;
  if (from > n || m > n - from) return AGC_NOT_FOUND;
  if (m == 0) return from;
  if (!f->fail) {
    const uint8_t *last = t + n - m;
    for (const uint8_t *at = t + from; at <= last; at++) {
      at = memchr(at, f->p[0], (size_t)(last - at) + 1);
      if (!at) break;
      if (memcmp(at + 1, f->p + 1, m - 1) == 0) return (size_t)(at - t);
    }
    return AGC_NOT_FOUND;
  }
  for (size_t i = from, k = 0; i < n; i++) {
    while (k > 0 && t[i] != f->p[k]) k = f->fail[k - 1];
    if (t[i] == f->p[k]) k++;
    if (k == m) return i + 1 - m;
  }
  return AGC_NOT_FOUND;
}

size_t agc_text_find(const agc_string *text, const agc_string *part, size_t from) {
  if (part->bytes > text->bytes) return AGC_NOT_FOUND;
  finder f = make_finder(part);
  return find(&f, text, from);
}

static size_t count_matches(const finder *f, const agc_string *text) {
  size_t count = 0;
  for (size_t at = find(f, text, 0); at != AGC_NOT_FOUND; at = find(f, text, at + f->m)) count++;
  return count;
}

static agc_string *piece(const agc_string *s, size_t start, size_t end) {
  return agc_make_string(s->data + start, end - start, agc_utf8_count((const uint8_t *)s->data + start, end - start));
}

static const uint32_t *case_row(const uint32_t (*map)[4], size_t count, uint32_t cp) {
  size_t lo = 0, hi = count;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    if (cp < map[mid][0])
      hi = mid;
    else if (cp > map[mid][0])
      lo = mid + 1;
    else
      return map[mid];
  }
  return NULL;
}

static size_t mapped(bool up, uint32_t cp, uint32_t out[3]) {
  if (cp < 0x80) {
    if (up && cp >= 'a' && cp <= 'z') cp -= 32;
    if (!up && cp >= 'A' && cp <= 'Z') cp += 32;
    out[0] = cp;
    return 1;
  }
  const uint32_t *row = up ? case_row(agc_upcase_map, agc_upcase_map_count, cp)
                           : case_row(agc_downcase_map, agc_downcase_map_count, cp);
  if (!row) {
    out[0] = cp;
    return 1;
  }
  size_t n = 0;
  while (n < 3 && row[n + 1]) {
    out[n] = row[n + 1];
    n++;
  }
  return n;
}

static bool cased(uint32_t cp) { return agc_in_ranges(agc_cased_ranges, agc_cased_count, cp); }

static bool case_ignorable(uint32_t cp) {
  return agc_in_ranges(agc_case_ignorable_ranges, agc_case_ignorable_count, cp);
}

static bool cased_after(const uint8_t *s, size_t len, size_t at) {
  while (at < len) {
    uint32_t cp = agc_utf8_next(s, len, &at);
    if (cased(cp)) return true;
    if (!case_ignorable(cp)) return false;
  }
  return false;
}

agc_string *agc_change_case(const agc_string *s, bool up) {
  const uint8_t *data = (const uint8_t *)s->data;
  size_t bytes = 0, chars = 0;
  bool sigma = false;
  uint32_t out[3];
  char buf[4];
  for (size_t at = 0; at < s->bytes;) {
    uint32_t cp = agc_utf8_next(data, s->bytes, &at);
    sigma = sigma || cp == SIGMA;
    size_t n = mapped(up, cp, out);
    chars = agc_size_add(chars, n);
    for (size_t k = 0; k < n; k++) bytes = agc_size_add(bytes, agc_utf8_encode(out[k], buf));
  }
  agc_string *result = agc_new_string(bytes, chars);
  bool before = false;
  size_t w = 0;
  for (size_t at = 0; at < s->bytes;) {
    uint32_t cp = agc_utf8_next(data, s->bytes, &at);
    size_t n = mapped(up, cp, out);
    if (!up && cp == SIGMA && before && !cased_after(data, s->bytes, at)) out[0] = FINAL_SIGMA;
    if (!up && sigma) before = cased(cp) || (before && case_ignorable(cp));
    for (size_t k = 0; k < n; k++) {
      size_t len = agc_utf8_encode(out[k], buf);
      memcpy(result->data + w, buf, len);
      w += len;
    }
  }
  return result;
}

static bool trim_space(uint8_t c) { return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r'; }

agc_number_status agc_parse_int(const uint8_t *s, size_t len, int64_t *value) {
  size_t i = len > 0 && (s[0] == '+' || s[0] == '-') ? 1 : 0;
  if (i == len) return AGC_NUMBER_INVALID;
  for (size_t k = i; k < len; k++)
    if (s[k] < '0' || s[k] > '9') return AGC_NUMBER_INVALID;
  bool negative = s[0] == '-';
  uint64_t limit = negative ? (uint64_t)INT64_MAX + 1 : (uint64_t)INT64_MAX, n = 0;
  for (size_t k = i; k < len; k++) {
    uint64_t digit = (uint64_t)(s[k] - '0');
    if (n > (limit - digit) / 10) return AGC_NUMBER_OVERFLOW;
    n = n * 10 + digit;
  }
  *value = negative ? (n == (uint64_t)INT64_MAX + 1 ? INT64_MIN : -(int64_t)n) : (int64_t)n;
  return AGC_NUMBER_OK;
}

agc_number_status agc_parse_float(const uint8_t *s, size_t len, double *value) {
  size_t i = len > 0 && (s[0] == '+' || s[0] == '-') ? 1 : 0, digits = 0;
  while (i < len && s[i] >= '0' && s[i] <= '9') i++, digits++;
  if (digits == 0) return AGC_NUMBER_INVALID;
  bool fraction = i < len && s[i] == '.';
  if (fraction) {
    size_t after = 0;
    for (i++; i < len && s[i] >= '0' && s[i] <= '9'; i++) after++;
    if (after == 0) return AGC_NUMBER_INVALID;
  }
  if (i != len) return AGC_NUMBER_INVALID;
  char *text = agc_alloc_atomic(agc_size_add(len, 1));
  memcpy(text, s, len);
  text[len] = '\0';
  double x = strtod(text, NULL);
  *value = !fraction && x == 0 ? 0.0 : x;
  return AGC_NUMBER_OK;
}

static agc_string *ascii(const char *text) {
  size_t n = strlen(text);
  return agc_make_string(text, n, n);
}

agc_string *agc_around(const char *before, const agc_string *part, const char *after) {
  size_t chars;
  size_t form = agc_write_form(part, NULL, &chars);
  size_t b = strlen(before), a = strlen(after);
  agc_string *s = agc_new_string(agc_size_add(agc_size_add(b, form), a), chars + b + a);
  memcpy(s->data, before, b);
  agc_write_form(part, s->data + b, &chars);
  memcpy(s->data + b + form, after, a);
  return s;
}

static agc_value failure(agc_string *message) { return agc_result_value(false, agc_string_value(message)); }

static agc_value builtin_length(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int((int64_t)agc_as_string(vm, args[0])->chars);
}

static agc_value builtin_upcase(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_string_value(agc_change_case(agc_as_string(vm, args[0]), true));
}

static agc_value builtin_downcase(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_string_value(agc_change_case(agc_as_string(vm, args[0]), false));
}

static agc_value builtin_trim(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  const uint8_t *data = (const uint8_t *)s->data;
  size_t start = 0, end = s->bytes;
  while (start < end && trim_space(data[start])) start++;
  while (end > start && trim_space(data[end - 1])) end--;
  return agc_string_value(agc_make_string(s->data + start, end - start, s->chars - (s->bytes - (end - start))));
}

static agc_value builtin_split(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]), *sep = agc_as_string(vm, args[1]);
  agc_list *l;
  if (sep->bytes == 0) {
    l = agc_new_list(s->chars);
    size_t at = 0;
    for (size_t k = 0; k < s->chars; k++) {
      size_t start = at;
      agc_utf8_next((const uint8_t *)s->data, s->bytes, &at);
      l->items[k] = agc_string_value(agc_make_string(s->data + start, at - start, 1));
    }
    return agc_list_value(l);
  }
  if (sep->bytes > s->bytes) {
    l = agc_new_list(1);
    l->items[0] = args[0];
    return agc_list_value(l);
  }
  finder f = make_finder(sep);
  l = agc_new_list(agc_size_add(count_matches(&f, s), 1));
  size_t start = 0, k = 0;
  for (size_t at = find(&f, s, 0); at != AGC_NOT_FOUND; at = find(&f, s, start)) {
    l->items[k++] = agc_string_value(piece(s, start, at));
    start = at + sep->bytes;
  }
  l->items[k] = agc_string_value(piece(s, start, s->bytes));
  return agc_list_value(l);
}

static agc_value builtin_join(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *parts = agc_as_list(vm, args[0]);
  const agc_string *sep = agc_as_string(vm, args[1]);
  if (parts->len == 0) return agc_string_value(&empty_text);
  size_t bytes = agc_size_mul(parts->len - 1, sep->bytes), chars = agc_size_mul(parts->len - 1, sep->chars);
  for (size_t k = 0; k < parts->len; k++) {
    const agc_string *part = agc_as_string(vm, parts->items[k]);
    bytes = agc_size_add(bytes, part->bytes);
    chars = agc_size_add(chars, part->chars);
  }
  agc_string *result = agc_new_string(bytes, chars);
  size_t w = 0;
  for (size_t k = 0; k < parts->len; k++) {
    const agc_string *part = agc_as_string(vm, parts->items[k]);
    if (k > 0 && sep->bytes) {
      memcpy(result->data + w, sep->data, sep->bytes);
      w += sep->bytes;
    }
    if (part->bytes) memcpy(result->data + w, part->data, part->bytes);
    w += part->bytes;
  }
  return agc_string_value(result);
}

static agc_value builtin_contains(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_bool(agc_text_find(agc_as_string(vm, args[0]), agc_as_string(vm, args[1]), 0) != AGC_NOT_FOUND);
}

static agc_value builtin_starts_with(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]), *p = agc_as_string(vm, args[1]);
  return agc_bool(p->bytes <= s->bytes && memcmp(s->data, p->data, p->bytes) == 0);
}

static agc_value builtin_ends_with(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]), *p = agc_as_string(vm, args[1]);
  return agc_bool(p->bytes <= s->bytes && memcmp(s->data + (s->bytes - p->bytes), p->data, p->bytes) == 0);
}

static agc_value builtin_replace(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]), *from = agc_as_string(vm, args[1]),
                   *to = agc_as_string(vm, args[2]);
  agc_string *result;
  size_t w = 0;
  if (from->bytes == 0) {
    size_t gaps = agc_size_add(s->chars, 1);
    result = agc_new_string(agc_size_add(s->bytes, agc_size_mul(gaps, to->bytes)),
                            agc_size_add(s->chars, agc_size_mul(gaps, to->chars)));
    for (size_t at = 0;;) {
      if (to->bytes) memcpy(result->data + w, to->data, to->bytes);
      w += to->bytes;
      if (at == s->bytes) break;
      size_t start = at;
      agc_utf8_next((const uint8_t *)s->data, s->bytes, &at);
      memcpy(result->data + w, s->data + start, at - start);
      w += at - start;
    }
    return agc_string_value(result);
  }
  if (from->bytes > s->bytes) return args[0];
  finder f = make_finder(from);
  size_t count = count_matches(&f, s);
  if (count == 0) return args[0];
  size_t bytes = agc_size_add(s->bytes - count * from->bytes, agc_size_mul(count, to->bytes));
  size_t chars = agc_size_add(s->chars - count * from->chars, agc_size_mul(count, to->chars));
  result = agc_new_string(bytes, chars);
  size_t start = 0;
  for (size_t at = find(&f, s, 0); at != AGC_NOT_FOUND; at = find(&f, s, start)) {
    memcpy(result->data + w, s->data + start, at - start);
    w += at - start;
    if (to->bytes) memcpy(result->data + w, to->data, to->bytes);
    w += to->bytes;
    start = at + from->bytes;
  }
  if (s->bytes > start) memcpy(result->data + w, s->data + start, s->bytes - start);
  return agc_string_value(result);
}

static agc_value builtin_slice(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_string *s = agc_as_string(vm, args[0]);
  int64_t start = agc_as_int(vm, args[1]), length = agc_as_int(vm, args[2]);
  if (start < 0 || length < 0 || (uint64_t)start > s->chars || (uint64_t)length > s->chars - (uint64_t)start) {
    char text[128];
    snprintf(text, sizeof text, "slice %" PRId64 ",%" PRId64 " is outside a string of length %zu", start, length,
             s->chars);
    agc_fail_text(vm, "RUNTIME-INDEX-OUT-OF-RANGE", ascii(text), span);
  }
  size_t from = agc_utf8_offset(vm, s, (size_t)start);
  size_t at = from + (size_t)length;
  if (s->bytes != s->chars) {
    at = walk(s, (size_t)start + (size_t)length, (size_t)start, from);
    remember(vm, s, (size_t)start + (size_t)length, at);
  }
  return agc_string_value(agc_make_string(s->data + from, at - from, (size_t)length));
}

static agc_value builtin_index_of(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]), *part = agc_as_string(vm, args[1]);
  size_t at = agc_text_find(s, part, 0);
  if (at == AGC_NOT_FOUND) return failure(agc_around("", part, " not found"));
  return agc_result_value(true, agc_int((int64_t)agc_utf8_count((const uint8_t *)s->data, at)));
}

static agc_value builtin_at(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_string *s = agc_as_string(vm, args[0]);
  int64_t index = agc_as_int(vm, args[1]);
  if (index < 0 || (uint64_t)index >= s->chars)
    agc_fail(vm, "RUNTIME-INDEX-OUT-OF-RANGE", "string index is out of range", span + 2);
  size_t from = agc_utf8_offset(vm, s, (size_t)index), at = from;
  agc_utf8_next((const uint8_t *)s->data, s->bytes, &at);
  if (s->bytes != s->chars) remember(vm, s, (size_t)index + 1, at);
  return agc_string_value(agc_make_string(s->data + from, at - from, 1));
}

static agc_value builtin_reverse(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  agc_string *result = agc_new_string(s->bytes, s->chars);
  for (size_t at = 0; at < s->bytes;) {
    size_t start = at;
    agc_utf8_next((const uint8_t *)s->data, s->bytes, &at);
    memcpy(result->data + (s->bytes - at), s->data + start, at - start);
  }
  return agc_string_value(result);
}

static agc_value builtin_code(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_string *s = agc_as_string(vm, args[0]);
  if (s->chars != 1)
    agc_fail(vm, "RUNTIME-INVALID-CHARACTER", "String.code needs exactly one character", span + 1);
  size_t at = 0;
  return agc_int(agc_utf8_next((const uint8_t *)s->data, s->bytes, &at));
}

static agc_value builtin_from_code(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t code = agc_as_int(vm, args[0]);
  if (code < 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF))
    agc_fail(vm, "RUNTIME-INVALID-CHARACTER", "not a Unicode scalar value", span + 1);
  char buf[4];
  size_t n = agc_utf8_encode((uint32_t)code, buf);
  return agc_string_value(agc_make_string(buf, n, 1));
}

static agc_value builtin_from_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *data = agc_as_list(vm, args[0]);
  for (size_t k = 0; k < data->len; k++) {
    int64_t b = agc_as_int(vm, data->items[k]);
    if (b < 0 || b > 255) return failure(ascii("bytes must be integers between 0 and 255"));
  }
  agc_string *s = agc_new_string(data->len, 0);
  for (size_t k = 0; k < data->len; k++) s->data[k] = (char)(uint8_t)agc_as_int(vm, data->items[k]);
  if (!agc_utf8_chars((const uint8_t *)s->data, s->bytes, &s->chars))
    return failure(ascii("invalid or incomplete UTF-8"));
  return agc_result_value(true, agc_string_value(s));
}

static agc_value to_int(agc_vm *vm, agc_value *args, uint32_t span, bool bang) {
  const agc_string *s = agc_as_string(vm, args[0]);
  int64_t n;
  agc_number_status status = agc_parse_int((const uint8_t *)s->data, s->bytes, &n);
  if (status == AGC_NUMBER_OK) return bang ? agc_int(n) : agc_result_value(true, agc_int(n));
  bool invalid = status == AGC_NUMBER_INVALID;
  agc_string *message =
    invalid ? agc_around("cannot convert ", s, " to Int") : ascii("Int result is outside the 64-bit range");
  if (bang) agc_fail_text(vm, invalid ? "RUNTIME-INVALID-NUMBER" : "RUNTIME-INTEGER-OVERFLOW", message, span);
  return failure(message);
}

static agc_value builtin_to_int(agc_vm *vm, agc_value *args, uint32_t span) { return to_int(vm, args, span, false); }

static agc_value builtin_to_int_bang(agc_vm *vm, agc_value *args, uint32_t span) {
  return to_int(vm, args, span, true);
}

static agc_value to_float(agc_vm *vm, agc_value *args, uint32_t span, bool bang) {
  const agc_string *s = agc_as_string(vm, args[0]);
  double x;
  if (agc_parse_float((const uint8_t *)s->data, s->bytes, &x) == AGC_NUMBER_OK)
    return bang ? agc_float(x) : agc_result_value(true, agc_float(x));
  agc_string *message = agc_around("cannot convert ", s, " to Float");
  if (bang) agc_fail_text(vm, "RUNTIME-INVALID-NUMBER", message, span);
  return failure(message);
}

static agc_value builtin_to_float(agc_vm *vm, agc_value *args, uint32_t span) {
  return to_float(vm, args, span, false);
}

static agc_value builtin_to_float_bang(agc_vm *vm, agc_value *args, uint32_t span) {
  return to_float(vm, args, span, true);
}

const agc_builtin agc_string_builtins[] = {
  {"String.length", 1, builtin_length, AGC_NATIVE_NONE},
  {"String.upcase", 1, builtin_upcase, AGC_NATIVE_NONE},
  {"String.downcase", 1, builtin_downcase, AGC_NATIVE_NONE},
  {"String.trim", 1, builtin_trim, AGC_NATIVE_NONE},
  {"String.split", 2, builtin_split, AGC_NATIVE_NONE},
  {"String.join", 2, builtin_join, AGC_NATIVE_NONE},
  {"String.contains?", 2, builtin_contains, AGC_NATIVE_NONE},
  {"String.starts_with?", 2, builtin_starts_with, AGC_NATIVE_NONE},
  {"String.ends_with?", 2, builtin_ends_with, AGC_NATIVE_NONE},
  {"String.replace", 3, builtin_replace, AGC_NATIVE_NONE},
  {"String.slice", 3, builtin_slice, AGC_NATIVE_NONE},
  {"String.index_of", 2, builtin_index_of, AGC_NATIVE_NONE},
  {"String.at", 2, builtin_at, AGC_NATIVE_NONE},
  {"String.reverse", 1, builtin_reverse, AGC_NATIVE_NONE},
  {"String.code", 1, builtin_code, AGC_NATIVE_NONE},
  {"String.from_code", 1, builtin_from_code, AGC_NATIVE_NONE},
  {"String.from_bytes", 1, builtin_from_bytes, AGC_NATIVE_NONE},
  {"String.to_int", 1, builtin_to_int, AGC_NATIVE_NONE},
  {"String.to_int!", 1, builtin_to_int_bang, AGC_NATIVE_NONE},
  {"String.to_float", 1, builtin_to_float, AGC_NATIVE_NONE},
  {"String.to_float!", 1, builtin_to_float_bang, AGC_NATIVE_NONE},
};

const size_t agc_string_builtin_count = sizeof agc_string_builtins / sizeof agc_string_builtins[0];
