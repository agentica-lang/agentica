#include "agc.h"

#include <string.h>

#define NO_STRUCT UINT32_MAX

typedef struct {
  const agc_json *node;
  const agc_list *items;
  const agc_struct_def *def;
  uint32_t kind, arg;
  size_t next, n;
  agc_list *list;
  agc_struct *record;
  agc_map *map;
} decode_frame;

typedef struct {
  char *data;
  size_t len, cap;
} text_buffer;

static void append(text_buffer *b, const char *text, size_t n) {
  size_t need = agc_size_add(b->len, n);
  if (need > b->cap) {
    size_t cap = b->cap;
    while (cap < need) cap = agc_size_mul(cap, 2);
    char *bigger = agc_alloc_atomic(cap);
    memcpy(bigger, b->data, b->len);
    b->data = bigger;
    b->cap = cap;
  }
  memcpy(b->data + b->len, text, n);
  b->len = need;
}

static agc_string *buffer_string(const text_buffer *b) {
  return agc_make_string(b->data, b->len, agc_utf8_count((const uint8_t *)b->data, b->len));
}

static agc_value decode_error(const decode_frame *stack, size_t depth, const char *expected) {
  text_buffer b;
  b.cap = 64;
  b.len = 0;
  b.data = agc_alloc_atomic(b.cap);
  for (size_t i = 0; i < depth; i++) {
    const decode_frame *f = &stack[i];
    if (f->kind == AGC_TYPE_STRUCT) {
      const agc_string *key = f->def->fields[f->next];
      if (b.len) append(&b, ".", 1);
      append(&b, key->data, key->bytes);
    } else if (f->kind == AGC_TYPE_LIST) {
      char index[32];
      int n = snprintf(index, sizeof index, "[%zu]", f->next);
      append(&b, index, (size_t)n);
    } else {
      const agc_string *key = agc_around("[", f->node->members[f->next].key, "]");
      append(&b, key->data, key->bytes);
    }
  }
  if (!b.len) append(&b, "$", 1);
  append(&b, ": expected ", 11);
  append(&b, expected, strlen(expected));
  return agc_result_value(false, agc_string_value(buffer_string(&b)));
}

static decode_frame *grow_frames(decode_frame *stack, size_t *capacity, size_t depth) {
  if (depth < *capacity) return stack;
  size_t bigger = agc_size_mul(*capacity, 2);
  decode_frame *grown = agc_alloc(agc_size_mul(bigger, sizeof(decode_frame)));
  memcpy(grown, stack, depth * sizeof(decode_frame));
  *capacity = bigger;
  return grown;
}

static bool next_child(const agc_program *p, const decode_frame *f, agc_value *item, const agc_type **type) {
  uint32_t index = f->arg;
  if (f->kind == AGC_TYPE_LIST) {
    *item = f->items->items[f->next];
  } else if (f->kind == AGC_TYPE_MAP) {
    *item = f->node->members[f->next].value;
  } else {
    const agc_json_member *member = agc_json_find(f->node, f->def->fields[f->next]);
    if (!member) return false;
    *item = member->value;
    index = f->def->field_types[f->next];
  }
  *type = &p->types[index];
  return true;
}

static void store_child(agc_vm *vm, decode_frame *f, agc_value v) {
  if (f->kind == AGC_TYPE_LIST)
    f->list->items[f->next] = v;
  else if (f->kind == AGC_TYPE_MAP)
    f->map = agc_map_put(vm, f->map, agc_string_value(f->node->members[f->next].key), v);
  else
    f->record->fields[f->next] = v;
}

static agc_value frame_value(const decode_frame *f) {
  if (f->kind == AGC_TYPE_LIST) return agc_list_value(f->list);
  if (f->kind == AGC_TYPE_MAP) return agc_map_value(f->map);
  return agc_struct_value(f->record);
}

static void open_frame(agc_vm *vm, decode_frame *f, const agc_json *node, uint32_t kind, uint32_t arg) {
  f->node = node;
  f->kind = kind;
  f->arg = arg;
  f->next = 0;
  f->items = NULL;
  f->def = NULL;
  f->list = NULL;
  f->record = NULL;
  f->map = NULL;
  if (kind == AGC_TYPE_LIST) {
    f->items = agc_as_list(vm, node->scalar);
    f->n = f->items->len;
    f->list = agc_new_list(f->n);
  } else if (kind == AGC_TYPE_MAP) {
    f->n = node->count;
    f->map = agc_new_map();
  } else {
    f->def = &vm->program->structs[arg];
    f->n = f->def->count;
    f->record = agc_new_struct(arg, f->def->count);
  }
}

agc_value agc_json_decode(agc_vm *vm, agc_value root, uint32_t type) {
  const agc_program *p = vm->program;
  size_t depth = 0, capacity = 16;
  decode_frame *stack = agc_alloc(agc_size_mul(capacity, sizeof(decode_frame)));
  agc_value item = root;
  uint32_t kind = AGC_TYPE_STRUCT, arg = type;
  for (;;) {
    const agc_json *j = agc_as_json(vm, item);
    agc_value v;
    double x;
    if (kind == AGC_TYPE_INT) {
      if (j->kind != AGC_JSON_INT) return decode_error(stack, depth, "signed 64-bit Int");
      v = j->scalar;
    } else if (kind == AGC_TYPE_FLOAT) {
      if (!agc_json_to_float(vm, j, &x)) return decode_error(stack, depth, "finite Float");
      v = agc_float(x);
    } else if (kind == AGC_TYPE_BOOL) {
      if (j->kind != AGC_JSON_BOOL) return decode_error(stack, depth, "Bool");
      v = j->scalar;
    } else if (kind == AGC_TYPE_STRING) {
      if (j->kind != AGC_JSON_STRING) return decode_error(stack, depth, "String");
      v = j->scalar;
    } else {
      bool list = kind == AGC_TYPE_LIST;
      if (j->kind != (list ? AGC_JSON_ARRAY : AGC_JSON_OBJECT))
        return decode_error(stack, depth, list ? "array" : "object");
      stack = grow_frames(stack, &capacity, depth);
      decode_frame *f = &stack[depth];
      open_frame(vm, f, j, kind, arg);
      v = frame_value(f);
      if (f->n) {
        depth++;
        const agc_type *t;
        if (!next_child(p, f, &item, &t)) return decode_error(stack, depth, "required field");
        kind = t->kind;
        arg = t->arg;
        continue;
      }
    }
    for (;;) {
      if (!depth) return agc_result_value(true, v);
      decode_frame *top = &stack[depth - 1];
      store_child(vm, top, v);
      if (++top->next < top->n) {
        const agc_type *t;
        if (!next_child(p, top, &item, &t)) return decode_error(stack, depth, "required field");
        kind = t->kind;
        arg = t->arg;
        break;
      }
      v = frame_value(top);
      depth--;
    }
  }
}

static agc_value json_text(const char *text) {
  size_t n = strlen(text);
  return agc_json_leaf(AGC_JSON_STRING, agc_string_value(agc_make_string(text, n, n)));
}

static agc_string *ascii(const char *text) {
  size_t n = strlen(text);
  return agc_make_string(text, n, n);
}

static agc_value object_of(size_t n, const char *const *keys, const agc_value *values) {
  agc_json_member *members = agc_alloc(agc_size_mul(n, sizeof(agc_json_member)));
  for (size_t i = 0; i < n; i++) {
    members[i].key = ascii(keys[i]);
    members[i].value = values[i];
  }
  return agc_json_object(members, n);
}

static agc_value typed(const char *name) {
  static const char *const keys[] = {"type"};
  agc_value values[] = {json_text(name)};
  return object_of(1, keys, values);
}

static agc_value reference(const agc_string *name) {
  text_buffer b;
  b.cap = agc_size_add(name->bytes, 16);
  b.len = 0;
  b.data = agc_alloc_atomic(b.cap);
  append(&b, "#/$defs/", 8);
  size_t start = 0;
  for (size_t i = 0; i < name->bytes; i++) {
    if (name->data[i] != '~' && name->data[i] != '/') continue;
    append(&b, name->data + start, i - start);
    append(&b, name->data[i] == '~' ? "~0" : "~1", 2);
    start = i + 1;
  }
  append(&b, name->data + start, name->bytes - start);
  static const char *const keys[] = {"$ref"};
  agc_value values[] = {agc_json_leaf(AGC_JSON_STRING, agc_string_value(buffer_string(&b)))};
  return object_of(1, keys, values);
}

static agc_value type_schema(const agc_program *p, const agc_type *t, const agc_value *schemas) {
  if (t->kind == AGC_TYPE_INT) {
    static const char *const keys[] = {"type", "minimum", "maximum"};
    agc_value values[] = {json_text("integer"), agc_json_leaf(AGC_JSON_INT, agc_int(INT64_MIN)),
                          agc_json_leaf(AGC_JSON_INT, agc_int(INT64_MAX))};
    return object_of(3, keys, values);
  }
  if (t->kind == AGC_TYPE_FLOAT) return typed("number");
  if (t->kind == AGC_TYPE_BOOL) return typed("boolean");
  if (t->kind == AGC_TYPE_STRING) return typed("string");
  if (t->kind == AGC_TYPE_STRUCT) return reference(p->structs[t->arg].json_name);
  if (t->kind == AGC_TYPE_LIST) {
    static const char *const keys[] = {"type", "items"};
    agc_value values[] = {json_text("array"), schemas[t->arg]};
    return object_of(2, keys, values);
  }
  static const char *const keys[] = {"type", "additionalProperties"};
  agc_value values[] = {json_text("object"), schemas[t->arg]};
  return object_of(2, keys, values);
}

static agc_value struct_schema(const agc_struct_def *def, const agc_value *schemas, agc_value defs) {
  agc_json_member *properties = agc_alloc(agc_size_mul(def->count, sizeof(agc_json_member)));
  agc_list *required = agc_new_list(def->count);
  for (uint32_t k = 0; k < def->count; k++) {
    properties[k].key = def->fields[k];
    properties[k].value = schemas[def->field_types[k]];
    required->items[k] = agc_json_leaf(AGC_JSON_STRING, agc_string_value(def->fields[k]));
  }
  static const char *const keys[] = {"type", "properties", "required", "$defs"};
  agc_value values[] = {json_text("object"), agc_json_object(properties, def->count), agc_json_array(required), defs};
  return object_of(agc_is(defs, AGC_T_VOID) ? 3 : 4, keys, values);
}

agc_value agc_json_schema(agc_vm *vm, uint32_t type) {
  const agc_program *p = vm->program;
  agc_value *schemas = agc_alloc(agc_size_mul(p->type_count, sizeof(agc_value)));
  uint32_t *base = agc_alloc_atomic(agc_size_mul(p->type_count, sizeof(uint32_t)));
  for (uint32_t i = 0; i < p->type_count; i++) {
    const agc_type *t = &p->types[i];
    base[i] = t->kind == AGC_TYPE_STRUCT ? t->arg : t->kind >= AGC_TYPE_LIST ? base[t->arg] : NO_STRUCT;
    schemas[i] = type_schema(p, t, schemas);
  }
  bool *seen = agc_alloc_atomic(p->struct_count);
  memset(seen, 0, p->struct_count);
  uint32_t *queue = agc_alloc_atomic(agc_size_mul(p->struct_count, sizeof(uint32_t)));
  size_t count = 0;
  uint32_t current = type;
  for (size_t head = 0;; current = queue[head++]) {
    const agc_struct_def *def = &p->structs[current];
    for (uint32_t k = 0; k < def->count; k++) {
      uint32_t s = base[def->field_types[k]];
      if (s == NO_STRUCT || seen[s]) continue;
      seen[s] = true;
      queue[count++] = s;
    }
    if (head == count) break;
  }
  agc_value defs = agc_void();
  if (count) {
    agc_json_member *members = agc_alloc(agc_size_mul(count, sizeof(agc_json_member)));
    for (size_t i = 0; i < count; i++) {
      members[i].key = p->structs[queue[i]].json_name;
      members[i].value = struct_schema(&p->structs[queue[i]], schemas, agc_void());
    }
    defs = agc_json_object(members, count);
  }
  return struct_schema(&p->structs[type], schemas, defs);
}
