/*
 * The Json value in C: its nodes, the builders that the parser and the
 * builtins share, and agc_json_encode, the one writer for JSON.encode and for
 * the text form of a Json. Core layer, because text and equality use it.
 * Design: docs/vm/05-values-execution-builtins.md §5.1 and
 * docs/vm/02-reference-behavior.md §2.6.
 */
#include "core.h"

#include <inttypes.h>
#include <math.h>
#include <string.h>

/* next is the child to read, written the number of children written so far: a JSON.Field.Absent struct field is read
   but not written, so the two differ. */
typedef struct {
  agc_value value;
  size_t next, written, n;
  /* The members of a JSON.Value object in the order they are written: by key for the canonical form of equality. */
  const agc_json_member *order;
  agc_value *keys;
  agc_json *node;
  agc_list_builder items;
} walk_frame;

static agc_json *new_node(agc_json_kind kind, agc_value scalar) {
  agc_json *j = agc_alloc(sizeof(agc_json));
  j->kind = kind;
  j->scalar = scalar;
  j->count = 0;
  j->members = NULL;
  j->sorted = NULL;
  return j;
}

agc_value agc_json_leaf(agc_json_kind kind, agc_value scalar) { return agc_json_value(new_node(kind, scalar)); }

agc_string *agc_json_ascii(const char *text, size_t n) { return agc_make_string(text, n, n); }

static int key_compare(const agc_string *a, const agc_string *b) {
  size_t n = a->bytes < b->bytes ? a->bytes : b->bytes;
  int c = n ? memcmp(a->data, b->data, n) : 0;
  if (c) return c;
  return a->bytes < b->bytes ? -1 : a->bytes > b->bytes;
}

/* Objects of at most this many members keep no sorted copy: a lookup scans them. */
#define SMALL_OBJECT 8

/* A stable merge sort of the n members at m by key, between m and a buffer of the same size; the result is in the
   array returned, then each key once with the value of its last member (the count is in *count). */
static agc_json_member *sort_members(agc_json_member *m, size_t n, size_t *count) {
  agc_json_member *from = m, *to = agc_alloc(agc_size_mul(n, sizeof(agc_json_member)));
  for (size_t width = 1; width < n; width = width > n / 2 ? n : width * 2) {
    for (size_t lo = 0; lo < n;) {
      size_t mid = lo + (width < n - lo ? width : n - lo);
      size_t hi = mid + (width < n - mid ? width : n - mid);
      size_t i = lo, j = mid, k = lo;
      while (i < mid && j < hi) to[k++] = key_compare(from[j].key, from[i].key) < 0 ? from[j++] : from[i++];
      while (i < mid) to[k++] = from[i++];
      while (j < hi) to[k++] = from[j++];
      lo = hi;
    }
    agc_json_member *swap = from;
    from = to;
    to = swap;
  }
  size_t kept = 0;
  for (size_t i = 0; i < n; i++)
    if (i + 1 == n || key_compare(from[i].key, from[i + 1].key) != 0) from[kept++] = from[i];
  *count = kept;
  return from;
}

static const agc_json_member *find_sorted(const agc_json_member *m, size_t n, const agc_string *key) {
  size_t lo = 0, hi = n;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    int c = key_compare(m[mid].key, key);
    if (c == 0) return &m[mid];
    if (c < 0)
      lo = mid + 1;
    else
      hi = mid;
  }
  return NULL;
}

static bool in_key_order(const agc_json_member *m, size_t n) {
  for (size_t i = 1; i < n; i++)
    if (key_compare(m[i - 1].key, m[i].key) >= 0) return false;
  return true;
}

/* Each key once, at the place of its first member with the value of its last, in O(n * n) for a small object. */
static size_t merge_small(agc_json_member *m, size_t n) {
  size_t kept = 0;
  for (size_t i = 0; i < n; i++) {
    size_t at = 0;
    while (at < kept && key_compare(m[at].key, m[i].key) != 0) at++;
    if (at < kept)
      m[at].value = m[i].value;
    else
      m[kept++] = m[i];
  }
  return kept;
}

/* The members in their order with each key once (at the place of its first member, with the value of its last), and
   the sorted copy that lookups use: none for a small object, the members themselves when they are in key order. The
   copy is made now, since a built value is shared between threads and never changes. */
static void index_members(agc_json *node, size_t n) {
  agc_json_member *m = node->members;
  size_t count = n;
  if (in_key_order(m, n)) {
    node->sorted = m;
  } else if (n <= SMALL_OBJECT) {
    count = merge_small(m, n);
    node->sorted = NULL;
  } else {
    agc_json_member *copy = agc_alloc(agc_size_mul(n, sizeof(agc_json_member)));
    memcpy(copy, m, n * sizeof(agc_json_member));
    agc_json_member *sorted = sort_members(copy, n, &count);
    if (count < n) {
      bool *placed = agc_alloc_atomic(count);
      memset(placed, 0, count);
      size_t kept = 0;
      for (size_t i = 0; i < n; i++) {
        const agc_json_member *found = find_sorted(sorted, count, m[i].key);
        if (!found) continue; /* never: every key has its place in the sorted copy */
        size_t at = (size_t)(found - sorted);
        if (placed[at]) continue;
        placed[at] = true;
        m[kept++] = sorted[at];
      }
    }
    node->sorted = sorted;
  }
  if (count < n) memset(m + count, 0, (n - count) * sizeof(agc_json_member));
  node->count = count;
}

/* The members of an object in key order: its sorted copy, or for a small object one made now (insertion sort). */
static const agc_json_member *by_key(const agc_json *j) {
  if (j->sorted || j->count == 0) return j->sorted;
  agc_json_member *m = agc_alloc(agc_size_mul(j->count, sizeof(agc_json_member)));
  for (size_t i = 0; i < j->count; i++) {
    size_t at = i;
    while (at > 0 && key_compare(m[at - 1].key, j->members[i].key) > 0) {
      m[at] = m[at - 1];
      at--;
    }
    m[at] = j->members[i];
  }
  return m;
}

agc_json *agc_json_container(bool object, size_t n, agc_list_builder *items) {
  agc_json *node = new_node(object ? AGC_JSON_OBJECT : AGC_JSON_ARRAY, agc_nil());
  *items = (agc_list_builder){0};
  if (object) {
    node->members = n ? agc_alloc(agc_size_mul(n, sizeof(agc_json_member))) : NULL;
  } else {
    agc_list_builder_sized(items, n);
    if (!n) node->scalar = agc_list_value(agc_list_builder_finish(items));
  }
  return node;
}

void agc_json_store(agc_json *node, agc_list_builder *items, size_t k, agc_value v) {
  if (node->kind == AGC_JSON_ARRAY)
    agc_list_builder_push(items, v);
  else
    node->members[k].value = v;
}

agc_value agc_json_finish(agc_json *node, agc_list_builder *items, size_t n) {
  if (node->kind == AGC_JSON_OBJECT) index_members(node, n);
  if (node->kind == AGC_JSON_ARRAY && n) node->scalar = agc_list_value(agc_list_builder_finish(items));
  return agc_json_value(node);
}

void *agc_json_grow(void *stack, size_t *capacity, size_t depth, size_t size) {
  if (depth < *capacity) return stack;
  size_t bigger = agc_size_mul(*capacity, 2);
  void *grown = agc_alloc(agc_size_mul(bigger, size));
  memcpy(grown, stack, depth * size);
  *capacity = bigger;
  return grown;
}

void agc_json_put(agc_json_buffer *b, const char *text, size_t n) {
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

static void put_string(agc_json_buffer *b, const agc_string *s) {
  const uint8_t *data = (const uint8_t *)s->data;
  size_t start = 0;
  agc_json_put(b, "\"", 1);
  for (size_t i = 0; i < s->bytes; i++) {
    uint8_t c = data[i];
    if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7F) continue;
    agc_json_put(b, s->data + start, i - start);
    start = i + 1;
    char hex[8];
    const char *escape = c == '\b' ? "\\b" : c == '\n' ? "\\n" : c == '\r' ? "\\r" : c == '\f' ? "\\f"
                       : c == '\t' ? "\\t" : c == '\\' ? "\\\\" : c == '"' ? "\\\"" : NULL;
    if (!escape) {
      snprintf(hex, sizeof hex, "\\u%04x", (unsigned)c);
      escape = hex;
    }
    agc_json_put(b, escape, strlen(escape));
  }
  agc_json_put(b, s->data + start, s->bytes - start);
  agc_json_put(b, "\"", 1);
}

static _Noreturn void not_finite(agc_vm *vm, uint32_t span) {
  agc_fail(vm, "RUNTIME-JSON-ENCODE", "cannot encode a non-finite Float", span);
}

/* JSON has no byte type and the checker refuses a Bytes there (CHECK-NOT-ENCODABLE), so only hand-made bytecode gets
   here; a Bytes Map key fails the same way, as a key that is not a String. */
static _Noreturn void not_encodable(agc_vm *vm, uint32_t span) {
  agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: a Bytes value has no JSON form", span);
}

static void put_scalar(agc_vm *vm, agc_json_buffer *b, agc_value v, uint32_t span) {
  char text[AGC_SCALAR_TEXT];
  if (agc_is(v, AGC_T_JSON)) {
    const agc_json *j = agc_as_json(vm, v);
    if (j->kind == AGC_JSON_NULL) {
      agc_json_put(b, "null", 4);
      return;
    }
    v = j->scalar;
  }
  if (agc_is(v, AGC_T_STRING)) {
    put_string(b, agc_as_string(vm, v));
  } else if (agc_is(v, AGC_T_NIL)) {
    agc_json_put(b, "null", 4);
  } else if (agc_is(v, AGC_T_BOOL)) {
    if (agc_as_bool(vm, v))
      agc_json_put(b, "true", 4);
    else
      agc_json_put(b, "false", 5);
  } else if (agc_is(v, AGC_T_FLOAT)) {
    double x = agc_as_float(vm, v);
    if (!isfinite(x)) not_finite(vm, span);
    agc_json_put(b, text, agc_float_text(x, text));
  } else if (agc_is(v, AGC_T_BYTES)) {
    not_encodable(vm, span);
  } else {
    agc_json_put(b, text, (size_t)snprintf(text, sizeof text, "%" PRId64, agc_as_int(vm, v)));
  }
}

static void put_big(agc_vm *vm, agc_json_buffer *b, agc_value v) {
  const agc_string *s = agc_as_string(vm, agc_as_json(vm, v)->scalar);
  agc_json_put(b, s->data, s->bytes);
}

static bool json_kind(agc_vm *vm, agc_value v, agc_json_kind kind) {
  return agc_is(v, AGC_T_JSON) && agc_as_json(vm, v)->kind == kind;
}

static bool open_frame(agc_vm *vm, agc_value v, walk_frame *f) {
  f->value = v;
  f->next = 0;
  f->written = 0;
  f->order = NULL;
  f->keys = NULL;
  if (agc_is(v, AGC_T_LIST)) {
    f->n = agc_list_len(agc_as_list(vm, v));
  } else if (agc_is(v, AGC_T_MAP)) {
    const agc_map *m = agc_as_map(vm, v);
    f->n = m->size;
    f->keys = m->size ? agc_map_keys(vm, m, 0) : NULL;
  } else if (agc_is(v, AGC_T_STRUCT)) {
    f->n = agc_struct_def_of(vm, agc_as_struct(vm, v))->count;
  } else if (agc_is(v, AGC_T_ENUM)) {
    f->n = 2; /* "tag" and "values" */
  } else if (json_kind(vm, v, AGC_JSON_ARRAY)) {
    f->n = agc_list_len(agc_as_list(vm, agc_as_json(vm, v)->scalar));
  } else if (json_kind(vm, v, AGC_JSON_OBJECT)) {
    f->n = agc_as_json(vm, v)->count;
  } else {
    return false;
  }
  return true;
}

static bool is_object(agc_vm *vm, agc_value v) {
  return agc_is(v, AGC_T_MAP) || agc_is(v, AGC_T_STRUCT) || agc_is(v, AGC_T_ENUM) ||
         json_kind(vm, v, AGC_JSON_OBJECT);
}

/* The two children of an enum value: its variant name under "tag", then its payload items as the array under
   "values" (an enum with no payload writes an empty one). Optional and JSON.Field have their own forms and never get
   here from a checked program. */
static agc_value enum_child(agc_vm *vm, const agc_enum *e, size_t k, agc_string **key) {
  if (k == 0) {
    *key = agc_json_ascii("tag", 3);
    return agc_string_value(vm->rt->program->variants[e->variant].name);
  }
  *key = agc_json_ascii("values", 6);
  agc_list_builder items;
  agc_list_builder_sized(&items, e->n);
  for (uint32_t i = 0; i < e->n; i++) agc_list_builder_push(&items, e->payload[i]);
  return agc_list_value(agc_list_builder_finish(&items));
}

static agc_value child(agc_vm *vm, walk_frame *f, agc_string **key) {
  size_t k = f->next;
  agc_value v = f->value, item;
  if (agc_is(v, AGC_T_LIST)) {
    *key = NULL;
    return agc_list_get(agc_as_list(vm, v), k);
  }
  if (agc_is(v, AGC_T_MAP)) {
    *key = agc_as_string(vm, f->keys[k]);
    if (!agc_map_get(vm, agc_as_map(vm, v), f->keys[k], &item)) agc_fail(vm, "RUNTIME-INTERNAL", "invalid map", 0);
    return item;
  }
  if (agc_is(v, AGC_T_STRUCT)) {
    const agc_struct *st = agc_as_struct(vm, v);
    *key = agc_struct_def_of(vm, st)->fields[k];
    return st->fields[k];
  }
  if (agc_is(v, AGC_T_ENUM)) return enum_child(vm, agc_as_enum(vm, v), k, key);
  const agc_json *j = agc_as_json(vm, v);
  if (j->kind == AGC_JSON_ARRAY) {
    *key = NULL;
    return agc_list_get(agc_as_list(vm, j->scalar), k);
  }
  const agc_json_member *m = f->order ? f->order : j->members;
  *key = m[k].key;
  return m[k].value;
}

/* A struct field's value as JSON writes it (docs/grammar/06b-builtins.md, typed JSON): false for JSON.Field.Absent,
   whose key is left out; JSON.Field.Null is nil (null) and JSON.Field.Value(x) is x. Any other value is unchanged. The
   checker allows JSON.Field only as the direct type of a struct field, so only struct children are looked at. Only
   hostile bytecode puts a JSON.Field anywhere else; it is then written as a tagged enum object like any other enum. */
static bool field_value(agc_vm *vm, agc_value *item) {
  if (!agc_is(*item, AGC_T_ENUM)) return true;
  uint32_t first = vm->rt->program->json_field;
  const agc_enum *e = agc_as_enum(vm, *item);
  if (first == UINT32_MAX || e->variant - first > AGC_JSON_FIELD_VALUE) return true;
  uint32_t which = e->variant - first;
  if (which == AGC_JSON_FIELD_ABSENT) return false;
  if (which == AGC_JSON_FIELD_NULL) {
    *item = agc_nil();
    return true;
  }
  if (e->n != 1) agc_fail(vm, "RUNTIME-INTERNAL", "invalid JSON.Field value", 0);
  *item = e->payload[0];
  return true;
}

/* A value as JSON writes it when it is an Optional, which may be anywhere a type is: none is nil (null) and some(x)
   is x, so some(none) is null too. Any other value is unchanged. */
static void optional_value(agc_vm *vm, agc_value *item) {
  /* Only an enum value reads the program: the C tests encode plain values with no program loaded. */
  if (!agc_is(*item, AGC_T_ENUM)) return;
  uint32_t first = vm->rt->program->optional;
  if (first == UINT32_MAX) return;
  while (agc_is(*item, AGC_T_ENUM)) {
    const agc_enum *e = agc_as_enum(vm, *item);
    if (e->variant - first > 1) return;
    if (e->n != (e->variant - first)) agc_fail(vm, "RUNTIME-INTERNAL", "invalid Optional value", 0);
    *item = e->n ? e->payload[0] : agc_nil();
  }
}

/* The next child of the frame that JSON writes, skipping JSON.Field.Absent struct fields; false when none is left. */
static bool next_child(agc_vm *vm, walk_frame *f, agc_value *item, agc_string **key) {
  while (f->next < f->n) {
    *item = child(vm, f, key);
    f->next++;
    if (!agc_is(f->value, AGC_T_STRUCT) || field_value(vm, item)) return true;
  }
  return false;
}

static agc_string *encode(agc_vm *vm, agc_value root, uint32_t span, bool sorted) {
  agc_json_buffer b;
  b.cap = 64;
  b.len = 0;
  b.data = agc_alloc_atomic(b.cap);
  size_t depth = 0, capacity = 16;
  walk_frame *stack = agc_alloc(agc_size_mul(capacity, sizeof(walk_frame)));
  agc_value item = root;
  for (;;) {
    stack = agc_json_grow(stack, &capacity, depth, sizeof(walk_frame));
    optional_value(vm, &item);
    if (open_frame(vm, item, &stack[depth])) {
      if (sorted && json_kind(vm, item, AGC_JSON_OBJECT)) stack[depth].order = by_key(agc_as_json(vm, item));
      agc_json_put(&b, is_object(vm, item) ? "{" : "[", 1);
      depth++;
    } else if (json_kind(vm, item, AGC_JSON_BIG)) {
      put_big(vm, &b, item);
    } else {
      put_scalar(vm, &b, item, span);
    }
    agc_string *key;
    for (;;) {
      if (!depth) {
        agc_string *s = agc_new_string(b.len, agc_utf8_count((const uint8_t *)b.data, b.len));
        if (b.len) memcpy(s->data, b.data, b.len);
        agc_charge_bytes(vm, b.len);
        return s;
      }
      walk_frame *top = &stack[depth - 1];
      if (next_child(vm, top, &item, &key)) break;
      agc_json_put(&b, is_object(vm, top->value) ? "}" : "]", 1);
      depth--;
    }
    walk_frame *top = &stack[depth - 1];
    if (top->written++) agc_json_put(&b, ",", 1);
    if (key) {
      put_string(&b, key);
      agc_json_put(&b, ":", 1);
    }
  }
}

agc_string *agc_json_encode(agc_vm *vm, agc_value root, uint32_t span) { return encode(vm, root, span, false); }

agc_string *agc_json_canonical(agc_vm *vm, agc_value root, uint32_t span) { return encode(vm, root, span, true); }

static agc_value scalar_json(agc_vm *vm, agc_value v, uint32_t span) {
  if (agc_is(v, AGC_T_NIL)) return agc_json_leaf(AGC_JSON_NULL, v);
  if (agc_is(v, AGC_T_BOOL)) return agc_json_leaf(AGC_JSON_BOOL, v);
  if (agc_is(v, AGC_T_INT)) return agc_json_leaf(AGC_JSON_INT, v);
  if (agc_is(v, AGC_T_FLOAT)) {
    if (!isfinite(agc_as_float(vm, v))) not_finite(vm, span);
    return agc_json_leaf(AGC_JSON_FLOAT, v);
  }
  if (agc_is(v, AGC_T_BYTES)) not_encodable(vm, span);
  agc_as_string(vm, v);
  return agc_json_leaf(AGC_JSON_STRING, v);
}

agc_value agc_json_from(agc_vm *vm, agc_value root, uint32_t span) {
  size_t depth = 0, capacity = 16;
  walk_frame *stack = agc_alloc(agc_size_mul(capacity, sizeof(walk_frame)));
  agc_value item = root;
  for (;;) {
    agc_value v;
    agc_charge(vm, 1);
    stack = agc_json_grow(stack, &capacity, depth, sizeof(walk_frame));
    walk_frame *f = &stack[depth];
    optional_value(vm, &item);
    if (agc_is(item, AGC_T_JSON)) {
      v = item;
    } else if (open_frame(vm, item, f)) {
      f->node = agc_json_container(!agc_is(item, AGC_T_LIST), f->n, &f->items);
      agc_string *key;
      if (next_child(vm, f, &item, &key)) {
        depth++;
        if (key) f->node->members[0].key = key;
        continue;
      }
      v = agc_json_finish(f->node, &f->items, 0);
    } else {
      v = scalar_json(vm, item, span);
    }
    for (;;) {
      if (depth == 0) return v;
      walk_frame *top = &stack[depth - 1];
      agc_json_store(top->node, &top->items, top->written++, v);
      agc_string *key;
      if (next_child(vm, top, &item, &key)) {
        if (key) top->node->members[top->written].key = key;
        break;
      }
      v = agc_json_finish(top->node, &top->items, top->written);
      depth--;
    }
  }
}

agc_value agc_json_number(int64_t n) { return agc_json_leaf(AGC_JSON_INT, agc_int(n)); }

agc_json_member agc_json_pair(const char *key, agc_value value) {
  size_t n = strlen(key);
  agc_json_member m;
  m.key = agc_make_string(key, n, n);
  m.value = value;
  return m;
}

agc_value agc_json_object(agc_json_member *members, size_t n) {
  agc_json *node = new_node(AGC_JSON_OBJECT, agc_nil());
  node->members = members;
  return agc_json_finish(node, NULL, n);
}

agc_value agc_json_array(agc_list *items) { return agc_json_leaf(AGC_JSON_ARRAY, agc_list_value(items)); }

const agc_json_member *agc_json_find(const agc_json *j, const agc_string *key) {
  if (j->sorted) return find_sorted(j->sorted, j->count, key);
  for (size_t i = 0; i < j->count; i++)
    if (key_compare(j->members[i].key, key) == 0) return &j->members[i];
  return NULL;
}
