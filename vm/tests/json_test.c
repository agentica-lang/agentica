/*
 * JSON parsing and encoding: the sign of zero, escapes, key order and dedupe,
 * very deep arrays and objects, and a deep list through JSON.from.
 */
#include "../core.h"
#include "../services.h"

#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static agc_vm vm;

static agc_json *parse(const char *text, size_t len) {
  agc_value v;
  assert(agc_json_parse((const uint8_t *)text, len, &v) == AGC_JSON_PARSED);
  return agc_as_json(&vm, v);
}

static void round_trip(const char *text, const char *expected) {
  agc_value v;
  assert(agc_json_parse((const uint8_t *)text, strlen(text), &v) == AGC_JSON_PARSED);
  agc_string *s = agc_json_encode(&vm, v, 0);
  if (s->bytes != strlen(expected) || memcmp(s->data, expected, s->bytes) != 0) {
    fprintf(stderr, "%s: got %.*s\n", text, (int)s->bytes, s->data);
    assert(0);
  }
  assert(s->chars == agc_utf8_count((const uint8_t *)s->data, s->bytes));
}

static char *nested(size_t depth, const char *open, const char *close, const char *middle) {
  size_t a = strlen(open), b = strlen(close), m = strlen(middle);
  char *text = malloc(depth * (a + b) + m + 1);
  assert(text);
  for (size_t i = 0; i < depth; i++) memcpy(text + i * a, open, a);
  memcpy(text + depth * a, middle, m);
  for (size_t i = 0; i < depth; i++) memcpy(text + depth * a + m + i * b, close, b);
  text[depth * (a + b) + m] = '\0';
  return text;
}

int main(void) {
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);

  agc_json *j = parse("-0.0", 4);
  assert(j->kind == AGC_JSON_FLOAT && agc_as_float(&vm, j->scalar) == 0.0 && !signbit(agc_as_float(&vm, j->scalar)));
  j = parse("-1e-500", 7);
  assert(j->kind == AGC_JSON_FLOAT && signbit(agc_as_float(&vm, j->scalar)));

  agc_value v;
  assert(agc_json_parse((const uint8_t *)"\"\x01\"", 3, &v) == AGC_JSON_CONTROL);
  assert(agc_json_parse((const uint8_t *)" ", 1, &v) == AGC_JSON_EMPTY);
  assert(agc_json_parse((const uint8_t *)"[1,]", 4, &v) == AGC_JSON_INVALID);
  assert(agc_json_parse((const uint8_t *)"01", 2, &v) == AGC_JSON_TRAILING);
  assert(agc_json_parse((const uint8_t *)"[1e400]", 7, &v) == AGC_JSON_NOT_FINITE);

  round_trip("[-9223372036854775809, 1e2, 0.1, 1e21, 1e-7, -0.0]", "[-9223372036854775809,100.0,0.1,1e+21,1e-7,0.0]");
  round_trip("\"\\u0000\\u001f\\b\\f\\n\\r\\t\\\"\\\\\\/\x7f\\u00e9\\ud83d\\ude00\"",
             "\"\\u0000\\u001f\\b\\f\\n\\r\\t\\\"\\\\/\\u007f\xc3\xa9\xf0\x9f\x98\x80\"");
  round_trip("{\"b\":1,\"a\":2,\"b\":3,\"\":4,\"\xc3\xa9\":5,\"Z\":6,\"a\\u0000\":7}",
             "{\"\":4,\"Z\":6,\"a\":2,\"a\\u0000\":7,\"b\":3,\"\xc3\xa9\":5}");

  size_t keys = 5000;
  char *wide = malloc(keys * 24 + 2);
  assert(wide);
  size_t at = 0;
  wide[at++] = '{';
  for (size_t k = 0; k < keys; k++) at += (size_t)sprintf(wide + at, "%s\"k%zu\":%zu", k ? "," : "", (keys - k) % 1000, k);
  wide[at++] = '}';
  j = parse(wide, at);
  assert(j->count == 1000);
  for (size_t k = 1; k < j->count; k++) {
    const agc_string *a = j->members[k - 1].key, *b = j->members[k].key;
    size_t n = a->bytes < b->bytes ? a->bytes : b->bytes;
    int c = memcmp(a->data, b->data, n);
    assert(c < 0 || (c == 0 && a->bytes < b->bytes));
  }
  for (size_t k = 0; k < j->count; k++) {
    int64_t value = agc_as_int(&vm, agc_as_json(&vm, j->members[k].value)->scalar);
    assert((size_t)value >= keys - 1000);
  }
  free(wide);

#if defined(AGC_GC_STRESS)
  size_t depth = 1000;
#elif defined(AGC_NO_GC)
  size_t depth = 100000;
#else
  size_t depth = 1000000;
#endif
  char *deep = nested(depth, "[", "]", "");
  round_trip(deep, deep);
  free(deep);
  deep = nested(depth, "{\"a\":", "}", "null");
  round_trip(deep, deep);
  free(deep);

  agc_value list = agc_list_value(agc_list_from_array(NULL, 0));
  for (size_t i = 0; i < depth; i++) list = agc_list_value(agc_list_from_array(&list, 1));
  agc_string *s = agc_json_encode(&vm, agc_json_from(&vm, list, 0), 0);
  agc_string *direct = agc_json_encode(&vm, list, 0);
  assert(s->bytes == 2 * (depth + 1) && s->bytes == direct->bytes && memcmp(s->data, direct->data, s->bytes) == 0);
  puts("json tests passed");
  return 0;
}
