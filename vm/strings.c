/*
 * The String builtins (one of the tables that agc_find_builtin searches), with
 * UTF-8 encoding, offsets through a per-task cursor, KMP search, case mapping,
 * the Int and Float parsers, and the edit distance and Jaro-Winkler similarity
 * of two Strings. Service layer. Design:
 * docs/vm/02-reference-behavior.md §2.3.
 */
#include "services.h"

#include <inttypes.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define SIGMA 0x3A3u
#define SMALL_SIGMA 0x3C3u
#define FINAL_SIGMA 0x3C2u
#define ASCII_HIGH_BITS UINT64_C(0x8080808080808080)
/* Code points (and cells) that the distances keep on the C stack before they take GC memory. */
#define DISTANCE_STACK 64
/* A distance whose quadratic work (table cells, or Jaro comparisons) fits one turn's cost runs in the call; a longer
   one runs as a stepper (port.h), DISTANCE_CHUNK of that work per STEP, so it yields between turns and meets
   --max-steps. Each AGC_COST_BYTES of the work is a unit of turn cost. */
#define DISTANCE_DIRECT ((size_t)AGC_TURN_STEPS * AGC_COST_BYTES)
#define DISTANCE_CHUNK 4096
#define CONTINUATION(byte) (((byte) & 0xC0) == 0x80)

typedef agc_finder finder;

/* One s.edit_distance walk over the Levenshtein table, which can stop at any cell and go on from it. A is the shorter
   text (N code points), B the longer one as UTF-8 (M characters, read once, at AT). ROW holds the N + 1 cells of one
   row. The walk is at row I (1..M) and column J, up to HI; C is the row's character of B, and DIAG, LEFT and BEST are
   the cell above-left, the cell to the left and the row's smallest cell so far. Run as a stepper, the state is GC
   memory that the task's stepper keeps: TEXTS keeps both Strings alive while B points into one of them, and A and ROW
   are atomic blocks. */
typedef struct {
  agc_stepper stepper;
  agc_value texts[2];
  const uint32_t *a;
  const uint8_t *b;
  size_t *row;
  size_t n, m, b_bytes, at, cap, top;
  size_t i, j, hi, diag, left, best, result;
  uint32_t c, span;
} distance_run;

/* One s.jaro_winkler matching walk, which can stop at any comparison and go on from it: character I of A (N code
   points) against B (M) from J up to HI, within WINDOW of I. The same ownership as distance_run. */
typedef struct {
  agc_stepper stepper;
  agc_value texts[2];
  const uint32_t *a, *b;
  uint8_t *matched_a, *matched_b;
  size_t n, m, window, i, j, hi, matches;
  uint32_t span;
} jaro_run;

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

/* Moves from character from_index (at byte offset) to character index. A word of eight bytes without the high bit is
   eight ASCII characters, so a run of ASCII is crossed a word at a time; elsewhere a character is its lead byte and
   the continuation bytes (10xxxxxx) after it, the same rule agc_utf8_count counts by. */
static size_t walk(const agc_string *s, size_t index, size_t from_index, size_t offset) {
  const uint8_t *data = (const uint8_t *)s->data;
  uint64_t word;
  while (from_index < index && offset < s->bytes) {
    if (index - from_index >= sizeof word && s->bytes - offset >= sizeof word) {
      memcpy(&word, data + offset, sizeof word);
      if (!(word & ASCII_HIGH_BITS)) {
        offset += sizeof word;
        from_index += sizeof word;
        continue;
      }
    }
    do offset++;
    while (offset < s->bytes && (data[offset] & 0xC0) == 0x80);
    from_index++;
  }
  while (from_index > index && offset > 0) {
    if (from_index - index >= sizeof word && offset >= sizeof word) {
      memcpy(&word, data + offset - sizeof word, sizeof word);
      if (!(word & ASCII_HIGH_BITS)) {
        offset -= sizeof word;
        from_index -= sizeof word;
        continue;
      }
    }
    do offset--;
    while (offset > 0 && (data[offset] & 0xC0) == 0x80);
    from_index--;
  }
  return offset;
}

static void remember(agc_vm *vm, const agc_string *s, size_t index, size_t offset) {
  vm->task->cursor = s;
  vm->task->cursor_index = index;
  vm->task->cursor_offset = offset;
}

size_t agc_utf8_offset(agc_vm *vm, const agc_string *s, size_t index) {
  if (s->bytes == s->chars) return index;
  size_t from_index = 0, offset = 0, cost = index;
  if (s->chars - index < cost) {
    from_index = s->chars;
    offset = s->bytes;
    cost = s->chars - index;
  }
  if (vm->task->cursor == s) {
    size_t ci = vm->task->cursor_index;
    size_t gap = ci > index ? ci - index : index - ci;
    if (gap < cost) {
      from_index = ci;
      offset = vm->task->cursor_offset;
    }
  }
  offset = walk(s, index, from_index, offset);
  remember(vm, s, index, offset);
  return offset;
}

agc_finder agc_finder_new(const uint8_t *p, size_t m) {
  agc_finder f = {p, m, NULL};
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

static finder make_finder(const agc_string *part) { return agc_finder_new((const uint8_t *)part->data, part->bytes); }

size_t agc_finder_find(const agc_finder *f, const uint8_t *t, size_t n, size_t from) {
  size_t m = f->m;
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

static size_t find(const finder *f, const agc_string *text, size_t from) {
  return agc_finder_find(f, (const uint8_t *)text->data, text->bytes, from);
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

/* The piece [start, end) of s. The first two tests are agc_small_string, kept in line because split("") of a long text
   runs this once per character. */
static agc_value piece(agc_vm *vm, const agc_string *s, size_t start, size_t end) {
  size_t bytes = end - start;
  if (bytes == 1 && (uint8_t)s->data[start] < AGC_ASCII_CHARS)
    return agc_string_value(vm->rt->chars[(uint8_t)s->data[start]]);
  if (bytes == 0) return agc_string_value(vm->rt->empty_string);
  return agc_string_value(
      agc_make_string(s->data + start, bytes, agc_utf8_count((const uint8_t *)s->data + start, bytes)));
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

static size_t digit_run(const uint8_t *s, size_t len, size_t i) {
  while (i < len && s[i] >= '0' && s[i] <= '9') i++;
  return i;
}

/* Reads [+-]digits[.digits][(e|E)[+-]digits], or exactly a form agc_float_text writes for infinity and NaN, so
   every Float#to_s reads back. strtod rounds correctly and the VM never leaves the C locale; a huge exponent gives an
   infinity or zero. Integer text keeps its old rule: "-0" is 0.0. */
agc_number_status agc_parse_float(const uint8_t *s, size_t len, double *value) {
  static const char *const special[] = {"+inf.0", "-inf.0", "+nan.0"};
  for (size_t k = 0; k < 3; k++)
    if (len == 6 && memcmp(s, special[k], 6) == 0) {
      *value = k == 2 ? NAN : k == 0 ? INFINITY : -INFINITY;
      return AGC_NUMBER_OK;
    }
  size_t start = len > 0 && (s[0] == '+' || s[0] == '-') ? 1 : 0;
  size_t i = digit_run(s, len, start);
  if (i == start) return AGC_NUMBER_INVALID;
  bool integer = true;
  if (i < len && s[i] == '.') {
    size_t after = digit_run(s, len, i + 1);
    if (after == i + 1) return AGC_NUMBER_INVALID;
    i = after;
    integer = false;
  }
  if (i < len && (s[i] == 'e' || s[i] == 'E')) {
    size_t sign = i + 1 < len && (s[i + 1] == '+' || s[i + 1] == '-') ? i + 2 : i + 1;
    i = digit_run(s, len, sign);
    if (i == sign) return AGC_NUMBER_INVALID;
    integer = false;
  }
  if (i != len) return AGC_NUMBER_INVALID;
  char *text = agc_alloc_atomic(agc_size_add(len, 1));
  memcpy(text, s, len);
  text[len] = '\0';
  double x = strtod(text, NULL);
  *value = integer && x == 0 ? 0.0 : x;
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

static agc_value failure(agc_vm *vm, agc_string *message) { return agc_error_string(vm, "error", message); }

/* In plain_leaves (vm/jit/jit.c): it must never agc_fail once its argument tags are right. */
static agc_value builtin_length(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int((int64_t)agc_as_string(vm, args[0])->chars);
}

/* The number of UTF-8 bytes, which the String keeps: no walk over the text. */
static agc_value builtin_bytesize(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int((int64_t)agc_as_string(vm, args[0])->bytes);
}

/* Upper or lower case of the String in args[0]. A String of no characters is its own result, and one ASCII character
   maps by itself (no special casing applies to ASCII), so neither allocates. */
static agc_value change_case(agc_vm *vm, agc_value *args, bool up) {
  const agc_string *s = agc_as_string(vm, args[0]);
  if (s->bytes == 0) return args[0];
  if (s->bytes == 1 && (uint8_t)s->data[0] < AGC_ASCII_CHARS) {
    char c = s->data[0];
    if (up && c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    if (!up && c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    return agc_string_value(vm->rt->chars[(uint8_t)c]);
  }
  return agc_string_value(agc_change_case(s, up));
}

static agc_value builtin_upcase(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return change_case(vm, args, true);
}

static agc_value builtin_downcase(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return change_case(vm, args, false);
}

static agc_value builtin_trim(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  const uint8_t *data = (const uint8_t *)s->data;
  size_t start = 0, end = s->bytes;
  while (start < end && trim_space(data[start])) start++;
  while (end > start && trim_space(data[end - 1])) end--;
  size_t kept = end - start;
  if (kept == s->bytes) return args[0];
  /* The trimmed bytes are ASCII, one character each. */
  return agc_string_value(agc_small_string(vm, s->data + start, kept, s->chars - (s->bytes - kept)));
}

static agc_value builtin_split(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]), *sep = agc_as_string(vm, args[1]);
  agc_list_builder b;
  if (sep->bytes == 0) {
    if (s->chars == 0) return vm->rt->empty_list;
    agc_list_builder_sized(&b, s->chars);
    size_t at = 0;
    bool ascii = s->bytes == s->chars;
    for (size_t k = 0; k < s->chars; k++) {
      size_t start = at;
      if (ascii)
        at++;
      else
        agc_utf8_next((const uint8_t *)s->data, s->bytes, &at);
      agc_list_builder_push(&b, piece(vm, s, start, at));
    }
    return agc_list_value(agc_list_builder_finish(&b));
  }
  if (sep->bytes > s->bytes) {
    agc_list_builder_sized(&b, 1);
    agc_list_builder_push(&b, args[0]);
    return agc_list_value(agc_list_builder_finish(&b));
  }
  finder f = make_finder(sep);
  agc_list_builder_sized(&b, agc_size_add(count_matches(&f, s), 1));
  size_t start = 0;
  for (size_t at = find(&f, s, 0); at != AGC_NOT_FOUND; at = find(&f, s, start)) {
    agc_list_builder_push(&b, piece(vm, s, start, at));
    start = at + sep->bytes;
  }
  agc_list_builder_push(&b, piece(vm, s, start, s->bytes));
  return agc_list_value(agc_list_builder_finish(&b));
}

static agc_value builtin_join(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *parts = agc_as_list(vm, args[0]);
  const agc_string *sep = agc_as_string(vm, args[1]);
  size_t count = agc_list_len(parts);
  if (count == 0) return agc_string_value(vm->rt->empty_string);
  size_t bytes = agc_size_mul(count - 1, sep->bytes), chars = agc_size_mul(count - 1, sep->chars);
  agc_list_cursor cursor;
  agc_value item;
  agc_list_cursor_begin(&cursor, parts, 0);
  while (agc_list_cursor_next(&cursor, &item)) {
    const agc_string *part = agc_as_string(vm, item);
    bytes = agc_size_add(bytes, part->bytes);
    chars = agc_size_add(chars, part->chars);
  }
  if (bytes == 0) return agc_string_value(vm->rt->empty_string);
  agc_string *result = agc_new_string(bytes, chars);
  size_t w = 0;
  agc_list_cursor_begin(&cursor, parts, 0);
  for (size_t k = 0; agc_list_cursor_next(&cursor, &item); k++) {
    const agc_string *part = agc_as_string(vm, item);
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
    size_t joined = agc_size_add(s->bytes, agc_size_mul(gaps, to->bytes));
    if (joined == 0) return agc_string_value(vm->rt->empty_string);
    result = agc_new_string(joined, agc_size_add(s->chars, agc_size_mul(gaps, to->chars)));
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
  if (bytes == 0) return agc_string_value(vm->rt->empty_string);
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
  if (length == 0) return agc_string_value(vm->rt->empty_string);
  /* The end is found from the nearest known place: the start just remembered as the cursor, or the end of the string
     (no walk at all for a slice that runs to the end). */
  size_t from = agc_utf8_offset(vm, s, (size_t)start);
  size_t at = agc_utf8_offset(vm, s, (size_t)start + (size_t)length);
  return agc_string_value(agc_small_string(vm, s->data + from, at - from, (size_t)length));
}

/* s.index_of(part): some(the character index of the first match), or none when part is absent. */
static agc_value builtin_index_of_optional(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_string *s = agc_as_string(vm, args[0]), *part = agc_as_string(vm, args[1]);
  size_t at = agc_text_find(s, part, 0);
  if (at == AGC_NOT_FOUND) return agc_optional_value(vm, false, agc_void(), span);
  return agc_optional_value(vm, true, agc_int((int64_t)agc_utf8_count((const uint8_t *)s->data, at)), span);
}

static agc_value builtin_at(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_string *s = agc_as_string(vm, args[0]);
  int64_t index = agc_as_int(vm, args[1]);
  if (index < 0 || (uint64_t)index >= s->chars)
    agc_fail(vm, "RUNTIME-INDEX-OUT-OF-RANGE", "string index is out of range", span + 2);
  size_t from = agc_utf8_offset(vm, s, (size_t)index), at = from;
  agc_utf8_next((const uint8_t *)s->data, s->bytes, &at);
  if (s->bytes != s->chars) remember(vm, s, (size_t)index + 1, at);
  return agc_string_value(agc_small_string(vm, s->data + from, at - from, 1));
}

static agc_value builtin_reverse(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  if (s->chars <= 1) return args[0];
  agc_string *result = agc_new_string(s->bytes, s->chars);
  for (size_t at = 0; at < s->bytes;) {
    size_t start = at;
    agc_utf8_next((const uint8_t *)s->data, s->bytes, &at);
    memcpy(result->data + (s->bytes - at), s->data + start, at - start);
  }
  return agc_string_value(result);
}

/* s * n, Ruby's String#*: n copies of s. A negative n is an error, as Ruby's ArgumentError, and so is a result over
   REPEAT_MAX_BYTES, so a large count fails at the count instead of asking the GC for gigabytes. The copy doubles what
   is written, so it takes log2(n) memcpy calls. */
#define REPEAT_MAX_BYTES ((size_t)256 * 1024 * 1024)
_Static_assert(REPEAT_MAX_BYTES == 268435456, "the error of builtin_multiply names the limit");

static agc_value builtin_multiply(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_string *s = agc_as_string(vm, args[0]);
  int64_t count = agc_as_int(vm, args[1]);
  if (count < 0) agc_fail(vm, "RUNTIME-INVALID-COUNT", "count must be nonnegative", span + 2);
  if (count == 0 || s->bytes == 0) return agc_string_value(vm->rt->empty_string);
  if (count == 1) return args[0];
  if ((uint64_t)count > REPEAT_MAX_BYTES / s->bytes)
    agc_fail(vm, "RUNTIME-INVALID-COUNT", "the repeated string would be over 268435456 bytes", span + 2);
  size_t bytes = s->bytes * (size_t)count;
  agc_string *result = agc_new_string(bytes, s->chars * (size_t)count);
  memcpy(result->data, s->data, s->bytes);
  for (size_t written = s->bytes; written < bytes;) {
    size_t step = written < bytes - written ? written : bytes - written;
    memcpy(result->data + written, result->data, step);
    written += step;
  }
  return agc_string_value(result);
}

/* In plain_leaves (vm/jit/jit.c): it must never agc_fail once its argument tag and its one character are checked. */
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
  return agc_string_value(agc_small_string(vm, buf, n, 1));
}

/* String.from_bytes: the String of a Bytes, decoded strictly: error for invalid or incomplete UTF-8. */
static agc_value builtin_from_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  size_t n, chars;
  const uint8_t *data = agc_bytes_data(vm, args[0], &n);
  if (!agc_utf8_chars(data, n, &chars)) return failure(vm, ascii("invalid or incomplete UTF-8"));
  return agc_result_value(true, agc_string_value(agc_small_string(vm, (const char *)data, n, chars)));
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
  return failure(vm, message);
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
  return failure(vm, message);
}

static agc_value builtin_to_float(agc_vm *vm, agc_value *args, uint32_t span) {
  return to_float(vm, args, span, false);
}

static agc_value builtin_to_float_bang(agc_vm *vm, agc_value *args, uint32_t span) {
  return to_float(vm, args, span, true);
}

/* -1, 0 or 1 in the order List.sort gives Strings: by bytes, which is the order of the code points in UTF-8. */
static int byte_order(const agc_string *a, const agc_string *b) {
  size_t n = a->bytes < b->bytes ? a->bytes : b->bytes;
  int order = n ? memcmp(a->data, b->data, n) : 0;
  if (order == 0) return a->bytes < b->bytes ? -1 : a->bytes > b->bytes ? 1 : 0;
  return order < 0 ? -1 : 1;
}

static agc_value builtin_compare(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(byte_order(agc_as_string(vm, args[0]), agc_as_string(vm, args[1])));
}

/* The code points of the CHARS characters in BYTES bytes of UTF-8 at DATA: in SMALL (DISTANCE_STACK of them) when it
   is given and they fit there, else in new GC memory, which the caller keeps alive. */
static uint32_t *code_points(const char *data, size_t bytes, size_t chars, uint32_t *small) {
  uint32_t *out = small && chars <= DISTANCE_STACK ? small : agc_alloc_atomic(agc_size_mul(chars, sizeof *out));
  for (size_t at = 0, k = 0; k < chars; k++) out[k] = agc_utf8_next((const uint8_t *)data, bytes, &at);
  return out;
}

/* The bytes that X and Y share at their start (returned) and at their end (*suffix), each cut back to whole characters
   and not overlapping: neither changes the edit distance. The shared bytes are equal in both, so a character boundary
   in one is a boundary in the other. */
static size_t common_ends(const agc_string *x, const agc_string *y, size_t *suffix) {
  const uint8_t *a = (const uint8_t *)x->data, *b = (const uint8_t *)y->data;
  size_t shorter = x->bytes < y->bytes ? x->bytes : y->bytes, p = 0, s = 0;
  while (p < shorter && a[p] == b[p]) p++;
  while (p > 0 && ((p < x->bytes && CONTINUATION(a[p])) || (p < y->bytes && CONTINUATION(b[p])))) p--;
  while (s < shorter - p && a[x->bytes - 1 - s] == b[y->bytes - 1 - s]) s++;
  while (s > 0 && CONTINUATION(a[x->bytes - s])) s--;
  *suffix = s;
  return p;
}

/* Row I of the walk starts: its character of B, its band from lo to HI, and the cell left of the band. row[lo - 1]
   still holds the previous row's cell (in its band), and row[HI] past the previous band holds TOP. */
static void distance_row(distance_run *r) {
  r->c = agc_utf8_next(r->b, r->b_bytes, &r->at);
  size_t i = r->i, lo = i > r->cap ? i - r->cap : 1;
  r->hi = i + r->cap < r->n ? i + r->cap : r->n;
  r->diag = r->row[lo - 1];
  r->left = r->best = lo == 1 && i < r->top ? i : r->top;
  r->row[lo - 1] = r->left;
  r->j = lo;
}

/* The Levenshtein distance of A and B capped at CAP + 1 (TOP), for 1 <= N <= M and M - N <= CAP <= M. Only the cells
   within CAP of the diagonal can hold CAP or less, so a row computes those alone and TOP stands for the rest: a cell
   then holds its distance when that is CAP or less, and more than CAP otherwise. The smallest cell of a row never
   shrinks in the rows below, so a row with every cell past CAP ends the walk. Walks at most BUDGET cells, counted in
   *CELLS; true once RESULT holds the distance. */
static bool distance_walk(distance_run *r, size_t budget, size_t *cells) {
  for (;;) {
    size_t end = r->hi - r->j < budget ? r->hi + 1 : r->j + budget;
    size_t diag = r->diag, left = r->left, best = r->best, *row = r->row;
    const uint32_t *a = r->a;
    uint32_t c = r->c;
    for (size_t j = r->j; j < end; j++) {
      size_t up = row[j], near = (up < left ? up : left) + 1, v = diag + (a[j - 1] != c);
      if (near < v) v = near;
      diag = up;
      row[j] = left = v;
      if (v < best) best = v;
    }
    r->diag = diag, r->left = left, r->best = best;
    *cells += end - r->j;
    budget -= end - r->j;
    r->j = end;
    if (r->j <= r->hi) return false;
    if (best >= r->top || r->i == r->m) {
      r->result = best >= r->top || row[r->n] >= r->top ? r->top : row[r->n];
      return true;
    }
    r->i++;
    distance_row(r);
  }
}

static agc_step distance_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  (void)last;
  distance_run *r = (distance_run *)self;
  for (;;) {
    size_t cells = 0;
    bool done = distance_walk(r, DISTANCE_CHUNK, &cells);
    agc_charge(vm, cells / AGC_COST_BYTES);
    if (done) {
      agc_turn_charge(vm);
      return (agc_step){.kind = AGC_STEP_END, .value = agc_int((int64_t)r->result)};
    }
    /* Both run: the charge must not be skipped when the step count ends the turn first. */
    bool charged = agc_turn_charge(vm);
    if (agc_step_turn(vm, r->span) || charged) return (agc_step){.kind = AGC_STEP_YIELD};
  }
}

/* s.edit_distance(other), and with CAPPED s.edit_distance(other, max): the Levenshtein distance in characters, or
   max + 1 once it passes max. The common prefix and suffix are cut first; the shorter rest is decoded and the longer
   one walked, so memory is O(min(n, m)). A walk of at most DISTANCE_DIRECT cells runs here, on the C stack when the
   text is short; a longer one runs as a stepper. */
static agc_value edit_distance(agc_vm *vm, agc_value *args, uint32_t span, bool capped) {
  const agc_string *x = agc_as_string(vm, args[0]), *y = agc_as_string(vm, args[1]);
  int64_t max = capped ? agc_as_int(vm, args[2]) : 0;
  if (max < 0) agc_fail(vm, "RUNTIME-INVALID-COUNT", "max must be nonnegative", span + 3);
  size_t suffix, prefix = common_ends(x, y, &suffix);
  const char *xs = x->data + prefix, *ys = y->data + prefix;
  size_t xb = x->bytes - prefix - suffix, yb = y->bytes - prefix - suffix;
  size_t xn = agc_utf8_count((const uint8_t *)xs, xb), yn = agc_utf8_count((const uint8_t *)ys, yb);
  agc_charge(vm, (x->bytes + y->bytes) / AGC_COST_BYTES);
  if (xn > yn) {
    const char *ts = xs;
    size_t tb = xb, tn = xn;
    xs = ys, xb = yb, xn = yn;
    ys = ts, yb = tb, yn = tn;
  }
  size_t cap = capped && (uint64_t)max < yn ? (size_t)max : yn;
  if (yn - xn > cap) return agc_int((int64_t)cap + 1);
  if (xn == 0) return agc_int((int64_t)yn);
  /* The band is at most 2 * cap + 1 cells wide, and cap <= yn, so neither sum overflows. */
  size_t width = 2 * cap + 1 < xn ? 2 * cap + 1 : xn;
  bool direct = width <= DISTANCE_DIRECT / yn;
  distance_run local, *r = direct ? &local : agc_alloc(sizeof *r);
  uint32_t small_points[DISTANCE_STACK];
  size_t small_row[DISTANCE_STACK + 1];
  *r = (distance_run){.texts = {args[0], args[1]}, .b = (const uint8_t *)ys, .n = xn, .m = yn, .b_bytes = yb,
                      .cap = cap, .top = cap + 1, .i = 1, .span = span};
  r->a = code_points(xs, xb, xn, direct ? small_points : NULL);
  r->row = direct && xn < DISTANCE_STACK + 1 ? small_row : agc_alloc_atomic(agc_size_mul(xn + 1, sizeof *r->row));
  for (size_t j = 0; j <= xn; j++) r->row[j] = j < r->top ? j : r->top;
  distance_row(r);
  if (direct) {
    size_t cells = 0;
    (void)distance_walk(r, SIZE_MAX, &cells);
    agc_charge(vm, cells / AGC_COST_BYTES);
    return agc_int((int64_t)r->result);
  }
  r->stepper.step = distance_step;
  /* The step reads the immutable texts and writes only this run, which belongs to the calling task. */
  r->stepper.unlocked = true;
  r->stepper.no_block = true;
  agc_task_stepper(vm, &r->stepper);
  return agc_void();
}

static agc_value builtin_edit_distance(agc_vm *vm, agc_value *args, uint32_t span) {
  return edit_distance(vm, args, span, false);
}

static agc_value builtin_edit_distance_max(agc_vm *vm, agc_value *args, uint32_t span) {
  return edit_distance(vm, args, span, true);
}

/* Character I of A starts: its window of B, from J up to HI. */
static void jaro_row(jaro_run *r) {
  r->j = r->i > r->window ? r->i - r->window : 0;
  r->hi = r->i + r->window + 1 < r->m ? r->i + r->window + 1 : r->m;
}

/* Matches each character of A with the first unmatched equal character of B in its window. Makes at most BUDGET
   comparisons, counted in *CELLS; true once every character of A is done. */
static bool jaro_walk(jaro_run *r, size_t budget, size_t *cells) {
  while (r->i < r->n) {
    size_t end = r->hi - r->j < budget ? r->hi : r->j + budget, j = r->j;
    uint32_t c = r->a[r->i];
    while (j < end && (r->matched_b[j] || r->b[j] != c)) j++;
    bool found = j < end;
    *cells += j - r->j + found;
    budget -= j - r->j + found;
    if (found) {
      r->matched_a[r->i] = r->matched_b[j] = 1;
      r->matches++;
    } else if (end < r->hi) {
      r->j = end;
      return false;
    }
    r->i++;
    if (r->i < r->n) jaro_row(r);
    if (budget == 0 && r->i < r->n) return false;
  }
  return true;
}

/* The similarity once every match is found: half the transposed matches, rounded down, and the prefix bonus. */
static double jaro_winkler_of(const jaro_run *r) {
  if (r->matches == 0) return 0.0;
  size_t transposed = 0;
  for (size_t i = 0, k = 0; i < r->n; i++) {
    if (!r->matched_a[i]) continue;
    while (!r->matched_b[k]) k++;
    if (r->a[i] != r->b[k++]) transposed++;
  }
  size_t transpositions = transposed / 2;
  double found = (double)r->matches;
  double jaro = (found / (double)r->n + found / (double)r->m + (found - (double)transpositions) / found) / 3.0;
  if (jaro <= 0.7) return jaro;
  size_t prefix = 0;
  while (prefix < 4 && prefix < r->n && r->a[prefix] == r->b[prefix]) prefix++;
  return jaro + (double)prefix * 0.1 * (1.0 - jaro);
}

static agc_step jaro_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  (void)last;
  jaro_run *r = (jaro_run *)self;
  for (;;) {
    size_t cells = 0;
    bool done = jaro_walk(r, DISTANCE_CHUNK, &cells);
    agc_charge(vm, cells / AGC_COST_BYTES);
    if (done) {
      agc_charge(vm, (r->n + r->m) / AGC_COST_BYTES);
      agc_turn_charge(vm);
      return (agc_step){.kind = AGC_STEP_END, .value = agc_float(jaro_winkler_of(r))};
    }
    /* Both run: the charge must not be skipped when the step count ends the turn first. */
    bool charged = agc_turn_charge(vm);
    if (agc_step_turn(vm, r->span) || charged) return (agc_step){.kind = AGC_STEP_YIELD};
  }
}

/* s.jaro_winkler(other): the Jaro similarity of the code points, plus 0.1 * (1 - jaro) for each character of a common
   prefix of up to 4 when it is above 0.7, as Ruby's DidYouMean::JaroWinkler; half the transpositions, rounded down, as
   Winkler's strcmp95. Two empty strings give 1.0. The shorter string (for equal lengths, the first in byte order) is
   matched against the longer, so the order of the two does not matter. Matching makes at most n * (2 * window + 1)
   comparisons: up to DISTANCE_DIRECT run here, more as a stepper. */
static agc_value builtin_jaro_winkler(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_string *x = agc_as_string(vm, args[0]), *y = agc_as_string(vm, args[1]);
  int order = x->chars == y->chars ? byte_order(x, y) : 0;
  if (x->chars == y->chars && order == 0) return agc_float(1.0);
  if (x->chars > y->chars || order > 0) {
    const agc_string *t = x;
    x = y;
    y = t;
  }
  size_t n = x->chars, m = y->chars;
  if (n == 0) return agc_float(0.0);
  size_t window = m / 2 > 0 ? m / 2 - 1 : 0;
  /* The window is under m, so 2 * window + 1 does not overflow. */
  size_t width = 2 * window + 1 < m ? 2 * window + 1 : m;
  bool direct = width <= DISTANCE_DIRECT / n;
  jaro_run local, *r = direct ? &local : agc_alloc(sizeof *r);
  uint32_t small_a[DISTANCE_STACK], small_b[DISTANCE_STACK];
  uint8_t small_flags[2 * DISTANCE_STACK];
  *r = (jaro_run){.texts = {args[0], args[1]}, .n = n, .m = m, .window = window, .span = span};
  r->a = code_points(x->data, x->bytes, n, direct ? small_a : NULL);
  r->b = code_points(y->data, y->bytes, m, direct ? small_b : NULL);
  r->matched_a = direct && m <= DISTANCE_STACK ? small_flags : agc_alloc_atomic(agc_size_add(n, m));
  r->matched_b = r->matched_a + n;
  memset(r->matched_a, 0, n + m);
  jaro_row(r);
  agc_charge(vm, (n + m) / AGC_COST_BYTES);
  if (direct) {
    size_t cells = 0;
    (void)jaro_walk(r, SIZE_MAX, &cells);
    /* n + m again for the pass over the matches in jaro_winkler_of, as jaro_step charges it. */
    agc_charge(vm, (cells + n + m) / AGC_COST_BYTES);
    return agc_float(jaro_winkler_of(r));
  }
  r->stepper.step = jaro_step;
  /* The step reads the immutable texts and writes only this run, which belongs to the calling task. */
  r->stepper.unlocked = true;
  r->stepper.no_block = true;
  agc_task_stepper(vm, &r->stepper);
  return agc_void();
}

const agc_builtin agc_string_builtins[] = {
  {"String.length", 1, builtin_length, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"String.bytesize", 1, builtin_bytesize, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"String.upcase", 1, builtin_upcase, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.downcase", 1, builtin_downcase, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.trim", 1, builtin_trim, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.split", 2, builtin_split, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.join", 2, builtin_join, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.contains?", 2, builtin_contains, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.starts_with?", 2, builtin_starts_with, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true},
  {"String.ends_with?", 2, builtin_ends_with, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true},
  {"String.replace", 3, builtin_replace, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.slice", 3, builtin_slice, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true},
  {"String.index_of.optional", 2, builtin_index_of_optional, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.compare", 2, builtin_compare, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.at", 2, builtin_at, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true},
  {"String.reverse", 1, builtin_reverse, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.code", 1, builtin_code, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"String.from_code", 1, builtin_from_code, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"String.to_int", 1, builtin_to_int, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.to_int!", 1, builtin_to_int_bang, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.to_float", 1, builtin_to_float, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.to_float!", 1, builtin_to_float_bang, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.from_bytes.bytes", 1, builtin_from_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.multiply", 2, builtin_multiply, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  /* The distances charge their own cost and may start a stepper, so they are neither leaf nor direct rows; the
     stepper touches only its own run (unlocked), so they are not shared. */
  {"String.edit_distance", 2, builtin_edit_distance, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"String.edit_distance", 3, builtin_edit_distance_max, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"String.jaro_winkler", 2, builtin_jaro_winkler, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
};

const size_t agc_string_builtin_count = sizeof agc_string_builtins / sizeof agc_string_builtins[0];
