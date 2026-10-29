/*
 * The Bytes builtins (one of the tables that agc_find_builtin searches):
 * Bytes.from_list, to_a, length, at, slice, take, drop, plus (`+`) and concat,
 * and String.bytes. A Bytes is an immutable byte string (agc_bytes in value.h);
 * every result is a new copy or the run's shared empty value. Service layer.
 * Design: docs/vm/05-values-execution-builtins.md §5.1.
 */
#include "services.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static agc_value bytes_of(const uint8_t *data, size_t len) {
  return agc_bytes_value(agc_make_bytes(data, len));
}

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
      return agc_error_value(text);
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
  return bytes_of(b->data + from, count);
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
  return bytes_of((const uint8_t *)s->data, s->bytes);
}

const agc_builtin agc_bytes_builtins[] = {
  {"Bytes.from_list", 1, builtin_from_list, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"Bytes.to_a", 1, builtin_to_a, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"Bytes.length", 1, builtin_length, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"Bytes.at", 2, builtin_at, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"Bytes.slice", 3, builtin_slice, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true},
  {"Bytes.take", 2, builtin_take, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true},
  {"Bytes.drop", 2, builtin_drop, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true},
  {"Bytes.plus", 2, builtin_plus, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"Bytes.concat", 1, builtin_concat, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
  {"String.bytes", 1, builtin_string_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true},
};

const size_t agc_bytes_builtin_count = sizeof agc_bytes_builtins / sizeof agc_bytes_builtins[0];
