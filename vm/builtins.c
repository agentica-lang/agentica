#include "agc.h"

#include <string.h>

typedef struct {
  const agc_builtin *entries;
  const size_t *count;
} builtin_table;

static void write_text(agc_vm *vm, FILE *stream, agc_value v, bool newline) {
  if (!agc_is(v, AGC_T_NIL) && !agc_is(v, AGC_T_BOOL) && !agc_is(v, AGC_T_INT) && !agc_is(v, AGC_T_FLOAT)) {
    agc_string *s = agc_text(vm, v);
    agc_write(vm, stream, s->data, s->bytes);
  } else {
    char text[AGC_SCALAR_TEXT];
    agc_write(vm, stream, text, agc_scalar_text(vm, v, text));
  }
  if (newline) agc_write(vm, stream, "\n", 1);
}

static agc_value builtin_puts(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  write_text(vm, vm->out, args[0], true);
  return agc_void();
}

static agc_value builtin_print(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  write_text(vm, vm->out, args[0], false);
  return agc_void();
}

static agc_value builtin_warn(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  write_text(vm, vm->err, args[0], true);
  return agc_void();
}

static agc_value builtin_inspect(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_value v = args[0];
  agc_string *s = agc_debug(vm, v);
  agc_write(vm, vm->out, s->data, s->bytes);
  agc_write(vm, vm->out, "\n", 1);
  return v;
}

static const char end_of_input[] = "IO.gets reached the end of input";

static agc_value builtin_gets(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  agc_string *line = agc_input_line(vm);
  if (line) return agc_result_value(true, agc_string_value(line));
  size_t n = sizeof end_of_input - 1;
  return agc_result_value(false, agc_string_value(agc_make_string(end_of_input, n, n)));
}

static agc_value builtin_gets_bang(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  agc_string *line = agc_input_line(vm);
  if (!line) agc_fail(vm, "RUNTIME-END-OF-INPUT", end_of_input, span);
  return agc_string_value(line);
}

static agc_value builtin_read(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_string_value(agc_input_all(vm));
}

static agc_value text_error(const char *text) {
  size_t n = strlen(text);
  return agc_result_value(false, agc_string_value(agc_make_string(text, n, n)));
}

static agc_value builtin_read_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t count = agc_as_int(vm, args[0]);
  if (count < 0 || count > AGC_MAX_READ_BYTES) return text_error("byte count must be between 0 and 1048576");
  agc_list *bytes;
  if (!agc_input_bytes(vm, (size_t)count, &bytes)) return text_error("input read failed");
  return agc_result_value(true, agc_list_value(bytes));
}

static agc_value builtin_flush(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  agc_flush(vm);
  return agc_void();
}

static agc_value builtin_eof(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_bool(agc_input_peek(vm) < 0);
}

static agc_value builtin_args(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return vm->args;
}

static agc_value builtin_exit(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_exit(vm, agc_as_int(vm, args[0]));
}

static agc_value builtin_from_int(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_string_value(agc_text(vm, agc_int(agc_as_int(vm, args[0]))));
}

static agc_value builtin_from_float(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_string_value(agc_text(vm, agc_float(agc_as_float(vm, args[0]))));
}

static agc_value builtin_list_concat(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *a = agc_as_list(vm, args[0]), *b = agc_as_list(vm, args[1]);
  agc_list *l = agc_new_list(agc_size_add(a->len, b->len));
  if (a->len) memcpy(l->items, a->items, a->len * sizeof(agc_value));
  if (b->len) memcpy(l->items + a->len, b->items, b->len * sizeof(agc_value));
  return agc_list_value(l);
}

static agc_value builtin_map_put(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_map_value(agc_map_put(vm, agc_as_map(vm, args[0]), args[1], args[2]));
}

static agc_list *list_slice(const agc_list *src, size_t from, size_t len, size_t extra) {
  agc_list *l = agc_new_list(agc_size_add(len, extra));
  if (len) memcpy(l->items, src->items + from, len * sizeof(agc_value));
  return l;
}

static agc_value builtin_list_size(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int((int64_t)agc_as_list(vm, args[0])->len);
}

static agc_value builtin_list_append(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *a = agc_as_list(vm, args[0]);
  agc_list *l = list_slice(a, 0, a->len, 1);
  l->items[a->len] = args[1];
  return agc_list_value(l);
}

static size_t list_index(agc_vm *vm, const agc_list *l, agc_value index, uint32_t span) {
  int64_t i = agc_as_int(vm, index);
  if (i < 0 || (uint64_t)i >= l->len) agc_fail(vm, "RUNTIME-INDEX-OUT-OF-RANGE", "list index is out of range", span + 2);
  return (size_t)i;
}

static agc_value builtin_list_at(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *a = agc_as_list(vm, args[0]);
  return a->items[list_index(vm, a, args[1], span)];
}

static agc_value builtin_list_set(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *a = agc_as_list(vm, args[0]);
  size_t k = list_index(vm, a, args[1], span);
  agc_list *l = list_slice(a, 0, a->len, 0);
  l->items[k] = args[2];
  return agc_list_value(l);
}

static agc_value builtin_list_repeat(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t count = agc_as_int(vm, args[1]);
  if (count < 0 || count > AGC_MAX_LIST_COUNT)
    agc_fail(vm, "RUNTIME-INVALID-COUNT", "count must be between 0 and 1048576", span + 2);
  agc_list *l = agc_new_list((size_t)count);
  for (size_t k = 0; k < (size_t)count; k++) l->items[k] = args[0];
  return agc_list_value(l);
}

static size_t list_count(agc_vm *vm, const agc_list *l, agc_value count, uint32_t span) {
  int64_t n = agc_as_int(vm, count);
  if (n < 0) agc_fail(vm, "RUNTIME-INVALID-COUNT", "count must be nonnegative", span + 2);
  return (uint64_t)n < l->len ? (size_t)n : l->len;
}

static agc_value builtin_list_take(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *a = agc_as_list(vm, args[0]);
  return agc_list_value(list_slice(a, 0, list_count(vm, a, args[1], span), 0));
}

static agc_value builtin_list_drop(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *a = agc_as_list(vm, args[0]);
  size_t k = list_count(vm, a, args[1], span);
  return agc_list_value(list_slice(a, k, a->len - k, 0));
}

static agc_value builtin_list_reverse(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *a = agc_as_list(vm, args[0]);
  agc_list *l = agc_new_list(a->len);
  for (size_t k = 0; k < a->len; k++) l->items[k] = a->items[a->len - 1 - k];
  return agc_list_value(l);
}

static agc_value builtin_list_sort(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *a = agc_as_list(vm, args[0]);
  return agc_sort_by_keys(vm, a, a);
}

static agc_value builtin_map_has_key(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_value value;
  return agc_bool(agc_map_get(vm, agc_as_map(vm, args[0]), args[1], &value));
}

static agc_value builtin_map_size(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int((int64_t)agc_as_map(vm, args[0])->size);
}

static agc_value map_walk(agc_vm *vm, agc_value map, bool values, uint32_t span) {
  const agc_map *m = agc_as_map(vm, map);
  agc_value *keys = agc_map_keys(vm, m, span);
  agc_list *l = agc_new_list(m->size);
  for (size_t k = 0; k < m->size; k++) {
    l->items[k] = keys[k];
    if (values && !agc_map_get(vm, m, keys[k], &l->items[k]))
      agc_fail(vm, "RUNTIME-INTERNAL", "map key list does not match its table", span);
  }
  return agc_list_value(l);
}

static agc_value builtin_map_keys(agc_vm *vm, agc_value *args, uint32_t span) {
  return map_walk(vm, args[0], false, span);
}

static agc_value builtin_map_values(agc_vm *vm, agc_value *args, uint32_t span) {
  return map_walk(vm, args[0], true, span);
}

static agc_string *ascii(const char *text) {
  size_t n = strlen(text);
  return agc_make_string(text, n, n);
}

static agc_value builtin_map_get(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_value value;
  if (agc_map_get(vm, agc_as_map(vm, args[0]), args[1], &value)) return agc_result_value(true, value);
  agc_string *message = agc_concat(agc_concat(ascii("key "), agc_debug(vm, args[1])), ascii(" is not in the map"));
  return agc_result_value(false, agc_string_value(message));
}

static agc_value builtin_map_get_default(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_value value;
  return agc_map_get(vm, agc_as_map(vm, args[0]), args[1], &value) ? value : args[2];
}

static agc_value builtin_map_delete(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_map_value(agc_map_delete(vm, agc_as_map(vm, args[0]), args[1]));
}

static agc_value builtin_ok(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)vm;
  (void)span;
  return agc_result_value(true, args[0]);
}

static agc_value builtin_ok_void(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)vm;
  (void)args;
  (void)span;
  return agc_result_value(true, agc_void());
}

static agc_value builtin_error(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_as_string(vm, args[0]);
  return agc_result_value(false, args[0]);
}

static agc_value builtin_result_ok(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_bool(agc_as_result(vm, args[0])->ok);
}

static agc_value builtin_result_unwrap(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_result *r = agc_as_result(vm, args[0]);
  if (!r->ok) agc_fail_text(vm, "RUNTIME-UNWRAP-ERROR", agc_as_string(vm, r->value), span);
  return r->value;
}

static agc_value builtin_result_unwrap_or(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_result *r = agc_as_result(vm, args[0]);
  return r->ok ? r->value : args[1];
}

static agc_value builtin_result_message(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_result *r = agc_as_result(vm, args[0]);
  if (r->ok) return agc_string_value(agc_new_string(0, 0));
  return r->value;
}

static bool range_size(agc_vm *vm, agc_value v, uint64_t *size) {
  int64_t first, last;
  if (!agc_range_bounds(agc_as_range(vm, v), &first, &last)) {
    *size = 0;
    return true;
  }
  uint64_t gap = (uint64_t)last - (uint64_t)first;
  if (gap >= (uint64_t)INT64_MAX) return false;
  *size = gap + 1;
  return true;
}

static agc_value builtin_range_size(agc_vm *vm, agc_value *args, uint32_t span) {
  uint64_t size;
  if (!range_size(vm, args[0], &size))
    agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "Int result is outside the 64-bit range", span + 1);
  return agc_int((int64_t)size);
}

static agc_value builtin_range_to_a(agc_vm *vm, agc_value *args, uint32_t span) {
  uint64_t size;
  if (!range_size(vm, args[0], &size) || size > (uint64_t)AGC_MAX_LIST_COUNT)
    agc_fail(vm, "RUNTIME-INVALID-COUNT", "to_a needs a range of at most 1048576 values", span + 1);
  agc_list *l = agc_new_list((size_t)size);
  int64_t first = agc_as_range(vm, args[0])->start;
  for (size_t k = 0; k < (size_t)size; k++) l->items[k] = agc_int(first + (int64_t)k);
  return agc_list_value(l);
}

static agc_value builtin_range_include(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t first, last, x = agc_as_int(vm, args[1]);
  bool more = agc_range_bounds(agc_as_range(vm, args[0]), &first, &last);
  return agc_bool(more && first <= x && x <= last);
}

static agc_value range_end(agc_vm *vm, agc_value v, bool first_end) {
  int64_t first, last;
  if (!agc_range_bounds(agc_as_range(vm, v), &first, &last)) return text_error("the range is empty");
  return agc_result_value(true, agc_int(first_end ? first : last));
}

static agc_value builtin_range_first(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return range_end(vm, args[0], true);
}

static agc_value builtin_range_last(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return range_end(vm, args[0], false);
}

static const agc_builtin table[] = {
  {"puts", 1, builtin_puts, AGC_NATIVE_NONE},
  {"IO.print", 1, builtin_print, AGC_NATIVE_NONE},
  {"IO.warn", 1, builtin_warn, AGC_NATIVE_NONE},
  {"IO.inspect", 1, builtin_inspect, AGC_NATIVE_NONE},
  {"IO.gets", 0, builtin_gets, AGC_NATIVE_NONE},
  {"IO.gets!", 0, builtin_gets_bang, AGC_NATIVE_NONE},
  {"IO.read", 0, builtin_read, AGC_NATIVE_NONE},
  {"IO.read_bytes", 1, builtin_read_bytes, AGC_NATIVE_NONE},
  {"IO.flush", 0, builtin_flush, AGC_NATIVE_NONE},
  {"IO.eof?", 0, builtin_eof, AGC_NATIVE_NONE},
  {"System.args", 0, builtin_args, AGC_NATIVE_NONE},
  {"System.exit", 1, builtin_exit, AGC_NATIVE_NONE},
  {"String.from_int", 1, builtin_from_int, AGC_NATIVE_NONE},
  {"String.from_float", 1, builtin_from_float, AGC_NATIVE_NONE},
  {"List.concat", 2, builtin_list_concat, AGC_NATIVE_NONE},
  {"Map.put", 3, builtin_map_put, AGC_NATIVE_NONE},
  {"List.size", 1, builtin_list_size, AGC_NATIVE_NONE},
  {"List.append", 2, builtin_list_append, AGC_NATIVE_NONE},
  {"List.at", 2, builtin_list_at, AGC_NATIVE_NONE},
  {"List.set", 3, builtin_list_set, AGC_NATIVE_NONE},
  {"List.repeat", 2, builtin_list_repeat, AGC_NATIVE_NONE},
  {"List.take", 2, builtin_list_take, AGC_NATIVE_NONE},
  {"List.drop", 2, builtin_list_drop, AGC_NATIVE_NONE},
  {"List.reverse", 1, builtin_list_reverse, AGC_NATIVE_NONE},
  {"List.sort", 1, builtin_list_sort, AGC_NATIVE_NONE},
  {"Map.has_key?", 2, builtin_map_has_key, AGC_NATIVE_NONE},
  {"Map.size", 1, builtin_map_size, AGC_NATIVE_NONE},
  {"Map.keys", 1, builtin_map_keys, AGC_NATIVE_NONE},
  {"Map.values", 1, builtin_map_values, AGC_NATIVE_NONE},
  {"Map.get", 2, builtin_map_get, AGC_NATIVE_NONE},
  {"Map.get", 3, builtin_map_get_default, AGC_NATIVE_NONE},
  {"Map.delete", 2, builtin_map_delete, AGC_NATIVE_NONE},
  {"ok", 1, builtin_ok, AGC_NATIVE_NONE},
  {"ok", 0, builtin_ok_void, AGC_NATIVE_NONE},
  {"error", 1, builtin_error, AGC_NATIVE_NONE},
  {"Result.ok?", 1, builtin_result_ok, AGC_NATIVE_NONE},
  {"Result.unwrap!", 1, builtin_result_unwrap, AGC_NATIVE_NONE},
  {"Result.unwrap_or", 2, builtin_result_unwrap_or, AGC_NATIVE_NONE},
  {"Result.message", 1, builtin_result_message, AGC_NATIVE_NONE},
  {"List.map", 2, NULL, AGC_NATIVE_MAP},
  {"List.filter", 2, NULL, AGC_NATIVE_FILTER},
  {"List.reduce", 3, NULL, AGC_NATIVE_REDUCE},
  {"List.each", 2, NULL, AGC_NATIVE_EACH},
  {"List.any?", 2, NULL, AGC_NATIVE_ANY},
  {"List.all?", 2, NULL, AGC_NATIVE_ALL},
  {"List.sort_by", 2, NULL, AGC_NATIVE_SORT_BY},
  {"Range.size", 1, builtin_range_size, AGC_NATIVE_NONE},
  {"Range.to_a", 1, builtin_range_to_a, AGC_NATIVE_NONE},
  {"Range.include?", 2, builtin_range_include, AGC_NATIVE_NONE},
  {"Range.first", 1, builtin_range_first, AGC_NATIVE_NONE},
  {"Range.last", 1, builtin_range_last, AGC_NATIVE_NONE},
  {"Range.each", 2, NULL, AGC_NATIVE_RANGE_EACH},
  {"Int.times", 2, NULL, AGC_NATIVE_TIMES},
  {"Int.upto", 3, NULL, AGC_NATIVE_UPTO},
  {"Int.downto", 3, NULL, AGC_NATIVE_DOWNTO},
};

static const size_t table_count = sizeof table / sizeof table[0];

static const builtin_table tables[] = {
  {table, &table_count},
  {agc_string_builtins, &agc_string_builtin_count},
  {agc_number_builtins, &agc_number_builtin_count},
  {agc_json_builtins, &agc_json_builtin_count},
  {agc_file_builtins, &agc_file_builtin_count},
};

const agc_builtin *agc_find_builtin(const uint8_t *name, size_t len, uint32_t arity) {
  for (size_t t = 0; t < sizeof tables / sizeof tables[0]; t++) {
    for (size_t i = 0; i < *tables[t].count; i++) {
      const agc_builtin *b = &tables[t].entries[i];
      if (b->arity == arity && strlen(b->name) == len && memcmp(b->name, name, len) == 0) return b;
    }
  }
  return NULL;
}
