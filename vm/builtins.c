#include "agc.h"

#include <inttypes.h>
#include <string.h>

static agc_value builtin_puts(agc_vm *vm, agc_value *args, uint32_t span) {
  if (agc_is(args[0], AGC_T_STRING)) {
    agc_string *s = agc_as_string(vm, args[0], span + 1);
    agc_write(vm, s->data, s->bytes);
  } else {
    char text[32];
    int n = snprintf(text, sizeof text, "%" PRId64, agc_as_int(vm, args[0], span + 1));
    agc_write(vm, text, (size_t)n);
  }
  agc_write(vm, "\n", 1);
  return agc_void();
}

static const agc_builtin table[] = {
  {"puts", 1, builtin_puts},
};

const agc_builtin *agc_find_builtin(const uint8_t *name, size_t len, uint32_t arity) {
  for (size_t i = 0; i < sizeof table / sizeof table[0]; i++) {
    if (table[i].arity == arity && strlen(table[i].name) == len && memcmp(table[i].name, name, len) == 0)
      return &table[i];
  }
  return NULL;
}
