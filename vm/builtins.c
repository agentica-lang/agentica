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
  return agc_result_value(false, agc_string_value(agc_as_string(vm, args[0])));
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
  if (r->ok) return agc_string_value(agc_make_string("", 0, 0));
  return agc_string_value(agc_as_string(vm, r->value));
}

static const agc_builtin table[] = {
  {"puts", 1, builtin_puts},
  {"IO.print", 1, builtin_print},
  {"IO.warn", 1, builtin_warn},
  {"String.from_int", 1, builtin_from_int},
  {"String.from_float", 1, builtin_from_float},
  {"List.concat", 2, builtin_list_concat},
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
