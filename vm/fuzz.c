/*
 * agc_fuzz_one: load one mutated .agcb file and, if it is accepted, run it, in the interpreter or with the JIT
 * (AGC_JIT_ALWAYS compiles every function it can, AGC_JIT_ON the hot ones, at low thresholds), so hostile bytecode
 * reaches the emitter and compiled code. Used by the libFuzzer target (vm/fuzz_libfuzzer.c) only, never in the
 * release binary. Driver layer. Design: docs/vm/11-build-ci-supply-chain.md (Fuzzing).
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

int agc_fuzz_one(const uint8_t *data, size_t len, int jit_mode, FILE *out, FILE *err) {
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
  // Set after the setjmp and never changed, so that no longjmp can clobber them.
  FILE *const to_out = out ? out : sink, *const to_err = err ? err : sink;
  vm = agc_alloc(sizeof(agc_vm));
  agc_vm_init(vm, program, to_out, to_err, 10000);
  vm->rt->no_files = true;
  // A mutant must not start programs: its strings are mutated shell commands, and a child waits outside --max-steps.
  vm->rt->deny_run = true;
  // Nor read the host's environment, which differs between machines, so an input would not reproduce elsewhere.
  vm->rt->deny_env = true;
  // Nor use the network: its waits are outside --max-steps and depend on the host.
  vm->rt->deny_net = true;
  // The code memory of the JIT outlives agc_release_all: the libFuzzer entry point unmaps it (vm/fuzz_libfuzzer.c).
  if (jit_mode != AGC_JIT_OFF) vm->rt->jit = agc_jit_new(program, (agc_jit_mode)jit_mode, &vm->rt->trace);
  /* A mutant's 10,000 steps seldom reach the thresholds of `on`, so here a function with a loop compiles at its second
     entry, after one interpreted, and one without at its first CALL exit from compiled code. */
  if (vm->rt->jit) {
    vm->rt->jit->hot_entries = 2;
    vm->rt->jit->hot_passes = 1;
    vm->rt->jit->hot_calls = 1;
  }
  agc_outcome outcome = agc_vm_run(vm);
  if (outcome.kind == AGC_FAILED)
    for (int style = AGC_STYLE_PLAIN; style <= AGC_STYLE_JSON; style++)
      agc_print_diagnostic(to_err, program, &outcome, (agc_style)style, false);
  // The end of the run is observable too: the comparison of vm/fuzz_libfuzzer.c reads it after the program's stderr.
  fprintf(to_err, "\nend kind=%d exit=%lld\n", (int)outcome.kind, (long long)outcome.exit_code);
  agc_io_close(vm);
  agc_release_all();
  fflush(to_out);
  fflush(to_err);
  return 1;
}
