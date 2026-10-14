#include "../core.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

#define APPEND_MAX ((size_t)1100)
#define LARGE ((size_t)33000)
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
  expect_run(l, 0, n);
  size_t starts[] = {0, 1, 31, 32, 33, n / 2, n ? n - 1 : 0, n};
  for (size_t s = 0; s < sizeof starts / sizeof starts[0]; s++)
    if (starts[s] <= n) expect_cursor(l, starts[s]);
  agc_value *copy = agc_alloc(agc_size_mul(n, sizeof(agc_value)));
  agc_list_to_array(l, copy);
  for (size_t k = 0; k < n; k++) assert(is_item(copy[k], k));
  expect_run(agc_list_from_array(copy, n), 0, n);
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
  for (size_t s = 0; s < sizeof at / sizeof at[0]; s++)
    if (changed[s]) expect_replaced(changed[s], n, at[s]);
}

static void expect_slices(const agc_list *l, size_t n) {
  size_t cuts[] = {0, 1, 31, 32, 33, n ? n - 1 : 0, n};
  for (size_t s = 0; s < sizeof cuts / sizeof cuts[0]; s++) {
    size_t k = cuts[s];
    if (k > n) continue;
    size_t span = n - k < 33 ? n - k : 33;
    expect_run(agc_list_slice(l, 0, k), 0, k);
    expect_run(agc_list_slice(l, k, n - k), k, n - k);
    expect_run(agc_list_slice(l, k, span), k, span);
  }
  expect_run(l, 0, n);
}

static void expect_joined(const agc_list *r, size_t items, size_t extra, bool extra_first) {
  assert(agc_list_len(r) == items + extra);
  size_t lead = extra_first ? extra : items;
  for (size_t k = 0; k < items + extra; k++) {
    bool in_lead = k < lead;
    size_t at = in_lead ? k : k - lead;
    assert(in_lead == extra_first ? is_other(agc_list_get(r, k), at) : is_item(agc_list_get(r, k), at));
  }
}

static void expect_concats(const agc_list *l, size_t n) {
  size_t sizes[] = {0, 1, 32, 33};
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
    if (n <= APPEND_MAX) {
      agc_list *grown = appended(n);
      expect_list(grown, n);
      expect_run(grown, 0, n);
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

  puts("list tests passed");
  return 0;
}
