#include "../agc.h"

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

static char *repeat_text(const char *head, char fill, size_t count, const char *tail) {
  size_t h = strlen(head), t = strlen(tail);
  char *s = malloc(h + count + t + 1);
  assert(s);
  memcpy(s, head, h);
  memset(s + h, fill, count);
  memcpy(s + h + count, tail, t + 1);
  return s;
}

int main(void) {
  agc_init();
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
  assert(agc_utf8_offset(mixed, 0) == 0 && agc_utf8_offset(mixed, 1) == 1 && agc_utf8_offset(mixed, 2) == 3);
  assert(agc_utf8_offset(mixed, 3) == 7 && agc_utf8_offset(mixed, 4) == 8);
  assert(agc_utf8_offset(text("abc"), 2) == 2);

  find_is("aaab", "aab", 0, 1);
  find_is("abababc", "ababc", 0, 2);
  find_is("abc", "", 0, 0);
  find_is("abc", "", 3, 3);
  find_is("abc", "", 4, SIZE_MAX);
  find_is("abc", "abcd", 0, SIZE_MAX);
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
  const char *bad_floats[] = {"", "+", "-", ".5", "1.", "1.e5", "1e5", "1.5e3", "inf", "-inf", "nan", "+nan.0",
                              "+inf.0", "0x1p3", "0x10", " 1.5", "1.5 ", "1.5\n", "1,5", "1..5", "1.5.2", "#e1.5",
                              "1/2", "\xd9\xa1.5"};
  for (size_t i = 0; i < sizeof bad_floats / sizeof bad_floats[0]; i++) float_invalid(bad_floats[i]);
  double x;
  assert(agc_parse_float((const uint8_t *)"1.5\0", 4, &x) == AGC_NUMBER_INVALID);

  printf("string tests passed\n");
  return 0;
}
