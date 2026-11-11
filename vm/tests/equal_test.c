/*
 * Deep equality (agc_equal, Value.equal and Optional.equal): 1,000,000-deep lists
 * and enums without C recursion, wide and nested maps and lists that grow the
 * stacks while the walk allocates, IEEE 754 for a NaN, and the hostile pairs.
 */
#include "../core.h"
#include "builtin_test.h"
#include "test_support.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static agc_vm vm;

static bool value_equal(agc_value a, agc_value b) {
  agc_value args[] = {a, b};
  const agc_builtin *row = agc_find_builtin((const uint8_t *)"Value.equal", 11, 2);
  assert(row);
  return agc_as_bool(&vm, row->fn(&vm, args, 0));
}

static agc_value list_of(agc_value *items, size_t n) { return agc_list_value(agc_list_from_array(items, n)); }

/* A list nested depth times around an Int, built by a loop so the C stack stays flat. */
static agc_value nested_list(size_t depth, int64_t leaf) {
  agc_value deep = agc_int(leaf);
  for (size_t k = 0; k < depth; k++) deep = list_of(&deep, 1);
  return deep;
}

/* The same depth through an enum payload (a Tree.Branch of a Tree), so the walk goes through enums too. */
static agc_value nested_enum(size_t depth, int64_t leaf) {
  agc_enum *e = agc_new_enum(0, 1);
  e->payload[0] = agc_int(leaf);
  agc_value deep = agc_enum_value(e);
  for (size_t k = 0; k < depth; k++) {
    agc_enum *branch = agc_new_enum(1, 1);
    branch->payload[0] = deep;
    deep = agc_enum_value(branch);
  }
  return deep;
}

static void test_deep_values(void) {
#ifdef AGC_GC_STRESS
  size_t depth = 1000;
#else
  size_t depth = 1000000;
#endif
  assert(value_equal(nested_list(depth, 1), nested_list(depth, 1)));
  assert(!value_equal(nested_list(depth, 1), nested_list(depth, 2)));
  assert(!value_equal(nested_list(depth, 1), nested_list(depth - 1, 1)));
  assert(value_equal(nested_enum(depth, 7), nested_enum(depth, 7)));
  assert(!value_equal(nested_enum(depth, 7), nested_enum(depth, 8)));
}

/* A map of n keys whose values are one-item lists of a Json number (each compare encodes both, so it allocates), and
   a list of n two-field structs whose second field is a list. Under GC_STRESS the walk collects while pairs are on
   the work stack, which has grown past its inline part. */
static agc_value wide_map(size_t n, int64_t last) {
  agc_map *m = agc_new_map();
  for (size_t k = 0; k < n; k++) {
    char key[32];
    snprintf(key, sizeof key, "key-%zu", k);
    agc_value json = agc_json_number(k + 1 == n ? last : (int64_t)k);
    m = agc_map_put(&vm, m, agc_test_str(key), list_of(&json, 1));
  }
  return agc_map_value(m);
}

static agc_value wide_list(size_t n, int64_t last) {
  agc_value *items = agc_alloc(n * sizeof(agc_value));
  for (size_t k = 0; k < n; k++) {
    agc_struct *s = agc_new_struct(0, 2);
    agc_value inner[] = {agc_test_str("x"), agc_int(k + 1 == n ? last : (int64_t)k)};
    s->fields[0] = agc_int((int64_t)k);
    s->fields[1] = list_of(inner, 2);
    items[k] = agc_struct_value(s);
  }
  return list_of(items, n);
}

static void test_wide_values(void) {
  assert(value_equal(wide_map(1000, -1), wide_map(1000, -1)));
  assert(!value_equal(wide_map(1000, -1), wide_map(1000, -2)));
  assert(value_equal(wide_list(1000, -1), wide_list(1000, -1)));
  assert(!value_equal(wide_list(1000, -1), wide_list(1000, -2)));
  agc_value deep_wide[] = {wide_map(200, 5), nested_list(50, 1), wide_list(200, 5), agc_test_str("end")};
  agc_value other[] = {wide_map(200, 5), nested_list(50, 1), wide_list(200, 5), agc_test_str("end")};
  assert(value_equal(list_of(deep_wide, 4), list_of(other, 4)));
  other[3] = agc_test_str("End");
  assert(!value_equal(list_of(deep_wide, 4), list_of(other, 4)));
}

/* Maps nested depth deep, each with a deleted key (so the walk keeps a dead set) and a Json list that allocates when
   it is compared: the walker stack grows past its inline part, and under GC_STRESS the walk collects while the
   walkers and their dead sets are live. */
static agc_value nested_maps(size_t depth, int64_t leaf) {
  agc_value inner = agc_int(leaf);
  for (size_t k = 0; k < depth; k++) {
    agc_value json = agc_json_number((int64_t)k);
    agc_map *m = agc_map_put(&vm, agc_new_map(), agc_test_str("gone"), agc_int(0));
    m = agc_map_put(&vm, m, agc_test_str("json"), list_of(&json, 1));
    m = agc_map_put(&vm, m, agc_test_str("next"), inner);
    inner = agc_map_value(agc_map_delete(&vm, m, agc_test_str("gone")));
  }
  return inner;
}

static void test_nested_maps(void) {
  assert(value_equal(nested_maps(100, 1), nested_maps(100, 1)));
  assert(!value_equal(nested_maps(100, 1), nested_maps(100, 2)));
  agc_value items = list_of((agc_value[]){agc_int(1), agc_test_str("x")}, 2);
  agc_map *one = agc_map_put(&vm, agc_new_map(), agc_test_str("a"), items);
  agc_map *other = agc_map_put(&vm, agc_new_map(), agc_test_str("b"), items);
  assert(!value_equal(agc_map_value(one), agc_map_value(other)));
}

/* Both rows of == run one function, which answers two different variants and two unit variants itself. */
static void test_enum_rows(void) {
  const agc_builtin *optional = agc_find_builtin((const uint8_t *)"Optional.equal", 14, 2);
  const agc_builtin *value = agc_find_builtin((const uint8_t *)"Value.equal", 11, 2);
  assert(optional && value && optional->fn == value->fn);
  agc_enum *some = agc_new_enum(1, 1);
  some->payload[0] = agc_int(1);
  agc_value none = agc_enum_value(agc_new_enum(0, 0));
  assert(!value_equal(agc_enum_value(some), none));
  assert(value_equal(none, agc_enum_value(agc_new_enum(0, 0))));
  assert(value_equal(agc_enum_value(some), agc_enum_value(some)));
}

static void test_nan(void) {
  agc_value nan = agc_float(NAN);
  agc_value floats = list_of(&nan, 1);
  assert(!value_equal(floats, floats));
  agc_value boxed = list_of(&floats, 1);
  assert(!value_equal(boxed, boxed));
  agc_enum *circle = agc_new_enum(0, 1);
  circle->payload[0] = nan;
  assert(!value_equal(agc_enum_value(circle), agc_enum_value(circle)));

  agc_value zeros[] = {agc_float(0.0), agc_float(-0.0)};
  assert(value_equal(list_of(&zeros[0], 1), list_of(&zeros[1], 1)));

  agc_value ints[] = {agc_int(1), agc_int(2), agc_int(3)};
  agc_value packed = list_of(ints, 3);
  assert(value_equal(packed, packed) && value_equal(packed, list_of(ints, 3)));
  agc_value other[] = {agc_int(1), agc_int(2), agc_int(4)};
  assert(!value_equal(packed, list_of(other, 3)));
}

static void test_hostile_pairs(void) {
  const agc_builtin *row = agc_find_builtin((const uint8_t *)"Value.equal", 11, 2);
  assert(row);
  agc_value s = agc_string_value(agc_make_string("a", 1, 1));
  assert(!value_equal(agc_int(1), s));
  agc_value fns[] = {agc_fn_value(agc_new_fn(0, 0)), agc_fn_value(agc_new_fn(0, 0))};
  agc_test_fails(&vm, "Value.equal", row, fns, "RUNTIME-INTERNAL");
  agc_value same[] = {fns[0], fns[0]};
  agc_test_fails(&vm, "Value.equal", row, same, "RUNTIME-INTERNAL");
  agc_value lists[] = {list_of(&fns[0], 1), list_of(&fns[1], 1)};
  agc_test_fails(&vm, "Value.equal", row, lists, "RUNTIME-INTERNAL");
}

int main(void) {
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_deep_values();
  test_wide_values();
  test_nested_maps();
  test_enum_rows();
  test_nan();
  test_hostile_pairs();
  return 0;
}
