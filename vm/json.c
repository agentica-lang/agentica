#include "agc.h"

#include <inttypes.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "yyjson.h"

typedef struct {
  union {
    yyjson_arr_iter arr;
    yyjson_obj_iter obj;
  } it;
  size_t next, n;
  agc_json *node;
  agc_list *items;
} parse_frame;

typedef struct {
  char *data;
  size_t len, cap;
} buffer;

typedef struct {
  agc_value value;
  size_t next, n;
  agc_value *keys;
  agc_json *node;
  agc_list *items;
} walk_frame;

const char *agc_json_version(void) { return YYJSON_VERSION_STRING; }

static agc_json *new_node(agc_json_kind kind, agc_value scalar) {
  agc_json *j = agc_alloc(sizeof(agc_json));
  j->kind = kind;
  j->scalar = scalar;
  j->count = 0;
  j->members = NULL;
  return j;
}

static agc_value leaf(agc_json_kind kind, agc_value scalar) { return agc_json_value(new_node(kind, scalar)); }

static agc_string *ascii(const char *text, size_t n) { return agc_make_string(text, n, n); }

static bool digit(uint8_t c) { return c >= '0' && c <= '9'; }

static bool json_space(uint8_t c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

static double decimal(const char *s, size_t len) {
  char small[64];
  char *text = len < sizeof small ? small : agc_alloc_atomic(agc_size_add(len, 1));
  memcpy(text, s, len);
  text[len] = '\0';
  return strtod(text, NULL);
}

static bool number_value(const uint8_t *s, size_t len, agc_value *out) {
  bool exact = true;
  size_t mantissa = len;
  for (size_t i = 0; i < len; i++) {
    if (s[i] == '.') exact = false;
    if (s[i] == 'e' || s[i] == 'E') {
      exact = false;
      mantissa = i;
      break;
    }
  }
  if (exact) {
    int64_t n;
    if (agc_parse_int(s, len, &n) == AGC_NUMBER_OK)
      *out = leaf(AGC_JSON_INT, agc_int(n));
    else
      *out = leaf(AGC_JSON_BIG, agc_string_value(ascii((const char *)s, len)));
    return true;
  }
  bool zero = true;
  for (size_t i = 0; i < mantissa; i++)
    if (s[i] >= '1' && s[i] <= '9') zero = false;
  double x = 0.0;
  if (!zero) {
    x = decimal((const char *)s, len);
    if (isinf(x)) return false;
  }
  *out = leaf(AGC_JSON_FLOAT, agc_float(x));
  return true;
}

static int key_compare(const agc_string *a, const agc_string *b) {
  size_t n = a->bytes < b->bytes ? a->bytes : b->bytes;
  int c = n ? memcmp(a->data, b->data, n) : 0;
  if (c) return c;
  return a->bytes < b->bytes ? -1 : a->bytes > b->bytes;
}

static size_t sort_members(agc_json_member *m, size_t n) {
  agc_json_member *tmp = agc_alloc(agc_size_mul(n, sizeof(agc_json_member)));
  for (size_t width = 1; width < n; width = width > n / 2 ? n : width * 2) {
    for (size_t lo = 0; lo < n;) {
      size_t mid = lo + (width < n - lo ? width : n - lo);
      size_t hi = mid + (width < n - mid ? width : n - mid);
      size_t i = lo, j = mid, k = lo;
      while (i < mid && j < hi) tmp[k++] = key_compare(m[j].key, m[i].key) < 0 ? m[j++] : m[i++];
      while (i < mid) tmp[k++] = m[i++];
      while (j < hi) tmp[k++] = m[j++];
      lo = hi;
    }
    memcpy(m, tmp, n * sizeof(agc_json_member));
  }
  size_t count = 0;
  for (size_t i = 0; i < n; i++)
    if (i + 1 == n || key_compare(m[i].key, m[i + 1].key) != 0) m[count++] = m[i];
  return count;
}

static agc_json *container(bool object, size_t n, agc_list **items) {
  agc_json *node = new_node(object ? AGC_JSON_OBJECT : AGC_JSON_ARRAY, agc_nil());
  *items = NULL;
  if (object) {
    node->members = n ? agc_alloc(agc_size_mul(n, sizeof(agc_json_member))) : NULL;
  } else {
    *items = agc_new_list(n);
    node->scalar = agc_list_value(*items);
  }
  return node;
}

static void store(agc_json *node, agc_list *items, size_t k, agc_value v) {
  if (items)
    items->items[k] = v;
  else
    node->members[k].value = v;
}

static agc_value finish(agc_json *node, size_t n) {
  if (node->kind == AGC_JSON_OBJECT && n) node->count = sort_members(node->members, n);
  return agc_json_value(node);
}

static void *grow(void *stack, size_t *capacity, size_t depth, size_t size) {
  if (depth < *capacity) return stack;
  size_t bigger = agc_size_mul(*capacity, 2);
  void *grown = agc_alloc(agc_size_mul(bigger, size));
  memcpy(grown, stack, depth * size);
  *capacity = bigger;
  return grown;
}

static yyjson_val *parse_child(parse_frame *f) {
  if (f->items) return yyjson_arr_iter_next(&f->it.arr);
  yyjson_val *key = yyjson_obj_iter_next(&f->it.obj);
  const char *text = yyjson_get_str(key);
  size_t len = yyjson_get_len(key);
  f->node->members[f->next].key = agc_make_string(text, len, agc_utf8_count((const uint8_t *)text, len));
  return yyjson_obj_iter_get_val(key);
}

static bool parse_leaf(yyjson_val *val, agc_value *out) {
  if (yyjson_is_raw(val)) return number_value((const uint8_t *)yyjson_get_raw(val), yyjson_get_len(val), out);
  if (yyjson_is_str(val)) {
    const char *text = yyjson_get_str(val);
    size_t len = yyjson_get_len(val);
    *out = leaf(AGC_JSON_STRING,
                agc_string_value(agc_make_string(text, len, agc_utf8_count((const uint8_t *)text, len))));
  } else if (yyjson_is_bool(val)) {
    *out = leaf(AGC_JSON_BOOL, agc_bool(yyjson_get_bool(val)));
  } else {
    *out = leaf(AGC_JSON_NULL, agc_nil());
  }
  return true;
}

static bool convert(yyjson_val *val, agc_value *out) {
  size_t depth = 0, capacity = 16;
  parse_frame *stack = agc_alloc(agc_size_mul(capacity, sizeof(parse_frame)));
  for (;;) {
    agc_value v;
    if (yyjson_is_arr(val) || yyjson_is_obj(val)) {
      bool object = yyjson_is_obj(val);
      size_t n = yyjson_get_len(val);
      agc_list *items;
      agc_json *node = container(object, n, &items);
      if (!n) {
        v = agc_json_value(node);
      } else {
        stack = grow(stack, &capacity, depth, sizeof(parse_frame));
        parse_frame *f = &stack[depth++];
        f->next = 0;
        f->n = n;
        f->node = node;
        f->items = items;
        if (object)
          yyjson_obj_iter_init(val, &f->it.obj);
        else
          yyjson_arr_iter_init(val, &f->it.arr);
        val = parse_child(f);
        continue;
      }
    } else if (!parse_leaf(val, &v)) {
      return false;
    }
    for (;;) {
      if (depth == 0) {
        *out = v;
        return true;
      }
      parse_frame *f = &stack[depth - 1];
      store(f->node, f->items, f->next, v);
      if (++f->next < f->n) {
        val = parse_child(f);
        break;
      }
      v = finish(f->node, f->n);
      depth--;
    }
  }
}

static bool scan_number(const uint8_t *s, size_t len, size_t i, size_t *end) {
  if (s[i] == '-') i++;
  if (i == len || !digit(s[i])) return false;
  if (s[i] == '0')
    i++;
  else
    while (i < len && digit(s[i])) i++;
  if (i < len && s[i] == '.') {
    if (++i == len || !digit(s[i])) return false;
    while (i < len && digit(s[i])) i++;
  }
  if (i < len && (s[i] == 'e' || s[i] == 'E')) {
    if (++i < len && (s[i] == '+' || s[i] == '-')) i++;
    if (i == len || !digit(s[i])) return false;
    while (i < len && digit(s[i])) i++;
  }
  *end = i;
  return true;
}

static bool word_char(uint8_t c) { return digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }

static bool only_space(const uint8_t *s, size_t len, size_t i) {
  for (; i < len; i++)
    if (!json_space(s[i])) return false;
  return true;
}

agc_json_status agc_json_parse(const uint8_t *s, size_t len, agc_value *out) {
  bool quoted = false, escaped = false;
  for (size_t i = 0; i < len; i++) {
    if (quoted && s[i] < 0x20) return AGC_JSON_CONTROL;
    if (escaped)
      escaped = false;
    else if (quoted && s[i] == '\\')
      escaped = true;
    else if (s[i] == '"')
      quoted = !quoted;
  }
  size_t i = 0;
  while (i < len && json_space(s[i])) i++;
  if (i == len) return AGC_JSON_EMPTY;
  uint8_t c = s[i];
  size_t end;
  if (c == '-' || digit(c)) {
    if (!scan_number(s, len, i, &end)) return AGC_JSON_INVALID;
    if (!only_space(s, len, end)) return AGC_JSON_TRAILING;
    return number_value(s + i, end - i, out) ? AGC_JSON_PARSED : AGC_JSON_NOT_FINITE;
  }
  if (c == 't' || c == 'f' || c == 'n') {
    const char *word = c == 't' ? "true" : c == 'f' ? "false" : "null";
    size_t n = strlen(word);
    if (len - i < n || memcmp(s + i, word, n) != 0) return AGC_JSON_INVALID;
    end = i + n;
    if (end < len && word_char(s[end])) return AGC_JSON_INVALID;
    if (!only_space(s, len, end)) return AGC_JSON_TRAILING;
    *out = c == 'n' ? leaf(AGC_JSON_NULL, agc_nil()) : leaf(AGC_JSON_BOOL, agc_bool(c == 't'));
    return AGC_JSON_PARSED;
  }
  if (c != '"' && c != '[' && c != '{') return AGC_JSON_INVALID;
  yyjson_read_err err;
  yyjson_doc *doc = yyjson_read_opts((char *)(s + i), len - i,
                                     YYJSON_READ_STOP_WHEN_DONE | YYJSON_READ_NUMBER_AS_RAW, NULL, &err);
  if (!doc) {
    if (err.code == YYJSON_READ_ERROR_MEMORY_ALLOCATION) agc_out_of_memory();
    return AGC_JSON_INVALID;
  }
  if (!only_space(s, len, i + yyjson_doc_get_read_size(doc))) {
    yyjson_doc_free(doc);
    return AGC_JSON_TRAILING;
  }
  bool finite = convert(yyjson_doc_get_root(doc), out);
  yyjson_doc_free(doc);
  return finite ? AGC_JSON_PARSED : AGC_JSON_NOT_FINITE;
}

static void put(buffer *b, const char *text, size_t n) {
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

static void put_string(buffer *b, const agc_string *s) {
  const uint8_t *data = (const uint8_t *)s->data;
  size_t start = 0;
  put(b, "\"", 1);
  for (size_t i = 0; i < s->bytes; i++) {
    uint8_t c = data[i];
    if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7F) continue;
    put(b, s->data + start, i - start);
    start = i + 1;
    char hex[8];
    const char *escape = c == '\b' ? "\\b" : c == '\n' ? "\\n" : c == '\r' ? "\\r" : c == '\f' ? "\\f"
                       : c == '\t' ? "\\t" : c == '\\' ? "\\\\" : c == '"' ? "\\\"" : NULL;
    if (!escape) {
      snprintf(hex, sizeof hex, "\\u%04x", (unsigned)c);
      escape = hex;
    }
    put(b, escape, strlen(escape));
  }
  put(b, s->data + start, s->bytes - start);
  put(b, "\"", 1);
}

static _Noreturn void not_finite(agc_vm *vm, uint32_t span) {
  agc_fail(vm, "RUNTIME-JSON-ENCODE", "cannot encode a non-finite Float", span);
}

static void put_scalar(agc_vm *vm, buffer *b, agc_value v, uint32_t span) {
  char text[AGC_SCALAR_TEXT];
  if (agc_is(v, AGC_T_JSON)) {
    const agc_json *j = agc_as_json(vm, v);
    if (j->kind == AGC_JSON_NULL) {
      put(b, "null", 4);
      return;
    }
    v = j->scalar;
  }
  if (agc_is(v, AGC_T_STRING)) {
    put_string(b, agc_as_string(vm, v));
  } else if (agc_is(v, AGC_T_NIL)) {
    put(b, "null", 4);
  } else if (agc_is(v, AGC_T_BOOL)) {
    if (agc_as_bool(vm, v))
      put(b, "true", 4);
    else
      put(b, "false", 5);
  } else if (agc_is(v, AGC_T_FLOAT)) {
    double x = agc_as_float(vm, v);
    if (!isfinite(x)) not_finite(vm, span);
    put(b, text, agc_float_text(x, text));
  } else {
    put(b, text, (size_t)snprintf(text, sizeof text, "%" PRId64, agc_as_int(vm, v)));
  }
}

static void put_big(agc_vm *vm, buffer *b, agc_value v) {
  const agc_string *s = agc_as_string(vm, agc_as_json(vm, v)->scalar);
  put(b, s->data, s->bytes);
}

static bool json_kind(agc_vm *vm, agc_value v, agc_json_kind kind) {
  return agc_is(v, AGC_T_JSON) && agc_as_json(vm, v)->kind == kind;
}

static bool open_frame(agc_vm *vm, agc_value v, walk_frame *f) {
  f->value = v;
  f->next = 0;
  f->keys = NULL;
  if (agc_is(v, AGC_T_LIST)) {
    f->n = agc_as_list(vm, v)->len;
  } else if (agc_is(v, AGC_T_MAP)) {
    const agc_map *m = agc_as_map(vm, v);
    f->n = m->size;
    f->keys = m->size ? agc_map_keys(vm, m, 0) : NULL;
  } else if (agc_is(v, AGC_T_STRUCT)) {
    f->n = agc_struct_def_of(vm, agc_as_struct(vm, v))->count;
  } else if (json_kind(vm, v, AGC_JSON_ARRAY)) {
    f->n = agc_as_list(vm, agc_as_json(vm, v)->scalar)->len;
  } else if (json_kind(vm, v, AGC_JSON_OBJECT)) {
    f->n = agc_as_json(vm, v)->count;
  } else {
    return false;
  }
  return true;
}

static bool is_object(agc_vm *vm, agc_value v) {
  return agc_is(v, AGC_T_MAP) || agc_is(v, AGC_T_STRUCT) || json_kind(vm, v, AGC_JSON_OBJECT);
}

static agc_value child(agc_vm *vm, walk_frame *f, agc_string **key) {
  size_t k = f->next;
  agc_value v = f->value, item;
  if (agc_is(v, AGC_T_LIST)) {
    *key = NULL;
    return agc_as_list(vm, v)->items[k];
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
  const agc_json *j = agc_as_json(vm, v);
  if (j->kind == AGC_JSON_ARRAY) {
    *key = NULL;
    return agc_as_list(vm, j->scalar)->items[k];
  }
  *key = j->members[k].key;
  return j->members[k].value;
}

agc_string *agc_json_encode(agc_vm *vm, agc_value root, uint32_t span) {
  buffer b;
  b.cap = 64;
  b.len = 0;
  b.data = agc_alloc_atomic(b.cap);
  size_t depth = 0, capacity = 16;
  walk_frame *stack = agc_alloc(agc_size_mul(capacity, sizeof(walk_frame)));
  agc_value item = root;
  for (;;) {
    stack = grow(stack, &capacity, depth, sizeof(walk_frame));
    if (open_frame(vm, item, &stack[depth])) {
      put(&b, is_object(vm, item) ? "{" : "[", 1);
      depth++;
    } else if (json_kind(vm, item, AGC_JSON_BIG)) {
      put_big(vm, &b, item);
    } else {
      put_scalar(vm, &b, item, span);
    }
    for (;;) {
      if (!depth) {
        agc_string *s = agc_new_string(b.len, agc_utf8_count((const uint8_t *)b.data, b.len));
        if (b.len) memcpy(s->data, b.data, b.len);
        return s;
      }
      walk_frame *top = &stack[depth - 1];
      if (top->next < top->n) break;
      put(&b, is_object(vm, top->value) ? "}" : "]", 1);
      depth--;
    }
    walk_frame *top = &stack[depth - 1];
    if (top->next) put(&b, ",", 1);
    agc_string *key;
    item = child(vm, top, &key);
    if (key) {
      put_string(&b, key);
      put(&b, ":", 1);
    }
    top->next++;
  }
}

static agc_value scalar_json(agc_vm *vm, agc_value v, uint32_t span) {
  if (agc_is(v, AGC_T_NIL)) return leaf(AGC_JSON_NULL, v);
  if (agc_is(v, AGC_T_BOOL)) return leaf(AGC_JSON_BOOL, v);
  if (agc_is(v, AGC_T_INT)) return leaf(AGC_JSON_INT, v);
  if (agc_is(v, AGC_T_FLOAT)) {
    if (!isfinite(agc_as_float(vm, v))) not_finite(vm, span);
    return leaf(AGC_JSON_FLOAT, v);
  }
  agc_as_string(vm, v);
  return leaf(AGC_JSON_STRING, v);
}

agc_value agc_json_from(agc_vm *vm, agc_value root, uint32_t span) {
  size_t depth = 0, capacity = 16;
  walk_frame *stack = agc_alloc(agc_size_mul(capacity, sizeof(walk_frame)));
  agc_value item = root;
  for (;;) {
    agc_value v;
    stack = grow(stack, &capacity, depth, sizeof(walk_frame));
    walk_frame *f = &stack[depth];
    if (agc_is(item, AGC_T_JSON)) {
      v = item;
    } else if (open_frame(vm, item, f)) {
      f->node = container(!agc_is(item, AGC_T_LIST), f->n, &f->items);
      v = agc_json_value(f->node);
      if (f->n) {
        depth++;
        agc_string *key;
        item = child(vm, f, &key);
        if (key) f->node->members[0].key = key;
        continue;
      }
    } else {
      v = scalar_json(vm, item, span);
    }
    for (;;) {
      if (depth == 0) return v;
      walk_frame *top = &stack[depth - 1];
      store(top->node, top->items, top->next, v);
      if (++top->next < top->n) {
        agc_string *key;
        item = child(vm, top, &key);
        if (key) top->node->members[top->next].key = key;
        break;
      }
      v = finish(top->node, top->n);
      depth--;
    }
  }
}

static agc_value ok(agc_value v) { return agc_result_value(true, v); }

static agc_value failure(const char *text) {
  return agc_result_value(false, agc_string_value(ascii(text, strlen(text))));
}

static agc_value builtin_parse(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  agc_value out;
  switch (agc_json_parse((const uint8_t *)s->data, s->bytes, &out)) {
    case AGC_JSON_PARSED: return ok(out);
    case AGC_JSON_CONTROL: return failure("JSON.parse: unescaped control character in a JSON string");
    case AGC_JSON_EMPTY: return failure("JSON.parse: expected a JSON value");
    case AGC_JSON_TRAILING: return failure("JSON.parse: unexpected content after the JSON value");
    case AGC_JSON_NOT_FINITE: return failure("JSON.parse: JSON number is not finite");
    default: return failure("JSON.parse: invalid JSON");
  }
}

static agc_value builtin_encode(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_string_value(agc_json_encode(vm, args[0], span));
}

static agc_value builtin_from(agc_vm *vm, agc_value *args, uint32_t span) { return agc_json_from(vm, args[0], span); }

static agc_value builtin_null(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)vm;
  (void)args;
  (void)span;
  return leaf(AGC_JSON_NULL, agc_nil());
}

static agc_value builtin_is_null(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_bool(agc_as_json(vm, args[0])->kind == AGC_JSON_NULL);
}

static agc_value builtin_get(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_json *j = agc_as_json(vm, args[0]);
  agc_string *key = agc_as_string(vm, args[1]);
  if (j->kind != AGC_JSON_OBJECT) return failure("expected a JSON object");
  size_t lo = 0, hi = j->count;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    int c = key_compare(j->members[mid].key, key);
    if (c == 0) return ok(j->members[mid].value);
    if (c < 0)
      lo = mid + 1;
    else
      hi = mid;
  }
  return agc_result_value(false, agc_string_value(agc_around("missing JSON key ", key, "")));
}

static agc_value builtin_at(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_json *j = agc_as_json(vm, args[0]);
  int64_t index = agc_as_int(vm, args[1]);
  if (j->kind != AGC_JSON_ARRAY) return failure("expected a JSON array");
  const agc_list *items = agc_as_list(vm, j->scalar);
  if (index < 0 || (uint64_t)index >= items->len) return failure("JSON array index is out of range");
  return ok(items->items[index]);
}

static agc_value extract(agc_vm *vm, agc_value v, agc_json_kind kind, const char *expected) {
  const agc_json *j = agc_as_json(vm, v);
  if (j->kind != kind) return failure(expected);
  return ok(j->scalar);
}

static agc_value builtin_string(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return extract(vm, args[0], AGC_JSON_STRING, "expected a JSON string");
}

static agc_value builtin_int(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return extract(vm, args[0], AGC_JSON_INT, "expected a signed 64-bit JSON integer");
}

static agc_value builtin_bool(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return extract(vm, args[0], AGC_JSON_BOOL, "expected a JSON boolean");
}

static agc_value builtin_list(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return extract(vm, args[0], AGC_JSON_ARRAY, "expected a JSON array");
}

static agc_value builtin_float(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_json *j = agc_as_json(vm, args[0]);
  if (j->kind == AGC_JSON_FLOAT) return ok(j->scalar);
  if (j->kind == AGC_JSON_INT) return ok(agc_float((double)agc_as_int(vm, j->scalar)));
  if (j->kind == AGC_JSON_BIG) {
    const agc_string *s = agc_as_string(vm, j->scalar);
    double x = decimal(s->data, s->bytes);
    if (isfinite(x)) return ok(agc_float(x));
  }
  return failure("expected a JSON number representable as a finite Float");
}

const agc_builtin agc_json_builtins[] = {
  {"JSON.parse", 1, builtin_parse, AGC_NATIVE_NONE},
  {"JSON.encode", 1, builtin_encode, AGC_NATIVE_NONE},
  {"JSON.from", 1, builtin_from, AGC_NATIVE_NONE},
  {"JSON.object", 1, builtin_from, AGC_NATIVE_NONE},
  {"JSON.array", 1, builtin_from, AGC_NATIVE_NONE},
  {"JSON.null", 0, builtin_null, AGC_NATIVE_NONE},
  {"JSON.null?", 1, builtin_is_null, AGC_NATIVE_NONE},
  {"JSON.get", 2, builtin_get, AGC_NATIVE_NONE},
  {"JSON.at", 2, builtin_at, AGC_NATIVE_NONE},
  {"JSON.string", 1, builtin_string, AGC_NATIVE_NONE},
  {"JSON.int", 1, builtin_int, AGC_NATIVE_NONE},
  {"JSON.float", 1, builtin_float, AGC_NATIVE_NONE},
  {"JSON.bool", 1, builtin_bool, AGC_NATIVE_NONE},
  {"JSON.list", 1, builtin_list, AGC_NATIVE_NONE},
};

const size_t agc_json_builtin_count = sizeof agc_json_builtins / sizeof agc_json_builtins[0];
