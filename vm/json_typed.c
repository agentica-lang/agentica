/*
 * Typed JSON: JSON.decode into a struct type and JSON.schema. Both run over
 * one explicit frame stack and the program's type table. Service layer.
 * Design: docs/vm/02-reference-behavior.md §2.7.
 */
#include "services.h"

#include <string.h>

/* One open container of the decode: a List, a Map, a struct, an enum variant with payloads, or a JSON.Field.Value or an
   Optional some whose T is not a scalar (n is 1 and value holds the decoded T until the frame closes). An enum frame
   walks the "values" array of the variant: items are its items, payload_types their types and tagged the enum being built. */
typedef struct {
  const agc_json *node;
  const agc_list *items;
  const agc_struct_def *def;
  const uint32_t *payload_types;
  uint32_t kind, arg;
  size_t next, n;
  agc_list_builder list;
  agc_struct *record;
  agc_enum *tagged;
  agc_map *map;
  agc_value value;
} decode_frame;

/* Not a kind of the type table: a JSON.Field or Optional struct field whose key is missing, decoded as JSON.Field.Absent
   or none (arg is the kind of the field's type). */
#define ABSENT_FIELD UINT32_MAX

static agc_string *buffer_string(const agc_json_buffer *b) {
  return agc_make_string(b->data, b->len, agc_utf8_count((const uint8_t *)b->data, b->len));
}

/* The error Result "path: expected what". The path is the keys and indexes of the open frames; field, when not NULL,
   is a key of the object being decoded (the "tag" or "values" of an enum) that comes last. */
static agc_value decode_error_in(agc_vm *vm, const decode_frame *stack, size_t depth, const char *field,
                                 const char *expected) {
  agc_json_buffer b;
  b.cap = 64;
  b.len = 0;
  b.data = agc_alloc_atomic(b.cap);
  for (size_t i = 0; i < depth; i++) {
    const decode_frame *f = &stack[i];
    if (f->kind == AGC_TYPE_STRUCT) {
      const agc_string *key = f->def->fields[f->next];
      if (b.len) agc_json_put(&b, ".", 1);
      agc_json_put(&b, key->data, key->bytes);
    } else if (f->kind == AGC_TYPE_JSON_FIELD || f->kind == AGC_TYPE_OPTIONAL) {
      continue; /* JSON.Field.Value and some add no step to the path */
    } else if (f->kind == AGC_TYPE_ENUM) {
      char index[48];
      int n = snprintf(index, sizeof index, "%svalues[%zu]", b.len ? "." : "", f->next);
      agc_json_put(&b, index, (size_t)n);
    } else if (f->kind == AGC_TYPE_LIST) {
      char index[32];
      int n = snprintf(index, sizeof index, "[%zu]", f->next);
      agc_json_put(&b, index, (size_t)n);
    } else {
      const agc_string *key = agc_around("[", f->node->members[f->next].key, "]");
      agc_json_put(&b, key->data, key->bytes);
    }
  }
  if (field) {
    if (b.len) agc_json_put(&b, ".", 1);
    agc_json_put(&b, field, strlen(field));
  }
  if (!b.len) agc_json_put(&b, "$", 1);
  agc_json_put(&b, ": expected ", 11);
  agc_json_put(&b, expected, strlen(expected));
  return agc_error_string(vm, AGC_KIND_JSON_DECODE, buffer_string(&b));
}

static agc_value decode_error(agc_vm *vm, const decode_frame *stack, size_t depth, const char *expected) {
  return decode_error_in(vm, stack, depth, NULL, expected);
}

/* The next child of a List, Map or struct frame and the kind and operand of its type. A missing key is false, except
   for a JSON.Field or Optional field, whose kind is then ABSENT_FIELD. */
static bool next_child(const agc_program *p, const decode_frame *f, agc_value *item, uint32_t *kind, uint32_t *arg) {
  uint32_t index = f->arg;
  if (f->kind == AGC_TYPE_LIST) {
    *item = agc_list_get(f->items, f->next);
  } else if (f->kind == AGC_TYPE_ENUM) {
    *item = agc_list_get(f->items, f->next);
    index = f->payload_types[f->next];
  } else if (f->kind == AGC_TYPE_MAP) {
    *item = f->node->members[f->next].value;
  } else {
    index = f->def->field_types[f->next];
    const agc_json_member *member = agc_json_find(f->node, f->def->fields[f->next]);
    uint32_t field = p->types[index].kind;
    if (!member && field != AGC_TYPE_JSON_FIELD && field != AGC_TYPE_OPTIONAL) return false;
    if (!member) {
      *kind = ABSENT_FIELD;
      *arg = field;
      return true;
    }
    *item = member->value;
  }
  *kind = p->types[index].kind;
  *arg = p->types[index].arg;
  return true;
}

static agc_value json_field_value(const agc_program *p, uint32_t which, agc_value v) {
  uint32_t variant = p->json_field + which;
  if (which != AGC_JSON_FIELD_VALUE) return agc_enum_value(p->variants[variant].shared);
  agc_enum *e = agc_new_enum(variant, 1);
  e->payload[0] = v;
  return agc_enum_value(e);
}

static void store_child(agc_vm *vm, decode_frame *f, agc_value v) {
  if (f->kind == AGC_TYPE_LIST)
    agc_list_builder_push(&f->list, v);
  else if (f->kind == AGC_TYPE_MAP)
    f->map = agc_map_put(vm, f->map, agc_string_value(f->node->members[f->next].key), v);
  else if (f->kind == AGC_TYPE_JSON_FIELD || f->kind == AGC_TYPE_OPTIONAL)
    f->value = v;
  else if (f->kind == AGC_TYPE_ENUM)
    f->tagged->payload[f->next] = v;
  else
    f->record->fields[f->next] = v;
}

static agc_value frame_value(const agc_program *p, decode_frame *f) {
  if (f->kind == AGC_TYPE_LIST) return agc_list_value(agc_list_builder_finish(&f->list));
  if (f->kind == AGC_TYPE_MAP) return agc_map_value(f->map);
  if (f->kind == AGC_TYPE_JSON_FIELD) return json_field_value(p, AGC_JSON_FIELD_VALUE, f->value);
  if (f->kind == AGC_TYPE_OPTIONAL) return agc_optional_make(p, true, f->value);
  if (f->kind == AGC_TYPE_ENUM) return agc_enum_value(f->tagged);
  return agc_struct_value(f->record);
}

/* The top kind check that a JSON.Field or an Optional makes before it decodes its T
   (docs/vm/02-reference-behavior.md §2.7): the text of the error, with "or null", or NULL when the JSON value has the
   kind T starts with. A failure deeper inside T keeps its own path and text. An Optional T makes its own check. */
static const char *nullable_mismatch(const agc_json *j, uint32_t kind) {
  bool number = j->kind == AGC_JSON_INT || j->kind == AGC_JSON_BIG || j->kind == AGC_JSON_FLOAT;
  switch (kind) {
    case AGC_TYPE_OPTIONAL: return NULL;
    case AGC_TYPE_INT: return j->kind == AGC_JSON_INT ? NULL : "signed 64-bit Int or null";
    case AGC_TYPE_FLOAT: return number ? NULL : "finite Float or null";
    case AGC_TYPE_BOOL: return j->kind == AGC_JSON_BOOL ? NULL : "Bool or null";
    case AGC_TYPE_STRING: return j->kind == AGC_JSON_STRING ? NULL : "String or null";
    case AGC_TYPE_LIST: return j->kind == AGC_JSON_ARRAY ? NULL : "array or null";
    default: return j->kind == AGC_JSON_OBJECT ? NULL : "object or null";
  }
}

static void open_frame(agc_vm *vm, decode_frame *f, const agc_json *node, uint32_t kind, uint32_t arg) {
  f->node = node;
  f->kind = kind;
  f->arg = arg;
  f->next = 0;
  f->items = NULL;
  f->def = NULL;
  f->payload_types = NULL;
  f->list = (agc_list_builder){0};
  f->record = NULL;
  f->tagged = NULL;
  f->map = NULL;
  f->value = agc_void();
  if (kind == AGC_TYPE_ENUM) {
    f->n = 0; /* the caller fills in the variant (decode_variant) */
  } else if (kind == AGC_TYPE_JSON_FIELD || kind == AGC_TYPE_OPTIONAL) {
    f->n = 1;
  } else if (kind == AGC_TYPE_LIST) {
    f->items = agc_as_list(vm, node->scalar);
    f->n = agc_list_len(f->items);
    agc_list_builder_sized(&f->list, f->n);
  } else if (kind == AGC_TYPE_MAP) {
    f->n = node->count;
    f->map = agc_as_map(vm, vm->rt->empty_map);
  } else {
    f->def = &vm->rt->program->structs[arg];
    f->n = f->def->count;
    f->record = agc_new_struct(arg, f->def->count);
  }
}

/* How many variant names the "expected one of" error lists; a wider enum ends the list with "...". */
#define MAX_LISTED_VARIANTS 20

/* The enum value of a JSON object {"tag": "Variant", "values": [...]} (docs/vm/02-reference-behavior.md §2.7): "tag"
   names a variant and "values" is an array of its payload items, which a variant with no payload may leave out. A
   variant with no payload is the shared value, left in *v with f->tagged NULL. Otherwise f is opened as an enum frame
   (f->tagged set) for the caller to push. False means a failure, and *error is the error Result; depth frames of
   stack are open, which gives its path. */
static bool decode_variant(agc_vm *vm, const agc_json *j, uint32_t index, decode_frame *f, agc_value *v,
                           agc_value *error, const decode_frame *stack, size_t depth) {
  const agc_program *p = vm->rt->program;
  const agc_enum_def *def = &p->enums[index];
  f->tagged = NULL; /* the slot may hold a frame that closed before */
  const agc_json_member *tag = agc_json_find(j, agc_json_ascii("tag", 3));
  if (!tag) {
    *error = decode_error_in(vm, stack, depth, "tag", "required field");
    return false;
  }
  const agc_json *name = agc_as_json(vm, tag->value);
  if (name->kind != AGC_JSON_STRING) {
    *error = decode_error_in(vm, stack, depth, "tag", "String");
    return false;
  }
  const agc_string *text = agc_as_string(vm, name->scalar);
  const agc_variant_def *found = NULL;
  size_t offset = 0; /* the payload types of the variants before the one found */
  for (uint32_t k = 0; k < def->count && !found; k++) {
    const agc_variant_def *candidate = &p->variants[def->first + k];
    if (candidate->name->bytes == text->bytes && memcmp(candidate->name->data, text->data, text->bytes) == 0)
      found = candidate;
    else
      offset += candidate->arity;
  }
  if (!found) {
    agc_json_buffer b;
    b.cap = 64;
    b.len = 0;
    b.data = agc_alloc_atomic(b.cap);
    agc_json_put(&b, "one of ", 7);
    for (uint32_t k = 0; k < def->count && k < MAX_LISTED_VARIANTS; k++) {
      const agc_string *candidate = p->variants[def->first + k].name;
      if (k) agc_json_put(&b, ", ", 2);
      agc_json_put(&b, candidate->data, candidate->bytes);
    }
    if (def->count > MAX_LISTED_VARIANTS) agc_json_put(&b, ", ...", 5);
    agc_json_put(&b, "", 1);
    *error = decode_error_in(vm, stack, depth, "tag", b.data);
    return false;
  }
  uint32_t id = (uint32_t)(found - p->variants);
  const agc_json_member *values = agc_json_find(j, agc_json_ascii("values", 6));
  const agc_list *items = NULL;
  size_t n = 0;
  if (values) {
    const agc_json *array = agc_as_json(vm, values->value);
    if (array->kind != AGC_JSON_ARRAY) {
      *error = decode_error_in(vm, stack, depth, "values", "array");
      return false;
    }
    items = agc_as_list(vm, array->scalar);
    n = agc_list_len(items);
  } else if (found->arity) {
    *error = decode_error_in(vm, stack, depth, "values", "required field");
    return false;
  }
  if (n != found->arity) {
    char expected[48];
    snprintf(expected, sizeof expected, "array of %u items", (unsigned)found->arity);
    *error = decode_error_in(vm, stack, depth, "values", expected);
    return false;
  }
  if (!found->arity) {
    *v = agc_enum_value(found->shared);
    return true;
  }
  open_frame(vm, f, j, AGC_TYPE_ENUM, index);
  f->items = items;
  f->payload_types = def->payload_types + offset;
  f->n = found->arity;
  f->tagged = agc_new_enum(id, found->arity);
  return true;
}

agc_value agc_json_decode(agc_vm *vm, agc_value root, uint32_t root_kind, uint32_t type) {
  const agc_program *p = vm->rt->program;
  size_t depth = 0, capacity = 16;
  decode_frame *stack = agc_alloc(agc_size_mul(capacity, sizeof(decode_frame)));
  agc_value item = root;
  uint32_t kind = root_kind, arg = type;
  for (;;) {
    agc_value v;
    double x;
    agc_charge(vm, 1);
    const agc_json *j = kind == ABSENT_FIELD ? NULL : agc_as_json(vm, item);
    if (kind == ABSENT_FIELD && arg == AGC_TYPE_OPTIONAL) {
      v = agc_optional_make(p, false, agc_void());
    } else if (kind == ABSENT_FIELD) {
      v = json_field_value(p, AGC_JSON_FIELD_ABSENT, agc_void());
    } else if (kind == AGC_TYPE_OPTIONAL && j->kind == AGC_JSON_NULL) {
      v = agc_optional_make(p, false, agc_void());
    } else if (kind == AGC_TYPE_JSON_FIELD && j->kind == AGC_JSON_NULL) {
      v = json_field_value(p, AGC_JSON_FIELD_NULL, agc_void());
    } else if (kind == AGC_TYPE_JSON_FIELD || kind == AGC_TYPE_OPTIONAL) {
      const agc_type *inner = &p->types[arg];
      const char *mismatch = nullable_mismatch(j, inner->kind);
      if (mismatch) return decode_error(vm, stack, depth, mismatch);
      stack = agc_json_grow(stack, &capacity, depth, sizeof(decode_frame));
      open_frame(vm, &stack[depth++], j, kind, arg);
      kind = inner->kind;
      arg = inner->arg;
      continue;
    } else if (kind == AGC_TYPE_INT) {
      if (j->kind != AGC_JSON_INT) return decode_error(vm, stack, depth, "signed 64-bit Int");
      v = j->scalar;
    } else if (kind == AGC_TYPE_FLOAT) {
      if (!agc_json_to_float(vm, j, &x)) return decode_error(vm, stack, depth, "finite Float");
      v = agc_float(x);
    } else if (kind == AGC_TYPE_BOOL) {
      if (j->kind != AGC_JSON_BOOL) return decode_error(vm, stack, depth, "Bool");
      v = j->scalar;
    } else if (kind == AGC_TYPE_STRING) {
      if (j->kind != AGC_JSON_STRING) return decode_error(vm, stack, depth, "String");
      v = j->scalar;
    } else if (kind == AGC_TYPE_ENUM) {
      if (j->kind != AGC_JSON_OBJECT) return decode_error(vm, stack, depth, "object");
      stack = agc_json_grow(stack, &capacity, depth, sizeof(decode_frame));
      agc_value error;
      if (!decode_variant(vm, j, arg, &stack[depth], &v, &error, stack, depth)) return error;
      if (stack[depth].tagged) {
        depth++;
        if (!next_child(p, &stack[depth - 1], &item, &kind, &arg)) return decode_error(vm, stack, depth, "required field");
        continue;
      }
    } else {
      bool list = kind == AGC_TYPE_LIST;
      if (j->kind != (list ? AGC_JSON_ARRAY : AGC_JSON_OBJECT))
        return decode_error(vm, stack, depth, list ? "array" : "object");
      stack = agc_json_grow(stack, &capacity, depth, sizeof(decode_frame));
      decode_frame *f = &stack[depth];
      open_frame(vm, f, j, kind, arg);
      if (f->n) {
        depth++;
        if (!next_child(p, f, &item, &kind, &arg)) return decode_error(vm, stack, depth, "required field");
        continue;
      }
      v = frame_value(p, f);
    }
    for (;;) {
      // cchecker: ignore CC-TIDY-CLANG-ANALYZER-CORE-CALLANDMESSAGE: *v is set unless tagged, which continues
      if (!depth) return agc_result_value(true, v);
      decode_frame *top = &stack[depth - 1];
      store_child(vm, top, v);
      if (++top->next < top->n) {
        if (!next_child(p, top, &item, &kind, &arg)) return decode_error(vm, stack, depth, "required field");
        break;
      }
      v = frame_value(p, top);
      depth--;
    }
  }
}

static agc_value json_text(const char *text) {
  return agc_json_leaf(AGC_JSON_STRING, agc_string_value(agc_json_ascii(text, strlen(text))));
}

static agc_value object_of(size_t n, const char *const *keys, const agc_value *values) {
  agc_json_member *members = agc_alloc(agc_size_mul(n, sizeof(agc_json_member)));
  for (size_t i = 0; i < n; i++) {
    members[i].key = agc_json_ascii(keys[i], strlen(keys[i]));
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
  agc_json_buffer b;
  b.cap = agc_size_add(name->bytes, 16);
  b.len = 0;
  b.data = agc_alloc_atomic(b.cap);
  agc_json_put(&b, "#/$defs/", 8);
  size_t start = 0;
  for (size_t i = 0; i < name->bytes; i++) {
    if (name->data[i] != '~' && name->data[i] != '/') continue;
    agc_json_put(&b, name->data + start, i - start);
    agc_json_put(&b, name->data[i] == '~' ? "~0" : "~1", 2);
    start = i + 1;
  }
  agc_json_put(&b, name->data + start, name->bytes - start);
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
  if (t->kind == AGC_TYPE_ENUM) return reference(p->enums[t->arg].json_name);
  if (t->kind == AGC_TYPE_JSON_FIELD || t->kind == AGC_TYPE_OPTIONAL) {
    agc_list_builder choices;
    agc_list_builder_sized(&choices, 2);
    agc_list_builder_push(&choices, schemas[t->arg]);
    agc_list_builder_push(&choices, typed("null"));
    static const char *const keys[] = {"anyOf"};
    agc_value values[] = {agc_json_array(agc_list_builder_finish(&choices))};
    return object_of(1, keys, values);
  }
  if (t->kind == AGC_TYPE_LIST) {
    static const char *const keys[] = {"type", "items"};
    agc_value values[] = {json_text("array"), schemas[t->arg]};
    return object_of(2, keys, values);
  }
  static const char *const keys[] = {"type", "additionalProperties"};
  agc_value values[] = {json_text("object"), schemas[t->arg]};
  return object_of(2, keys, values);
}

static bool required_field(const agc_program *p, uint32_t type) {
  uint32_t kind = p->types[type].kind;
  return kind != AGC_TYPE_JSON_FIELD && kind != AGC_TYPE_OPTIONAL;
}

/* A JSON.Field or Optional field is not required. With no required field the "required" key is left out, since
   draft-04 wants a non-empty list there. */
static agc_value struct_schema(const agc_program *p, const agc_struct_def *def, const agc_value *schemas,
                               agc_value defs) {
  agc_json_member *properties = agc_alloc(agc_size_mul(def->count, sizeof(agc_json_member)));
  size_t needed = 0;
  for (uint32_t k = 0; k < def->count; k++) {
    properties[k].key = def->fields[k];
    properties[k].value = schemas[def->field_types[k]];
    if (required_field(p, def->field_types[k])) needed++;
  }
  const char *keys[4] = {"type", "properties"};
  agc_value values[4] = {json_text("object"), agc_json_object(properties, def->count)};
  size_t n = 2;
  if (needed) {
    agc_list_builder required;
    agc_list_builder_sized(&required, needed);
    for (uint32_t k = 0; k < def->count; k++)
      if (required_field(p, def->field_types[k]))
        agc_list_builder_push(&required, agc_json_leaf(AGC_JSON_STRING, agc_string_value(def->fields[k])));
    keys[n] = "required";
    values[n++] = agc_json_array(agc_list_builder_finish(&required));
  }
  if (!agc_is(defs, AGC_T_VOID)) {
    keys[n] = "$defs";
    values[n++] = defs;
  }
  return object_of(n, keys, values);
}

/* The structs and enums to describe in $defs are numbered together: a struct by its index and an enum by
   struct_count plus its index. */
static void mark_type(const agc_program *p, uint32_t t, bool *needed, bool *seen, uint32_t *queue, size_t *count) {
  while (!needed[t]) {
    needed[t] = true;
    const agc_type *type = &p->types[t];
    if (type->kind == AGC_TYPE_STRUCT || type->kind == AGC_TYPE_ENUM) {
      uint32_t id = type->kind == AGC_TYPE_STRUCT ? type->arg : p->struct_count + type->arg;
      if (!seen[id]) {
        seen[id] = true;
        queue[(*count)++] = id;
      }
      return;
    }
    if (type->kind < AGC_TYPE_LIST) return;
    t = type->arg;
  }
}

static agc_value tag_schema(agc_string *name) {
  static const char *const keys[] = {"enum"};
  agc_list_builder names;
  agc_list_builder_sized(&names, 1);
  agc_list_builder_push(&names, agc_json_leaf(AGC_JSON_STRING, agc_string_value(name)));
  agc_value values[] = {agc_json_array(agc_list_builder_finish(&names))};
  return object_of(1, keys, values);
}

/* The object of one variant: "tag" is the name alone, and "values" an array of exactly the payload items
   (prefixItems is for 2020-12 validators, minItems and maxItems for all). A variant with no payload may leave "values"
   out, as the decoder accepts. */
static agc_value variant_schema(const agc_variant_def *v, const uint32_t *payload_types, const agc_value *schemas) {
  const char *keys[4] = {"type"};
  agc_value values[4] = {json_text("array")};
  size_t n = 1;
  if (v->arity) {
    agc_list_builder items;
    agc_list_builder_sized(&items, v->arity);
    for (uint32_t k = 0; k < v->arity; k++) agc_list_builder_push(&items, schemas[payload_types[k]]);
    keys[n] = "minItems";
    values[n++] = agc_json_number(v->arity);
    keys[n] = "prefixItems";
    values[n++] = agc_json_array(agc_list_builder_finish(&items));
  }
  keys[n] = "maxItems";
  values[n++] = agc_json_number(v->arity);
  static const char *const property_keys[] = {"tag", "values"};
  agc_value property_values[] = {tag_schema(v->name), object_of(n, keys, values)};
  agc_list_builder required;
  agc_list_builder_sized(&required, v->arity ? 2 : 1);
  agc_list_builder_push(&required, json_text("tag"));
  if (v->arity) agc_list_builder_push(&required, json_text("values"));
  static const char *const variant_keys[] = {"type", "properties", "required"};
  agc_value variant_values[] = {json_text("object"), object_of(2, property_keys, property_values),
                                agc_json_array(agc_list_builder_finish(&required))};
  return object_of(3, variant_keys, variant_values);
}

/* An enum as the tagged objects its decoder reads: a oneOf with one schema for each variant. */
static agc_value enum_schema(const agc_program *p, const agc_enum_def *def, const agc_value *schemas, agc_value defs) {
  agc_list_builder choices;
  agc_list_builder_sized(&choices, def->count);
  const uint32_t *payload_types = def->payload_types;
  for (uint32_t k = 0; k < def->count; k++) {
    const agc_variant_def *v = &p->variants[def->first + k];
    agc_list_builder_push(&choices, variant_schema(v, payload_types, schemas));
    payload_types += v->arity;
  }
  const char *keys[2] = {"oneOf"};
  agc_value values[2] = {agc_json_array(agc_list_builder_finish(&choices))};
  size_t n = 1;
  if (!agc_is(defs, AGC_T_VOID)) {
    keys[n] = "$defs";
    values[n++] = defs;
  }
  return object_of(n, keys, values);
}

agc_value agc_json_schema(agc_vm *vm, uint32_t kind, uint32_t index) {
  const agc_program *p = vm->rt->program;
  uint32_t total = p->struct_count + p->enum_count;
  bool *needed = agc_alloc_atomic(p->type_count);
  memset(needed, 0, p->type_count);
  bool *seen = agc_alloc_atomic(total);
  memset(seen, 0, total);
  uint32_t *queue = agc_alloc_atomic(agc_size_mul(total, sizeof(uint32_t)));
  size_t count = 0;
  uint32_t root = kind == AGC_TYPE_STRUCT ? index : p->struct_count + index;
  uint32_t current = root;
  for (size_t head = 0;; current = queue[head++]) {
    if (current < p->struct_count) {
      const agc_struct_def *def = &p->structs[current];
      for (uint32_t k = 0; k < def->count; k++) mark_type(p, def->field_types[k], needed, seen, queue, &count);
    } else {
      const agc_enum_def *def = &p->enums[current - p->struct_count];
      uint32_t items = 0;
      for (uint32_t k = 0; k < def->count; k++) items += p->variants[def->first + k].arity;
      for (uint32_t j = 0; j < items; j++) mark_type(p, def->payload_types[j], needed, seen, queue, &count);
    }
    if (head == count) break;
  }
  agc_value *schemas = agc_alloc(agc_size_mul(p->type_count, sizeof(agc_value)));
  for (uint32_t i = 0; i < p->type_count; i++)
    if (needed[i]) schemas[i] = type_schema(p, &p->types[i], schemas);
  agc_value defs = agc_void();
  if (count) {
    agc_json_member *members = agc_alloc(agc_size_mul(count, sizeof(agc_json_member)));
    for (size_t i = 0; i < count; i++) {
      uint32_t id = queue[i];
      if (id < p->struct_count) {
        members[i].key = p->structs[id].json_name;
        members[i].value = struct_schema(p, &p->structs[id], schemas, agc_void());
      } else {
        members[i].key = p->enums[id - p->struct_count].json_name;
        members[i].value = enum_schema(p, &p->enums[id - p->struct_count], schemas, agc_void());
      }
    }
    defs = agc_json_object(members, count);
  }
  if (kind == AGC_TYPE_ENUM) return enum_schema(p, &p->enums[index], schemas, defs);
  return struct_schema(p, &p->structs[index], schemas, defs);
}
