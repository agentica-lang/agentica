/*
 * UTF-8 helpers over every code point, case mapping, KMP search, and the Int
 * and Float parsing edge cases.
 */
#include "../core.h"
#include "../services.h"

#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static agc_string *text(const char *data) {
  size_t chars;
  assert(agc_utf8_chars((const uint8_t *)data, strlen(data), &chars));
  return agc_make_string(data, strlen(data), chars);
}

static void case_is(const char *input, bool up, const char *expected) {
  agc_string *result = agc_change_case(text(input), up);
  agc_string *want = text(expected);
  if (result->bytes != want->bytes || memcmp(result->data, want->data, want->bytes) != 0 || result->chars != want->chars) {
    fprintf(stderr, "case of \"%s\": got \"%.*s\"\n", input, (int)result->bytes, result->data);
    assert(0);
  }
}

static void find_is(const char *haystack, const char *needle, size_t from, size_t expected) {
  assert(agc_text_find(text(haystack), text(needle), from) == expected);
}

static agc_number_status int_of(const char *s, int64_t *value) {
  return agc_parse_int((const uint8_t *)s, strlen(s), value);
}

static void int_is(const char *s, int64_t expected) {
  int64_t value;
  assert(int_of(s, &value) == AGC_NUMBER_OK && value == expected);
}

static void float_bits(const char *s, uint64_t expected) {
  double value;
  assert(agc_parse_float((const uint8_t *)s, strlen(s), &value) == AGC_NUMBER_OK);
  uint64_t bits;
  memcpy(&bits, &value, sizeof bits);
  if (bits != expected) {
    fprintf(stderr, "float of \"%.40s\": got %016llx\n", s, (unsigned long long)bits);
    assert(0);
  }
}

static void float_invalid(const char *s) {
  double value;
  assert(agc_parse_float((const uint8_t *)s, strlen(s), &value) == AGC_NUMBER_INVALID);
}

/* Float#to_s text reads back to the same bits: special values, the edges of each range and xorshift patterns. */
static void float_text_round_trips(void) {
  uint64_t fixed[] = {0, 0x8000000000000000ull, 1, 0x000FFFFFFFFFFFFFull, 0x0010000000000000ull, 0x7FEFFFFFFFFFFFFFull,
                      0xFFEFFFFFFFFFFFFFull, 0x7FF0000000000000ull, 0xFFF0000000000000ull, 0x4415AF1D78B58C40ull};
  uint64_t state = 0x9E3779B97F4A7C15ull;
  for (size_t k = 0; k < 20000; k++) {
    uint64_t bits = k < sizeof fixed / sizeof fixed[0] ? fixed[k] : state;
    state ^= state << 13, state ^= state >> 7, state ^= state << 17;
    double x, back;
    memcpy(&x, &bits, sizeof x);
    if (isnan(x)) continue;
    char out[AGC_SCALAR_TEXT];
    size_t n = agc_float_text(x, out);
    assert(agc_parse_float((const uint8_t *)out, n, &back) == AGC_NUMBER_OK);
    if (memcmp(&x, &back, sizeof x) != 0) {
      fprintf(stderr, "float text \"%.*s\" does not read back\n", (int)n, out);
      assert(0);
    }
  }
}

static char *repeat_text(const char *head, char fill, size_t count, const char *tail) {
  size_t h = strlen(head), t = strlen(tail);
  char *s = malloc(h + count + t + 1);
  assert(s);
  memcpy(s, head, h + 1);
  memset(s + h, fill, count);
  memcpy(s + h + count, tail, t + 1);
  return s;
}

/* The references for the eight-bytes-at-a-time paths of agc_utf8_chars and agc_utf8_count: one character, one byte. */
static bool chars_by_one(const uint8_t *s, size_t len, size_t *chars) {
  size_t count = 0;
  for (size_t i = 0; i < len; count++) {
    size_t n = agc_utf8_valid(s + i, len - i);
    if (n == 0) return false;
    i += n;
  }
  *chars = count;
  return true;
}

static size_t count_by_one(const uint8_t *s, size_t len) {
  size_t count = 0;
  for (size_t i = 0; i < len; i++) count += (s[i] & 0xC0) != 0x80;
  return count;
}

/* One case: the filler and the pieces are copied to a block of exactly len bytes, so a sanitizer build catches a word
 * read past the end. Both paths must agree with the references on the answer, and the count of agc_utf8_count is
 * defined for invalid text too (every byte that is not a continuation byte). */
static void utf8_word_case(const uint8_t *text, size_t len) {
  uint8_t *exact = malloc(len ? len : 1);
  assert(exact);
  memcpy(exact, text, len);
  size_t want = 0, got = 0;
  bool valid = chars_by_one(exact, len, &want);
  assert(agc_utf8_chars(exact, len, &got) == valid);
  if (valid) assert(got == want);
  assert(agc_utf8_count(exact, len) == count_by_one(exact, len));
  free(exact);
}

/* ASCII filler with one piece (valid, truncated, stray or overlong bytes) at every offset, for every length around the
 * word size, and then with a second piece in a later eight-byte word. */
static void utf8_word_paths(void) {
  static const char *const pieces[] = {"a", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "\x80", "\xc3", "\xe2\x82",
                                       "\xf0\x9f\x98", "\xc0\xaf", "\xf5\x80\x80\x80", "\xed\xa0\x80", "\xff"};
  size_t piece_count = sizeof pieces / sizeof *pieces;
  for (size_t len = 0; len <= 40; len++) {
    for (size_t at = 0; at < (len ? len : 1); at++) {
      for (size_t k = 0; k < piece_count; k++) {
        uint8_t buf[64];
        memset(buf, 'a', sizeof buf);
        size_t piece = strlen(pieces[k]);
        if (at + piece > len) continue;
        memcpy(buf + at, pieces[k], piece);
        utf8_word_case(buf, len);
        for (size_t later = (at / 8 + 1) * 8; later < len; later += 3) {
          for (size_t m = 0; m < piece_count; m++) {
            size_t second = strlen(pieces[m]);
            if (later + second > len) continue;
            uint8_t both[64];
            memcpy(both, buf, sizeof both);
            memcpy(both + later, pieces[m], second);
            utf8_word_case(both, len);
          }
        }
      }
    }
  }
}

/* Calls the builtin NAME of the String, Result and core tables the way the interpreter does. */
static agc_value call(agc_vm *vm, const char *name, uint32_t arity, agc_value *args) {
  const agc_builtin *b = agc_find_builtin((const uint8_t *)name, strlen(name), arity);
  assert(b);
  return b->fn(vm, args, 0);
}

static agc_value str(const char *data) { return agc_string_value(text(data)); }

#define STR(v) agc_as_string(vm, (v))

/* The builtins return the run's shared empty and one-character ASCII Strings, never for a longer or non-ASCII result,
   and the shared Strings keep their text through a collection. */
static void shared_strings(agc_vm *vm) {
  agc_runtime *rt = vm->rt;
  agc_value args[3];

  args[0] = str("hello");
  args[1] = agc_int(1);
  assert(STR(call(vm, "String.at", 2, args)) == rt->chars['e']);
  assert(STR(call(vm, "String.at", 2, args)) == STR(call(vm, "String.at", 2, args)));
  args[2] = agc_int(1);
  assert(STR(call(vm, "String.slice", 3, args)) == rt->chars['e']);
  args[2] = agc_int(0);
  assert(STR(call(vm, "String.slice", 3, args)) == rt->empty_string);
  args[2] = agc_int(2);
  agc_string *two = STR(call(vm, "String.slice", 3, args));
  assert(two->bytes == 2 && memcmp(two->data, "el", 2) == 0);
  args[0] = str("a\xf0\x9f\x98\x80");
  args[1] = agc_int(1);
  agc_string *wide = STR(call(vm, "String.at", 2, args));
  assert(wide->bytes == 4 && wide->chars == 1 && wide != STR(call(vm, "String.at", 2, args)));

  args[0] = str("  \t ");
  assert(STR(call(vm, "String.trim", 1, args)) == rt->empty_string);
  args[0] = str("  a ");
  assert(STR(call(vm, "String.trim", 1, args)) == rt->chars['a']);
  args[0] = str("ab");
  assert(STR(call(vm, "String.trim", 1, args)) == STR(args[0]));

  args[0] = str("a,,b");
  args[1] = str(",");
  agc_value parts = call(vm, "String.split", 2, args);
  assert(agc_list_len(agc_as_list(vm, parts)) == 3);
  assert(STR(agc_list_get(agc_as_list(vm, parts), 0)) == rt->chars['a']);
  assert(STR(agc_list_get(agc_as_list(vm, parts), 1)) == rt->empty_string);
  assert(STR(agc_list_get(agc_as_list(vm, parts), 2)) == rt->chars['b']);
  args[0] = str("");
  args[1] = str("");
  assert(agc_as_list(vm, call(vm, "String.split", 2, args)) == agc_as_list(vm, rt->empty_list));

  agc_value blanks[2] = {str(""), str("")};
  args[0] = agc_list_value(agc_list_from_array(blanks, 2));
  args[1] = str("");
  assert(STR(call(vm, "String.join", 2, args)) == rt->empty_string);
  args[0] = agc_list_value(agc_list_from_array(NULL, 0));
  args[1] = str(",");
  assert(STR(call(vm, "String.join", 2, args)) == rt->empty_string);
  args[0] = str("abc");
  args[1] = str("abc");
  args[2] = str("");
  assert(STR(call(vm, "String.replace", 3, args)) == rt->empty_string);

  args[0] = agc_int(65);
  assert(STR(call(vm, "String.from_code", 1, args)) == rt->chars[65]);
  args[0] = agc_int(0);
  assert(STR(call(vm, "String.from_code", 1, args)) == rt->chars[0]);
  args[0] = agc_int(0x1F600);
  assert(STR(call(vm, "String.from_code", 1, args))->bytes == 4);

  args[0] = agc_bytes_value(agc_empty_bytes());
  assert(STR(agc_as_result(vm, call(vm, "String.from_bytes.bytes", 1, args))->value) == rt->empty_string);
  args[0] = agc_bytes_value(agc_make_bytes((const uint8_t *)"h", 1));
  assert(STR(agc_as_result(vm, call(vm, "String.from_bytes.bytes", 1, args))->value) == rt->chars['h']);
  args[0] = agc_bytes_value(agc_make_bytes((const uint8_t *)"\xC3\xA9", 2));
  agc_string *accent = STR(agc_as_result(vm, call(vm, "String.from_bytes.bytes", 1, args))->value);
  assert(accent->bytes == 2 && accent->chars == 1);

  args[0] = str("");
  assert(agc_as_bytes(vm, call(vm, "String.bytes", 1, args)) == agc_empty_bytes());
  args[0] = agc_string_value(accent);
  const agc_bytes *encoded = agc_as_bytes(vm, call(vm, "String.bytes", 1, args));
  assert(encoded->len == 2 && encoded->data[0] == 0xC3 && encoded->data[1] == 0xA9);

  args[0] = str("a");
  assert(STR(call(vm, "String.upcase", 1, args)) == rt->chars['A']);
  args[0] = str("Q");
  assert(STR(call(vm, "String.downcase", 1, args)) == rt->chars['q']);
  args[0] = str("5");
  assert(STR(call(vm, "String.upcase", 1, args)) == rt->chars['5']);
  args[0] = str("\xc3\xa9");
  agc_string *upper = STR(call(vm, "String.upcase", 1, args));
  assert(upper->bytes == 2 && memcmp(upper->data, "\xc3\x89", 2) == 0);
  args[0] = str("");
  assert(STR(call(vm, "String.upcase", 1, args)) == STR(args[0]));
  args[0] = str("x");
  assert(STR(call(vm, "String.reverse", 1, args)) == STR(args[0]));
  args[0] = str("ab");
  agc_string *reversed = STR(call(vm, "String.reverse", 1, args));
  assert(reversed->bytes == 2 && memcmp(reversed->data, "ba", 2) == 0);

  assert(agc_text(vm, agc_int(7)) == rt->chars['7']);
  assert(agc_text(vm, agc_int(12))->bytes == 2);
  args[0] = agc_result_value(true, agc_int(1));
  assert(STR(call(vm, "Result.message", 1, args)) == rt->empty_string);

  agc_gc_collect();
  for (size_t c = 0; c < AGC_ASCII_CHARS; c++) assert(rt->chars[c]->bytes == 1 && rt->chars[c]->chars == 1);
  for (size_t c = 0; c < AGC_ASCII_CHARS; c++) assert(rt->chars[c]->data[0] == (char)c);
  assert(rt->empty_string->bytes == 0 && rt->empty_string->chars == 0);
}

int main(void) {
  agc_init();
  utf8_word_paths();
  char buf[4];
  for (uint32_t cp = 0; cp <= 0x10FFFF; cp++) {
    if (cp >= 0xD800 && cp <= 0xDFFF) continue;
    size_t n = agc_utf8_encode(cp, buf);
    assert(n == (cp < 0x80 ? 1u : cp < 0x800 ? 2u : cp < 0x10000 ? 3u : 4u));
    assert(agc_utf8_valid((const uint8_t *)buf, n) == n);
    assert(agc_utf8_count((const uint8_t *)buf, n) == 1);
    agc_string *one = agc_make_string(buf, n, 1);
    agc_string *up = agc_change_case(one, true), *down = agc_change_case(one, false);
    size_t chars;
    assert(agc_utf8_chars((const uint8_t *)up->data, up->bytes, &chars) && chars == up->chars && chars <= 3);
    assert(agc_utf8_chars((const uint8_t *)down->data, down->bytes, &chars) && chars == down->chars && chars <= 3);
  }
  for (size_t i = 1; i < agc_upcase_map_count; i++) assert(agc_upcase_map[i - 1][0] < agc_upcase_map[i][0]);
  for (size_t i = 1; i < agc_downcase_map_count; i++) assert(agc_downcase_map[i - 1][0] < agc_downcase_map[i][0]);

  agc_string *mixed = text("a\xc3\xa9\xf0\x9f\x98\x80z");
  assert(mixed->chars == 4);
  agc_vm vm;
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  assert(agc_utf8_offset(&vm, mixed, 0) == 0 && agc_utf8_offset(&vm, mixed, 1) == 1);
  assert(agc_utf8_offset(&vm, mixed, 2) == 3 && agc_utf8_offset(&vm, mixed, 3) == 7);
  assert(agc_utf8_offset(&vm, mixed, 4) == 8 && agc_utf8_offset(&vm, mixed, 1) == 1);
  assert(agc_utf8_offset(&vm, text("abc"), 2) == 2);
  static const char *pieces[] = {"a", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80"};
  size_t count = 5000, offsets[5001], bytes = 0;
  char *built = malloc(count * 4 + 1);
  assert(built);
  unsigned seed = 7;
  for (size_t k = 0; k < count; k++) {
    seed = seed * 1103515245u + 12345u;
    const char *p = pieces[(seed >> 16) % 4];
    offsets[k] = bytes;
    memcpy(built + bytes, p, strlen(p));
    bytes += strlen(p);
  }
  offsets[count] = bytes;
  built[bytes] = '\0';
  agc_string *wide = text(built);
  agc_string *other = text("x\xc3\xa9y\xc3\xa9");
  for (size_t k = 0; k < 20000; k++) {
    seed = seed * 1103515245u + 12345u;
    size_t index = k % 3 == 0 ? (seed >> 8) % (count + 1) : (k * 7) % (count + 1);
    assert(agc_utf8_offset(&vm, wide, index) == offsets[index]);
    if (k % 97 == 0) assert(agc_utf8_offset(&vm, other, 3) == 4);
  }
  free(built);
  size_t n = 4096;
  char *accents = malloc(2 * n + 1);
  assert(accents);
  for (size_t k = 0; k < n; k++) memcpy(accents + 2 * k, "\xc3\xa9", 2);
  accents[2 * n] = '\0';
  agc_string *e = text(accents);
  free(accents);
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  for (size_t k = 0; k < n; k++) {
    assert(agc_utf8_offset(&vm, e, k) == 2 * k);
    assert(vm.task->cursor == e && vm.task->cursor_index == k && vm.task->cursor_offset == 2 * k);
  }
  vm.task->cursor_index = 1000;
  vm.task->cursor_offset = (size_t)2 * 999;
  assert(agc_utf8_offset(&vm, e, 1001) == (size_t)2 * 1000);
  vm.task->cursor_index = 1000;
  vm.task->cursor_offset = (size_t)2 * 999;
  assert(agc_utf8_offset(&vm, e, 999) == (size_t)2 * 998);
  vm.task->cursor_index = 3000;
  vm.task->cursor_offset = (size_t)2 * 2999;
  assert(agc_utf8_offset(&vm, e, 2990) == (size_t)2 * 2989);
  vm.task->cursor = NULL;
  assert(agc_utf8_offset(&vm, e, 4000) == (size_t)2 * 4000);
  assert(agc_utf8_offset(&vm, e, 10) == (size_t)2 * 10);

  find_is("aaab", "aab", 0, 1);
  find_is("abababc", "ababc", 0, 2);
  find_is("abc", "", 0, 0);
  find_is("abc", "", 3, 3);
  find_is("abc", "", 4, AGC_NOT_FOUND);
  find_is("abc", "abcd", 0, AGC_NOT_FOUND);
  find_is("abcabc", "bc", 2, 4);
  find_is("x\xc3\xa9y\xc3\xa9", "\xc3\xa9", 2, 4);
  find_is("aaaaaaaaaaaaaaaaaaaaaaaaaaaaab", "aaaaaaaab", 0, 21);
  char *long_text = repeat_text("", 'a', 1000000, "b");
  char *long_part = repeat_text("", 'a', 5000, "b");
  find_is(long_text, long_part, 0, 995000);
  free(long_text);
  free(long_part);

  case_is("stra\xc3\x9f" "e", true, "STRASSE");
  case_is("\xc5\x89", true, "\xca\xbcN");
  case_is("\xc4\xb0", false, "i\xcc\x87");
  case_is("\xce\x91\xce\xa3", false, "\xce\xb1\xcf\x82");
  case_is("\xce\xa3", false, "\xcf\x83");
  case_is("\xce\xa3\xce\xa3", false, "\xcf\x83\xcf\x82");
  case_is("\xce\x91\xce\xa3\xce\x91", false, "\xce\xb1\xcf\x83\xce\xb1");
  case_is("A\xce\xa3.", false, "a\xcf\x82.");
  case_is("A\xce\xa3.B", false, "a\xcf\x83.b");
  case_is("A\xcc\x81\xce\xa3 ", false, "a\xcc\x81\xcf\x82 ");
  case_is("1\xce\xa3", false, "1\xcf\x83");
  case_is("A \xce\xa3", false, "a \xcf\x83");
  case_is("Hello, World", false, "hello, world");
  case_is("Hello, World", true, "HELLO, WORLD");
  case_is("", true, "");

  int_is("0", 0);
  int_is("-0", 0);
  int_is("+17", 17);
  int_is("007", 7);
  int_is("9223372036854775807", INT64_MAX);
  int_is("-9223372036854775808", INT64_MIN);
  int_is("00000000000000000000000000009223372036854775807", INT64_MAX);
  int64_t value;
  assert(int_of("9223372036854775808", &value) == AGC_NUMBER_OVERFLOW);
  assert(int_of("-9223372036854775809", &value) == AGC_NUMBER_OVERFLOW);
  assert(int_of("99999999999999999999999", &value) == AGC_NUMBER_OVERFLOW);
  assert(int_of("18446744073709551616", &value) == AGC_NUMBER_OVERFLOW);
  const char *bad_ints[] = {"", "+", "-", " 1", "1 ", "1\n", "1.0", "1e3", "0x10", "--1", "+-1", "1_000", "\xd9\xa1"};
  for (size_t i = 0; i < sizeof bad_ints / sizeof bad_ints[0]; i++)
    assert(int_of(bad_ints[i], &value) == AGC_NUMBER_INVALID);
  assert(agc_parse_int((const uint8_t *)"1\0", 2, &value) == AGC_NUMBER_INVALID);

  float_bits("0", 0);
  float_bits("-0", 0);
  float_bits("-000", 0);
  float_bits("-0.0", 0x8000000000000000ull);
  float_bits("1.5", 0x3FF8000000000000ull);
  float_bits("+1.5", 0x3FF8000000000000ull);
  float_bits("0.1", 0x3FB999999999999Aull);
  float_bits("9007199254740993", 0x4340000000000000ull);
  float_bits("9007199254740995", 0x4340000000000002ull);
  float_bits("9007199254740993.000000000000000000001", 0x4340000000000001ull);
  float_bits("1.00000000000000011102230246251565404236316680908203125", 0x3FF0000000000000ull);
  float_bits("1.00000000000000011102230246251565404236316680908203125000001", 0x3FF0000000000001ull);
  char *huge = repeat_text("", '9', 400, "");
  float_bits(huge, 0x7FF0000000000000ull);
  free(huge);
  char *small = repeat_text("0.", '0', 400, "1");
  float_bits(small, 0);
  free(small);
  char *denormal = repeat_text("0.", '0', 323, "5");
  float_bits(denormal, 1);
  free(denormal);
  float_bits("1e5", 0x40F86A0000000000ull);
  float_bits("1.5E-3", 0x3F589374BC6A7EFAull);
  float_bits("1e+20", 0x4415AF1D78B58C40ull);
  float_bits("-0e0", 0x8000000000000000ull);
  float_bits("5e-324", 1);
  float_bits("2.4703282292062328e-324", 1);
  float_bits("2.4703282292062327e-324", 0);
  float_bits("1.7976931348623157e+308", 0x7FEFFFFFFFFFFFFFull);
  float_bits("1.7976931348623159e+308", 0x7FF0000000000000ull);
  float_bits("-1e99999999999999999999", 0xFFF0000000000000ull);
  float_bits("1e-99999999999999999999", 0);
  float_bits("+inf.0", 0x7FF0000000000000ull);
  float_bits("-inf.0", 0xFFF0000000000000ull);
  double nan_value;
  assert(agc_parse_float((const uint8_t *)"+nan.0", 6, &nan_value) == AGC_NUMBER_OK && isnan(nan_value));
  float_text_round_trips();
  const char *bad_floats[] = {"", "+", "-", ".5", "1.", "1.e5", "1e", "e5", "1e+", "1e-", "1.5e", "1e5.0", "1e 5",
                              "1e+-5", "1ee5", "1e5e5", "inf", "-inf", "nan", "-nan.0", "+inf", "inf.0", "+INF.0",
                              "+nan.0 ", "Infinity", "-Infinity", "NaN", "0x1p3", "0x10", " 1.5", "1.5 ", "1.5\n",
                              "1,5", "1..5", "1.5.2", "#e1.5", "1/2", "1_000.0", "1e1_0", "\xd9\xa1.5"};
  for (size_t i = 0; i < sizeof bad_floats / sizeof bad_floats[0]; i++) float_invalid(bad_floats[i]);
  double x;
  assert(agc_parse_float((const uint8_t *)"1.5\0", 4, &x) == AGC_NUMBER_INVALID);

  shared_strings(&vm);

  printf("string tests passed\n");
  return 0;
}
