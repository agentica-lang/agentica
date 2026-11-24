/*
 * The Bytes builtins (one of the tables that agc_find_builtin searches):
 * Bytes.from_list, to_a, length, at, slice, take, drop, equal (`==`), plus
 * (`+`) and concat, String.bytes, the `.bytes` of an interpolation, and
 * Bytes.build with the write of its Bytes.Builder. A Bytes is an immutable
 * byte string (agc_bytes in value.h); every result is a new copy, the empty
 * constant, or the buffer of a Bytes.build that no write can reach again.
 * Service layer.
 * Design: docs/vm/05-values-execution-builtins.md §5.1.
 */
#include "services.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#define BUILDER_FIRST 256
#define BUILDER_SPARE_MAX ((size_t)64 * 1024)

/* The state of a Bytes.build call, which its block sees as a Bytes.Builder (AGC_T_BUILDER). buf holds cap bytes, of
   which len are written; the builder is the only reference to it. When the block returns the builder closes, and a
   write after the close, or from another task than the one that called Bytes.build, is RUNTIME-BUILDER-CLOSED, so a
   builder that escapes its block (through a channel, or into a block that another task runs) can reach no buffer: a
   returned Bytes stays immutable and no two schedulers write one buffer. A buffer of up to BUILDER_SPARE_MAX bytes is
   copied into the Bytes and kept in the task for its next build, so a build in a loop allocates only its result; a
   larger one becomes the Bytes itself. */
typedef struct {
  agc_stepper stepper;
  agc_bytes *buf;
  size_t cap;
  agc_task *owner;
  bool called, closed;
} builder;

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

/* The text of V in *DATA and its length: printed into PRINTED for an Int, Float, Bool or nil. */
static size_t part_text(agc_vm *vm, agc_value v, char printed[AGC_SCALAR_TEXT], const void **data, uint32_t span) {
  if (agc_is(v, AGC_T_INT) || agc_is(v, AGC_T_FLOAT) || agc_is(v, AGC_T_BOOL) || agc_is(v, AGC_T_NIL) ||
      agc_is(v, AGC_T_UINT64)) {
    *data = printed;
    return agc_scalar_text(vm, v, printed);
  }
  agc_string *text;
  if (!agc_text_checked(vm, v, &text)) agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: a value has no text", span);
  *data = text->data;
  return text->bytes;
}

static agc_value interpolated(agc_vm *vm, agc_value *args, uint32_t count, uint32_t span) {
  char printed[INTERPOLATED_PARTS][AGC_SCALAR_TEXT];
  const void *data[INTERPOLATED_PARTS];
  size_t len[INTERPOLATED_PARTS], total = 0;
  for (uint32_t k = 0; k < count; k++) {
    len[k] = part_text(vm, args[k], printed[k], &data[k], span);
    total = agc_size_add(total, len[k]);
  }
  if (total == 0) return agc_bytes_value(agc_empty_bytes());
  agc_bytes *joined = agc_new_bytes(total);
  size_t at = 0;
  for (uint32_t k = 0; k < count; k++) {
    if (len[k]) memcpy(joined->data + at, data[k], len[k]);
    at += len[k];
  }
  return agc_bytes_value(joined);
}

#define INTERPOLATED(n)                                                                  \
  static agc_value builtin_interpolated##n(agc_vm *vm, agc_value *args, uint32_t span) { \
    return interpolated(vm, args, n, span);                                              \
  }
INTERPOLATED(1) INTERPOLATED(2) INTERPOLATED(3) INTERPOLATED(4)
INTERPOLATED(5) INTERPOLATED(6) INTERPOLATED(7) INTERPOLATED(8)
#define INTERPOLATED_ROW(n) \
  {"String.interpolated.bytes", n, builtin_interpolated##n, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false}

/* Bytes.concat([a, b]) with a list literal of 1 to CONCAT_PARTS items, and a + b + c: the lowering sends the parts in
   registers, so no List is made for them and no Bytes for a partial sum. */
#define CONCAT_PARTS 8

static agc_value concat_parts(agc_vm *vm, agc_value *args, uint32_t count) {
  const agc_bytes *part[CONCAT_PARTS];
  size_t total = 0;
  uint32_t filled = 0, last = 0;
  for (uint32_t k = 0; k < count; k++) {
    part[k] = agc_as_bytes(vm, args[k]);
    if (part[k]->len) {
      total = agc_size_add(total, part[k]->len);
      filled++;
      last = k;
    }
  }
  if (filled == 0) return agc_bytes_value(agc_empty_bytes());
  if (filled == 1) return args[last];
  agc_bytes *joined = agc_new_bytes(total);
  size_t at = 0;
  for (uint32_t k = 0; k < count; k++) {
    if (part[k]->len) memcpy(joined->data + at, part[k]->data, part[k]->len);
    at += part[k]->len;
  }
  return agc_bytes_value(joined);
}

#define CONCAT(n)                                                                  \
  static agc_value builtin_concat##n(agc_vm *vm, agc_value *args, uint32_t span) { \
    (void)span;                                                                    \
    return concat_parts(vm, args, n);                                              \
  }
CONCAT(1) CONCAT(2) CONCAT(3) CONCAT(4) CONCAT(5) CONCAT(6) CONCAT(7) CONCAT(8)
#define CONCAT_ROW(n) {"Bytes.concat.parts", n, builtin_concat##n, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false}

static agc_value closed(builder *b) {
  b->closed = true;
  agc_bytes *buf = b->buf;
  b->buf = NULL;
  if (b->cap > BUILDER_SPARE_MAX) return agc_bytes_value(buf);
  agc_value out = agc_bytes_value(agc_make_bytes(buf->data, buf->len));
  if (b->cap >= b->owner->build_spare_cap) {
    b->owner->build_spare = buf;
    b->owner->build_spare_cap = b->cap;
  }
  return out;
}

static agc_step build_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  (void)vm;
  (void)last;
  builder *b = (builder *)self;
  if (!b->called) {
    b->called = true;
    return (agc_step){.kind = AGC_STEP_CALL, .value = agc_builder_value(b)};
  }
  return (agc_step){.kind = AGC_STEP_END, .value = closed(b)};
}

/* Bytes.build(block): a stepper that calls the block once with the builder and ends with its buffer. The step touches
   only the builder and its task, so it runs without rt->sync. */
static agc_value builtin_build(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  builder *b = agc_alloc(sizeof *b);
  b->stepper.step = build_step;
  b->stepper.unlocked = true;
  b->owner = vm->task;
  if (b->owner->build_spare) {
    b->buf = b->owner->build_spare;
    b->cap = b->owner->build_spare_cap;
    b->owner->build_spare = NULL;
    b->owner->build_spare_cap = 0;
  } else {
    b->buf = agc_alloc_atomic(sizeof(agc_bytes) + BUILDER_FIRST);
    b->cap = BUILDER_FIRST;
  }
  b->buf->len = 0;
  agc_task_stepper(vm, &b->stepper);
  return agc_void();
}

/* Room for EXTRA more bytes after what was written; the buffer at least doubles when it grows. */
static uint8_t *reserve(builder *b, size_t extra) {
  size_t need = agc_size_add(b->buf->len, extra);
  if (need > b->cap) {
    size_t cap = b->cap;
    while (cap < need) cap = agc_size_mul(cap, 2);
    agc_bytes *grown = agc_alloc_atomic(agc_size_add(sizeof(agc_bytes), cap));
    grown->len = b->buf->len;
    memcpy(grown->data, b->buf->data, b->buf->len);
    b->buf = grown;
    b->cap = cap;
  }
  uint8_t *at = b->buf->data + b->buf->len;
  b->buf->len = need;
  return at;
}

/* out.write(a, b, ...): each value's bytes appended in order, a Bytes or a String as it is, an Int, Float, Bool or nil
   printed on the stack, any other value in the text TO_TEXT gives it. The lowering sends out and 1 to
   INTERPOLATED_PARTS values. */
static agc_value write_values(agc_vm *vm, agc_value *args, uint32_t count, uint32_t span) {
  builder *b = agc_as_builder(vm, args[0]);
  if (b->owner != vm->task)
    agc_fail(vm, "RUNTIME-BUILDER-CLOSED", "the Bytes.Builder is used from another task than its Bytes.build", span + 1);
  if (b->closed) agc_fail(vm, "RUNTIME-BUILDER-CLOSED", "the Bytes.Builder is used after its Bytes.build ended", span + 1);
  char printed[INTERPOLATED_PARTS][AGC_SCALAR_TEXT];
  const void *data[INTERPOLATED_PARTS];
  size_t len[INTERPOLATED_PARTS], total = 0;
  for (uint32_t k = 0; k + 1 < count; k++) {
    agc_value v = args[k + 1];
    if (agc_is(v, AGC_T_BYTES)) {
      const agc_bytes *part = agc_as_bytes(vm, v);
      data[k] = part->data;
      len[k] = part->len;
    } else if (agc_is(v, AGC_T_STRING)) {
      const agc_string *part = agc_as_string(vm, v);
      data[k] = part->data;
      len[k] = part->bytes;
    } else {
      len[k] = part_text(vm, v, printed[k], &data[k], span + 2 + k);
    }
    total = agc_size_add(total, len[k]);
  }
  uint8_t *at = reserve(b, total);
  for (uint32_t k = 0; k + 1 < count; k++) {
    const uint8_t *from = data[k];
    if (len[k] <= 16)
      for (size_t i = 0; i < len[k]; i++) at[i] = from[i];
    else
      memcpy(at, from, len[k]);
    at += len[k];
  }
  return agc_void();
}

#define WRITE(n)                                                                  \
  static agc_value builtin_write##n(agc_vm *vm, agc_value *args, uint32_t span) { \
    return write_values(vm, args, n, span);                                       \
  }
WRITE(2) WRITE(3) WRITE(4) WRITE(5) WRITE(6) WRITE(7) WRITE(8) WRITE(9)
#define WRITE_ROW(n) {"Bytes.Builder.write", n, builtin_write##n, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false}

const agc_builtin agc_bytes_builtins[] = {
  {"Bytes.from_list", 1, builtin_from_list, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false},
  {"Bytes.to_a", 1, builtin_to_a, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false},
  {"Bytes.length", 1, builtin_length, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Bytes.at", 2, builtin_at, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Bytes.slice", 3, builtin_slice, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true, false},
  {"Bytes.take", 2, builtin_take, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true, false},
  {"Bytes.drop", 2, builtin_drop, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true, false},
  {"Bytes.equal", 2, builtin_equal, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true, false},
  {"Bytes.plus", 2, builtin_plus, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false},
  {"Bytes.concat", 1, builtin_concat, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false},
  {"String.bytes", 1, builtin_string_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false},
  INTERPOLATED_ROW(1), INTERPOLATED_ROW(2), INTERPOLATED_ROW(3), INTERPOLATED_ROW(4),
  INTERPOLATED_ROW(5), INTERPOLATED_ROW(6), INTERPOLATED_ROW(7), INTERPOLATED_ROW(8),
  CONCAT_ROW(1), CONCAT_ROW(2), CONCAT_ROW(3), CONCAT_ROW(4),
  CONCAT_ROW(5), CONCAT_ROW(6), CONCAT_ROW(7), CONCAT_ROW(8),
  {"Bytes.build", 1, builtin_build, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  WRITE_ROW(2), WRITE_ROW(3), WRITE_ROW(4), WRITE_ROW(5),
  WRITE_ROW(6), WRITE_ROW(7), WRITE_ROW(8), WRITE_ROW(9),
};

const size_t agc_bytes_builtin_count = sizeof agc_bytes_builtins / sizeof agc_bytes_builtins[0];
