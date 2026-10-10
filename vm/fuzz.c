#include "agc.h"

static FILE *sink;

int agc_fuzz_one(const uint8_t *data, size_t len) {
  agc_init();
  if (!sink) sink = fopen("/dev/null", "w");
  if (!sink) return -1;
  agc_program *program = NULL;
  char error[160];
  if (!agc_load(data, len, &program, error, sizeof error)) return 0;
  agc_vm *vm = agc_alloc(sizeof(agc_vm));
  agc_vm_init(vm, program, sink, 10000);
  agc_outcome outcome = agc_vm_run(vm);
  if (outcome.kind == AGC_FAILED) agc_print_diagnostic(sink, program, &outcome);
  return 1;
}
