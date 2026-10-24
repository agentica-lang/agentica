/*
 * The status contract of the opcode helpers (agc_op_* in core.h): a status on
 * overflow, division by zero, a bad index or a wrong tag, the result register
 * left alone then, and no longjmp (the VM here has no failure target).
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static agc_vm vm;

/* The tag and the 8-byte payload: bytes 4 to 7 are padding that the constructors leave unset. */
static bool same_bits(agc_value x, agc_value y) { return x.tag == y.tag && agc_value_word(x) == agc_value_word(y); }

/* A failing helper returns `want` and leaves `dst` as it was. */
static void fails(agc_status got, agc_status want, const agc_value *dst, agc_value before) {
  assert(got == want);
  assert(same_bits(*dst, before));
}

static void int_rules(void) {
  agc_value max = agc_int(INT64_MAX), min = agc_int(INT64_MIN), one = agc_int(1), zero = agc_int(0);
  agc_value minus = agc_int(-1), mark = agc_nil(), dst = mark;
  fails(agc_op_add_i(&vm, &dst, &max, &one), AGC_STATUS_OVERFLOW, &dst, mark);
  fails(agc_op_sub_i(&vm, &dst, &min, &one), AGC_STATUS_OVERFLOW, &dst, mark);
  fails(agc_op_mul_i(&vm, &dst, &max, &max), AGC_STATUS_OVERFLOW, &dst, mark);
  fails(agc_op_div_i(&vm, &dst, &min, &minus), AGC_STATUS_OVERFLOW, &dst, mark);
  fails(agc_op_neg_i(&vm, &dst, &min), AGC_STATUS_OVERFLOW, &dst, mark);
  fails(agc_op_div_i(&vm, &dst, &one, &zero), AGC_STATUS_DIVISION_BY_ZERO, &dst, mark);
  fails(agc_op_mod_i(&vm, &dst, &one, &zero), AGC_STATUS_DIVISION_BY_ZERO, &dst, mark);
  assert(agc_op_mod_i(&vm, &dst, &min, &minus) == AGC_STATUS_OK && same_bits(dst, zero));
  /* The result register may be an operand: both are read before it is written. */
  agc_value acc = agc_int(40);
  assert(agc_op_add_i(&vm, &acc, &acc, &acc) == AGC_STATUS_OK && same_bits(acc, agc_int(80)));
  assert(agc_op_lt_i(&vm, &dst, &min, &max) == AGC_STATUS_OK && same_bits(dst, agc_bool(true)));
}

static void float_rules(void) {
  agc_value x = agc_float(1.5), zero = agc_float(0.0), mark = agc_nil(), dst = mark;
  fails(agc_op_div_f(&vm, &dst, &x, &zero), AGC_STATUS_DIVISION_BY_ZERO, &dst, mark);
  assert(agc_op_mul_f(&vm, &dst, &x, &x) == AGC_STATUS_OK && same_bits(dst, agc_float(2.25)));
  agc_value neg = agc_float(-0.0);
  assert(agc_op_same(&vm, &dst, &zero, &neg) == AGC_STATUS_OK && same_bits(dst, agc_bool(false)));
  assert(agc_op_eq(&vm, &dst, &zero, &neg) == AGC_STATUS_OK && same_bits(dst, agc_bool(true)));
  /* A NaN is the same as a NaN but not equal to it (isnan's nonzero result is not taken for the -1 sentinel). */
  agc_value nan = agc_float(NAN);
  assert(agc_op_same(&vm, &dst, &nan, &nan) == AGC_STATUS_OK && same_bits(dst, agc_bool(true)));
  assert(agc_op_eq(&vm, &dst, &nan, &nan) == AGC_STATUS_OK && same_bits(dst, agc_bool(false)));
  assert(agc_op_ne(&vm, &dst, &nan, &nan) == AGC_STATUS_OK && same_bits(dst, agc_bool(true)));
  /* The divisor is checked first, as before the helpers returned a status. */
  agc_value i = agc_int(1);
  dst = mark;
  fails(agc_op_div_f(&vm, &dst, &i, &zero), AGC_STATUS_DIVISION_BY_ZERO, &dst, mark);
  fails(agc_op_div_f(&vm, &dst, &i, &x), AGC_STATUS_WRONG_TAG, &dst, mark);
}

/* A wrong tag is hand-made bytecode: the helper reports it instead of calling agc_wrong_tag. */
static void wrong_tags(void) {
  agc_value i = agc_int(1), f = agc_float(1.0), list = agc_list_value(agc_list_from_array(&i, 1));
  agc_value mark = agc_nil(), dst = mark;
  fails(agc_op_add_i(&vm, &dst, &i, &f), AGC_STATUS_WRONG_TAG, &dst, mark);
  fails(agc_op_add_f(&vm, &dst, &f, &i), AGC_STATUS_WRONG_TAG, &dst, mark);
  fails(agc_op_neg_i(&vm, &dst, &f), AGC_STATUS_WRONG_TAG, &dst, mark);
  fails(agc_op_lt_f(&vm, &dst, &i, &i), AGC_STATUS_WRONG_TAG, &dst, mark);
  fails(agc_op_list_get(&vm, &dst, &i, &i), AGC_STATUS_WRONG_TAG, &dst, mark);
  fails(agc_op_list_get(&vm, &dst, &list, &f), AGC_STATUS_WRONG_TAG, &dst, mark);
  /* EQ has no equality for two lists; SAME is false for two different tags before it looks. */
  fails(agc_op_eq(&vm, &dst, &list, &list), AGC_STATUS_WRONG_TAG, &dst, mark);
  assert(agc_op_same(&vm, &dst, &i, &f) == AGC_STATUS_OK && same_bits(dst, agc_bool(false)));
}

static void lists(void) {
  agc_value items[3] = {agc_int(7), agc_int(8), agc_int(9)};
  agc_value list = agc_list_value(agc_list_from_array(items, 3));
  agc_value at = agc_int(3), back = agc_int(-1), mark = agc_nil(), dst = mark;
  fails(agc_op_list_get(&vm, &dst, &list, &at), AGC_STATUS_INDEX_OUT_OF_RANGE, &dst, mark);
  fails(agc_op_list_get(&vm, &dst, &list, &back), AGC_STATUS_INDEX_OUT_OF_RANGE, &dst, mark);
  at = agc_int(2);
  assert(agc_op_list_get(&vm, &dst, &list, &at) == AGC_STATUS_OK && same_bits(dst, items[2]));
  assert(agc_op_list_len(&vm, &dst, &list) == AGC_STATUS_OK && same_bits(dst, agc_int(3)));
}

/* The printed bytes of a String result. */
static void text_is(agc_value got, const char *want) {
  size_t n = strlen(want);
  assert(agc_is(got, AGC_T_STRING));
  const agc_string *s = agc_as_string(&vm, got);
  assert(s->bytes == n && s->chars == n && memcmp(s->data, want, n) == 0);
}

/* A Void nested in a compound has no text form: the checked form reports it, and the helper answers WRONG_TAG with
   dst and the turn cost left alone. The program holds one struct S(x) and one enum E with variants v/1 and w/2, as
   a loaded program would, so the record and enum shapes walk their defs first. Void map keys and set elements are
   not covered: a void key never survives construction (agc_key_hash fails it in agc_map_put), so hostile bytecode
   fails at MAP, never at TO_TEXT. */
static void void_text(void) {
  agc_test_shapes shapes;
  agc_test_shapes_init(&shapes);
  const agc_program *saved = vm.rt->program;
  vm.rt->program = &shapes.program;
  agc_value one = agc_int(1), void_value = agc_void(), mark = agc_nil(), dst;
  agc_value inner_items[2] = {one, void_value};
  agc_value inner = agc_list_value(agc_list_from_array(inner_items, 2));
  agc_value deep_items[2] = {one, inner};
  agc_value key = agc_string_value(agc_make_string("a", 1, 1));
  agc_struct *st = agc_new_struct(0, 1);
  st->fields[0] = void_value;
  agc_enum *en = agc_new_enum(1, 2);
  en->payload[0] = one;
  en->payload[1] = void_value;
  agc_value holes[6] = {
    inner,
    agc_list_value(agc_list_from_array(deep_items, 2)),
    agc_map_value(agc_map_put(&vm, agc_new_map(), key, void_value)),
    agc_struct_value(st),
    agc_enum_value(en),
    agc_result_value(false, void_value),
  };
  for (size_t k = 0; k < sizeof holes / sizeof holes[0]; k++) {
    dst = mark;
    vm.task->turn_cost = 0;
    assert(agc_op_to_text(&vm, &dst, &holes[k]) == AGC_STATUS_WRONG_TAG);
    assert(same_bits(dst, mark) && vm.task->turn_cost == 0);
  }
  /* ok(void) and a single void payload print with no items, as the formatter always did. */
  agc_value ok_void = agc_result_value(true, void_value);
  assert(agc_op_to_text(&vm, &dst, &ok_void) == AGC_STATUS_OK);
  text_is(dst, "ok()");
  agc_enum *unit = agc_new_enum(0, 1);
  unit->payload[0] = void_value;
  agc_value unit_value = agc_enum_value(unit);
  assert(agc_op_to_text(&vm, &dst, &unit_value) == AGC_STATUS_OK);
  text_is(dst, "E.v()");
  vm.rt->program = saved;
  vm.task->turn_cost = 0;
}

/* Valid compounds print exactly what agc_text prints, and charge exactly what it charges: the checked form is the
   same single walk, so the helper adds no second hash or traversal. */
static void compound_text(void) {
  agc_value one = agc_int(1), two = agc_int(2), mark = agc_nil(), dst;
  agc_value pair[2] = {one, two};
  agc_map *m = agc_map_put(&vm, agc_new_map(), agc_string_value(agc_make_string("a", 1, 1)), one);
  m = agc_map_put(&vm, m, agc_int(2), two);
  agc_map *s = agc_map_put(&vm, agc_new_map(), one, agc_nil());
  s = agc_map_put(&vm, s, two, agc_nil());
  agc_value forms[5] = {
    agc_list_value(agc_list_from_array(pair, 2)),
    agc_map_value(m),
    agc_set_value(s),
    agc_result_value(true, one),
    agc_list_value(agc_list_from_array(pair, 0)),
  };
  for (size_t k = 0; k < sizeof forms / sizeof forms[0]; k++) {
    vm.task->turn_cost = 0;
    agc_string *want_text = agc_text(&vm, forms[k]);
    int64_t want_cost = vm.task->turn_cost;
    dst = mark;
    vm.task->turn_cost = 0;
    assert(agc_op_to_text(&vm, &dst, &forms[k]) == AGC_STATUS_OK);
    assert(agc_is(dst, AGC_T_STRING));
    const agc_string *got = agc_as_string(&vm, dst);
    assert(got->bytes == want_text->bytes && memcmp(got->data, want_text->data, got->bytes) == 0);
    assert(vm.task->turn_cost == want_cost);
  }
  vm.task->turn_cost = 0;
}

static void strings(void) {
  agc_value ab = agc_string_value(agc_make_string("ab", 2, 2));
  agc_value cd = agc_string_value(agc_make_string("cd", 2, 2));
  agc_value i = agc_int(1), mark = agc_nil(), dst = mark;
  /* CONCAT joins; 4 bytes charge no turn cost (AGC_COST_BYTES is 64). */
  vm.task->turn_cost = 0;
  assert(agc_op_concat(&vm, &dst, &ab, &cd) == AGC_STATUS_OK);
  text_is(dst, "abcd");
  assert(vm.task->turn_cost == 0);
  /* The result register may be an operand: both Strings are read before it is written. */
  agc_value acc = ab;
  assert(agc_op_concat(&vm, &acc, &acc, &cd) == AGC_STATUS_OK);
  text_is(acc, "abcd");
  assert(agc_op_concat(&vm, &acc, &ab, &acc) == AGC_STATUS_OK);
  text_is(acc, "ababcd");
  /* Any other pair is hand-made bytecode (the checker keeps `+` to two Strings or two numbers). */
  dst = mark;
  fails(agc_op_concat(&vm, &dst, &ab, &i), AGC_STATUS_WRONG_TAG, &dst, mark);
  fails(agc_op_concat(&vm, &dst, &i, &ab), AGC_STATUS_WRONG_TAG, &dst, mark);
  fails(agc_op_concat(&vm, &dst, &i, &i), AGC_STATUS_WRONG_TAG, &dst, mark);
  /* TO_TEXT prints every tag with a form; a String comes back as it was. */
  agc_value neg = agc_int(-42), one_five = agc_float(1.5), yes = agc_bool(true), nothing = agc_nil();
  agc_value range = agc_range_value(1, 3, false), void_value = agc_void();
  assert(agc_op_to_text(&vm, &dst, &ab) == AGC_STATUS_OK && same_bits(dst, ab));
  assert(agc_op_to_text(&vm, &dst, &neg) == AGC_STATUS_OK);
  text_is(dst, "-42");
  assert(agc_op_to_text(&vm, &dst, &one_five) == AGC_STATUS_OK);
  text_is(dst, "1.5");
  assert(agc_op_to_text(&vm, &dst, &yes) == AGC_STATUS_OK);
  text_is(dst, "true");
  assert(agc_op_to_text(&vm, &dst, &nothing) == AGC_STATUS_OK);
  text_is(dst, "nil");
  assert(agc_op_to_text(&vm, &dst, &range) == AGC_STATUS_OK);
  text_is(dst, "1..3");
  agc_value items[2] = {agc_int(7), agc_int(8)};
  agc_value list = agc_list_value(agc_list_from_array(items, 2));
  assert(agc_op_to_text(&vm, &dst, &list) == AGC_STATUS_OK);
  text_is(dst, "[7, 8]");
  /* A Void value is hand-made bytecode (the checker rejects one with CHECK-VOID-VALUE). */
  dst = mark;
  fails(agc_op_to_text(&vm, &dst, &void_value), AGC_STATUS_WRONG_TAG, &dst, mark);
  /* A 200-byte join charges its bytes, as the interpreter's case did. */
  char text[200];
  memset(text, 'a', sizeof text);
  agc_value big = agc_string_value(agc_make_string(text, sizeof text, sizeof text));
  vm.task->turn_cost = 0;
  assert(agc_op_concat(&vm, &dst, &big, &big) == AGC_STATUS_OK);
  assert(agc_as_string(&vm, dst)->bytes == 2 * sizeof text);
  assert(vm.task->turn_cost == (int64_t)(2 * sizeof text / AGC_COST_BYTES));
  vm.task->turn_cost = 0;
}

int main(void) {
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  int_rules();
  float_rules();
  wrong_tags();
  lists();
  strings();
  void_text();
  compound_text();
  puts("op helper tests passed");
  return 0;
}
