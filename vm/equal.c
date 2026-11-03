/*
 * Deep value equality (agc_equal): == and != on lists, maps, sets, Results,
 * structs and enums (the builtins Value.equal and Optional.equal), and Test.eq.
 * A Json at any depth compares as its canonical text. One explicit work stack
 * (pairs, and long lists walked by two cursors), no recursion. Core layer.
 * Design: docs/future/25-ruby-typed-idioms.md §25.4, docs/future/36-unit-tests.md §36.3.
 */
#include "core.h"

#include <string.h>

/* The work stack starts on the C stack and moves to GC memory only when it grows past this: most compares (a small
   struct, a unit variant) never allocate. */
#define INLINE_WORK 16

/* Lists up to this length push their item pairs; a longer one gets one cursor entry, so the stack grows with the
   depth of the values, not with their width. */
#define SHORT_LIST 3

/* One entry of the work stack: a pair still to compare, or two lists of one length whose items are taken from the
   cursors, in order. */
typedef struct {
  bool cursors;
  union {
    struct {
      agc_value a, b;
    } pair;
    struct {
      agc_list_cursor left, right;
    } lists;
  } as;
} work;

/* items points at the inline array of agc_equal until the first growth. Boehm scans the C stack, so the values held
   there stay reachable; after a growth they live in scanned GC memory (agc_alloc). */
typedef struct {
  work *items;
  size_t depth, capacity;
} work_stack;

/* What agc_map_each_pair hands back to visit_values. */
typedef struct {
  agc_vm *vm;
  work_stack *stack;
} map_walk;

static work *push_slot(work_stack *s) {
  if (s->depth == s->capacity) {
    size_t bigger = agc_size_mul(s->capacity, 2);
    work *grown = agc_alloc(agc_size_mul(bigger, sizeof(work)));
    memcpy(grown, s->items, s->depth * sizeof(work));
    s->items = grown;
    s->capacity = bigger;
  }
  return &s->items[s->depth++];
}

static void push_pair(work_stack *s, agc_value a, agc_value b) {
  work *w = push_slot(s);
  w->cursors = false;
  w->as.pair.a = a;
  w->as.pair.b = b;
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

/* A tag whose values hold no other value. */
static bool scalar_tag(uint32_t tag) {
  switch ((agc_tag)tag) {
    case AGC_T_VOID:
    case AGC_T_NIL:
    case AGC_T_BOOL:
    case AGC_T_INT:
    case AGC_T_FLOAT:
    case AGC_T_STRING:
    case AGC_T_BYTES:
    case AGC_T_RANGE: return true;
    default: return false;
  }
}

/* Two values of one scalar tag; Floats by IEEE 754. */
static bool scalar_equal(agc_vm *vm, agc_value a, agc_value b) {
  switch ((agc_tag)a.tag) {
    case AGC_T_BOOL: return agc_as_bool(vm, a) == agc_as_bool(vm, b);
    case AGC_T_INT: return agc_as_int(vm, a) == agc_as_int(vm, b);
    case AGC_T_FLOAT: return agc_as_float(vm, a) == agc_as_float(vm, b);
    case AGC_T_STRING: return agc_same_string(vm, agc_as_string(vm, a), agc_as_string(vm, b));
    case AGC_T_BYTES: return agc_same_bytes(vm, agc_as_bytes(vm, a), agc_as_bytes(vm, b));
    case AGC_T_RANGE: {
      const agc_range *x = agc_as_range(vm, a), *y = agc_as_range(vm, b);
      return x->start == y->start && x->end == y->end && x->exclusive == y->exclusive;
    }
    default: return true;
  }
}

/* A pair inside a container: two scalars are compared here, so a difference stops the walk before any later pair is
   pushed; a pair of containers goes on the stack. False when the pair differs. Each scalar pair costs one unit, as
   a pair taken from the stack does in expand. */
static bool visit(agc_vm *vm, work_stack *s, agc_value a, agc_value b) {
  if (a.tag != b.tag) return false;
  if (!scalar_tag(a.tag)) {
    push_pair(s, a, b);
    return true;
  }
  agc_charge(vm, 1);
  return scalar_equal(vm, a, b);
}

static bool visit_values(void *walk, agc_value a, agc_value b) {
  map_walk *w = walk;
  return visit(w->vm, w->stack, a, b);
}

/* Fields, payloads or the items of a short list, in order: the scalars are compared first, then the containers are
   pushed last first, so the first one is compared first. */
static bool visit_items(agc_vm *vm, work_stack *s, const agc_value *x, const agc_value *y, size_t n) {
  for (size_t k = 0; k < n; k++)
    if (scalar_tag(x[k].tag) && !visit(vm, s, x[k], y[k])) return false;
  for (size_t k = n; k > 0; k--)
    if (!scalar_tag(x[k - 1].tag) && !visit(vm, s, x[k - 1], y[k - 1])) return false;
  return true;
}

/* Two packed lists of one kind compare here, with no stack entry per item. Int lists compare each stretch the two
   cursors share with memcmp (a leaf both lists share is skipped); Floats go one by one, by IEEE 754, so a NaN item
   is not equal. One unit per item compared, as a pair taken from the stack would cost. */
static bool same_scalars(agc_vm *vm, const agc_list *x, const agc_list *y) {
  agc_list_cursor left, right;
  size_t compared = 0;
  bool same = true;
  agc_list_cursor_begin(&left, x, 0);
  agc_list_cursor_begin(&right, y, 0);
  if (agc_list_kind(x) == AGC_T_INT) {
    while (same) {
      if (left.index >= left.end && !agc_list_cursor_fill(&left)) break;
      if (right.index >= right.end && !agc_list_cursor_fill(&right)) break;
      size_t n = left.end - left.index < right.end - right.index ? left.end - left.index : right.end - right.index;
      const char *p = left.chunk + (left.index - left.start) * sizeof(uint64_t);
      const char *q = right.chunk + (right.index - right.start) * sizeof(uint64_t);
      same = p == q || memcmp(p, q, n * sizeof(uint64_t)) == 0;
      left.index += n;
      right.index += n;
      compared += n;
    }
  } else {
    agc_value a, b;
    while (same && agc_list_cursor_next(&left, &a) && agc_list_cursor_next(&right, &b)) {
      compared++;
      same = a.tag == b.tag && agc_as_float(vm, a) == agc_as_float(vm, b);
    }
  }
  agc_charge(vm, compared);
  return same;
}

static bool visit_list(agc_vm *vm, work_stack *s, const agc_list *x, const agc_list *y) {
  size_t n = agc_list_len(x);
  if (n != agc_list_len(y)) return false;
  if (agc_list_kind(x) && agc_list_kind(x) == agc_list_kind(y)) return same_scalars(vm, x, y);
  if (n > SHORT_LIST) {
    work *w = push_slot(s);
    w->cursors = true;
    agc_list_cursor_begin(&w->as.lists.left, x, 0);
    agc_list_cursor_begin(&w->as.lists.right, y, 0);
    return true;
  }
  agc_value a[SHORT_LIST], b[SHORT_LIST];
  agc_list_cursor left, right;
  agc_list_cursor_begin(&left, x, 0);
  agc_list_cursor_begin(&right, y, 0);
  for (size_t k = 0; k < n; k++)
    if (!agc_list_cursor_next(&left, &a[k]) || !agc_list_cursor_next(&right, &b[k])) return false;
  return visit_items(vm, s, a, b, n);
}

/* Equal sets have the same size and every element of x is in y, in any order. Each element costs a lookup, so the
   walk is charged its size up front. */
static bool set_equal(agc_vm *vm, const agc_map *x, const agc_map *y) {
  if (x->size != y->size) return false;
  agc_charge(vm, x->size);
  return agc_set_subset(vm, x, y);
}

/* One object compared with itself is equal without a walk only when nothing inside it can be a NaN, which is not
   equal to itself (§25.4: a struct that holds a NaN is not equal to itself either). Strings, Bytes, sets (their
   elements are Ints, Strings or Bytes) and packed Int lists hold no Float; any other value is walked. */
static bool same_object(agc_vm *vm, agc_value a, agc_value b) {
  if (agc_value_word(a) != agc_value_word(b)) return false;
  switch ((agc_tag)a.tag) {
    case AGC_T_STRING:
    case AGC_T_BYTES:
    case AGC_T_SET: return true;
    case AGC_T_LIST: return agc_list_kind(agc_as_list(vm, a)) == AGC_T_INT;
    default: return false;
  }
}

/* A pair taken from the stack: false when it differs; a container's inner pairs are compared or pushed. */
static bool expand(agc_vm *vm, work_stack *s, agc_value a, agc_value b, uint32_t span) {
  if (a.tag != b.tag) return false;
  agc_charge(vm, 1);
  if (same_object(vm, a, b)) return true;
  if (scalar_tag(a.tag)) return scalar_equal(vm, a, b);
  switch ((agc_tag)a.tag) {
    case AGC_T_JSON: return agc_same_string(vm, agc_json_encode(vm, a, span), agc_json_encode(vm, b, span));
    case AGC_T_LIST: return visit_list(vm, s, agc_as_list(vm, a), agc_as_list(vm, b));
    case AGC_T_MAP: {
      const agc_map *x = agc_as_map(vm, a), *y = agc_as_map(vm, b);
      map_walk walk = {vm, s};
      return x->size == y->size && agc_map_each_pair(vm, x, y, visit_values, &walk);
    }
    case AGC_T_SET: return set_equal(vm, agc_as_set(vm, a), agc_as_set(vm, b));
    case AGC_T_STRUCT: {
      const agc_struct *x = agc_as_struct(vm, a), *y = agc_as_struct(vm, b);
      return x->type == y->type && x->n == y->n && visit_items(vm, s, x->fields, y->fields, x->n);
    }
    case AGC_T_ENUM: {
      const agc_enum *x = agc_as_enum(vm, a), *y = agc_as_enum(vm, b);
      return x->variant == y->variant && x->n == y->n && visit_items(vm, s, x->payload, y->payload, x->n);
    }
    case AGC_T_RESULT: {
      const agc_result *x = agc_as_result(vm, a), *y = agc_as_result(vm, b);
      return x->ok == y->ok && visit(vm, s, x->value, y->value);
    }
    default: agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: these values have no equality", span);
  }
}

bool agc_equal(agc_vm *vm, agc_value a, agc_value b, uint32_t span) {
  work inline_items[INLINE_WORK];
  work_stack s = {inline_items, 0, INLINE_WORK};
  push_pair(&s, a, b);
  while (s.depth) {
    work *top = &s.items[s.depth - 1];
    if (top->cursors) {
      agc_value x, y;
      /* Both lists have one length, so the cursors end together. visit may move the stack, so top is not used
         after it. */
      if (!agc_list_cursor_next(&top->as.lists.left, &x) || !agc_list_cursor_next(&top->as.lists.right, &y)) {
        s.depth--;
      } else if (!visit(vm, &s, x, y)) {
        return false;
      }
      continue;
    }
    agc_value x = top->as.pair.a, y = top->as.pair.b;
    s.depth--;
    if (!expand(vm, &s, x, y, span)) return false;
  }
  return true;
}
