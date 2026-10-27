/*
 * The libFuzzer entry point (make vm-libfuzz): each input is one .agcb file for agc_fuzz_one, run in the interpreter
 * and then, when the build sets AGC_FUZZ_JIT_WRAP (mk/vm.mk, on Linux), with the JIT compiling every function it can.
 * AFL++, honggfuzz and Centipede call the same function. Driver layer.
 * Design: docs/vm/11-build-ci-supply-chain.md (Fuzzing).
 */
#include "core.h"
#include "jit/jit.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(readability-identifier-naming)

#ifdef AGC_FUZZ_JIT_WRAP
/* The JIT keeps its code memory until the process exits, as a run of the binary does, so one fuzzing process would
   keep every input's code. The link wraps agc_jit_mem_reserve (-Wl,--wrap in mk/vm-test.mk) so that each reservation
   is noted here and unmapped after its input. Without the define (and the link flag) the harness fuzzes the interpreter
   only. Past RESERVATIONS the wrapper refuses, which jit.c takes as memory that failed: the rest of that run stays
   interpreted. A run takes a few chunks (AGC_JIT_CODE_CAP in doubling chunks). */
#define RESERVATIONS 64

typedef struct {
  void *pages;
  size_t size;
} reservation;

static reservation reserved[RESERVATIONS]; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static size_t reserved_count;              // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

// NOLINTBEGIN(bugprone-reserved-identifier,readability-identifier-naming)
void *__real_agc_jit_mem_reserve(size_t size);
void *__wrap_agc_jit_mem_reserve(size_t size);

void *__wrap_agc_jit_mem_reserve(size_t size) {
  if (reserved_count == RESERVATIONS) return NULL;
  void *pages = __real_agc_jit_mem_reserve(size);
  if (pages) reserved[reserved_count++] = (reservation){pages, size};
  return pages;
}
// NOLINTEND(bugprone-reserved-identifier,readability-identifier-naming)

/* After a run, which agc_fuzz_one closed and released: nothing is left that could enter the code. */
static void release_code(void) {
  for (size_t k = 0; k < reserved_count; k++) agc_jit_mem_unmap(reserved[k].pages, reserved[k].size);
  reserved_count = 0;
}
#endif

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  // The return value of agc_fuzz_one (accepted, refused, over the limit) is not a failure; a crash is.
  agc_fuzz_one(data, size, false);
#ifdef AGC_FUZZ_JIT_WRAP
  agc_fuzz_one(data, size, true);
  release_code();
#endif
  return 0;
}
