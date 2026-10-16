/*
 * The HAMT: 20,000 keys, order, replacement, persistence, full hash
 * collisions, add that leaves a member alone (and the Set text), delete down to
 * an empty map, and deep nesting.
 */
#include "../core.h"

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

static agc_value call(const char *name, uint32_t arity, agc_value *args) {
  const agc_builtin *b = agc_find_builtin((const uint8_t *)name, strlen(name), arity);
  assert(b);
  return b->fn(&vm, args, 0);
}

/* The Set, Map and List builtins return the run's shared empty values when nothing is left, and building on a shared
   value leaves it empty. A Set is a Map under another tag, so the two empties are one object. */
static void shared_empties(void) {
  agc_runtime *rt = vm.rt;
  agc_map *empty_set = agc_as_set(&vm, rt->empty_set), *empty_map = agc_as_map(&vm, rt->empty_map);
  const agc_list *empty_list = agc_as_list(&vm, rt->empty_list);
  assert(empty_set == empty_map && empty_set->size == 0 && empty_set->table == NULL && empty_set->reversed == NULL);

  agc_value args[2];
  args[0] = rt->empty_list;
  assert(agc_as_set(&vm, call("Set.new", 1, args)) == empty_set);
  agc_value one = agc_int(1), two = agc_int(2);
  args[0] = agc_list_value(agc_list_from_array(&one, 1));
  agc_value single = call("Set.new", 1, args);
  agc_value other = agc_set_value(agc_map_put(&vm, empty_set, two, agc_nil()));
  assert(agc_as_set(&vm, single)->size == 1 && agc_as_set(&vm, single) != empty_set);
  args[0] = single;
  args[1] = one;
  assert(agc_as_set(&vm, call("Set.delete", 2, args)) == empty_set);
  args[1] = single;
  assert(agc_as_set(&vm, call("Set.difference", 2, args)) == empty_set);
  args[1] = other;
  assert(agc_as_set(&vm, call("Set.intersection", 2, args)) == empty_set);

  agc_value pair[2] = {one, one};
  args[0] = agc_map_value(agc_map_put(&vm, empty_map, pair[0], pair[1]));
  args[1] = one;
  assert(agc_as_map(&vm, call("Map.delete", 2, args)) == empty_map);
  assert(agc_as_list(&vm, call("Map.keys", 1, (agc_value[]){rt->empty_map})) == empty_list);

  agc_value items[3] = {one, two, one};
  args[0] = agc_list_value(agc_list_from_array(items, 3));
  args[1] = agc_int(0);
  assert(agc_as_list(&vm, call("List.take", 2, args)) == empty_list);
  args[1] = agc_int(3);
  assert(agc_as_list(&vm, call("List.drop", 2, args)) == empty_list);
  args[0] = one;
  args[1] = agc_int(0);
  assert(agc_as_list(&vm, call("List.repeat", 2, args)) == empty_list);
  args[0] = agc_list_value(agc_list_from_array(&one, 1));
  assert(agc_as_list(&vm, call("List.reverse", 1, args)) == agc_as_list(&vm, args[0]));

  /* A put, an add or a push on a shared empty gives a new value and leaves the shared one empty. */
  args[0] = rt->empty_set;
  args[1] = two;
  assert(agc_as_set(&vm, call("Set.add", 2, args))->size == 1);
  agc_value triple[3] = {rt->empty_map, one, two};
  assert(agc_as_map(&vm, call("Map.put", 3, triple))->size == 1);
  args[0] = rt->empty_list;
  args[1] = one;
  assert(agc_list_len(agc_as_list(&vm, call("List.append", 2, args))) == 1);
  assert(empty_set->size == 0 && empty_set->table == NULL && empty_set->reversed == NULL);
  assert(agc_list_len(empty_list) == 0);
}

int main(void) {
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);

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
  agc_value *keys = agc_map_keys(&vm, m, 0);
  for (int64_t k = 0; k < n; k++) assert(agc_as_int(&vm, keys[k]) == k * 7919 - 50000);

  agc_map *replaced = agc_map_put(&vm, m, agc_int(-50000), agc_int(-1));
  assert(replaced->size == m->size && get_int(replaced, agc_int(-50000)) == -1 && get_int(m, agc_int(-50000)) == 0);
  assert(agc_as_int(&vm, agc_map_keys(&vm, replaced, 0)[0]) == -50000);

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

  /* agc_map_add_hash returns the map itself for a member, at any depth and in a collision node, and adds like put otherwise. */
  agc_value nothing = agc_nil();
  agc_value member = agc_int(5 * 7919 - 50000);
  assert(agc_map_add_hash(&vm, m, agc_key_hash(&vm, member), member, nothing) == m);
  assert(agc_map_add_hash(&vm, collide, same, agc_int(7), nothing) == collide);
  agc_map *collide_plus = agc_map_add_hash(&vm, collide, same, agc_int(77), nothing);
  assert(collide_plus != collide && collide_plus->size == 41 && collide->size == 40);
  assert(agc_map_add_hash(&vm, collide_plus, same, agc_int(77), nothing) == collide_plus);
  assert(agc_as_int(&vm, agc_map_keys(&vm, collide_plus, 0)[40]) == 77);
  agc_value fresh = agc_int(1);
  agc_map *m_plus = agc_map_add_hash(&vm, m, agc_key_hash(&vm, fresh), fresh, nothing);
  assert(m_plus != m && m_plus->size == m->size + 1 && m->size == (size_t)n);
  assert(agc_map_get(&vm, m_plus, fresh, &missing) && agc_is(missing, AGC_T_NIL) && !agc_map_get(&vm, m, fresh, &missing));
  assert(get_int(m_plus, agc_int(-50000)) == 0);
  assert(agc_map_add_hash(&vm, agc_new_map(), 9, fresh, nothing)->size == 1);

  agc_map *members = agc_new_map();
  members = agc_map_add_hash(&vm, members, agc_key_hash(&vm, text("b")), text("b"), nothing);
  members = agc_map_add_hash(&vm, members, agc_key_hash(&vm, agc_int(3)), agc_int(3), nothing);
  assert(agc_map_add_hash(&vm, members, agc_key_hash(&vm, text("b")), text("b"), nothing) == members);
  debug_is(agc_set_value(members), "Set[\"b\", 3]");
  debug_is(agc_set_value(agc_new_map()), "Set[]");

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
  agc_value *prefix_keys = agc_map_keys(&vm, prefix, 0);
  assert(agc_as_int(&vm, prefix_keys[0]) == 0 && agc_as_int(&vm, prefix_keys[16]) == 99);

  /* agc_map_add_hash on the long shared prefixes: a member returns the map itself (a leaf at the end of the chain, a
     collision node, a leaf at the root); a new key adds where its hash leaves the chain or joins a leaf with its own hash. */
  const uint64_t tail = 0x0aaaaaaaaaaaaaaaULL;
  assert(agc_map_add_hash(&vm, prefix, ((uint64_t)9 << 60) | tail, agc_int(9), agc_int(555)) == prefix);
  assert(agc_map_add_hash(&vm, prefix, tail, agc_int(99), agc_int(555)) == prefix);
  assert(agc_map_add_hash(&vm, prefix, 0, agc_int(-1), agc_int(555)) == prefix);
  assert(agc_map_add_hash(&vm, prefix, 1ULL << 63, agc_int(-2), agc_int(555)) == prefix);
  uint64_t branch = ((uint64_t)3 << 60) | (tail ^ (1ULL << 59));
  agc_map *branched = agc_map_add_hash(&vm, prefix, branch, agc_int(200), agc_int(555));
  assert(branched != prefix && branched->size == 20 && prefix->size == 19);
  assert(get_hashed(branched, branch, 200) == 555 && !agc_map_get_hash(&vm, prefix, branch, agc_int(200), &missing));
  assert(agc_map_add_hash(&vm, branched, branch, agc_int(200), agc_int(1)) == branched);
  uint64_t twin = ((uint64_t)7 << 60) | tail;
  agc_map *twinned = agc_map_add_hash(&vm, branched, twin, agc_int(201), agc_int(556));
  assert(twinned != branched && twinned->size == 21 && branched->size == 20);
  assert(get_hashed(twinned, twin, 201) == 556 && get_hashed(twinned, twin, 7) == 107 && get_hashed(twinned, branch, 200) == 555);
  assert(agc_map_add_hash(&vm, twinned, twin, agc_int(201), agc_int(1)) == twinned);
  agc_value *twin_keys = agc_map_keys(&vm, twinned, 0);
  assert(agc_as_int(&vm, twin_keys[19]) == 200 && agc_as_int(&vm, twin_keys[20]) == 201);
  for (int64_t k = 0; k < 16; k++) assert(get_hashed(twinned, ((uint64_t)k << 60) | tail, k) == k + 100);

  const int64_t few = 2000;
  agc_map *removed = agc_new_map();
  for (int64_t k = 0; k < few; k++) removed = agc_map_put(&vm, removed, agc_int(k * 7919 - 50000), agc_int(k));
  agc_map *full = removed;
  for (int64_t k = 0; k < few; k += 2) removed = agc_map_delete(&vm, removed, agc_int(k * 7919 - 50000));
  assert(removed->size == (size_t)few / 2 && full->size == (size_t)few);
  for (int64_t k = 0; k < few; k++) {
    agc_value v;
    assert(agc_map_get(&vm, removed, agc_int(k * 7919 - 50000), &v) == (k % 2 == 1));
    assert(get_int(full, agc_int(k * 7919 - 50000)) == k);
  }
  agc_value *left = agc_map_keys(&vm, removed, 0);
  for (int64_t k = 0; k < few / 2; k++) assert(agc_as_int(&vm, left[k]) == (2 * k + 1) * 7919 - 50000);
  assert(agc_map_delete(&vm, removed, agc_int(1)) == removed);
  assert(agc_map_delete(&vm, agc_new_map(), agc_int(1))->size == 0);
  for (int64_t k = few - 1; k > 0; k -= 2) removed = agc_map_delete(&vm, removed, agc_int(k * 7919 - 50000));
  assert(removed->size == 0 && removed->table == NULL && removed->reversed == NULL);
  removed = agc_map_put(&vm, removed, agc_int(3), agc_int(4));
  assert(removed->size == 1 && get_int(removed, agc_int(3)) == 4);

  agc_map *thin = collide;
  for (int64_t k = 0; k < 39; k++) thin = agc_map_delete_hash(&vm, thin, same, agc_int(k));
  assert(thin->size == 1 && get_hashed(thin, same, 39) == 390 && get_hashed(collide, same, 0) == 0);
  thin = agc_map_put_hash(&vm, thin, same, agc_int(0), agc_int(1));
  assert(thin->size == 2 && get_hashed(thin, same, 0) == 1 && get_hashed(thin, same, 39) == 390);
  thin = agc_map_delete_hash(&vm, agc_map_delete_hash(&vm, thin, same, agc_int(39)), same, agc_int(0));
  assert(thin->size == 0 && thin->table == NULL);

  agc_map *cut = prefix;
  for (int64_t k = 0; k < 16; k++) cut = agc_map_delete_hash(&vm, cut, ((uint64_t)k << 60) | 0x0aaaaaaaaaaaaaaaULL, agc_int(k));
  assert(cut->size == 3 && get_hashed(cut, 0x0aaaaaaaaaaaaaaaULL, 99) == 7 && get_hashed(cut, 0, -1) == -1);
  assert(!agc_map_get_hash(&vm, cut, 0x0aaaaaaaaaaaaaaaULL, agc_int(0), &missing));
  agc_value *cut_keys = agc_map_keys(&vm, cut, 0);
  assert(agc_as_int(&vm, cut_keys[0]) == 99 && agc_as_int(&vm, cut_keys[1]) == -1 && agc_as_int(&vm, cut_keys[2]) == -2);
  debug_is(agc_map_value(agc_map_delete(&vm, words, text(""))), "{\"b\": 4, \"a\\\"\\n\": 3, 98: 5}");

  agc_value wrapped = agc_map_value(words);
  debug_is(agc_list_value(agc_list_from_array(&wrapped, 1)), "[{\"b\": 4, \"\": 2, \"a\\\"\\n\": 3, 98: 5}]");
#ifdef AGC_GC_STRESS
  const size_t depth = 1000;
#else
  const size_t depth = 1000000;
#endif
  agc_value deep = agc_map_value(agc_new_map());
  for (size_t k = 0; k < depth; k++) deep = agc_map_value(agc_map_put(&vm, agc_new_map(), agc_int(1), deep));
  agc_string *deep_text = agc_debug(&vm, deep);
  assert(deep_text->bytes == depth * 5 + 2);

  shared_empties();

  puts("map tests passed");
  return 0;
}
