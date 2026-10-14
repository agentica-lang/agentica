/*
 * The list API at the lengths around the 32-way boundaries: trie shape, builder,
 * append, set, slice, concat, reverse and repeat, cursors, and persistence.
 */
#include "../core.h"
#include "../list_impl.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

#define LARGE ((size_t)33000)
#define EXTEND_MAX ((size_t)1100)
#define EXTENSION 70
#ifdef AGC_GC_STRESS
#define MAX_LENGTH ((size_t)1000)
#define KEPT ((size_t)1000)
#else
#define MAX_LENGTH ((size_t)2000000)
#define KEPT ((size_t)5000)
#endif

static agc_vm vm;

static agc_value item(size_t i) { return agc_int((int64_t)i * 3 + 1); }

static agc_value other(size_t i) { return agc_int(-(int64_t)i - 1); }

static int64_t int_of(agc_value v) {
  assert(agc_is(v, AGC_T_INT));
  return agc_as_int(&vm, v);
}

static bool is_item(agc_value v, size_t i) { return int_of(v) == (int64_t)i * 3 + 1; }

static bool is_other(agc_value v, size_t i) { return int_of(v) == -(int64_t)i - 1; }

static agc_list *built(size_t n) {
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&b, item(k));
  return agc_list_builder_finish(&b);
}

static agc_list *others(size_t n) {
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&b, other(k));
  return agc_list_builder_finish(&b);
}

static agc_list *appended(size_t n) {
  agc_list *l = agc_list_from_array(NULL, 0);
  for (size_t k = 0; k < n; k++) l = agc_list_append(l, item(k));
  return l;
}

static uint32_t expected_shift(size_t n) {
  if (n >= 1048609) return 20;
  if (n >= 32801) return 15;
  if (n >= 1057) return 10;
  return n >= 33 ? 5 : 0;
}

static size_t count_leaves(const list_branch *node, uint32_t level) { // NOLINT(misc-no-recursion)
  size_t used = 0, leaves = 0;
  while (used < LIST_WIDTH && node->child[used]) used++;
  assert(used > 0);
  for (size_t k = used; k < LIST_WIDTH; k++) assert(!node->child[k]);
  for (size_t k = 0; k < used; k++) {
    size_t below = level == LIST_BITS ? 1 : count_leaves(node->child[k], level - LIST_BITS);
    if (k + 1 < used) assert(below == (level == LIST_BITS ? 1 : (size_t)1 << (level - LIST_BITS)));
    leaves += below;
  }
  return leaves;
}

static void expect_shape(const agc_list *l, size_t n) {
  assert(agc_list_len(l) == n);
  assert((l->root == NULL) == (n <= LIST_WIDTH));
  assert(l->shift == expected_shift(n));
  if (n > LIST_WIDTH) assert(count_leaves(l->root, l->shift) == (n - 1) / LIST_WIDTH);
}

static void expect_run(const agc_list *l, size_t from, size_t n) {
  assert(agc_list_len(l) == n);
  for (size_t k = 0; k < n; k++) assert(is_item(agc_list_get(l, k), from + k));
}

static void expect_cursor(const agc_list *l, size_t at) {
  size_t n = agc_list_len(l);
  agc_list_cursor c;
  agc_value v;
  agc_list_cursor_begin(&c, l, at);
  for (size_t k = at; k < n; k++) {
    assert(agc_list_cursor_next(&c, &v));
    assert(int_of(v) == int_of(agc_list_get(l, k)));
  }
  assert(!agc_list_cursor_next(&c, &v));
  assert(!agc_list_cursor_next(&c, &v));
}

static void expect_list(const agc_list *l, size_t n) {
  expect_shape(l, n);
  expect_run(l, 0, n);
  size_t starts[] = {0, 1, 31, 32, 33, n / 2, n ? n - 1 : 0, n};
  for (size_t s = 0; s < sizeof starts / sizeof starts[0]; s++)
    if (starts[s] <= n) expect_cursor(l, starts[s]);
  agc_value *copy = agc_alloc(agc_size_mul(n, sizeof(agc_value)));
  agc_list_to_array(l, copy);
  for (size_t k = 0; k < n; k++) assert(is_item(copy[k], k));
  const agc_list *again = agc_list_from_array(copy, n);
  expect_shape(again, n);
  expect_run(again, 0, n);
}

static void expect_appended(const agc_list *l, size_t n, size_t id) {
  assert(agc_list_len(l) == n + 1);
  for (size_t k = 0; k < n; k++) assert(is_item(agc_list_get(l, k), k));
  assert(is_other(agc_list_get(l, n), id));
}

static void expect_replaced(const agc_list *l, size_t n, size_t at) {
  assert(agc_list_len(l) == n);
  for (size_t k = 0; k < n; k++) assert(k == at ? is_other(agc_list_get(l, k), at) : is_item(agc_list_get(l, k), k));
}

static void expect_extends(const agc_list *r) {
  size_t n = agc_list_len(r);
  if (n > EXTEND_MAX) return;
  agc_value *snapshot = agc_alloc(agc_size_mul(n, sizeof(agc_value)));
  agc_list_to_array(r, snapshot);
  const agc_list *grown = r;
  for (size_t j = 0; j < EXTENSION; j++) grown = agc_list_append(grown, other(j));
  expect_shape(grown, n + EXTENSION);
  for (size_t k = 0; k < n; k++) {
    assert(int_of(agc_list_get(r, k)) == int_of(snapshot[k]));
    assert(int_of(agc_list_get(grown, k)) == int_of(snapshot[k]));
  }
  for (size_t j = 0; j < EXTENSION; j++) assert(is_other(agc_list_get(grown, n + j), j));
}

static void expect_light(const agc_list *l, size_t n) {
  agc_list *grown = agc_list_append(l, other(0));
  agc_list *changed = agc_list_set(l, n - 1, other(n - 1));
  expect_appended(grown, n, 0);
  expect_replaced(changed, n, n - 1);
  expect_run(l, 0, n);
}

static void expect_persistent(const agc_list *l, size_t n) {
  size_t tail = n ? n - (((n - 1) & 31) + 1) : 0;
  size_t at[] = {0, 31, 32, tail ? tail - 1 : 0, tail, n ? n - 1 : 0};
  agc_list *first = agc_list_append(l, other(0));
  agc_list *second = agc_list_append(l, other(1));
  agc_list *changed[sizeof at / sizeof at[0]] = {NULL};
  for (size_t s = 0; s < sizeof at / sizeof at[0]; s++)
    if (at[s] < n) changed[s] = agc_list_set(l, at[s], other(at[s]));
  expect_run(l, 0, n);
  expect_appended(first, n, 0);
  expect_appended(second, n, 1);
  expect_shape(first, n + 1);
  expect_shape(second, n + 1);
  expect_extends(first);
  for (size_t s = 0; s < sizeof at / sizeof at[0]; s++) {
    if (!changed[s]) continue;
    expect_replaced(changed[s], n, at[s]);
    expect_shape(changed[s], n);
    expect_extends(changed[s]);
  }
}

static void expect_part(const agc_list *part, size_t from, size_t count) {
  expect_run(part, from, count);
  expect_shape(part, count);
  expect_extends(part);
}

static void expect_slices(const agc_list *l, size_t n) {
  size_t trie = n ? list_tail_off(n) : 0;
  size_t cuts[] = {0, 1, 31, 32, 33, n ? n - 1 : 0, n, trie, trie + 1, trie + 2};
  for (size_t s = 0; s < sizeof cuts / sizeof cuts[0]; s++) {
    size_t k = cuts[s];
    if (k > n) continue;
    size_t span = n - k < 33 ? n - k : 33;
    const agc_list *taken = agc_list_slice(l, 0, k);
    expect_part(taken, 0, k);
    if (k > trie && k < n) assert(taken->root == l->root && taken->shift == l->shift);
    expect_part(agc_list_slice(l, k, n - k), k, n - k);
    expect_part(agc_list_slice(l, k, span), k, span);
  }
  expect_run(l, 0, n);
}

static void expect_joined(const agc_list *r, size_t items, size_t extra, bool extra_first) {
  assert(agc_list_len(r) == items + extra);
  expect_shape(r, items + extra);
  expect_extends(r);
  size_t lead = extra_first ? extra : items;
  for (size_t k = 0; k < items + extra; k++) {
    bool in_lead = k < lead;
    size_t at = in_lead ? k : k - lead;
    assert(in_lead == extra_first ? is_other(agc_list_get(r, k), at) : is_item(agc_list_get(r, k), at));
  }
}

static void expect_concats(const agc_list *l, size_t n) {
  size_t sizes[] = {0, 1, 2, 31, 32, 33};
  for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
    size_t m = sizes[s];
    agc_list *right = others(m);
    expect_joined(agc_list_concat(l, right), n, m, false);
    expect_joined(agc_list_concat(right, l), n, m, true);
    expect_joined(agc_list_concat(agc_list_from_array(NULL, 0), right), 0, m, false);
    expect_joined(right, 0, m, false);
  }
  expect_run(l, 0, n);
}

static void expect_reversed(const agc_list *l, size_t n) {
  agc_list *r = agc_list_reverse(l);
  expect_shape(r, n);
  for (size_t k = 0; k < n; k++) assert(is_item(agc_list_get(r, k), n - 1 - k));
  expect_run(l, 0, n);
}

static void expect_same(const agc_list *l, size_t n, size_t at, bool changed) {
  assert(agc_list_len(l) == n);
  for (size_t k = 0; k < n; k++) {
    if (changed && k == at)
      assert(is_item(agc_list_get(l, k), at));
    else
      assert(is_other(agc_list_get(l, k), 7));
  }
}

static void expect_repeated(size_t n) {
  agc_list *r = agc_list_repeat(other(7), n);
  expect_shape(r, n);
  expect_same(r, n, 0, false);
  size_t trie = n ? list_tail_off(n) : 0;
  size_t at[] = {0, 31, 32, trie ? trie - 1 : 0, trie, n ? n - 1 : 0};
  for (size_t s = 0; s < sizeof at / sizeof at[0]; s++) {
    if (at[s] >= n) continue;
    agc_list *changed = agc_list_set(r, at[s], item(at[s]));
    expect_shape(changed, n);
    expect_same(changed, n, at[s], true);
    expect_same(r, n, 0, false);
  }
  agc_list *grown = agc_list_append(r, item(0));
  assert(agc_list_len(grown) == n + 1 && is_item(agc_list_get(grown, n), 0));
  expect_same(r, n, 0, false);
  expect_shape(agc_list_reverse(r), n);
  expect_same(agc_list_slice(r, n / 2, n - n / 2), n - n / 2, 0, false);
}

static void expect_debug(void) {
  char want[1024];
  size_t at = 0;
  want[at++] = '[';
  for (size_t k = 0; k < 100; k++) at += (size_t)snprintf(want + at, sizeof want - at, "%s%zu", k ? ", " : "", k * 3 + 1);
  want[at++] = ']';
  agc_string *d = agc_debug(&vm, agc_list_value(built(100)));
  assert(d->bytes == at && memcmp(d->data, want, at) == 0);
  d = agc_debug(&vm, agc_list_value(agc_list_from_array(NULL, 0)));
  assert(d->bytes == 2 && memcmp(d->data, "[]", 2) == 0);
}

static size_t chain_index(size_t k, size_t n) {
  size_t trie = list_tail_off(n);
  size_t pins[] = {0, 31, 32, trie ? trie - 1 : 0, trie, n - 1};
  return k < sizeof pins / sizeof pins[0] ? pins[k] % n : (k * 37) % n;
}

static void expect_set_chain(size_t n) {
  enum { STEPS = 60 };
  agc_list *versions[STEPS + 1];
  versions[0] = built(n);
  for (size_t k = 0; k < STEPS; k++) versions[k + 1] = agc_list_set(versions[k], chain_index(k, n), other(k));
  for (size_t j = 0; j <= STEPS; j++) {
    expect_shape(versions[j], n);
    for (size_t i = 0; i < n; i++) {
      size_t hit = STEPS;
      for (size_t k = 0; k < j; k++)
        if (chain_index(k, n) == i) hit = k;
      agc_value got = agc_list_get(versions[j], i);
      assert(hit == STEPS ? is_item(got, i) : is_other(got, hit));
    }
  }
}

static void expect_sharing(void) {
  agc_list *base = built(33);
  const agc_list *fits = agc_list_concat(base, others(2));
  assert(fits->root == base->root && fits->shift == base->shift);
  expect_joined(fits, 33, 2, false);
  agc_list *full = built(64);
  const agc_list *spills = agc_list_concat(full, others(1));
  expect_joined(spills, 64, 1, false);
  expect_run(full, 0, 64);
  const agc_list *topped = agc_list_append(built(1056), other(0));
  assert(topped->shift == 10);
  expect_shape(topped, 1057);
}

static void expect_shared_leaves(void) {
  agc_list *big = built(200);
  const agc_list *dropped = agc_list_slice(big, 64, 136);
  expect_part(dropped, 64, 136);
  for (size_t k = 0; k < 4; k++) assert(dropped->root->child[k] == big->root->child[k + 2]);
  const agc_list *taken = agc_list_slice(big, 0, 128);
  expect_part(taken, 0, 128);
  for (size_t k = 0; k < 3; k++) assert(taken->root->child[k] == big->root->child[k]);
  const agc_list *few = agc_list_slice(big, 0, 40);
  expect_part(few, 0, 40);
  assert(few->root->child[0] != big->root->child[0]);
  const agc_list *odd = agc_list_slice(big, 33, 160);
  expect_part(odd, 33, 160);
  assert(odd->root->child[0] != big->root->child[1]);
  agc_list *head = built(100);
  const agc_list *both = agc_list_concat(head, others(100));
  assert(both->root->child[0] == head->root->child[0] && both->root->child[2] == head->root->child[2]);
  expect_joined(both, 100, 100, false);
  const size_t sizes[] = {1500, 4000};
  for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
    expect_joined(agc_list_concat(built(sizes[s]), others(sizes[s])), sizes[s], sizes[s], false);
    expect_joined(agc_list_concat(others(sizes[s]), built(sizes[s])), sizes[s], sizes[s], true);
  }
}

static agc_list *replaced_first(size_t n) { return agc_list_set(built(n), 0, other(0)); }

static void expect_interior_pointers(void) {
  enum { JUNK = 16384, ROUNDS = 100000, AFTER = 2000 };
  agc_gc_info info;
  if (!agc_gc_stats(&info)) return;
  const size_t n = 20000;
  agc_list *kept = replaced_first(n);
  uint64_t stop = info.collections + 3;
  for (size_t round = 0; round < ROUNDS && info.collections < stop; round++) {
    memset(agc_alloc(JUNK), 0xAB, JUNK);
    agc_gc_stats(&info);
  }
  assert(info.collections >= stop);
  for (size_t round = 0; round < AFTER; round++) memset(agc_alloc(JUNK), 0xAB, JUNK);
  assert(is_other(agc_list_get(kept, 0), 0));
  for (size_t k = 1; k < n; k++) assert(is_item(agc_list_get(kept, k), k));
}

static void expect_versions(void) {
  agc_list **versions = agc_alloc(agc_size_mul(KEPT + 1, sizeof(agc_list *)));
  agc_list *l = agc_list_from_array(NULL, 0);
  versions[0] = l;
  for (size_t k = 0; k < KEPT; k++) {
    l = agc_list_append(l, item(k));
    versions[k + 1] = l;
  }
  for (size_t k = 0; k <= KEPT; k++) expect_run(versions[k], 0, k);
}

int main(void) {
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);

  const size_t lengths[] = {0,     1,     2,     31,    32,    33,    63,      64,      65,      1023,    1024,
                            1025,  1056,  1057,  32768, 32769, 32800, 32801,   1048576, 1048608, 1048609};
  for (size_t s = 0; s < sizeof lengths / sizeof lengths[0]; s++) {
    size_t n = lengths[s];
    if (n > MAX_LENGTH) continue;
    agc_list *l = built(n);
    expect_list(l, n);
    expect_reversed(l, n);
    expect_repeated(n);
    if (n <= LARGE) {
      agc_list *grown = appended(n);
      expect_list(grown, n);
      expect_run(grown, 0, n);
      assert(grown->shift == l->shift && (grown->root == NULL) == (l->root == NULL));
    }
    if (n <= LARGE) {
      expect_persistent(l, n);
      expect_slices(l, n);
      expect_concats(l, n);
    } else {
      expect_light(l, n);
    }
  }

  agc_list_builder empty;
  agc_list_builder_sized(&empty, 0);
  assert(agc_list_len(agc_list_builder_finish(&empty)) == 0);
  expect_debug();
  expect_versions();
  expect_sharing();
  expect_shared_leaves();
  expect_interior_pointers();
  const size_t chains[] = {33, 65, 1057, 1100};
  for (size_t s = 0; s < sizeof chains / sizeof chains[0]; s++)
    if (chains[s] <= MAX_LENGTH) expect_set_chain(chains[s]);

  puts("list tests passed");
  return 0;
}
