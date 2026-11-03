/*
 * Deep equality (agc_equal and the builtin Value.equal of ==): 1,000,000-deep
 * lists and enums without C recursion, IEEE 754 for a NaN at any depth (an
 * object holding one is not equal to itself), and the hostile pairs.
 */
#include "../core.h"
#include "builtin_test.h"

#include <assert.h>
#include <math.h>
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
  test_nan();
  test_hostile_pairs();
  return 0;
}
