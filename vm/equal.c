/*
 * Deep value equality (agc_equal): == and != on lists, maps, sets, Results,
 * structs and enums (the builtins Value.equal and Optional.equal), and Test.eq.
 * A Json at any depth compares as its canonical text. One explicit work stack
 * of pairs, and a walker stack for long lists and maps, which are walked one
 * pair at a time; no recursion. Core layer.
 * Design: docs/grammar/06-semantics.md (Operators), site/content/library/testing/test.md.
 */
#include "core.h"

#include <string.h>

/* The stacks start on the C stack and move to GC memory only when they grow past these: most compares (a small
   struct, a unit variant) never allocate. */
#define INLINE_WORK 16
#define INLINE_WALKERS 4

/* Lists up to this length push their item pairs; a longer one gets a walker, so the stacks grow with the depth of
   the values, not with their width. */
#define SHORT_LIST 3

/* A pair still to compare, or the turn of the walker on top of the walker stack: two lists of one length, or two
   maps of one size. A walker entry is pushed with its walker and popped with it, so the two stacks stay in step and
   an entry needs no pointer to its walker. */
typedef enum { WORK_PAIR, WORK_LISTS, WORK_MAP } work_kind;

typedef struct {
  work_kind kind;
  agc_value a, b;
} work;

/* The state of a walk, apart from the work entries so they stay small: the cursors of two lists, whose items are
   taken in order, or the key walk of two maps (vm/map.c). */
typedef struct {
  union {
    struct {
      agc_list_cursor left, right;
    } lists;
    agc_map_pairs map;
  } as;
} walker;

/* items and walkers point at the inline arrays of agc_equal until their first growth. Boehm scans the C stack, so
   the values and the cursors held there stay reachable; after a growth they live in scanned GC memory (agc_alloc). */
typedef struct {
  work *items;
  size_t depth, capacity;
  walker *walkers;
  size_t walking, walker_capacity;
} work_stack;

/* The array of *items with room for one more of size bytes: the same array, or a copy twice as big in GC memory. */
static void *grow(void *items, size_t used, size_t *capacity, size_t size) {
  if (used < *capacity) return items;
  size_t bigger = agc_size_mul(*capacity, 2);
  void *grown = agc_alloc(agc_size_mul(bigger, size));
  memcpy(grown, items, used * size);
  *capacity = bigger;
  return grown;
}

static work *push_slot(work_stack *s) {
  s->items = grow(s->items, s->depth, &s->capacity, sizeof(work));
  return &s->items[s->depth++];
}

/* A walker entry and its walker; the caller fills the walker. */
static walker *push_walker(work_stack *s, work_kind kind) {
  push_slot(s)->kind = kind;
  s->walkers = grow(s->walkers, s->walking, &s->walker_capacity, sizeof(walker));
  return &s->walkers[s->walking++];
}

static void push_pair(work_stack *s, agc_value a, agc_value b) {
  work *w = push_slot(s);
  w->kind = WORK_PAIR;
  w->a = a;
  w->b = b;
}

bool agc_same_string(agc_vm *vm, const agc_string *x, const agc_string *y) {
  if (x == y) return true;
  if (x->bytes != y->bytes) return false;
  agc_charge_bytes(vm, x->bytes);
  return x->bytes == 0 || memcmp(x->data, y->data, x->bytes) == 0;
}

bool agc_same_bytes(agc_vm *vm, const agc_bytes *x, const agc_bytes *y) {
  if (x == y) return true;
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
   a pair taken from the stack does in expand. For a walker (a long list or a map) the walk is depth-first in key
   order, one pair at a time (visit_items, for the fields of a struct and short lists, compares the scalars first), so
   a container pair is walked whole before the next pair of its walker: a scalar difference at a later key of a map
   does not end the compare before a large container at an earlier key is walked. */
static bool visit(agc_vm *vm, work_stack *s, agc_value a, agc_value b) {
  if (a.tag != b.tag) return false;
  if (!scalar_tag(a.tag)) {
    push_pair(s, a, b);
    return true;
  }
  agc_charge(vm, 1);
  return scalar_equal(vm, a, b);
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
    walker *w = push_walker(s, WORK_LISTS);
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
   equal to itself (a list or struct that holds a NaN is not equal to itself either, docs/grammar/06-semantics.md).
   Strings, Bytes, sets (their elements are Ints, Strings or Bytes) and packed Int lists hold no Float; any other
   value is walked. */
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
      if (x->size != y->size) return false;
      agc_map_pairs_begin(vm, &push_walker(s, WORK_MAP)->as.map, x, y);
      return true;
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

/* The next pair of the walker on top, or false when it is done. A map walk that met a key missing from the other
   map is done too, and *differs says so. */
static bool walk_next(agc_vm *vm, work_stack *s, work_kind kind, agc_value *x, agc_value *y, bool *differs) {
  walker *w = &s->walkers[s->walking - 1];
  if (kind == WORK_MAP) {
    if (agc_map_pairs_next(vm, &w->as.map, x, y)) return true;
    *differs = w->as.map.missing;
    return false;
  }
  /* Both lists have one length, so the cursors end together. */
  return agc_list_cursor_next(&w->as.lists.left, x) && agc_list_cursor_next(&w->as.lists.right, y);
}

bool agc_equal(agc_vm *vm, agc_value a, agc_value b, uint32_t span) {
  work inline_items[INLINE_WORK];
  walker inline_walkers[INLINE_WALKERS];
  work_stack s = {inline_items, 0, INLINE_WORK, inline_walkers, 0, INLINE_WALKERS};
  push_pair(&s, a, b);
  while (s.depth) {
    const work *top = &s.items[s.depth - 1];
    agc_value x, y;
    if (top->kind == WORK_PAIR) {
      x = top->a;
      y = top->b;
      s.depth--;
      if (!expand(vm, &s, x, y, span)) return false;
      continue;
    }
    /* The walker entry stays on the stack while its pairs are compared; visit may push a pair above it (and move the
       stack), so top is not used after this. */
    bool differs = false;
    if (walk_next(vm, &s, top->kind, &x, &y, &differs)) {
      if (!visit(vm, &s, x, y)) return false;
    } else if (differs) {
      return false;
    } else {
      s.depth--;
      s.walking--;
    }
  }
  return true;
}
