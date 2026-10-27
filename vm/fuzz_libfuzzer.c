/*
 * The libFuzzer entry point (make vm-libfuzz): each input is one .agcb file for agc_fuzz_one, run in the interpreter
 * and then, when the build sets AGC_FUZZ_JIT_WRAP (mk/vm.mk, on Linux), with the JIT under `always` (every function
 * it can, at its first entry) and under `on` (the hot ones, as a user's run): a differential test, which aborts when a
 * JIT run's stdout, stderr, diagnostic or end differs from the interpreter's. AFL++, honggfuzz and Centipede call the
 * same function. Driver layer. Design: docs/vm/11-build-ci-supply-chain.md (Fuzzing).
 */
#include "core.h"
#include "jit/jit.h"

#ifdef AGC_FUZZ_JIT_WRAP
#include <stdlib.h>
#include <string.h>
#include <time.h>
#endif

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

/* What one run showed: agc_fuzz_one's result, whether it read the clock, the program's stdout, and its stderr
   followed by the diagnostic and the end of the run (vm/fuzz.c). A run that reads no clock is deterministic (one
   scheduler, the fixed seed and hash key, 10,000 steps, no files, network, environment or processes) and the JIT
   keeps the interpreter's safe points, so the tiers must agree byte for byte (black-box parity,
   docs/future/22-jit.md). */
typedef struct {
  int status;
  bool clocked;
  char *out, *err;
  size_t out_size, err_size;
} seen;

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

/* The one input a run takes from the host is the clock: Time.now and Time.monotonic return it, and a timed wait,
   which lasts 0 ms in a fuzz run (agc_timeout_length), still ends at the first turn boundary that sees its deadline
   passed, so how many turns the others get before it depends on the speed of the run, which compiling changes. The
   link wraps the C library's clocks (mk/vm-test.mk), every one the VM and libuv read, and agc_vm_run, so that a run
   whose program read one is known and is not compared. The reads around the run (agc_vm_init's trace setup, the
   flush in agc_io_close) cannot change what the program did. */
static bool clock_read, in_run; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

// NOLINTBEGIN(bugprone-reserved-identifier,readability-identifier-naming)
agc_outcome __real_agc_vm_run(agc_vm *vm);
agc_outcome __wrap_agc_vm_run(agc_vm *vm);

agc_outcome __wrap_agc_vm_run(agc_vm *vm) {
  in_run = true;
  agc_outcome outcome = __real_agc_vm_run(vm);
  in_run = false;
  return outcome;
}

int __real_clock_gettime(clockid_t id, struct timespec *ts);
int __wrap_clock_gettime(clockid_t id, struct timespec *ts);
int __real_timespec_get(struct timespec *ts, int base);
int __wrap_timespec_get(struct timespec *ts, int base);

int __wrap_clock_gettime(clockid_t id, struct timespec *ts) {
  clock_read |= in_run;
  return __real_clock_gettime(id, ts);
}

int __wrap_timespec_get(struct timespec *ts, int base) {
  clock_read |= in_run;
  return __real_timespec_get(ts, base);
}
// NOLINTEND(bugprone-reserved-identifier,readability-identifier-naming)

static seen run(const uint8_t *data, size_t size, agc_jit_mode mode) {
  seen s = {0};
  FILE *out = open_memstream(&s.out, &s.out_size);
  FILE *err = open_memstream(&s.err, &s.err_size);
  if (!out || !err) abort();
  // The allocation limit's longjmp leaves agc_vm_run without passing the wrapper's end.
  clock_read = in_run = false;
  s.status = agc_fuzz_one(data, size, (int)mode, out, err);
  s.clocked = clock_read;
  fclose(out);
  fclose(err);
  if (mode != AGC_JIT_OFF) release_code();
  return s;
}

static void seen_free(seen *s) {
  free(s->out);
  free(s->err);
}

static bool same(const seen *a, const seen *b) {
  return a->out_size == b->out_size && a->err_size == b->err_size && memcmp(a->out, b->out, a->out_size) == 0 &&
         memcmp(a->err, b->err, a->err_size) == 0;
}

static void show(const char *what, const char *bytes, size_t size) {
  enum { SHOWN = 2048 };
  fprintf(stderr, "--- %s (%zu bytes)\n%.*s\n", what, size, (int)(size < SHOWN ? size : SHOWN), bytes);
}

/* Runs the input in MODE and aborts (a crash for libFuzzer, which keeps the input) if the run differs from the
   interpreter's. Past the allocation limit (status 2) a run stops where its allocations, which the JIT changes, cross
   the limit, so only runs that ended compare, and only those that read no clock. As a guard against any other input
   from the host, a second interpreter run must agree with the first before a difference counts. */
static void check(const uint8_t *data, size_t size, const seen *base, agc_jit_mode mode) {
  seen jit = run(data, size, mode);
  if (base->status == 1 && jit.status == 1 && !base->clocked && !jit.clocked && !same(base, &jit)) {
    seen again = run(data, size, AGC_JIT_OFF);
    bool stable = again.status == 1 && !again.clocked && same(base, &again);
    seen_free(&again);
    if (stable) {
      fprintf(stderr, "vm-libfuzz: the JIT (%s) and the interpreter differ\n", mode == AGC_JIT_ON ? "on" : "always");
      show("interpreter stdout", base->out, base->out_size);
      show("jit stdout", jit.out, jit.out_size);
      show("interpreter stderr", base->err, base->err_size);
      show("jit stderr", jit.err, jit.err_size);
      abort();
    }
  }
  seen_free(&jit);
}
#endif

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  // The return value of agc_fuzz_one (accepted, refused, over the limit) is not a failure; a crash or a difference is.
#ifdef AGC_FUZZ_JIT_WRAP
  seen base = run(data, size, AGC_JIT_OFF);
  /* The loader is deterministic: an input it refused once it refuses again, so only accepted ones run with the JIT.
     Without an emitter (AGC_JIT_HOST 0: Linux arm64) a JIT run would only run the interpreter again. */
  if (AGC_JIT_HOST && base.status != 0) {
    check(data, size, &base, AGC_JIT_ALWAYS);
    check(data, size, &base, AGC_JIT_ON);
  }
  seen_free(&base);
#else
  agc_fuzz_one(data, size, AGC_JIT_OFF, NULL, NULL);
#endif
  return 0;
}
