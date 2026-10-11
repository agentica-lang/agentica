#include "../agc.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static agc_vm vm;

static int64_t get_int(const agc_map *m, agc_value key) {
  agc_value v;
  assert(agc_map_get(&vm, m, key, &v));
  return agc_as_int(&vm, v);
}

static int64_t get_hashed(const agc_map *m, uint64_t hash, int64_t key) {
  agc_value v;
  assert(agc_map_get_hash(&vm, m, hash, agc_int(key), &v));
  return agc_as_int(&vm, v);
}

static agc_value text(const char *s) { return agc_string_value(agc_make_string(s, strlen(s), strlen(s))); }

static void debug_is(agc_value v, const char *expected) {
  agc_string *d = agc_debug(&vm, v);
  if (d->bytes != strlen(expected) || memcmp(d->data, expected, d->bytes) != 0) {
    fprintf(stderr, "got \"%.*s\", expected \"%s\"\n", (int)d->bytes, d->data, expected);
    assert(0);
  }
}

int main(void) {
  agc_init();
  memset(&vm, 0, sizeof vm);

  const int64_t n = 20000;
  agc_map *m = agc_new_map();
  agc_map *half = NULL;
  for (int64_t k = 0; k < n; k++) {
    m = agc_map_put(&vm, m, agc_int(k * 7919 - 50000), agc_int(k));
    if (k == n / 2 - 1) half = m;
  }
  assert(m->size == (size_t)n && half->size == (size_t)n / 2);
  for (int64_t k = 0; k < n; k++) assert(get_int(m, agc_int(k * 7919 - 50000)) == k);
  agc_value missing;
  assert(!agc_map_get(&vm, half, agc_int((n - 1) * 7919 - 50000), &missing));
  assert(!agc_map_get(&vm, m, agc_int(1), &missing));
  agc_value *keys = agc_map_keys(m);
  for (int64_t k = 0; k < n; k++) assert(agc_as_int(&vm, keys[k]) == k * 7919 - 50000);

  agc_map *replaced = agc_map_put(&vm, m, agc_int(-50000), agc_int(-1));
  assert(replaced->size == m->size && get_int(replaced, agc_int(-50000)) == -1 && get_int(m, agc_int(-50000)) == 0);
  assert(agc_as_int(&vm, agc_map_keys(replaced)[0]) == -50000);

  agc_map *words = agc_new_map();
  words = agc_map_put(&vm, words, text("b"), agc_int(1));
  words = agc_map_put(&vm, words, text(""), agc_int(2));
  words = agc_map_put(&vm, words, text("a\"\n"), agc_int(3));
  words = agc_map_put(&vm, words, text("b"), agc_int(4));
  words = agc_map_put(&vm, words, agc_int(98), agc_int(5));
  assert(words->size == 4 && get_int(words, text("b")) == 4 && get_int(words, text("")) == 2);
  assert(!agc_map_get(&vm, words, text("a"), &missing));
  debug_is(agc_map_value(words), "{\"b\": 4, \"\": 2, \"a\\\"\\n\": 3, 98: 5}");
  debug_is(agc_map_value(agc_new_map()), "{}");

  const uint64_t same = 0x123456789abcdef0ULL;
  agc_map *collide = agc_new_map();
  for (int64_t k = 0; k < 40; k++) collide = agc_map_put_hash(&vm, collide, same, agc_int(k), agc_int(k * 10));
  collide = agc_map_put_hash(&vm, collide, same, agc_int(5), agc_int(-5));
  assert(collide->size == 40);
  for (int64_t k = 0; k < 40; k++) assert(get_hashed(collide, same, k) == (k == 5 ? -5 : k * 10));
  assert(!agc_map_get_hash(&vm, collide, same, agc_int(40), &missing));
  assert(!agc_map_get_hash(&vm, collide, same ^ (1ULL << 63), agc_int(1), &missing));

  agc_map *prefix = agc_new_map();
  for (int64_t k = 0; k < 16; k++)
    prefix = agc_map_put_hash(&vm, prefix, ((uint64_t)k << 60) | 0x0aaaaaaaaaaaaaaaULL, agc_int(k), agc_int(k + 100));
  prefix = agc_map_put_hash(&vm, prefix, 0x0aaaaaaaaaaaaaaaULL, agc_int(99), agc_int(7));
  prefix = agc_map_put_hash(&vm, prefix, 0, agc_int(-1), agc_int(-1));
  prefix = agc_map_put_hash(&vm, prefix, 1ULL << 63, agc_int(-2), agc_int(-2));
  assert(prefix->size == 19);
  for (int64_t k = 0; k < 16; k++) assert(get_hashed(prefix, ((uint64_t)k << 60) | 0x0aaaaaaaaaaaaaaaULL, k) == k + 100);
  assert(get_hashed(prefix, 0x0aaaaaaaaaaaaaaaULL, 99) == 7);
  assert(get_hashed(prefix, 0, -1) == -1 && get_hashed(prefix, 1ULL << 63, -2) == -2);
  assert(!agc_map_get_hash(&vm, prefix, 0x1aaaaaaaaaaaaaaaULL, agc_int(0), &missing));
  agc_value *prefix_keys = agc_map_keys(prefix);
  assert(agc_as_int(&vm, prefix_keys[0]) == 0 && agc_as_int(&vm, prefix_keys[16]) == 99);

  agc_list *wrapped = agc_new_list(1);
  wrapped->items[0] = agc_map_value(words);
  debug_is(agc_list_value(wrapped), "[{\"b\": 4, \"\": 2, \"a\\\"\\n\": 3, 98: 5}]");
#ifdef AGC_GC_STRESS
  const size_t depth = 1000;
#else
  const size_t depth = 1000000;
#endif
  agc_value deep = agc_map_value(agc_new_map());
  for (size_t k = 0; k < depth; k++) deep = agc_map_value(agc_map_put(&vm, agc_new_map(), agc_int(1), deep));
  agc_string *deep_text = agc_debug(&vm, deep);
  assert(deep_text->bytes == depth * 5 + 2);

  puts("map tests passed");
  return 0;
}
