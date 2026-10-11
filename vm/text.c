#include "agc.h"

#include <inttypes.h>
#include <string.h>

bool agc_in_ranges(const uint32_t (*ranges)[2], size_t count, uint32_t cp) {
  size_t lo = 0, hi = count;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    if (cp < ranges[mid][0])
      hi = mid;
    else if (cp > ranges[mid][1])
      lo = mid + 1;
    else
      return true;
  }
  return false;
}

bool agc_write_raw(uint32_t cp) { return agc_in_ranges(agc_write_raw_ranges, agc_write_raw_count, cp); }

static uint32_t decode(const uint8_t *s, size_t width) {
  static const uint8_t lead_mask[] = {0, 0x7F, 0x1F, 0x0F, 0x07};
  uint32_t cp = s[0] & lead_mask[width];
  for (size_t k = 1; k < width; k++) cp = (cp << 6) | (s[k] & 0x3Fu);
  return cp;
}

static const char *short_escape(uint32_t cp) {
  switch (cp) {
    case 7: return "\\a";
    case 8: return "\\b";
    case 9: return "\\t";
    case 10: return "\\n";
    case 11: return "\\v";
    case 12: return "\\f";
    case 13: return "\\r";
    case 27: return "\\e";
    case '"': return "\\\"";
    case '\\': return "\\\\";
    default: return NULL;
  }
}

size_t agc_write_form(const agc_string *s, char *out, size_t *chars) {
  const uint8_t *data = (const uint8_t *)s->data;
  size_t n = 1, count = 2, at = 0;
  bool join = false;
  if (out) out[0] = '"';
  while (at < s->bytes) {
    uint8_t c = data[at];
    if (c >= 0x20 && c < 0x7F && c != '"' && c != '\\') {
      if (out) out[n] = (char)c;
      n++;
      count++;
      at++;
      join = c != ' ';
      continue;
    }
    size_t width = agc_utf8_width(c);
    if (width > s->bytes - at) width = s->bytes - at;
    uint32_t cp = decode(data + at, width);
    const char *escape = short_escape(cp);
    bool raw = !escape && (agc_write_raw(cp) || (join && agc_in_ranges(agc_write_joiner_ranges, agc_write_joiner_count, cp)));
    join = raw && !agc_in_ranges(agc_write_blank_ranges, agc_write_blank_count, cp);
    char hex[12];
    const char *piece = (const char *)data + at;
    size_t len = width;
    if (raw) {
      count++;
    } else {
      if (!escape) {
        snprintf(hex, sizeof hex, cp < 0x10000 ? "\\u%04" PRIX32 : "\\U%08" PRIX32, cp);
        escape = hex;
      }
      piece = escape;
      len = strlen(escape);
      count += len;
    }
    if (out) memcpy(out + n, piece, len);
    n = agc_size_add(n, len);
    at += width;
  }
  if (out) out[n] = '"';
  *chars = count;
  return agc_size_add(n, 1);
}

agc_string *agc_concat(const agc_string *a, const agc_string *b) {
  agc_string *s = agc_new_string(agc_size_add(a->bytes, b->bytes), agc_size_add(a->chars, b->chars));
  if (a->bytes) memcpy(s->data, a->data, a->bytes);
  if (b->bytes) memcpy(s->data + a->bytes, b->data, b->bytes);
  return s;
}

size_t agc_scalar_text(agc_vm *vm, agc_value v, char text[AGC_SCALAR_TEXT]) {
  if (agc_is(v, AGC_T_NIL)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "nil");
  if (agc_is(v, AGC_T_BOOL)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "%s", agc_as_bool(vm, v) ? "true" : "false");
  if (agc_is(v, AGC_T_FLOAT)) return agc_float_text(agc_as_float(vm, v), text);
  if (agc_is(v, AGC_T_FN)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<Fn>");
  if (agc_is(v, AGC_T_RANGE)) {
    const agc_range *r = agc_as_range(vm, v);
    return (size_t)snprintf(text, AGC_SCALAR_TEXT, "%" PRId64 "%s%" PRId64, r->start, r->exclusive ? "..." : "..",
                            r->end);
  }
  return (size_t)snprintf(text, AGC_SCALAR_TEXT, "%" PRId64, agc_as_int(vm, v));
}

typedef struct {
  agc_string *s;
  size_t cap;
} builder;

static char *reserve(builder *b, size_t extra) {
  size_t need = agc_size_add(b->s->bytes, extra);
  if (need > b->cap) {
    size_t cap = b->cap;
    while (cap < need) cap = agc_size_mul(cap, 2);
    agc_string *bigger = agc_new_string(cap, b->s->chars);
    bigger->bytes = b->s->bytes;
    if (b->s->bytes) memcpy(bigger->data, b->s->data, b->s->bytes);
    b->s = bigger;
    b->cap = cap;
  }
  return b->s->data + b->s->bytes;
}

static void append(builder *b, const char *text, size_t len) {
  memcpy(reserve(b, len), text, len);
  b->s->bytes += len;
  b->s->chars += len;
}

static void append_item(agc_vm *vm, builder *b, agc_value v) {
  if (agc_is(v, AGC_T_STRING)) {
    const agc_string *s = agc_as_string(vm, v);
    size_t chars;
    size_t len = agc_write_form(s, NULL, &chars);
    agc_write_form(s, reserve(b, len), &chars);
    b->s->bytes += len;
    b->s->chars += chars;
  } else {
    char text[AGC_SCALAR_TEXT];
    append(b, text, agc_scalar_text(vm, v, text));
  }
}

static void append_string(builder *b, const agc_string *s) {
  if (s->bytes) memcpy(reserve(b, s->bytes), s->data, s->bytes);
  b->s->bytes += s->bytes;
  b->s->chars += s->chars;
}

static bool compound(agc_value v) {
  return agc_is(v, AGC_T_LIST) || agc_is(v, AGC_T_MAP) || agc_is(v, AGC_T_STRUCT) || agc_is(v, AGC_T_ENUM) || agc_is(v, AGC_T_RESULT);
}

typedef struct {
  agc_value value;
  size_t next;
  agc_value *keys;
} debug_frame;

static const agc_struct_def *struct_def(agc_vm *vm, const agc_struct *st) {
  const agc_program *p = vm->program;
  if (!p || st->type >= p->struct_count || p->structs[st->type].count != st->n)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: unknown struct type", 0);
  return &p->structs[st->type];
}

static const agc_variant_def *variant_def(agc_vm *vm, const agc_enum *e) {
  const agc_program *p = vm->program;
  if (!p || e->variant >= p->variant_count || p->variants[e->variant].arity != e->n)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: unknown enum variant", 0);
  return &p->variants[e->variant];
}

static size_t item_count(agc_vm *vm, agc_value v) {
  if (agc_is(v, AGC_T_LIST)) return agc_as_list(vm, v)->len;
  if (agc_is(v, AGC_T_MAP)) return agc_as_map(vm, v)->size;
  if (agc_is(v, AGC_T_STRUCT)) return agc_as_struct(vm, v)->n;
  if (agc_is(v, AGC_T_RESULT)) {
    const agc_result *r = agc_as_result(vm, v);
    return r->ok && agc_is(r->value, AGC_T_VOID) ? 0 : 1;
  }
  return agc_as_enum(vm, v)->n;
}

static agc_value item_at(agc_vm *vm, agc_value v, size_t k) {
  if (agc_is(v, AGC_T_LIST)) return agc_as_list(vm, v)->items[k];
  if (agc_is(v, AGC_T_STRUCT)) return agc_as_struct(vm, v)->fields[k];
  if (agc_is(v, AGC_T_RESULT)) return agc_as_result(vm, v)->value;
  return agc_as_enum(vm, v)->payload[k];
}

static bool open_value(agc_vm *vm, builder *b, agc_value v) {
  if (agc_is(v, AGC_T_LIST)) {
    append(b, "[", 1);
    return true;
  }
  if (agc_is(v, AGC_T_MAP)) {
    append(b, "{", 1);
    return true;
  }
  if (agc_is(v, AGC_T_STRUCT)) {
    append_string(b, struct_def(vm, agc_as_struct(vm, v))->name);
    append(b, "(", 1);
    return true;
  }
  if (agc_is(v, AGC_T_RESULT)) {
    if (agc_as_result(vm, v)->ok)
      append(b, "ok(", 3);
    else
      append(b, "error(", 6);
    return true;
  }
  const agc_enum *e = agc_as_enum(vm, v);
  const agc_variant_def *variant = variant_def(vm, e);
  append_string(b, vm->program->enums[variant->owner].name);
  append(b, ".", 1);
  append_string(b, variant->name);
  if (e->n == 0) return false;
  append(b, "(", 1);
  return true;
}

static agc_string *compound_debug(agc_vm *vm, agc_value root) {
  builder b;
  b.cap = 64;
  b.s = agc_new_string(b.cap, 0);
  b.s->bytes = 0;
  size_t depth = 0, capacity = 16;
  debug_frame *stack = agc_alloc(agc_size_mul(capacity, sizeof(debug_frame)));
  agc_value item = root;
  for (;;) {
    if (!compound(item)) {
      append_item(vm, &b, item);
    } else if (open_value(vm, &b, item)) {
      if (depth == capacity) {
        size_t bigger = agc_size_mul(capacity, 2);
        debug_frame *grown = agc_alloc(agc_size_mul(bigger, sizeof(debug_frame)));
        memcpy(grown, stack, depth * sizeof(debug_frame));
        stack = grown;
        capacity = bigger;
      }
      stack[depth].value = item;
      stack[depth].next = 0;
      stack[depth].keys = agc_is(item, AGC_T_MAP) ? agc_map_keys(agc_as_map(vm, item)) : NULL;
      depth++;
    }
    for (;;) {
      if (!depth) return b.s;
      debug_frame *top = &stack[depth - 1];
      if (top->next < item_count(vm, top->value)) break;
      append(&b, agc_is(top->value, AGC_T_LIST) ? "]" : agc_is(top->value, AGC_T_MAP) ? "}" : ")", 1);
      depth--;
    }
    debug_frame *top = &stack[depth - 1];
    if (top->next) append(&b, ", ", 2);
    if (agc_is(top->value, AGC_T_STRUCT)) {
      append_string(&b, struct_def(vm, agc_as_struct(vm, top->value))->fields[top->next]);
      append(&b, ": ", 2);
    }
    if (agc_is(top->value, AGC_T_MAP)) {
      agc_value key = top->keys[top->next++];
      append_item(vm, &b, key);
      append(&b, ": ", 2);
      if (!agc_map_get(vm, agc_as_map(vm, top->value), key, &item))
        agc_fail(vm, "RUNTIME-INTERNAL", "invalid map", 0);
      continue;
    }
    item = item_at(vm, top->value, top->next++);
  }
}

agc_string *agc_text(agc_vm *vm, agc_value v) {
  if (agc_is(v, AGC_T_STRING)) return agc_as_string(vm, v);
  return agc_debug(vm, v);
}

agc_string *agc_debug(agc_vm *vm, agc_value v) {
  if (compound(v)) return compound_debug(vm, v);
  if (!agc_is(v, AGC_T_STRING)) {
    char text[AGC_SCALAR_TEXT];
    size_t n = agc_scalar_text(vm, v, text);
    return agc_make_string(text, n, n);
  }
  const agc_string *s = agc_as_string(vm, v);
  size_t chars;
  size_t bytes = agc_write_form(s, NULL, &chars);
  agc_string *result = agc_new_string(bytes, chars);
  agc_write_form(s, result->data, &chars);
  return result;
}
