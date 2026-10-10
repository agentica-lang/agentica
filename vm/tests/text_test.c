#include "../agc.h"

#include <assert.h>
#include <string.h>

static void debug_is(const char *text, const char *expected) {
  size_t chars;
  assert(agc_utf8_chars((const uint8_t *)text, strlen(text), &chars));
  agc_string *s = agc_make_string(text, strlen(text), chars);
  agc_vm vm;
  memset(&vm, 0, sizeof vm);
  agc_string *d = agc_debug(&vm, agc_string_value(s));
  size_t expected_chars;
  assert(agc_utf8_chars((const uint8_t *)expected, strlen(expected), &expected_chars));
  if (d->bytes != strlen(expected) || memcmp(d->data, expected, d->bytes) != 0 || d->chars != expected_chars) {
    fprintf(stderr, "debug form of \"%s\": got \"%.*s\"\n", text, (int)d->bytes, d->data);
    assert(0);
  }
}

int main(void) {
  agc_init();
  for (size_t i = 0; i < agc_write_raw_count; i++) {
    uint32_t lo = agc_write_raw_ranges[i][0], hi = agc_write_raw_ranges[i][1];
    assert(lo <= hi && (i == 0 || agc_write_raw_ranges[i - 1][1] + 1 < lo));
    assert(agc_write_raw(lo) && agc_write_raw(hi));
    assert(!agc_write_raw(lo - 1) && !agc_write_raw(hi + 1));
  }
  debug_is("", "\"\"");
  debug_is("a\"b\\c", "\"a\\\"b\\\\c\"");
  debug_is("\a\b\t\n\v\f\r\x1b", "\"\\a\\b\\t\\n\\v\\f\\r\\e\"");
  debug_is("\x01\x7f\xc2\x80\xc2\xad", "\"\\u0001\\u007F\\u0080\\u00AD\"");
  debug_is("e\xcc\x81 \xc2\xa0\xe3\x80\x80", "\"e\xcc\x81 \xc2\xa0\xe3\x80\x80\"");
  debug_is("\xe2\x80\xa8\xee\x80\x80\xef\xbb\xbf", "\"\\u2028\\uE000\\uFEFF\"");
  debug_is("\xf0\x9f\x98\x80\xf4\x8f\xbf\xbf\xf3\xa0\x80\x81", "\"\xf0\x9f\x98\x80\\U0010FFFF\\U000E0001\"");
  puts("text tests passed");
  return 0;
}
