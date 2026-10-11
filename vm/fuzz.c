#include "agc.h"

#ifdef _WIN32
#define NULL_DEVICE "NUL"
#else
#define NULL_DEVICE "/dev/null"
#endif

#define ALLOC_LIMIT ((size_t)256 << 20)

static FILE *sink;

int agc_fuzz_one(const uint8_t *data, size_t len) {
  agc_init();
  if (!sink) sink = fopen(NULL_DEVICE, "w");
  if (!sink) return -1;
  jmp_buf over_limit;
  if (setjmp(over_limit)) {
    agc_release_all();
    return 1;
  }
  agc_set_alloc_limit(&over_limit, ALLOC_LIMIT);
  agc_program *program = NULL;
  char error[160];
  if (!agc_load(data, len, &program, error, sizeof error)) {
    agc_release_all();
    return 0;
  }
  agc_vm *vm = agc_alloc(sizeof(agc_vm));
  agc_vm_init(vm, program, sink, sink, 10000);
  agc_outcome outcome = agc_vm_run(vm);
  if (outcome.kind == AGC_FAILED)
    for (int style = AGC_STYLE_PLAIN; style <= AGC_STYLE_JSON; style++)
      agc_print_diagnostic(sink, program, &outcome, (agc_style)style);
  agc_release_all();
  return 1;
}
