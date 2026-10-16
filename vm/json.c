/*
 * The JSON builtins (agc_json_builtins) and agc_json_parse, which builds Json
 * nodes from yyjson's reader. Service layer. Design:
 * docs/vm/02-reference-behavior.md §2.6.
 */
#include "services.h"

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
  agc_list_builder items;
} parse_frame;

const char *agc_json_version(void) { return YYJSON_VERSION_STRING; }

#ifdef AGC_NO_GC
static void *yy_malloc(void *ctx, size_t size) {
  (void)ctx;
  return agc_alloc_atomic(size);
}

static void *yy_realloc(void *ctx, void *ptr, size_t old_size, size_t size) {
  (void)ctx;
  void *p = agc_alloc_atomic(size);
  memcpy(p, ptr, old_size < size ? old_size : size);
  return p;
}

static void yy_free(void *ctx, void *ptr) {
  (void)ctx;
  (void)ptr;
}
#endif

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
      *out = agc_json_leaf(AGC_JSON_INT, agc_int(n));
    else
      *out = agc_json_leaf(AGC_JSON_BIG, agc_string_value(agc_json_ascii((const char *)s, len)));
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
  *out = agc_json_leaf(AGC_JSON_FLOAT, agc_float(x));
  return true;
}

/* A key or string of the document: the empty String and a one-character ASCII String are the shared ones. */
static agc_string *json_string(agc_vm *vm, const char *text, size_t len) {
  if (len <= 1) return agc_small_string(vm, text, len, len);
  return agc_make_string(text, len, agc_utf8_count((const uint8_t *)text, len));
}

static yyjson_val *parse_child(agc_vm *vm, parse_frame *f) {
  if (f->node->kind == AGC_JSON_ARRAY) return yyjson_arr_iter_next(&f->it.arr);
  yyjson_val *key = yyjson_obj_iter_next(&f->it.obj);
  const char *text = yyjson_get_str(key);
  size_t len = yyjson_get_len(key);
  f->node->members[f->next].key = json_string(vm, text, len);
  return yyjson_obj_iter_get_val(key);
}

static bool parse_leaf(agc_vm *vm, yyjson_val *val, agc_value *out) {
  if (yyjson_is_raw(val)) return number_value((const uint8_t *)yyjson_get_raw(val), yyjson_get_len(val), out);
  if (yyjson_is_str(val)) {
    const char *text = yyjson_get_str(val);
    size_t len = yyjson_get_len(val);
    *out = agc_json_leaf(AGC_JSON_STRING, agc_string_value(json_string(vm, text, len)));
  } else if (yyjson_is_bool(val)) {
    *out = agc_json_leaf(AGC_JSON_BOOL, agc_bool(yyjson_get_bool(val)));
  } else {
    *out = agc_json_leaf(AGC_JSON_NULL, agc_nil());
  }
  return true;
}

static bool convert(agc_vm *vm, yyjson_val *val, agc_value *out) {
  size_t depth = 0, capacity = 16;
  parse_frame *stack = agc_alloc(agc_size_mul(capacity, sizeof(parse_frame)));
  for (;;) {
    agc_value v;
    if (yyjson_is_arr(val) || yyjson_is_obj(val)) {
      bool object = yyjson_is_obj(val);
      size_t n = yyjson_get_len(val);
      agc_list_builder items;
      agc_json *node = agc_json_container(object, n, &items);
      if (!n) {
        v = agc_json_value(node);
      } else {
        stack = agc_json_grow(stack, &capacity, depth, sizeof(parse_frame));
        parse_frame *f = &stack[depth++];
        f->next = 0;
        f->n = n;
        f->node = node;
        f->items = items;
        if (object)
          yyjson_obj_iter_init(val, &f->it.obj);
        else
          yyjson_arr_iter_init(val, &f->it.arr);
        val = parse_child(vm, f);
        continue;
      }
    } else if (!parse_leaf(vm, val, &v)) {
      return false;
    }
    for (;;) {
      if (depth == 0) {
        *out = v;
        return true;
      }
      parse_frame *f = &stack[depth - 1];
      agc_json_store(f->node, &f->items, f->next, v);
      if (++f->next < f->n) {
        val = parse_child(vm, f);
        break;
      }
      v = agc_json_finish(f->node, &f->items, f->n);
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

agc_json_status agc_json_parse(agc_vm *vm, const uint8_t *s, size_t len, agc_value *out) {
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
    *out = c == 'n' ? agc_json_leaf(AGC_JSON_NULL, agc_nil()) : agc_json_leaf(AGC_JSON_BOOL, agc_bool(c == 't'));
    return AGC_JSON_PARSED;
  }
  if (c != '"' && c != '[' && c != '{') return AGC_JSON_INVALID;
  yyjson_read_err err;
#ifdef AGC_NO_GC
  yyjson_alc alc = {yy_malloc, yy_realloc, yy_free, NULL};
  const yyjson_alc *use = &alc;
#else
  const yyjson_alc *use = NULL;
#endif
  yyjson_doc *doc = yyjson_read_opts((char *)(s + i), len - i,
                                     YYJSON_READ_STOP_WHEN_DONE | YYJSON_READ_NUMBER_AS_RAW, use, &err);
  if (!doc) {
    if (err.code == YYJSON_READ_ERROR_MEMORY_ALLOCATION) agc_out_of_memory();
    return AGC_JSON_INVALID;
  }
  if (!only_space(s, len, i + yyjson_doc_get_read_size(doc))) {
    yyjson_doc_free(doc);
    return AGC_JSON_TRAILING;
  }
  bool finite = convert(vm, yyjson_doc_get_root(doc), out);
  yyjson_doc_free(doc);
  return finite ? AGC_JSON_PARSED : AGC_JSON_NOT_FINITE;
}

static agc_value ok(agc_value v) { return agc_result_value(true, v); }

static agc_value failure(const char *text) {
  return agc_result_value(false, agc_string_value(agc_json_ascii(text, strlen(text))));
}

const char *agc_json_status_message(agc_json_status status) {
  switch (status) {
    case AGC_JSON_CONTROL: return "JSON.parse: unescaped control character in a JSON string";
    case AGC_JSON_EMPTY: return "JSON.parse: expected a JSON value";
    case AGC_JSON_TRAILING: return "JSON.parse: unexpected content after the JSON value";
    case AGC_JSON_NOT_FINITE: return "JSON.parse: JSON number is not finite";
    default: return "JSON.parse: invalid JSON";
  }
}

static agc_value builtin_parse(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *s = agc_as_string(vm, args[0]);
  agc_value out;
  agc_json_status status = agc_json_parse(vm, (const uint8_t *)s->data, s->bytes, &out);
  return status == AGC_JSON_PARSED ? ok(out) : failure(agc_json_status_message(status));
}

static uint32_t decodable_struct(agc_vm *vm, agc_value name, uint32_t span) {
  const agc_string *text = agc_as_string(vm, name);
  const agc_program *p = vm->rt->program;
  for (uint32_t i = 0; i < p->struct_count; i++) {
    const agc_string *json_name = p->structs[i].json_name;
    if (json_name && json_name->bytes == text->bytes && memcmp(json_name->data, text->data, text->bytes) == 0)
      return i;
  }
  agc_fail(vm, "RUNTIME-INTERNAL", "unknown JSON type", span);
}

static agc_value builtin_decode(agc_vm *vm, agc_value *args, uint32_t span) {
  uint32_t type = decodable_struct(vm, args[1], span + 2);
  const agc_string *s = agc_as_string(vm, args[0]);
  agc_value root;
  agc_json_status status = agc_json_parse(vm, (const uint8_t *)s->data, s->bytes, &root);
  if (status != AGC_JSON_PARSED) return failure(agc_json_status_message(status));
  return agc_json_decode(vm, root, type);
}

static agc_value builtin_schema(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_json_schema(vm, decodable_struct(vm, args[0], span + 1));
}

static agc_value builtin_encode(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_string_value(agc_json_encode(vm, args[0], span));
}

static agc_value builtin_from(agc_vm *vm, agc_value *args, uint32_t span) { return agc_json_from(vm, args[0], span); }

static agc_value builtin_null(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)vm;
  (void)args;
  (void)span;
  return agc_json_leaf(AGC_JSON_NULL, agc_nil());
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
  const agc_json_member *member = agc_json_find(j, key);
  if (member) return ok(member->value);
  return agc_result_value(false, agc_string_value(agc_around("missing JSON key ", key, "")));
}

static agc_value builtin_at(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_json *j = agc_as_json(vm, args[0]);
  int64_t index = agc_as_int(vm, args[1]);
  if (j->kind != AGC_JSON_ARRAY) return failure("expected a JSON array");
  const agc_list *items = agc_as_list(vm, j->scalar);
  if (index < 0 || (uint64_t)index >= agc_list_len(items)) return failure("JSON array index is out of range");
  return ok(agc_list_get(items, (size_t)index));
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

bool agc_json_to_float(agc_vm *vm, const agc_json *j, double *out) {
  if (j->kind == AGC_JSON_FLOAT) {
    *out = agc_as_float(vm, j->scalar);
    return true;
  }
  if (j->kind == AGC_JSON_INT) {
    *out = (double)agc_as_int(vm, j->scalar);
    return true;
  }
  if (j->kind != AGC_JSON_BIG) return false;
  const agc_string *s = agc_as_string(vm, j->scalar);
  *out = decimal(s->data, s->bytes);
  return isfinite(*out);
}

static agc_value builtin_float(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  double x;
  if (agc_json_to_float(vm, agc_as_json(vm, args[0]), &x)) return ok(agc_float(x));
  return failure("expected a JSON number representable as a finite Float");
}

const agc_builtin agc_json_builtins[] = {
  {"JSON.parse", 1, builtin_parse, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"JSON.encode", 1, builtin_encode, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.from", 1, builtin_from, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.object", 1, builtin_from, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.array", 1, builtin_from, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.null", 0, builtin_null, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.null?", 1, builtin_is_null, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.get", 2, builtin_get, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"JSON.at", 2, builtin_at, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.string", 1, builtin_string, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.int", 1, builtin_int, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.float", 1, builtin_float, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.bool", 1, builtin_bool, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.list", 1, builtin_list, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"JSON.decode", 2, builtin_decode, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"JSON.schema", 1, builtin_schema, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_json_builtin_count = sizeof agc_json_builtins / sizeof agc_json_builtins[0];
