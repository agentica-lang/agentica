/*
 * agc_fuzz_one: load one mutated .agcb file and, if it is accepted, run it, in the interpreter or with the JIT
 * compiling every function it can (AGC_JIT_ALWAYS), so hostile bytecode reaches the emitter and compiled code.
 * Used by the libFuzzer target (vm/fuzz_libfuzzer.c) only, never in the release binary. Driver layer.
 * Design: docs/vm/11-build-ci-supply-chain.md (Fuzzing).
 */
#include "core.h"
#include "services.h"
#include "jit/jit.h"

#ifdef _WIN32
#define NULL_DEVICE "NUL"
#else
#define NULL_DEVICE "/dev/null"
#endif

#define ALLOC_LIMIT ((size_t)256 << 20)

static FILE *sink; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

int agc_fuzz_one(const uint8_t *data, size_t len, bool jit) {
  agc_init();
  if (!sink) sink = fopen(NULL_DEVICE, "w");
  if (!sink) return -1;
  jmp_buf over_limit;
  agc_vm *volatile vm = NULL;
  if (setjmp(over_limit)) {
    if (vm) agc_io_close(vm);
    agc_release_all();
    return 2;
  }
  agc_set_alloc_limit(&over_limit, ALLOC_LIMIT);
  agc_program *program = NULL;
  char error[160];
  if (!agc_load(data, len, &program, error, sizeof error)) {
    agc_release_all();
    return 0;
  }
  vm = agc_alloc(sizeof(agc_vm));
  agc_vm_init(vm, program, sink, sink, 10000);
  vm->rt->no_files = true;
  // A mutant must not start programs: its strings are mutated shell commands, and a child waits outside --max-steps.
  vm->rt->deny_run = true;
  // Nor read the host's environment, which differs between machines, so an input would not reproduce elsewhere.
  vm->rt->deny_env = true;
  // Nor use the network: its waits are outside --max-steps and depend on the host.
  vm->rt->deny_net = true;
  // The code memory of the JIT outlives agc_release_all: the libFuzzer entry point unmaps it (vm/fuzz_libfuzzer.c).
  if (jit) vm->rt->jit = agc_jit_new(program, AGC_JIT_ALWAYS, &vm->rt->trace);
  agc_outcome outcome = agc_vm_run(vm);
  if (outcome.kind == AGC_FAILED)
    for (int style = AGC_STYLE_PLAIN; style <= AGC_STYLE_JSON; style++)
      agc_print_diagnostic(sink, program, &outcome, (agc_style)style, false);
  agc_io_close(vm);
  agc_release_all();
  return 1;
}
