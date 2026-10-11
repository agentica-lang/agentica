#include "agc.h"

#include <string.h>

static void write_text(agc_vm *vm, FILE *stream, agc_value v, bool newline) {
  if (!agc_is(v, AGC_T_NIL) && !agc_is(v, AGC_T_BOOL) && !agc_is(v, AGC_T_INT) && !agc_is(v, AGC_T_FLOAT)) {
    agc_string *s = agc_text(vm, v);
    agc_write(vm, stream, s->data, s->bytes);
  } else {
    char text[AGC_FLOAT_TEXT];
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

static agc_string empty_string = {0, 0};

static agc_value builtin_result_message(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_result *r = agc_as_result(vm, args[0]);
  if (r->ok) return agc_string_value(&empty_string);
  return r->value;
}

static const agc_builtin table[] = {
  {"puts", 1, builtin_puts},
  {"IO.print", 1, builtin_print},
  {"IO.warn", 1, builtin_warn},
  {"IO.inspect", 1, builtin_inspect},
  {"IO.gets", 0, builtin_gets},
  {"IO.gets!", 0, builtin_gets_bang},
  {"IO.read", 0, builtin_read},
  {"IO.read_bytes", 1, builtin_read_bytes},
  {"IO.flush", 0, builtin_flush},
  {"IO.eof?", 0, builtin_eof},
  {"System.args", 0, builtin_args},
  {"System.exit", 1, builtin_exit},
  {"String.from_int", 1, builtin_from_int},
  {"String.from_float", 1, builtin_from_float},
  {"List.concat", 2, builtin_list_concat},
  {"Map.put", 3, builtin_map_put},
  {"ok", 1, builtin_ok},
  {"ok", 0, builtin_ok_void},
  {"error", 1, builtin_error},
  {"Result.ok?", 1, builtin_result_ok},
  {"Result.unwrap!", 1, builtin_result_unwrap},
  {"Result.unwrap_or", 2, builtin_result_unwrap_or},
  {"Result.message", 1, builtin_result_message},
};

const agc_builtin *agc_find_builtin(const uint8_t *name, size_t len, uint32_t arity) {
  for (size_t i = 0; i < sizeof table / sizeof table[0]; i++) {
    if (table[i].arity == arity && strlen(table[i].name) == len && memcmp(table[i].name, name, len) == 0)
      return &table[i];
  }
  return NULL;
}
