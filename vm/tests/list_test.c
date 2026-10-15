/*
 * The list API at the lengths around the 32-way boundaries, for Int, Float and
 * boxed items: trie shape, builder, append, set, slice, concat, reverse and
 * repeat, cursors, persistence, the kind of a list (unboxed leaves, 17.12) and
 * the conversion to boxed leaves when kinds mix.
 */
#include "../core.h"
#include "../list_impl.h"

#include <assert.h>
#include <math.h>
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

typedef enum { FLAVOR_INT, FLAVOR_FLOAT, FLAVOR_BOXED, FLAVORS } flavor_t;

static flavor_t flavor;

static uint32_t kind_of_flavor(flavor_t f) { return f == FLAVOR_INT ? AGC_T_INT : f == FLAVOR_FLOAT ? AGC_T_FLOAT : 0; }

static agc_value make_as(flavor_t f, int64_t n) {
  if (f == FLAVOR_INT) return agc_int(n);
  if (f == FLAVOR_FLOAT) return agc_float((double)n);
  return agc_range_value(n, 0, false);
}

static int64_t number_as(flavor_t f, agc_value v) {
  if (f == FLAVOR_INT) {
    assert(agc_is(v, AGC_T_INT));
    return agc_as_int(&vm, v);
  }
  if (f == FLAVOR_FLOAT) {
    assert(agc_is(v, AGC_T_FLOAT));
    return (int64_t)agc_as_float(&vm, v);
  }
  assert(agc_is(v, AGC_T_RANGE));
  return agc_as_range(&vm, v)->start;
}

static agc_value item(size_t i) { return make_as(flavor, (int64_t)i * 3 + 1); }

static agc_value other(size_t i) { return make_as(flavor, -(int64_t)i - 1); }

static int64_t int_of(agc_value v) { return number_as(flavor, v); }

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
  assert(l->kind == (n ? kind_of_flavor(flavor) : 0));
  assert(agc_list_kind(l) == l->kind);
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

static void run_lengths(void) {
  const size_t lengths[] = {0,     1,     2,     31,    32,    33,    63,      64,      65,      1023,    1024,
                            1025,  1056,  1057,  32768, 32769, 32800, 32801,   1048576, 1048608, 1048609};
  for (size_t s = 0; s < sizeof lengths / sizeof lengths[0]; s++) {
    size_t n = lengths[s];
    if (n > MAX_LENGTH || (flavor != FLAVOR_INT && n > LARGE)) continue;
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
  if (flavor == FLAVOR_INT) expect_debug();
  expect_versions();
  expect_sharing();
  expect_shared_leaves();
  expect_interior_pointers();
  const size_t chains[] = {33, 65, 1057, 1100};
  for (size_t s = 0; s < sizeof chains / sizeof chains[0]; s++)
    if (chains[s] <= MAX_LENGTH) expect_set_chain(chains[s]);
}

static agc_value sample(flavor_t k, size_t i) { return make_as(k, (int64_t)i * 3 + 1); }

static bool is_sample(agc_value v, flavor_t k, size_t i) { return number_as(k, v) == (int64_t)i * 3 + 1; }


static agc_list *sampled(flavor_t k, size_t n) {
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t i = 0; i < n; i++) agc_list_builder_push(&b, sample(k, i));
  return agc_list_builder_finish(&b);
}

static void expect_samples(const agc_list *l, flavor_t k, size_t n) {
  assert(agc_list_len(l) == n);
  assert(l->kind == (n ? kind_of_flavor(k) : 0));
  for (size_t i = 0; i < n; i++) assert(is_sample(agc_list_get(l, i), k, i));
}

static void expect_mixed(const agc_list *l, flavor_t base, flavor_t odd, size_t n, size_t at) {
  assert(agc_list_len(l) == n);
  assert(l->kind == 0);
  for (size_t i = 0; i < n; i++) assert(is_sample(agc_list_get(l, i), i == at ? odd : base, i));
  agc_list_cursor c;
  agc_value v;
  agc_list_cursor_begin(&c, l, 0);
  for (size_t i = 0; i < n; i++) {
    assert(agc_list_cursor_next(&c, &v));
    assert(is_sample(v, i == at ? odd : base, i));
  }
}

static void expect_builder_mixing(flavor_t base, flavor_t odd) {
  const size_t sizes[] = {1, 2, 3, 31, 32, 33, 34, 64, 65, 66, 1056, 1057, 1058, 2113};
  for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
    size_t n = sizes[s];
    if (n < 2) continue;
    size_t trie = list_tail_off(n);
    size_t spots[] = {0, 1, 31, 32, 33, trie ? trie - 1 : 0, trie, trie + 1, n / 2, n - 1};
    for (size_t t = 0; t < sizeof spots / sizeof spots[0]; t++) {
      size_t at = spots[t];
      if (at >= n) continue;
      agc_list_builder b;
      agc_list_builder_sized(&b, n);
      for (size_t i = 0; i < n; i++) agc_list_builder_push(&b, sample(i == at ? odd : base, i));
      expect_mixed(agc_list_builder_finish(&b), base, odd, n, at);
    }
  }
}

static void expect_append_mixing(flavor_t base, flavor_t odd) {
  const size_t sizes[] = {1, 31, 32, 33, 64, 65, 1056, 1057};
  for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
    size_t n = sizes[s];
    agc_list *l = sampled(base, n);
    agc_list *grown = agc_list_append(l, sample(odd, n));
    assert(agc_list_len(grown) == n + 1 && grown->kind == 0);
    for (size_t i = 0; i < n; i++) assert(is_sample(agc_list_get(grown, i), base, i));
    assert(is_sample(agc_list_get(grown, n), odd, n));
    expect_samples(l, base, n);
    size_t trie = list_tail_off(n);
    size_t spots[] = {0, 31, 32, trie ? trie - 1 : 0, trie, n - 1};
    for (size_t t = 0; t < sizeof spots / sizeof spots[0]; t++) {
      size_t at = spots[t];
      if (at >= n) continue;
      agc_list *changed = agc_list_set(l, at, sample(odd, at));
      expect_mixed(changed, base, odd, n, at);
      expect_samples(l, base, n);
    }
  }
}

static void expect_concat_mixing(flavor_t left, flavor_t right) {
  const size_t lefts[] = {1, 31, 32, 33, 100};
  const size_t rights[] = {1, 2, 32, 33, 100};
  for (size_t s = 0; s < sizeof lefts / sizeof lefts[0]; s++) {
    for (size_t t = 0; t < sizeof rights / sizeof rights[0]; t++) {
      size_t n = lefts[s], m = rights[t];
      agc_list *a = sampled(left, n);
      agc_list *b = sampled(right, m);
      agc_list *joined = agc_list_concat(a, b);
      assert(agc_list_len(joined) == n + m && joined->kind == 0);
      for (size_t i = 0; i < n; i++) assert(is_sample(agc_list_get(joined, i), left, i));
      for (size_t i = 0; i < m; i++) assert(is_sample(agc_list_get(joined, n + i), right, i));
      expect_samples(a, left, n);
      expect_samples(b, right, m);
      agc_list *edited = agc_list_set(joined, 0, sample(right, 0));
      assert(is_sample(agc_list_get(edited, 0), right, 0));
      expect_samples(a, left, n);
    }
  }
}

static void expect_from_array_kinds(void) {
  agc_value mixed[70];
  memset(mixed, 0, sizeof mixed);
  for (size_t n = 0; n <= 70; n += n < 3 ? 1 : 67) {
    for (size_t k = 0; k < n; k++) mixed[k] = sample(FLAVOR_INT, k);
    agc_list *ints = agc_list_from_array(mixed, n);
    assert(ints->kind == (n ? AGC_T_INT : 0) && agc_list_len(ints) == n);
    for (size_t at = 0; at < n; at += at < 3 ? 1 : 33) {
      for (size_t k = 0; k < n; k++) mixed[k] = sample(k == at ? FLAVOR_BOXED : FLAVOR_INT, k);
      agc_list *wide = agc_list_from_array(mixed, n);
      expect_mixed(wide, FLAVOR_INT, FLAVOR_BOXED, n, at);
    }
  }
  for (size_t k = 0; k < 40; k++) mixed[k] = sample(k == 39 ? FLAVOR_INT : FLAVOR_FLOAT, k);
  agc_list *floats = agc_list_from_array(mixed, 39);
  assert(floats->kind == AGC_T_FLOAT);
  expect_samples(floats, FLAVOR_FLOAT, 39);
  expect_mixed(agc_list_from_array(mixed, 40), FLAVOR_FLOAT, FLAVOR_INT, 40, 39);
}

static void expect_empty_kinds(void) {
  agc_list *empty = agc_list_from_array(NULL, 0);
  assert(empty->kind == 0 && agc_list_kind(empty) == 0);
  agc_list_builder b;
  agc_list_builder_sized(&b, 0);
  assert(agc_list_builder_finish(&b)->kind == 0);
  assert(agc_list_slice(sampled(FLAVOR_INT, 40), 40, 0)->kind == 0);
  assert(agc_list_slice(sampled(FLAVOR_FLOAT, 40), 3, 0)->kind == 0);
  assert(agc_list_repeat(sample(FLAVOR_INT, 0), 0)->kind == 0);
  assert(agc_list_concat(empty, empty)->kind == 0);
  agc_list *ints = sampled(FLAVOR_INT, 5);
  assert(agc_list_concat(ints, empty) == ints && agc_list_concat(empty, ints) == ints);
  agc_list *wide = sampled(FLAVOR_BOXED, 5);
  assert(agc_list_concat(empty, wide) == wide);
  assert(agc_list_append(empty, sample(FLAVOR_INT, 0))->kind == AGC_T_INT);
  assert(agc_list_append(empty, sample(FLAVOR_FLOAT, 0))->kind == AGC_T_FLOAT);
  assert(agc_list_append(empty, sample(FLAVOR_BOXED, 0))->kind == 0);
  assert(agc_list_append(wide, sample(FLAVOR_INT, 0))->kind == 0);
  agc_list_builder first;
  agc_list_builder_sized(&first, 3);
  agc_list_builder_push(&first, sample(FLAVOR_FLOAT, 0));
  agc_list_builder_push(&first, sample(FLAVOR_FLOAT, 1));
  agc_list_builder_push(&first, sample(FLAVOR_FLOAT, 2));
  assert(agc_list_builder_finish(&first)->kind == AGC_T_FLOAT);
}

static bool same_word(agc_value a, agc_value b) { return a.tag == b.tag && agc_value_word(a) == agc_value_word(b); }

static agc_value special_value(flavor_t k, size_t i) {
  static const int64_t ints[] = {INT64_MIN, INT64_MAX, 0, -1, 1, INT64_MIN + 1};
  static const uint64_t floats[] = {0x8000000000000000ull, 0, 0x7ff8dead00000001ull, 0xfff8000000000000ull,
                                    0x7ff0000000000000ull, 0xfff0000000000000ull, 0x0010000000000000ull,
                                    1, 0x7fefffffffffffffull};
  if (k == FLAVOR_INT) return agc_int(ints[i % (sizeof ints / sizeof ints[0])]);
  return agc_word_value(AGC_T_FLOAT, floats[i % (sizeof floats / sizeof floats[0])]);
}

static void expect_special_run(const agc_list *l, flavor_t k, size_t from, size_t n) {
  assert(agc_list_len(l) == n);
  for (size_t i = 0; i < n; i++) assert(same_word(agc_list_get(l, i), special_value(k, from + i)));
}

static void expect_specials(flavor_t k) {
  const size_t n = 100;
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t i = 0; i < n; i++) agc_list_builder_push(&b, special_value(k, i));
  agc_list *l = agc_list_builder_finish(&b);
  assert(l->kind == kind_of_flavor(k));
  expect_special_run(l, k, 0, n);
  agc_list *grown = agc_list_from_array(NULL, 0);
  for (size_t i = 0; i < n; i++) grown = agc_list_append(grown, special_value(k, i));
  expect_special_run(grown, k, 0, n);
  agc_list *changed = agc_list_set(l, 40, special_value(k, 3));
  assert(same_word(agc_list_get(changed, 40), special_value(k, 3)));
  assert(same_word(agc_list_get(changed, 41), special_value(k, 41)));
  expect_special_run(l, k, 0, n);
  expect_special_run(agc_list_slice(l, 64, 36), k, 64, 36);
  expect_special_run(agc_list_slice(l, 0, 70), k, 0, 70);
  agc_list *back = agc_list_reverse(l);
  for (size_t i = 0; i < n; i++) assert(same_word(agc_list_get(back, i), special_value(k, n - 1 - i)));
  agc_list *joined = agc_list_concat(l, l);
  expect_special_run(agc_list_slice(joined, n, n), k, 0, n);
  for (size_t i = 0; i < 9; i++) {
    agc_list *same = agc_list_repeat(special_value(k, i), 70);
    for (size_t j = 0; j < 70; j++) assert(same_word(agc_list_get(same, j), special_value(k, i)));
  }
  assert(isnan(agc_as_float(&vm, special_value(FLAVOR_FLOAT, 2))));
}

static void expect_kind_persistence(void) {
  agc_list *ints = sampled(FLAVOR_INT, 200);
  agc_list *boxed = sampled(FLAVOR_BOXED, 40);
  agc_list *wide = agc_list_concat(ints, boxed);
  assert(wide->kind == 0 && wide->root != ints->root);
  agc_list *wider = agc_list_set(wide, 10, sample(FLAVOR_BOXED, 10));
  agc_list *head = agc_list_slice(ints, 0, 128);
  agc_list *rest = agc_list_slice(ints, 64, 136);
  assert(head->kind == AGC_T_INT && rest->kind == AGC_T_INT);
  for (size_t k = 0; k < 3; k++) assert(head->root->child[k] == ints->root->child[k]);
  for (size_t k = 0; k < 4; k++) assert(rest->root->child[k] == ints->root->child[k + 2]);
  agc_list *edited = agc_list_set(head, 5, sample(FLAVOR_FLOAT, 5));
  assert(edited->kind == 0 && edited->root != head->root);
  expect_samples(ints, FLAVOR_INT, 200);
  expect_samples(boxed, FLAVOR_BOXED, 40);
  expect_samples(head, FLAVOR_INT, 128);
  for (size_t i = 0; i < 136; i++) assert(is_sample(agc_list_get(rest, i), FLAVOR_INT, 64 + i));
  for (size_t i = 0; i < 200; i++) assert(is_sample(agc_list_get(wide, i), FLAVOR_INT, i));
  for (size_t i = 0; i < 40; i++) assert(is_sample(agc_list_get(wide, 200 + i), FLAVOR_BOXED, i));
  assert(is_sample(agc_list_get(wider, 10), FLAVOR_BOXED, 10));
  assert(is_sample(agc_list_get(edited, 5), FLAVOR_FLOAT, 5));
  agc_list *floats = sampled(FLAVOR_FLOAT, 200);
  agc_list *both = agc_list_concat(ints, floats);
  assert(both->kind == 0 && agc_list_len(both) == 400);
  agc_list *again = agc_list_slice(both, 100, 200);
  assert(again->kind == 0);
  for (size_t i = 0; i < 100; i++) assert(is_sample(agc_list_get(again, i), FLAVOR_INT, 100 + i));
  for (size_t i = 0; i < 100; i++) assert(is_sample(agc_list_get(again, 100 + i), FLAVOR_FLOAT, i));
}

int main(void) {
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);

  for (flavor = 0; flavor < FLAVORS; flavor++) run_lengths();

  for (flavor_t a = 0; a < FLAVORS; a++) {
    for (flavor_t b = 0; b < FLAVORS; b++) {
      if (a == b) continue;
      expect_builder_mixing(a, b);
      expect_append_mixing(a, b);
      expect_concat_mixing(a, b);
    }
  }
  expect_from_array_kinds();
  expect_empty_kinds();
  expect_specials(FLAVOR_INT);
  expect_specials(FLAVOR_FLOAT);
  expect_kind_persistence();

  puts("list tests passed");
  return 0;
}
