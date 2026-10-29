/*
 * Deep value equality (agc_equal), pulled forward for Test.eq. A Json at any
 * depth compares as its canonical text. One explicit stack, no recursion.
 * Core layer. Design: docs/future/25-ruby-typed-idioms.md §25.4 and
 * docs/future/36-unit-tests.md §36.3.
 */
#include "core.h"

#include <string.h>

typedef struct {
  agc_value a, b;
} pair;

typedef struct {
  pair *items;
  size_t depth, capacity;
} pair_stack;

static void push(pair_stack *s, agc_value a, agc_value b) {
  if (s->depth == s->capacity) {
    size_t bigger = agc_size_mul(s->capacity, 2);
    pair *grown = agc_alloc(agc_size_mul(bigger, sizeof(pair)));
    memcpy(grown, s->items, s->depth * sizeof(pair));
    s->items = grown;
    s->capacity = bigger;
  }
  s->items[s->depth].a = a;
  s->items[s->depth].b = b;
  s->depth++;
}

bool agc_same_string(agc_vm *vm, const agc_string *x, const agc_string *y) {
  if (x->bytes != y->bytes) return false;
  agc_charge_bytes(vm, x->bytes);
  return x->bytes == 0 || memcmp(x->data, y->data, x->bytes) == 0;
}

bool agc_same_bytes(agc_vm *vm, const agc_bytes *x, const agc_bytes *y) {
  if (x->len != y->len) return false;
  agc_charge_bytes(vm, x->len);
  return x->len == 0 || memcmp(x->data, y->data, x->len) == 0;
}

int agc_equal_rest(agc_vm *vm, const agc_value *x, const agc_value *y) {
  if (agc_is(*x, AGC_T_BYTES) && agc_is(*y, AGC_T_BYTES))
    return agc_same_bytes(vm, agc_as_bytes(vm, *x), agc_as_bytes(vm, *y));
  return -1;
}

static bool push_map(agc_vm *vm, pair_stack *s, const agc_map *x, const agc_map *y) {
  if (x->size != y->size) return false;
  const agc_value *keys = agc_map_keys(vm, x, 0);
  for (size_t k = 0; k < x->size; k++) {
    agc_value left, right;
    if (!agc_map_get(vm, x, keys[k], &left) || !agc_map_get(vm, y, keys[k], &right)) return false;
    push(s, left, right);
  }
  return true;
}

/* Elements are Ints, Strings or Bytes, so no pair is pushed: equal sets have
   the same size and every element of x is in y, in any order. Each element
   costs a lookup, so the walk is charged its size up front. */
static bool set_equal(agc_vm *vm, const agc_map *x, const agc_map *y) {
  if (x->size != y->size) return false;
  agc_charge(vm, x->size);
  return agc_set_subset(vm, x, y);
}

static bool push_items(pair_stack *s, const agc_value *x, const agc_value *y, size_t n) {
  for (size_t k = 0; k < n; k++) push(s, x[k], y[k]);
  return true;
}

static bool push_list(pair_stack *s, const agc_list *x, const agc_list *y) {
  agc_list_cursor left, right;
  agc_value a, b;
  agc_list_cursor_begin(&left, x, 0);
  agc_list_cursor_begin(&right, y, 0);
  while (agc_list_cursor_next(&left, &a) && agc_list_cursor_next(&right, &b)) push(s, a, b);
  return true;
}

static bool expand(agc_vm *vm, pair_stack *s, agc_value a, agc_value b, uint32_t span) {
  if (a.tag != b.tag) return false;
  agc_charge(vm, 1);
  switch ((agc_tag)a.tag) {
    case AGC_T_VOID:
    case AGC_T_NIL: return true;
    case AGC_T_BOOL: return agc_as_bool(vm, a) == agc_as_bool(vm, b);
    case AGC_T_INT: return agc_as_int(vm, a) == agc_as_int(vm, b);
    case AGC_T_FLOAT: return agc_as_float(vm, a) == agc_as_float(vm, b);
    case AGC_T_STRING: return agc_same_string(vm, agc_as_string(vm, a), agc_as_string(vm, b));
    case AGC_T_BYTES: return agc_same_bytes(vm, agc_as_bytes(vm, a), agc_as_bytes(vm, b));
    case AGC_T_RANGE: {
      const agc_range *x = agc_as_range(vm, a), *y = agc_as_range(vm, b);
      return x->start == y->start && x->end == y->end && x->exclusive == y->exclusive;
    }
    case AGC_T_JSON: return agc_same_string(vm, agc_json_encode(vm, a, span), agc_json_encode(vm, b, span));
    case AGC_T_LIST: {
      const agc_list *x = agc_as_list(vm, a), *y = agc_as_list(vm, b);
      return agc_list_len(x) == agc_list_len(y) && push_list(s, x, y);
    }
    case AGC_T_MAP: return push_map(vm, s, agc_as_map(vm, a), agc_as_map(vm, b));
    case AGC_T_SET: return set_equal(vm, agc_as_set(vm, a), agc_as_set(vm, b));
    case AGC_T_STRUCT: {
      const agc_struct *x = agc_as_struct(vm, a), *y = agc_as_struct(vm, b);
      return x->type == y->type && x->n == y->n && push_items(s, x->fields, y->fields, x->n);
    }
    case AGC_T_ENUM: {
      const agc_enum *x = agc_as_enum(vm, a), *y = agc_as_enum(vm, b);
      return x->variant == y->variant && x->n == y->n && push_items(s, x->payload, y->payload, x->n);
    }
    case AGC_T_RESULT: {
      const agc_result *x = agc_as_result(vm, a), *y = agc_as_result(vm, b);
      if (x->ok != y->ok) return false;
      push(s, x->value, y->value);
      return true;
    }
    default: agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: these values have no equality", span);
  }
}

bool agc_equal(agc_vm *vm, agc_value a, agc_value b, uint32_t span) {
  pair_stack s;
  s.capacity = 16;
  s.depth = 0;
  s.items = agc_alloc(agc_size_mul(s.capacity, sizeof(pair)));
  push(&s, a, b);
  while (s.depth) {
    s.depth--;
    if (!expand(vm, &s, s.items[s.depth].a, s.items[s.depth].b, span)) return false;
  }
  return true;
}
