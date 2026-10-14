#include "core.h"

#include <string.h>

static agc_string *text_of(agc_vm *vm, agc_value v) {
  if (agc_is(v, AGC_T_NIL) || agc_is(v, AGC_T_BOOL) || agc_is(v, AGC_T_INT) || agc_is(v, AGC_T_FLOAT)) {
    char text[AGC_SCALAR_TEXT];
    size_t n = agc_scalar_text(vm, v, text);
    return agc_make_string(text, n, n);
  }
  return agc_text(vm, v);
}

static void write_text(agc_vm *vm, agc_output *out, agc_value v, bool newline) {
  agc_write(vm, out, agc_output_waiting(vm, out) ? NULL : text_of(vm, v), newline);
}

static agc_value builtin_puts(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  write_text(vm, &vm->rt->out, args[0], true);
  return agc_void();
}

static agc_value builtin_print(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  write_text(vm, &vm->rt->out, args[0], false);
  return agc_void();
}

static agc_value builtin_warn(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  write_text(vm, &vm->rt->err, args[0], true);
  return agc_void();
}

static agc_value builtin_inspect(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_value v = args[0];
  agc_write(vm, &vm->rt->out, agc_output_waiting(vm, &vm->rt->out) ? NULL : agc_debug(vm, v), true);
  return v;
}

static const char end_of_input[] = "IO.gets reached the end of input";

static agc_value builtin_gets(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  agc_string *line = NULL;
  agc_input_status status = agc_input_line(vm, &line);
  if (status == AGC_INPUT_WAIT) return agc_void();
  if (status == AGC_INPUT_OK) return agc_result_value(true, agc_string_value(line));
  size_t n = sizeof end_of_input - 1;
  return agc_result_value(false, agc_string_value(agc_make_string(end_of_input, n, n)));
}

static agc_value builtin_gets_bang(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  agc_string *line = NULL;
  agc_input_status status = agc_input_line(vm, &line);
  if (status == AGC_INPUT_WAIT) return agc_void();
  if (status != AGC_INPUT_OK) agc_fail(vm, "RUNTIME-END-OF-INPUT", end_of_input, span);
  return agc_string_value(line);
}

static agc_value builtin_read(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  agc_string *text = NULL;
  if (agc_input_all(vm, &text) == AGC_INPUT_WAIT) return agc_void();
  return agc_string_value(text);
}

static agc_value text_error(const char *text) {
  size_t n = strlen(text);
  return agc_result_value(false, agc_string_value(agc_make_string(text, n, n)));
}

static agc_value builtin_read_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t count = agc_as_int(vm, args[0]);
  if (count < 0 || count > AGC_MAX_READ_BYTES) return text_error("byte count must be between 0 and 1048576");
  agc_list *bytes = NULL;
  agc_input_status status = agc_input_bytes(vm, (size_t)count, &bytes);
  if (status == AGC_INPUT_WAIT) return agc_void();
  if (status == AGC_INPUT_FAILED) return text_error("input read failed");
  return agc_result_value(true, agc_list_value(bytes));
}

static agc_value builtin_flush(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  agc_drain(vm);
  return agc_void();
}

static agc_value builtin_eof(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  int byte;
  agc_input_status status = agc_input_peek(vm, &byte);
  if (status == AGC_INPUT_WAIT) return agc_void();
  return agc_bool(status == AGC_INPUT_EOF);
}

static agc_value builtin_args(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return vm->rt->args;
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
  const agc_list *a = agc_as_list(vm, args[0]);
  const agc_list *b = agc_as_list(vm, args[1]);
  if (agc_list_len(b) > AGC_LIST_WIDTH) agc_charge(vm, 2 * ((uint64_t)agc_list_len(a) + agc_list_len(b)));
  return agc_list_value(agc_list_concat(a, b));
}

static agc_value builtin_map_put(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_map_value(agc_map_put(vm, agc_as_map(vm, args[0]), args[1], args[2]));
}

static agc_value builtin_list_size(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int((int64_t)agc_list_len(agc_as_list(vm, args[0])));
}

static agc_value builtin_list_append(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_list_value(agc_list_append(agc_as_list(vm, args[0]), args[1]));
}

static size_t list_index(agc_vm *vm, const agc_list *l, agc_value index, uint32_t span) {
  int64_t i = agc_as_int(vm, index);
  if (i < 0 || (uint64_t)i >= agc_list_len(l))
    agc_fail(vm, "RUNTIME-INDEX-OUT-OF-RANGE", "list index is out of range", span + 2);
  return (size_t)i;
}

static agc_value builtin_list_at(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *a = agc_as_list(vm, args[0]);
  return agc_list_get(a, list_index(vm, a, args[1], span));
}

static agc_value builtin_list_set(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *a = agc_as_list(vm, args[0]);
  size_t k = list_index(vm, a, args[1], span);
  return agc_list_value(agc_list_set(a, k, args[2]));
}

static agc_value builtin_list_repeat(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t count = agc_as_int(vm, args[1]);
  if (count < 0 || count > AGC_MAX_LIST_COUNT)
    agc_fail(vm, "RUNTIME-INVALID-COUNT", "count must be between 0 and 1048576", span + 2);
  agc_list_builder b;
  agc_list_builder_sized(&b, (size_t)count);
  for (size_t k = 0; k < (size_t)count; k++) agc_list_builder_push(&b, args[0]);
  return agc_list_value(agc_list_builder_finish(&b));
}

static size_t list_count(agc_vm *vm, const agc_list *l, agc_value count, uint32_t span) {
  int64_t n = agc_as_int(vm, count);
  if (n < 0) agc_fail(vm, "RUNTIME-INVALID-COUNT", "count must be nonnegative", span + 2);
  size_t len = agc_list_len(l);
  return (uint64_t)n < len ? (size_t)n : len;
}

static agc_value builtin_list_take(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *a = agc_as_list(vm, args[0]);
  return agc_list_value(agc_list_slice(a, 0, list_count(vm, a, args[1], span)));
}

static agc_value builtin_list_drop(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *a = agc_as_list(vm, args[0]);
  size_t k = list_count(vm, a, args[1], span);
  return agc_list_value(agc_list_slice(a, k, agc_list_len(a) - k));
}

static agc_value builtin_list_reverse(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *a = agc_as_list(vm, args[0]);
  size_t n = agc_list_len(a);
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&b, agc_list_get(a, n - 1 - k));
  return agc_list_value(agc_list_builder_finish(&b));
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
  agc_list_builder b;
  agc_list_builder_sized(&b, m->size);
  for (size_t k = 0; k < m->size; k++) {
    agc_value item = keys[k];
    if (values && !agc_map_get(vm, m, keys[k], &item))
      agc_fail(vm, "RUNTIME-INTERNAL", "map key list does not match its table", span);
    agc_list_builder_push(&b, item);
  }
  return agc_list_value(agc_list_builder_finish(&b));
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
  agc_list_builder b;
  agc_list_builder_sized(&b, (size_t)size);
  int64_t first = agc_as_range(vm, args[0])->start;
  for (size_t k = 0; k < (size_t)size; k++) agc_list_builder_push(&b, agc_int(first + (int64_t)k));
  return agc_list_value(agc_list_builder_finish(&b));
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

const agc_builtin agc_core_builtins[] = {
  {"puts", 1, builtin_puts, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"IO.print", 1, builtin_print, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"IO.warn", 1, builtin_warn, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"IO.inspect", 1, builtin_inspect, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"IO.gets", 0, builtin_gets, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"IO.gets!", 0, builtin_gets_bang, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"IO.read", 0, builtin_read, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"IO.read_bytes", 1, builtin_read_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"IO.flush", 0, builtin_flush, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"IO.eof?", 0, builtin_eof, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"System.args", 0, builtin_args, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"System.exit", 1, builtin_exit, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"String.from_int", 1, builtin_from_int, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"String.from_float", 1, builtin_from_float, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"List.concat", 2, builtin_list_concat, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Map.put", 3, builtin_map_put, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"List.size", 1, builtin_list_size, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"List.append", 2, builtin_list_append, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"List.at", 2, builtin_list_at, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"List.set", 3, builtin_list_set, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"List.repeat", 2, builtin_list_repeat, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"List.take", 2, builtin_list_take, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"List.drop", 2, builtin_list_drop, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"List.reverse", 1, builtin_list_reverse, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"List.sort", 1, builtin_list_sort, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Map.has_key?", 2, builtin_map_has_key, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Map.size", 1, builtin_map_size, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Map.keys", 1, builtin_map_keys, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Map.values", 1, builtin_map_values, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Map.get", 2, builtin_map_get, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Map.get", 3, builtin_map_get_default, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Map.delete", 2, builtin_map_delete, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"ok", 1, builtin_ok, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"ok", 0, builtin_ok_void, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"error", 1, builtin_error, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Result.ok?", 1, builtin_result_ok, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Result.unwrap!", 1, builtin_result_unwrap, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Result.unwrap_or", 2, builtin_result_unwrap_or, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Result.message", 1, builtin_result_message, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"List.map", 2, NULL, AGC_NATIVE_MAP, AGC_COST_NONE},
  {"List.filter", 2, NULL, AGC_NATIVE_FILTER, AGC_COST_NONE},
  {"List.reduce", 3, NULL, AGC_NATIVE_REDUCE, AGC_COST_NONE},
  {"List.each", 2, NULL, AGC_NATIVE_EACH, AGC_COST_NONE},
  {"List.any?", 2, NULL, AGC_NATIVE_ANY, AGC_COST_NONE},
  {"List.all?", 2, NULL, AGC_NATIVE_ALL, AGC_COST_NONE},
  {"List.sort_by", 2, NULL, AGC_NATIVE_SORT_BY, AGC_COST_NONE},
  {"Range.size", 1, builtin_range_size, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Range.to_a", 1, builtin_range_to_a, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Range.include?", 2, builtin_range_include, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Range.first", 1, builtin_range_first, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Range.last", 1, builtin_range_last, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Range.each", 2, NULL, AGC_NATIVE_RANGE_EACH, AGC_COST_NONE},
  {"Int.times", 2, NULL, AGC_NATIVE_TIMES, AGC_COST_NONE},
  {"Int.upto", 3, NULL, AGC_NATIVE_UPTO, AGC_COST_NONE},
  {"Int.downto", 3, NULL, AGC_NATIVE_DOWNTO, AGC_COST_NONE},
};

const size_t agc_core_builtin_count = sizeof agc_core_builtins / sizeof agc_core_builtins[0];

const agc_builtin *agc_find_builtin(const uint8_t *name, size_t len, uint32_t arity) {
  for (size_t t = 0; t < agc_builtin_table_count; t++) {
    for (size_t i = 0; i < *agc_builtin_tables[t].count; i++) {
      const agc_builtin *b = &agc_builtin_tables[t].entries[i];
      if (b->arity == arity && strlen(b->name) == len && memcmp(b->name, name, len) == 0) return b;
    }
  }
  return NULL;
}

uint32_t agc_builtin_struct(agc_vm *vm, const char *name, const char *const *fields, uint32_t count) {
  const agc_program *p = vm->rt->program;
  for (uint32_t k = 0; k < p->struct_count; k++) {
    const agc_struct_def *d = &p->structs[k];
    if (d->name->bytes != strlen(name) || memcmp(d->name->data, name, d->name->bytes) != 0 || d->count != count) continue;
    bool same = true;
    for (uint32_t f = 0; f < count; f++)
      same = same && d->fields[f]->bytes == strlen(fields[f]) && memcmp(d->fields[f]->data, fields[f], d->fields[f]->bytes) == 0;
    if (same) return k;
  }
  size_t size = agc_size_add(strlen(name), 48);
  char *message = agc_alloc_atomic(size);
  snprintf(message, size, "invalid bytecode: the %s struct is missing", name);
  agc_fail(vm, "RUNTIME-INTERNAL", message, 0);
}

static bool named(const agc_string *s, const char *text) { return s->bytes == strlen(text) && memcmp(s->data, text, s->bytes) == 0; }

uint32_t agc_builtin_variant(agc_vm *vm, const char *enum_name, const char *variant_name, uint32_t arity) {
  const agc_program *p = vm->rt->program;
  for (uint32_t k = 0; k < p->enum_count; k++) {
    const agc_enum_def *d = &p->enums[k];
    if (!named(d->name, enum_name)) continue;
    for (uint32_t v = d->first; v < d->first + d->count; v++)
      if (named(p->variants[v].name, variant_name) && p->variants[v].arity == arity) return v;
  }
  size_t size = agc_size_add(strlen(enum_name), 48);
  char *message = agc_alloc_atomic(size);
  snprintf(message, size, "invalid bytecode: the %s enum is missing", enum_name);
  agc_fail(vm, "RUNTIME-INTERNAL", message, 0);
}
