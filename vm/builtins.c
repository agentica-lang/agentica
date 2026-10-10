#include "agc.h"

#include <inttypes.h>
#include <string.h>

static void write_text(agc_vm *vm, agc_value v) {
  char text[AGC_FLOAT_TEXT];
  size_t n;
  if (agc_is(v, AGC_T_STRING)) {
    agc_string *s = agc_as_string(vm, v);
    agc_write(vm, s->data, s->bytes);
    return;
  }
  if (agc_is(v, AGC_T_NIL)) {
    agc_write(vm, "nil", 3);
  } else if (agc_is(v, AGC_T_BOOL)) {
    bool b = agc_as_bool(vm, v);
    agc_write(vm, b ? "true" : "false", b ? 4 : 5);
  } else if (agc_is(v, AGC_T_FLOAT)) {
    n = agc_float_text(agc_as_float(vm, v), text);
    agc_write(vm, text, n);
  } else {
    n = (size_t)snprintf(text, sizeof text, "%" PRId64, agc_as_int(vm, v));
    agc_write(vm, text, n);
  }
}

static agc_value builtin_puts(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  write_text(vm, args[0]);
  agc_write(vm, "\n", 1);
  return agc_void();
}

static agc_value builtin_print(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  write_text(vm, args[0]);
  return agc_void();
}

static const agc_builtin table[] = {
  {"puts", 1, builtin_puts},
  {"IO.print", 1, builtin_print},
};

const agc_builtin *agc_find_builtin(const uint8_t *name, size_t len, uint32_t arity) {
  for (size_t i = 0; i < sizeof table / sizeof table[0]; i++) {
    if (table[i].arity == arity && strlen(table[i].name) == len && memcmp(table[i].name, name, len) == 0)
      return &table[i];
  }
  return NULL;
}
