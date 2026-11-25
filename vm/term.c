/*
 * Term.encode: a value in CBOR (RFC 8949), deterministic and typed by the checker. One explicit frame stack walks the
 * value, so no C recursion follows its depth. Service layer.
 * Design: docs/vm/02-reference-behavior.md §2.9.
 */
#include "services.h"

#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#define TERM_MAX_DEPTH AGC_TERM_MAX_DEPTH
#define TERM_MAX_ITEMS AGC_TERM_MAX_ITEMS
#define TERM_MAX_BYTES AGC_TERM_MAX_BYTES

typedef enum { FRAME_LIST, FRAME_MAP, FRAME_STRUCT, FRAME_ENUM } frame_kind;

/* An open container. next counts the children taken, n the children it has: a Map and a struct have a key (a field
   name) and a value for each entry, so twice their size, and the entry of the last child taken is (next - 1) / 2. */
typedef struct {
  frame_kind kind;
  agc_value value;
  const agc_value *keys;
  size_t next, n;
} term_frame;

typedef struct {
  uint8_t *data;
  size_t len, cap;
} term_buffer;

static void reserve(term_buffer *b, size_t n) {
  if (b->len + n <= b->cap) return;
  size_t cap = b->cap ? b->cap : 64;
  while (cap < b->len + n) cap = cap * 2;
  uint8_t *grown = agc_alloc_atomic(cap);
  if (b->len) memcpy(grown, b->data, b->len);
  b->data = grown;
  b->cap = cap;
}

static bool put(term_buffer *b, const void *data, size_t n) {
  if (n > TERM_MAX_BYTES - b->len) return false;
  reserve(b, n);
  if (n) memcpy(b->data + b->len, data, n);
  b->len += n;
  return true;
}

/* The head of a data item: the major type and its argument, in the fewest bytes (RFC 8949 section 3). */
static bool put_head(term_buffer *b, unsigned major, uint64_t arg) {
  uint8_t head[9];
  size_t n;
  head[0] = (uint8_t)(major << 5);
  if (arg < 24) {
    head[0] |= (uint8_t)arg;
    n = 1;
  } else {
    unsigned size = arg <= UINT8_MAX ? 0 : arg <= UINT16_MAX ? 1 : arg <= UINT32_MAX ? 2 : 3;
    head[0] |= (uint8_t)(24 + size);
    n = (size_t)1 << size;
    for (size_t k = 0; k < n; k++) head[1 + k] = (uint8_t)(arg >> (8 * (n - 1 - k)));
    n += 1;
  }
  return put(b, head, n);
}

static bool put_float(term_buffer *b, double x, bool wide) {
  uint8_t out[9];
  if (wide) {
    uint64_t bits;
    if (isnan(x)) {
      bits = UINT64_C(0x7FF8000000000000);
    } else {
      memcpy(&bits, &x, sizeof bits);
    }
    out[0] = 0xFB;
    for (size_t k = 0; k < 8; k++) out[1 + k] = (uint8_t)(bits >> (8 * (7 - k)));
    return put(b, out, 9);
  }
  uint32_t bits;
  float f = (float)x;
  if (isnan(f)) {
    bits = UINT32_C(0x7FC00000);
  } else {
    memcpy(&bits, &f, sizeof bits);
  }
  out[0] = 0xFA;
  for (size_t k = 0; k < 4; k++) out[1 + k] = (uint8_t)(bits >> (8 * (3 - k)));
  return put(b, out, 5);
}

/* The path keeps at most this many bytes of a String key, so a huge key does not become a huge message. */
#define PATH_KEY_BYTES 64

void agc_term_path_key(agc_json_buffer *b, const uint8_t *key, size_t bytes) {
  size_t n = bytes;
  if (n > PATH_KEY_BYTES) {
    n = PATH_KEY_BYTES;
    while (n > 0 && (key[n] & 0xC0) == 0x80) n--;
  }
  agc_json_put(b, "\"", 1);
  for (size_t k = 0; k < n; k++) {
    char escape[8];
    if (key[k] == '"' || key[k] == '\\') {
      escape[0] = '\\';
      escape[1] = (char)key[k];
      agc_json_put(b, escape, 2);
    } else if (key[k] < 0x20) {
      agc_json_put(b, escape, (size_t)snprintf(escape, sizeof escape, "\\u%04x", key[k]));
    } else {
      agc_json_put(b, (const char *)&key[k], 1);
    }
  }
  if (n < bytes) agc_json_put(b, "...", 3);
  agc_json_put(b, "\"", 1);
}

/* The error "path: reason" for the value being written, which is the last child that each open frame took: the keys,
   indexes and field names of the frames (a payload of an enum is `values[i]`, as in the JSON form). The root is $. The
   bytes written so far and the text of the error are charged. */
static agc_value limit_error(agc_vm *vm, const term_buffer *written, const term_frame *stack, size_t depth,
                             const char *reason) {
  agc_charge_bytes(vm, written->len);
  agc_json_buffer b = {agc_alloc_atomic(64), 0, 64};
  for (size_t i = 0; i < depth; i++) {
    const term_frame *f = &stack[i];
    size_t child = f->next - 1;
    size_t entry = child / 2;
    char text[48];
    if (f->kind == FRAME_LIST) {
      agc_json_put(&b, text, (size_t)snprintf(text, sizeof text, "[%zu]", child));
    } else if (f->kind == FRAME_MAP) {
      agc_value key = f->keys[entry];
      if (agc_is(key, AGC_T_INT)) {
        agc_json_put(&b, text, (size_t)snprintf(text, sizeof text, "[%" PRId64 "]", key.as.i));
      } else if (agc_is(key, AGC_T_STRING)) {
        const agc_string *name = agc_as_string(vm, key);
        agc_json_put(&b, "[", 1);
        agc_term_path_key(&b, (const uint8_t *)name->data, name->bytes);
        agc_json_put(&b, "]", 1);
      } else {
        agc_json_put(&b, "[?]", 3);
      }
    } else if (f->kind == FRAME_STRUCT) {
      const agc_string *name = agc_struct_def_of(vm, agc_as_struct(vm, f->value))->fields[entry];
      if (b.len) agc_json_put(&b, ".", 1);
      agc_json_put(&b, name->data, name->bytes);
    } else {
      agc_json_put(&b, text, (size_t)snprintf(text, sizeof text, "%svalues[%zu]", b.len ? "." : "", child));
    }
  }
  if (!b.len) agc_json_put(&b, "$", 1);
  agc_json_put(&b, ": ", 2);
  agc_json_put(&b, reason, strlen(reason));
  agc_charge_bytes(vm, b.len);
  agc_string *message = agc_make_string(b.data, b.len, agc_utf8_count((const uint8_t *)b.data, b.len));
  return agc_error_string(vm, AGC_KIND_TERM_ENCODE, message);
}

/* The next child of the frame: a list item, an enum payload, or the key or the value of a Map entry or struct field. */
static agc_value child_of(agc_vm *vm, const term_frame *f) {
  size_t k = f->next;
  switch (f->kind) {
    case FRAME_LIST: return agc_list_get(agc_as_list(vm, f->value), k);
    case FRAME_MAP: {
      if (k % 2 == 0) return f->keys[k / 2];
      agc_value item;
      if (!agc_map_get(vm, agc_as_map(vm, f->value), f->keys[k / 2], &item))
        agc_fail(vm, "RUNTIME-INTERNAL", "invalid map", 0);
      return item;
    }
    case FRAME_STRUCT: return agc_as_struct(vm, f->value)->fields[k / 2];
    default: return agc_as_enum(vm, f->value)->payload[k];
  }
}

/* Term.encode(value): ok(bytes), or an error of kind term.encode when the value is nested deeper than TERM_MAX_DEPTH
   levels (an enum is one level), holds more than TERM_MAX_ITEMS values (a Map key is one) or writes more than
   TERM_MAX_BYTES bytes. The first value past a limit names the path; nothing is written after it. */
static agc_value builtin_encode(agc_vm *vm, agc_value *args, uint32_t span) {
  term_buffer b = {agc_alloc_atomic(64), 0, 64};
  size_t capacity = 16, depth = 0, items = 0;
  term_frame *stack = agc_alloc(agc_size_mul(capacity, sizeof(term_frame)));
  agc_value item = args[0];
  for (;;) {
    bool fits = true, opened = false;
    if (++items > TERM_MAX_ITEMS) return limit_error(vm, &b, stack, depth, "more than 4000000 values");
    agc_unwrap_optional(vm, &item);
    if (agc_is(item, AGC_T_NIL)) {
      fits = put_head(&b, 7, 22);
    } else if (agc_is(item, AGC_T_BOOL)) {
      fits = put_head(&b, 7, agc_as_bool(vm, item) ? 21 : 20);
    } else if (agc_is(item, AGC_T_INT)) {
      int64_t n = agc_as_int(vm, item);
      fits = n >= 0 ? put_head(&b, 0, (uint64_t)n) : put_head(&b, 1, ~(uint64_t)n);
    } else if (agc_is(item, AGC_T_UINT64)) {
      fits = put_head(&b, 0, agc_as_uint64(vm, item));
    } else if (agc_is(item, AGC_T_FLOAT)) {
      fits = put_float(&b, agc_as_float(vm, item), true);
    } else if (agc_is(item, AGC_T_FLOAT32)) {
      fits = put_float(&b, agc_as_float32(vm, item), false);
    } else if (agc_is(item, AGC_T_STRING)) {
      const agc_string *s = agc_as_string(vm, item);
      fits = put_head(&b, 3, s->bytes) && put(&b, s->data, s->bytes);
    } else if (agc_is(item, AGC_T_BYTES)) {
      size_t n;
      const uint8_t *data = agc_bytes_data(vm, item, &n);
      fits = put_head(&b, 2, n) && put(&b, data, n);
    } else if (agc_is(item, AGC_T_LIST) || agc_is(item, AGC_T_MAP) || agc_is(item, AGC_T_STRUCT) ||
               agc_is(item, AGC_T_ENUM)) {
      if (depth + 1 > TERM_MAX_DEPTH) return limit_error(vm, &b, stack, depth, "nested deeper than 10000 levels");
      stack = agc_json_grow(stack, &capacity, depth, sizeof(term_frame));
      term_frame *f = &stack[depth];
      f->value = item;
      f->keys = NULL;
      f->next = 0;
      if (agc_is(item, AGC_T_LIST)) {
        f->kind = FRAME_LIST;
        f->n = agc_list_len(agc_as_list(vm, item));
        fits = put_head(&b, 4, f->n);
      } else if (agc_is(item, AGC_T_MAP)) {
        const agc_map *m = agc_as_map(vm, item);
        f->kind = FRAME_MAP;
        f->n = agc_size_mul(m->size, 2);
        fits = put_head(&b, 5, m->size);
        f->keys = fits && m->size ? agc_map_keys(vm, m, span) : NULL;
      } else if (agc_is(item, AGC_T_STRUCT)) {
        const agc_struct_def *def = agc_struct_def_of(vm, agc_as_struct(vm, item));
        f->kind = FRAME_STRUCT;
        f->n = agc_size_mul(def->count, 2);
        fits = put_head(&b, 5, def->count);
      } else {
        const agc_enum *e = agc_as_enum(vm, item);
        const agc_string *tag = vm->rt->program->variants[e->variant].name;
        f->kind = FRAME_ENUM;
        f->n = e->n;
        fits = put_head(&b, 4, 2) && put_head(&b, 3, tag->bytes) && put(&b, tag->data, tag->bytes) &&
               put_head(&b, 4, e->n);
      }
      opened = true;
    } else {
      agc_fail(vm, "RUNTIME-INTERNAL", "a value that Term.encode cannot write", span);
    }
    /* The path of a value that does not fit is the frames that hold it, not its own, which is not open yet. */
    if (!fits) return limit_error(vm, &b, stack, depth, "larger than 67108864 bytes");
    if (opened) depth++;
    for (;;) {
      if (depth == 0) {
        agc_charge_bytes(vm, b.len);
        return agc_result_value(true, agc_bytes_value(agc_make_bytes(b.data, b.len)));
      }
      term_frame *top = &stack[depth - 1];
      if (top->next < top->n) {
        if (top->kind == FRAME_STRUCT && top->next % 2 == 0) {
          const agc_string *name = agc_struct_def_of(vm, agc_as_struct(vm, top->value))->fields[top->next / 2];
          top->next++;
          if (!(put_head(&b, 3, name->bytes) && put(&b, name->data, name->bytes)))
            return limit_error(vm, &b, stack, depth, "larger than 67108864 bytes");
        }
        item = child_of(vm, top);
        top->next++;
        break;
      }
      depth--;
    }
  }
}

/* Term.decode(data, Type): the type is the struct or enum that the checker named, found as JSON.decode finds its own. */
static agc_value builtin_decode(agc_vm *vm, agc_value *args, uint32_t span) {
  uint32_t kind;
  uint32_t type = agc_decode_target(vm, args[1], span + 2, &kind);
  size_t len;
  const uint8_t *data = agc_bytes_data(vm, args[0], &len);
  return agc_term_decode(vm, data, len, kind, type);
}

const agc_builtin agc_term_builtins[] = {
  {"Term.encode", 1, builtin_encode, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"Term.decode", 2, builtin_decode, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
};

const size_t agc_term_builtin_count = sizeof agc_term_builtins / sizeof agc_term_builtins[0];
