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
  agc_vm vm;
  memset(&vm, 0, sizeof vm);
  agc_string *previous = agc_make_string("", 0, 0);
  for (uint32_t cp = 0; cp <= 0x10FFFF; cp++) {
    if (cp >= 0xD800 && cp <= 0xDFFF) continue;
    char bytes[4];
    size_t n = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
    static const uint8_t lead[] = {0, 0, 0xC0, 0xE0, 0xF0};
    for (size_t k = n - 1; k > 0; k--) bytes[k] = (char)(0x80 | ((cp >> (6 * (n - 1 - k))) & 0x3F));
    bytes[0] = (char)(n == 1 ? cp : lead[n] | (cp >> (6 * (n - 1))));
    agc_string *one = agc_make_string(bytes, n, 1);
    agc_string *pair = agc_concat(previous, one);
    agc_string *d = agc_debug(&vm, agc_string_value(pair));
    size_t chars;
    assert(agc_utf8_chars((const uint8_t *)pair->data, pair->bytes, &chars) && chars == pair->chars);
    assert(agc_utf8_chars((const uint8_t *)d->data, d->bytes, &chars) && chars == d->chars);
    previous = one;
  }
  debug_is("", "\"\"");
  debug_is("a\xe2\x80\x8d\xe2\x80\x8d \xe2\x80\x8d\xe2\x80\x8c", "\"a\xe2\x80\x8d\xe2\x80\x8d \\u200D\\u200C\"");
  debug_is("\xe2\x80\x8d\xf3\xa0\x81\x81", "\"\\u200D\\U000E0041\"");
  debug_is("a\"b\\c", "\"a\\\"b\\\\c\"");
  debug_is("\a\b\t\n\v\f\r\x1b", "\"\\a\\b\\t\\n\\v\\f\\r\\e\"");
  debug_is("\x01\x7f\xc2\x80\xc2\xad", "\"\\u0001\\u007F\\u0080\\u00AD\"");
  debug_is("e\xcc\x81 \xc2\xa0\xe3\x80\x80", "\"e\xcc\x81 \xc2\xa0\xe3\x80\x80\"");
  debug_is("\xe2\x80\xa8\xee\x80\x80\xef\xbb\xbf", "\"\\u2028\\uE000\\uFEFF\"");
  debug_is("\xf0\x9f\x98\x80\xf4\x8f\xbf\xbf\xf3\xa0\x80\x81", "\"\xf0\x9f\x98\x80\\U0010FFFF\\U000E0001\"");
  agc_list *inner = agc_new_list(4);
  inner->items[0] = agc_int(-7);
  inner->items[1] = agc_float(0.5);
  inner->items[2] = agc_string_value(agc_make_string("a\"\xce\xbb", 4, 3));
  inner->items[3] = agc_list_value(agc_new_list(0));
  agc_list *outer = agc_new_list(3);
  outer->items[0] = agc_nil();
  outer->items[1] = agc_list_value(inner);
  outer->items[2] = agc_bool(true);
  agc_string *mixed = agc_text(&vm, agc_list_value(outer));
  const char *expected = "[nil, [-7, 0.5, \"a\\\"\xce\xbb\", []], true]";
  assert(mixed->bytes == strlen(expected) && memcmp(mixed->data, expected, mixed->bytes) == 0);
  assert(mixed->chars == strlen(expected) - 1);

  size_t depth = 1000000;
  agc_value deep = agc_int(1);
  for (size_t k = 0; k < depth; k++) {
    agc_list *wrap = agc_new_list(1);
    wrap->items[0] = deep;
    deep = agc_list_value(wrap);
  }
  agc_string *text = agc_debug(&vm, deep);
  assert(text->bytes == 2 * depth + 1 && text->chars == text->bytes);
  for (size_t k = 0; k < depth; k++) assert(text->data[k] == '[' && text->data[depth + 1 + k] == ']');
  assert(text->data[depth] == '1');

  puts("text tests passed");
  return 0;
}
