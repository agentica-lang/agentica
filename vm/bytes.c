/*
 * The Bytes builtins (one of the tables that agc_find_builtin searches):
 * Bytes.from_list, to_a, length, at, slice, take, drop, equal (`==`), plus
 * (`+`) and concat, String.bytes and the `.bytes` of an interpolation. A
 * Bytes is an immutable byte string (agc_bytes in value.h); every result is
 * a new copy or the empty constant.
 * Service layer.
 * Design: docs/vm/05-values-execution-builtins.md §5.1.
 */
#include "services.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

/* error on the first item outside 0..255, with its index: the type cannot say that an Int is a byte. */
static agc_value builtin_from_list(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *items = agc_as_list(vm, args[0]);
  size_t n = agc_list_len(items);
  if (n == 0) return agc_result_value(true, agc_bytes_value(agc_empty_bytes()));
  agc_bytes *b = agc_new_bytes(n);
  agc_list_cursor cursor;
  agc_list_cursor_begin(&cursor, items, 0);
  agc_value item;
  for (size_t k = 0; agc_list_cursor_next(&cursor, &item); k++) {
    int64_t x = agc_as_int(vm, item);
    if (x < 0 || x > 255) {
      char text[96];
      snprintf(text, sizeof text, "item %zu is %" PRId64 ", not a byte (0 to 255)", k, x);
      return agc_error(vm, AGC_KIND_ARGUMENT, text);
    }
    b->data[k] = (uint8_t)x;
  }
  return agc_result_value(true, agc_bytes_value(b));
}

static agc_value builtin_to_a(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  size_t len;
  const uint8_t *data = agc_bytes_data(vm, args[0], &len);
  if (len == 0) return vm->rt->empty_list;
  return agc_list_value(agc_list_of_bytes(data, len));
}

static agc_value builtin_length(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int((int64_t)agc_as_bytes(vm, args[0])->len);
}

static agc_value builtin_at(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_bytes *b = agc_as_bytes(vm, args[0]);
  int64_t i = agc_as_int(vm, args[1]);
  if (i < 0 || (uint64_t)i >= b->len) agc_fail(vm, "RUNTIME-INDEX-OUT-OF-RANGE", "byte index is out of range", span + 2);
  return agc_int(b->data[i]);
}

/* The bytes [from, from + count) of the argument, which they lie inside. A cut copies (a view would keep a large
   parent alive) and is charged by what it copies, not by the size of the parent, so a parser that cuts small pieces
   out of a large buffer pays for the pieces. */
static agc_value cut(agc_vm *vm, agc_value whole, size_t from, size_t count) {
  const agc_bytes *b = agc_as_bytes(vm, whole);
  if (count == b->len) return whole;
  agc_charge_bytes(vm, count);
  return agc_bytes_value(agc_make_bytes(b->data + from, count));
}

static agc_value builtin_slice(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_bytes *b = agc_as_bytes(vm, args[0]);
  int64_t start = agc_as_int(vm, args[1]), length = agc_as_int(vm, args[2]);
  if (start < 0 || length < 0 || (uint64_t)start > b->len || (uint64_t)length > b->len - (uint64_t)start) {
    char text[128];
    snprintf(text, sizeof text, "slice %" PRId64 ",%" PRId64 " is outside bytes of length %zu", start, length, b->len);
    agc_fail_text(vm, "RUNTIME-INDEX-OUT-OF-RANGE", agc_make_string(text, strlen(text), strlen(text)), span);
  }
  return cut(vm, args[0], (size_t)start, (size_t)length);
}

/* The count of take and drop, clamped to the length as List#take and List#drop do. */
static size_t clamped(agc_vm *vm, const agc_bytes *b, agc_value count, uint32_t span) {
  int64_t n = agc_as_int(vm, count);
  if (n < 0) agc_fail(vm, "RUNTIME-INVALID-COUNT", "count must be nonnegative", span + 2);
  return (uint64_t)n < b->len ? (size_t)n : b->len;
}

static agc_value builtin_take(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_bytes *b = agc_as_bytes(vm, args[0]);
  return cut(vm, args[0], 0, clamped(vm, b, args[1], span));
}

static agc_value builtin_drop(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_bytes *b = agc_as_bytes(vm, args[0]);
  size_t k = clamped(vm, b, args[1], span);
  return cut(vm, args[0], k, b->len - k);
}

/* a == b: the same length and the same bytes, by memcmp (not constant time). A builtin, not the EQ instruction:
   EQ's equal_values sits above the turn loop in vm/interp.c, and any change to it moves the loop (make
   layout-check). The checker allows == on no type variable, so no generic code reaches EQ with a Bytes. */
static agc_value builtin_equal(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_bool(agc_same_bytes(vm, agc_as_bytes(vm, args[0]), agc_as_bytes(vm, args[1])));
}

/* a + b. In a loop it copies everything each time; Bytes.concat joins many parts in one copy. */
static agc_value builtin_plus(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_bytes *a = agc_as_bytes(vm, args[0]), *b = agc_as_bytes(vm, args[1]);
  if (b->len == 0) return args[0];
  if (a->len == 0) return args[1];
  agc_bytes *joined = agc_new_bytes(agc_size_add(a->len, b->len));
  memcpy(joined->data, a->data, a->len);
  memcpy(joined->data + a->len, b->data, b->len);
  return agc_bytes_value(joined);
}

/* The parts joined in one copy: a pass for the size (agc_size_add stops an overflow), then a pass that fills it. */
static agc_value builtin_concat(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *parts = agc_as_list(vm, args[0]);
  agc_list_cursor cursor;
  agc_value part, last = agc_bytes_value(agc_empty_bytes());
  size_t total = 0, filled = 0;
  agc_list_cursor_begin(&cursor, parts, 0);
  while (agc_list_cursor_next(&cursor, &part)) {
    size_t len = agc_as_bytes(vm, part)->len;
    if (len) {
      total = agc_size_add(total, len);
      filled++;
      last = part;
    }
  }
  if (filled <= 1) return last;
  agc_bytes *joined = agc_new_bytes(total);
  size_t at = 0;
  agc_list_cursor_begin(&cursor, parts, 0);
  while (agc_list_cursor_next(&cursor, &part)) {
    const agc_bytes *b = agc_as_bytes(vm, part);
    if (b->len) memcpy(joined->data + at, b->data, b->len);
    at += b->len;
  }
  return agc_bytes_value(joined);
}

/* The UTF-8 bytes of a String, as it is stored. */
static agc_value builtin_string_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  return agc_bytes_value(agc_make_bytes((const uint8_t *)s->data, s->bytes));
}

/* "a#{b}c".bytes: the text of every part written into one Bytes, with no String for a part or for the whole. A part
   is a String as it is, or any other value in the text TO_TEXT gives it; an Int, Float, Bool or nil is printed on the
   stack. The lowering sends 1 to INTERPOLATED_PARTS parts; a longer interpolation is joined as a String first. */
#define INTERPOLATED_PARTS 8

static agc_value interpolated(agc_vm *vm, agc_value *args, uint32_t count, uint32_t span) {
  char printed[INTERPOLATED_PARTS][AGC_SCALAR_TEXT];
  const agc_string *kept[INTERPOLATED_PARTS];
  const char *data[INTERPOLATED_PARTS];
  size_t len[INTERPOLATED_PARTS], total = 0;
  for (uint32_t k = 0; k < count; k++) {
    agc_value v = args[k];
    kept[k] = NULL;
    if (agc_is(v, AGC_T_INT) || agc_is(v, AGC_T_FLOAT) || agc_is(v, AGC_T_BOOL) || agc_is(v, AGC_T_NIL)) {
      data[k] = printed[k];
      len[k] = agc_scalar_text(vm, v, printed[k]);
    } else {
      agc_string *text;
      if (!agc_text_checked(vm, v, &text))
        agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: a part of an interpolation has no text", span);
      kept[k] = text;
      data[k] = text->data;
      len[k] = text->bytes;
    }
    total = agc_size_add(total, len[k]);
  }
  if (total == 0) return agc_bytes_value(agc_empty_bytes());
  agc_bytes *joined = agc_new_bytes(total);
  size_t at = 0;
  for (uint32_t k = 0; k < count; k++) {
    if (len[k]) memcpy(joined->data + at, data[k], len[k]);
    at += len[k];
  }
  (void)kept;
  return agc_bytes_value(joined);
}

#define INTERPOLATED(n)                                                                  \
  static agc_value builtin_interpolated##n(agc_vm *vm, agc_value *args, uint32_t span) { \
    return interpolated(vm, args, n, span);                                              \
  }
INTERPOLATED(1) INTERPOLATED(2) INTERPOLATED(3) INTERPOLATED(4)
INTERPOLATED(5) INTERPOLATED(6) INTERPOLATED(7) INTERPOLATED(8)
#define INTERPOLATED_ROW(n) \
  {"String.interpolated.bytes", n, builtin_interpolated##n, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true}

const agc_builtin agc_bytes_builtins[] = {
  {"Bytes.from_list", 1, builtin_from_list, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"Bytes.to_a", 1, builtin_to_a, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"Bytes.length", 1, builtin_length, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"Bytes.at", 2, builtin_at, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"Bytes.slice", 3, builtin_slice, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true},
  {"Bytes.take", 2, builtin_take, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true},
  {"Bytes.drop", 2, builtin_drop, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true},
  {"Bytes.equal", 2, builtin_equal, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true},
  {"Bytes.plus", 2, builtin_plus, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"Bytes.concat", 1, builtin_concat, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.bytes", 1, builtin_string_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  INTERPOLATED_ROW(1), INTERPOLATED_ROW(2), INTERPOLATED_ROW(3), INTERPOLATED_ROW(4),
  INTERPOLATED_ROW(5), INTERPOLATED_ROW(6), INTERPOLATED_ROW(7), INTERPOLATED_ROW(8),
};

const size_t agc_bytes_builtin_count = sizeof agc_bytes_builtins / sizeof agc_bytes_builtins[0];
