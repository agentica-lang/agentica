/*
 * The libFuzzer entry point (make vm-libfuzz): each input is one .agcb file for agc_fuzz_one, run in the interpreter
 * and then, when the build sets AGC_FUZZ_JIT_WRAP (mk/vm.mk, on Linux), with the JIT under `always` (every function
 * it can, at its first entry) and under `on` (the hot ones, at the low thresholds agc_fuzz_one sets): a differential
 * test, which aborts when a JIT run's stdout, stderr, diagnostic or end differs from the interpreter's. AFL++,
 * honggfuzz and Centipede call the same function. Driver layer. Design: docs/vm/11-build-ci-supply-chain.md (Fuzzing).
 */
#ifdef AGC_FUZZ_JIT_WRAP
/* glibc declares fopencookie only for _GNU_SOURCE; the wrapped build is Linux only. */
#define _GNU_SOURCE
#endif
#include "core.h"
#include "jit/jit.h"

#ifdef AGC_FUZZ_JIT_WRAP
#include <stdatomic.h>
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

/* A run may write gigabytes in its 10,000 steps (a 64 MB string printed in a loop), which the interpreter-only build
   sends to the null device, so a stream keeps no copy: it counts every byte, hashes the first HASHED (FNV-1a 64) and
   keeps the first HEAD for the report. Past HASHED only the count is compared, which keeps the hashing far below the
   timeout. */
#define HASHED ((size_t)16 << 20)
#define HEAD ((size_t)4096)
#define FNV_OFFSET 0xcbf29ce484222325u
#define FNV_PRIME 0x100000001b3u

typedef struct {
  void *pages;
  size_t size;
} reservation;

typedef struct {
  uint64_t hash;
  size_t size;
  char head[HEAD];
} stream;

/* What one run showed: agc_fuzz_one's result, whether it read the clock, the program's stdout, and its stderr
   followed by the diagnostic and the end of the run (vm/fuzz.c). A run that reads no clock is deterministic (one
   scheduler, the fixed seed and hash key, 10,000 steps, no files, network, environment or processes) and the JIT
   keeps the interpreter's safe points, so the tiers must agree byte for byte (black-box parity,
   docs/vm/05-values-execution-builtins.md §6.4). */
typedef struct {
  int status;
  bool clocked;
  stream out, err;
} seen;

static reservation reserved[RESERVATIONS]; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static size_t reserved_count;              // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

/* The JIT runs, by mode, that stopped at the allocation limit where the interpreter's ended: not compared (check),
   only counted, and printed when the process exits. */
static unsigned long long over_limit[AGC_JIT_ALWAYS + 1]; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

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
   flush in agc_io_close) cannot change what the program did. A libuv pool thread may read a clock too, so both are
   atomic; relaxed is enough, since agc_fuzz_one ends every thread's work before it returns. */
static _Atomic bool clock_read, in_run; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

// NOLINTBEGIN(bugprone-reserved-identifier,readability-identifier-naming)
agc_outcome __real_agc_vm_run(agc_vm *vm);
agc_outcome __wrap_agc_vm_run(agc_vm *vm);

agc_outcome __wrap_agc_vm_run(agc_vm *vm) {
  atomic_store_explicit(&in_run, true, memory_order_relaxed);
  agc_outcome outcome = __real_agc_vm_run(vm);
  atomic_store_explicit(&in_run, false, memory_order_relaxed);
  return outcome;
}

int __real_clock_gettime(clockid_t id, struct timespec *ts);
int __wrap_clock_gettime(clockid_t id, struct timespec *ts);
int __real_timespec_get(struct timespec *ts, int base);
int __wrap_timespec_get(struct timespec *ts, int base);

static void note_clock(void) {
  if (atomic_load_explicit(&in_run, memory_order_relaxed))
    atomic_store_explicit(&clock_read, true, memory_order_relaxed);
}

int __wrap_clock_gettime(clockid_t id, struct timespec *ts) {
  note_clock();
  return __real_clock_gettime(id, ts);
}

int __wrap_timespec_get(struct timespec *ts, int base) {
  note_clock();
  return __real_timespec_get(ts, base);
}
// NOLINTEND(bugprone-reserved-identifier,readability-identifier-naming)

/* SecureRandom is the other input from the host: agc_secure_random draws from OpenSSL, so an interpreter run and a JIT
   run of one program would print other bytes. The link wraps it (mk/vm-test.mk) to give every run the same stream
   instead, restarted by run() as the fixed seed restarts Random, so programs that draw still compare. Only this
   harness links the wrap: the VM, its tests and the fuzz runs without the JIT draw from OpenSSL. A fuzz run has one
   scheduler and no pool thread draws, so the state needs no lock. */
static agc_random secure_stream; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

// NOLINTBEGIN(bugprone-reserved-identifier,readability-identifier-naming)
bool __wrap_agc_secure_random(unsigned char *out, size_t n);

bool __wrap_agc_secure_random(unsigned char *out, size_t n) {
  for (size_t k = 0; k < n; k += 8) {
    uint64_t word = agc_random_next(&secure_stream);
    memcpy(out + k, &word, n - k < 8 ? n - k : 8);
  }
  return true;
}
// NOLINTEND(bugprone-reserved-identifier,readability-identifier-naming)

static size_t smaller(size_t a, size_t b) { return a < b ? a : b; }

/* No coverage hooks: the hash loop is not fuzzed code, and with them it costs two hook calls per byte. */
__attribute__((no_sanitize("coverage"))) static ssize_t stream_write(void *cookie, const char *bytes, size_t size) {
  stream *s = cookie;
  if (s->size < HEAD) memcpy(s->head + s->size, bytes, smaller(size, HEAD - s->size));
  size_t hashed = s->size < HASHED ? smaller(size, HASHED - s->size) : 0;
  for (size_t k = 0; k < hashed; k++) s->hash = (s->hash ^ (uint8_t)bytes[k]) * FNV_PRIME;
  s->size += size;
  return (ssize_t)size;
}

static FILE *stream_open(stream *s) {
  s->hash = FNV_OFFSET;
  s->size = 0;
  FILE *f = fopencookie(s, "w", (cookie_io_functions_t){.write = stream_write});
  if (!f) abort();
  return f;
}

static void run(const uint8_t *data, size_t size, agc_jit_mode mode, seen *s) {
  FILE *out = stream_open(&s->out), *err = stream_open(&s->err);
  // The allocation limit's longjmp leaves agc_vm_run without passing the wrapper's end.
  atomic_store_explicit(&clock_read, false, memory_order_relaxed);
  atomic_store_explicit(&in_run, false, memory_order_relaxed);
  agc_random_seed(&secure_stream, 0);
  s->status = agc_fuzz_one(data, size, (int)mode, out, err);
  s->clocked = atomic_load_explicit(&clock_read, memory_order_relaxed);
  fclose(out);
  fclose(err);
  if (mode != AGC_JIT_OFF) release_code();
}

static bool same_stream(const stream *a, const stream *b) { return a->size == b->size && a->hash == b->hash; }

static bool same(const seen *a, const seen *b) {
  return same_stream(&a->out, &b->out) && same_stream(&a->err, &b->err);
}

static void show(const char *what, const stream *s) {
  fprintf(stderr, "--- %s (%zu bytes, the first %zu)\n%.*s\n", what, s->size, smaller(s->size, HEAD),
          (int)smaller(s->size, HEAD), s->head);
}

static void report(void) {
  fprintf(stderr, "vm-libfuzz: JIT runs past the allocation limit where the interpreter's ended (not compared): "
                  "always %llu, on %llu\n",
          over_limit[AGC_JIT_ALWAYS], over_limit[AGC_JIT_ON]);
}

/* Runs the input in MODE and aborts (a crash for libFuzzer, which keeps the input) if the run differs from the
   interpreter's. Past the allocation limit (status 2) a run stops where its allocations, which the JIT changes, cross
   the limit, so only runs that ended compare, and only those that read no clock. As a guard against any other input
   from the host, a second interpreter run must agree with the first before a difference counts. */
static void check(const uint8_t *data, size_t size, const seen *base, agc_jit_mode mode) {
  seen jit;
  run(data, size, mode, &jit);
  if (base->status == 1 && jit.status == 2) over_limit[mode]++;
  if (base->status == 1 && jit.status == 1 && !base->clocked && !jit.clocked && !same(base, &jit)) {
    seen again;
    run(data, size, AGC_JIT_OFF, &again);
    if (again.status == 1 && !again.clocked && same(base, &again)) {
      fprintf(stderr, "vm-libfuzz: the JIT (%s) and the interpreter differ\n", mode == AGC_JIT_ON ? "on" : "always");
      show("interpreter stdout", &base->out);
      show("jit stdout", &jit.out);
      show("interpreter stderr", &base->err);
      show("jit stderr", &jit.err);
      abort();
    }
  }
}

/* The loader is deterministic: an input it refused once it refuses again, so only accepted ones run with the JIT. */
static void differential(const uint8_t *data, size_t size) {
  static bool reporting; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
  if (!reporting) reporting = atexit(report) == 0;
  seen base;
  run(data, size, AGC_JIT_OFF, &base);
  if (base.status == 0) return;
  check(data, size, &base, AGC_JIT_ALWAYS);
  check(data, size, &base, AGC_JIT_ON);
}
#endif

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  // The return value of agc_fuzz_one (accepted, refused, over the limit) is not a failure; a crash or a difference is.
#ifdef AGC_FUZZ_JIT_WRAP
  /* Without an emitter (AGC_JIT_HOST 0) a JIT run would only run the interpreter again: nothing to compare, so
     nothing is captured either. */
  if (AGC_JIT_HOST) {
    differential(data, size);
    return 0;
  }
#endif
  agc_fuzz_one(data, size, AGC_JIT_OFF, NULL, NULL);
  return 0;
}
