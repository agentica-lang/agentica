/*
 * Values in C: allocation through the Boehm GC (with its stress hook), the
 * checked agc_as_* accessors, String allocation, UTF-8 checks and code point
 * counts, and the error Results built in C (agc_error: an Error record, or a String
 * in a program without one) with their readers. Core layer.
 * Design: docs/vm/05-values-execution-builtins.md §5.
 */
#include "core.h"

#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Pauses under 16 us have a bucket each; above, each power of two has four (pause_bucket). */
#define PAUSE_EXACT 16
#define PAUSE_BUCKETS (PAUSE_EXACT + 4 * 60)

#ifndef AGC_NO_GC
/* A call of agc_gc_blocking, for the function that GC_do_blocking runs. */
typedef struct {
  void (*fn)(void *arg);
  void *arg;
} blocking_call;
#endif

/* A weak reference (agc_weak_new). Under Boehm it is a pointer-free block, so the collector never reads the word as a
   reference, and the word holds the pointer hidden (GC_HIDE_POINTER) besides; Boehm writes 0 into it once the object is
   unreachable (a disappearing link). */
struct agc_weak {
  uintptr_t hidden;
};

/* An unsigned integer in 32-bit limbs, least significant first. The reader's integers stay under 620 bits: at most
   129 digits (FLOAT32_DIGITS + 1) times 10^38 or over 10^174, scaled by 2^149 at most, then by 2^26 in big_divide. */
#define BIG_LIMBS 32

typedef struct {
  uint32_t limb[BIG_LIMBS];
  size_t n;
} big;

#ifndef AGC_NO_GC
/* The record of agc_gc_record_start. The collector writes it from its event callback, with its lock held, and
   agc_gc_record reads it under that lock. `start_ns` and `start_cpu_us` are the clocks at agc_gc_record_start;
   `stop_ns` is when the current stop of the world began, 0 outside one; `buckets` counts the pauses by their length
   (pause_bucket). */
typedef struct {
  uint64_t start_ns, start_cpu_us, stop_ns, pauses, max_ns, total_ns, used_last, used_max;
  uint64_t buckets[PAUSE_BUCKETS];
} pause_record;
#endif

#ifdef AGC_NO_GC
const char *__asan_default_options(void); // NOLINT(readability-identifier-naming,misc-use-internal-linkage)
const char *__asan_default_options(void) { return "detect_leaks=0:allocator_may_return_null=1"; }
#else
/* gc.h declares the thread registration calls only with GC_THREADS. The system libgc is built for threads, and the
   vendored one gets the same define from the Makefile. */
#define GC_THREADS
#include <gc.h>
#ifdef _WIN32
#include <signal.h>
#endif
#endif

#ifdef AGC_NO_GC
#define BLOCK_COST ((size_t)64)
#else
#define FREE_SPACE_DIVISOR 2
#define HEAP_FLOOR_DEFAULT ((size_t)32 << 20)
#endif

static const char oom_line[] = "agentica: out of memory\n";
#define HEAP_LIMIT_TEXT "the program needs more memory than --max-heap allows"
static const char limit_line[] = "agentica: RUNTIME-HEAP-LIMIT: " HEAP_LIMIT_TEXT "\n";
static const char limit_json[] = "{\"code\":\"RUNTIME-HEAP-LIMIT\",\"message\":\"" HEAP_LIMIT_TEXT "\"}\n";
/* libgc grows the heap by whole blocks, so a request this close to the limit is refused for the limit. */
#define HEAP_LIMIT_SLACK ((size_t)1 << 20)
static size_t heap_limit; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static bool heap_limit_json; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
#ifndef AGC_NO_GC
/* The collector's event callback gets no context, so its record is process state (docs/vm/10-io-multicore.md
   §10.2.3). */
static pause_record pause_log; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
#endif
/* The counts of the calling thread while it counts (agc_alloc_count_start): plain integers, never a GC pointer. */
static _Thread_local bool counting; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static _Thread_local agc_alloc_counts counts; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
/* The text of each agc_error_kind (vm/error_kinds.h). */
static const char *const kind_names[AGC_KIND_COUNT] = {
  [AGC_KIND_ERROR] = "error",
  [AGC_KIND_ARGUMENT] = "argument",
  [AGC_KIND_IO_NOT_FOUND] = "io.not_found",
  [AGC_KIND_IO_PERMISSION] = "io.permission",
  [AGC_KIND_IO_EXISTS] = "io.exists",
  [AGC_KIND_IO_IS_DIRECTORY] = "io.is_directory",
  [AGC_KIND_IO_NOT_DIRECTORY] = "io.not_directory",
  [AGC_KIND_IO_TOO_LARGE] = "io.too_large",
  [AGC_KIND_IO_EOF] = "io.eof",
  [AGC_KIND_IO_CLOSED] = "io.closed",
  [AGC_KIND_IO_TIMEOUT] = "io.timeout",
  [AGC_KIND_IO_FAILED] = "io.failed",
  [AGC_KIND_NET_TIMEOUT] = "net.timeout",
  [AGC_KIND_NET_REFUSED] = "net.refused",
  [AGC_KIND_NET_HOST_NOT_FOUND] = "net.host_not_found",
  [AGC_KIND_NET_CLOSED] = "net.closed",
  [AGC_KIND_NET_EOF] = "net.eof",
  [AGC_KIND_NET_TLS] = "net.tls",
  [AGC_KIND_NET_TOO_LARGE] = "net.too_large",
  [AGC_KIND_NET_FAILED] = "net.failed",
  [AGC_KIND_HTTP_PROTOCOL] = "http.protocol",
  [AGC_KIND_HTTP_TOO_LARGE] = "http.too_large",
  [AGC_KIND_HTTP_CLOSED] = "http.closed",
  [AGC_KIND_PROCESS_NOT_FOUND] = "process.not_found",
  [AGC_KIND_PROCESS_TIMEOUT] = "process.timeout",
  [AGC_KIND_PROCESS_CLOSED] = "process.closed",
  [AGC_KIND_PROCESS_EOF] = "process.eof",
  [AGC_KIND_PROCESS_TOO_LARGE] = "process.too_large",
  [AGC_KIND_PROCESS_FAILED] = "process.failed",
  [AGC_KIND_TASK_CRASHED] = "task.crashed",
  [AGC_KIND_TASK_CANCELLED] = "task.cancelled",
  [AGC_KIND_TASK_TIMEOUT] = "task.timeout",
  [AGC_KIND_CHANNEL_CLOSED] = "channel.closed",
  [AGC_KIND_CHANNEL_TIMEOUT] = "channel.timeout",
  [AGC_KIND_CHANNEL_GONE] = "channel.gone",
  [AGC_KIND_JSON_PARSE] = "json.parse",
  [AGC_KIND_JSON_DECODE] = "json.decode",
  [AGC_KIND_NUMBER_PARSE] = "number.parse",
  [AGC_KIND_NUMBER_RANGE] = "number.range",
  [AGC_KIND_TEXT_ENCODING] = "text.encoding",
  [AGC_KIND_ZLIB_DATA] = "zlib.data",
  [AGC_KIND_ZLIB_TOO_LARGE] = "zlib.too_large",
  [AGC_KIND_CRYPTO_AUTH] = "crypto.auth",
  [AGC_KIND_CRYPTO_KEY] = "crypto.key",
  [AGC_KIND_CRYPTO_FAILED] = "crypto.failed",
  [AGC_KIND_SYSTEM_ENV] = "system.env",
  [AGC_KIND_NATIVE_FAILED] = "native.failed",
  [AGC_KIND_NATIVE_TIMEOUT] = "native.timeout",
  [AGC_KIND_TEST_FAILED] = "test.failed",
  [AGC_KIND_DENIED_ENV] = "denied.env",
  [AGC_KIND_DENIED_FS] = "denied.fs",
  [AGC_KIND_DENIED_NET] = "denied.net",
  [AGC_KIND_DENIED_RUN] = "denied.run",
  [AGC_KIND_SYSTEM_SIGNAL] = "system.signal",
};

#ifdef AGC_NO_GC
static void **owned; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static size_t owned_count, owned_cap, owned_bytes, limit_bytes; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static jmp_buf *on_limit; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static bool over_limit; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
/* Nothing is freed without the collector, so the bytes handed out since the limit was set are the heap. */
static atomic_size_t heap_used; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
#endif

_Noreturn void agc_out_of_memory(void) {
  ssize_t ignored = write(2, oom_line, sizeof oom_line - 1);
  (void)ignored;
#ifdef AGC_FUZZ
  /* 70 is libFuzzer's timeout exit code, so abort() (a crash) is used instead and the input is saved. */
  abort();
#else
  _Exit(70);
#endif
}

_Noreturn void agc_heap_limit_reached(void) {
  ssize_t ignored = heap_limit_json ? write(2, limit_json, sizeof limit_json - 1)
                                    : write(2, limit_line, sizeof limit_line - 1);
  (void)ignored;
  _Exit(70);
}

size_t agc_heap_limit(void) { return heap_limit; }

/* The bytes in use: without the collector, those handed out; with it, the heap less its free blocks, which still
   counts the garbage that no collection has freed yet. */
static size_t heap_in_use(void) {
#ifdef AGC_NO_GC
  return atomic_load(&heap_used);
#else
  size_t heap = GC_get_heap_size(), unused = GC_get_free_bytes();
  return heap > unused ? heap - unused : 0;
#endif
}

static bool fits(size_t outside) {
  size_t used = heap_in_use();
  return used < heap_limit && outside <= heap_limit - used;
}

/* Bytes that do not fit get one collection, as the heap's own growth does, since most of what is in use may be
   garbage. On a thread the collector knows, outside its lock. */
bool agc_heap_room(size_t outside) {
  if (!heap_limit || fits(outside)) return true;
#ifndef AGC_NO_GC
  GC_gcollect();
#endif
  return fits(outside);
}

/* A limit under the heap the process already has is that heap: it cannot shrink, only stop growing. */
void agc_heap_limit_set(size_t bytes, bool json) {
#ifndef AGC_NO_GC
  size_t heap = GC_get_heap_size();
  if (bytes && bytes < heap) bytes = heap;
#endif
  heap_limit = bytes;
  heap_limit_json = json;
#ifndef AGC_NO_GC
  GC_set_max_heap_size(bytes);
  /* libgc gives up at the first growth the limit refuses, even when most of the heap is garbage it has not
     collected yet; with retries it collects first. */
  GC_set_max_retries(bytes ? 2 : 0);
#endif
}

#ifndef AGC_NO_GC
static void *on_gc_oom(size_t size) {
  if (heap_limit) {
    size_t heap = GC_get_heap_size();
    if (heap >= heap_limit || size >= heap_limit - heap || heap_limit - heap - size <= HEAP_LIMIT_SLACK)
      agc_heap_limit_reached();
  }
  agc_out_of_memory();
  return NULL;
}

static const char gc_error_line[] = "agentica: internal GC error\n";

/* libgc aborts instead of calling the OOM function when the system refuses the memory of its own tables: the mark
   stack of the parallel marker ("Insufficient memory for main local_mark_stack", mark.c), a thread record ("Failed to
   allocate memory for thread registering"), the heap section list. Under a low ulimit -v that is plain out of memory,
   so those messages, which start with one of these, end with the out-of-memory line; any other abort is a fault.
   The prefixes are libgc's own text, the same in the vendored bdwgc and in a system libgc from GC_MIN (mk/vm.mk) on.
   tests/test_vm_style.py lists every abort of the vendored bdwgc that speaks of memory, space or allocation and
   whether it is out of memory here, so an update of bdwgc that adds or rewords one fails there for a review instead
   of turning silently into "internal GC error"; vm/tests/gc_thread_test.c sends some of them to this function.
   An abort through ABORT_ARGn writes a line of its own first, the message with its arguments (the size asked for the
   /proc/self/maps buffer, the size of the E2K procedure stack), so stderr then has that line before ours.
   "Cannot allocate executable pages" is not here: the system refused PROT_EXEC (a W^X policy), not memory. */
static bool gc_abort_is_out_of_memory(const char *message) {
  static const char *const prefixes[] = {"Insufficient memory",       "Insufficient space",   "Failed to allocate",
                                         "Could not allocate memory", "Could not map memory", "Not enough memory"};
  for (size_t k = 0; message && k < sizeof prefixes / sizeof prefixes[0]; k++)
    if (strncmp(message, prefixes[k], strlen(prefixes[k])) == 0) return true;
  return false;
}

static void on_gc_abort(const char *message) {
  if (gc_abort_is_out_of_memory(message)) agc_out_of_memory();
  ssize_t ignored = write(2, gc_error_line, sizeof gc_error_line - 1);
  (void)ignored;
  _Exit(70);
}
#endif

#ifndef AGC_NO_GC
/* A collection stops the other registered threads wherever they are; on Windows (SuspendThread) one may be inside
   malloc and hold the process heap's lock. The collecting thread must not malloc until the world starts again, but
   Boehm's mark phase, built with GCC for Windows, sets a SIGSEGV handler with signal() (GC_mark_some), and the UCRT's
   signal() mallocs the calling thread's own copy of the signal table the first time that thread calls it. A thread's
   first collection then waited for ever on the heap lock that a stopped thread held (#528). So each thread that may
   collect calls signal() once before it is registered, while no collection can stop it, and keeps its handler. */
static void own_signal_table(void) {
#ifdef _WIN32
  void (*kept)(int) = signal(SIGSEGV, SIG_DFL);
  if (kept != SIG_ERR) (void)signal(SIGSEGV, kept);
#endif
}
#endif

/* A size in bytes, with an optional K, M or G suffix (powers of 1024), as libgc's GC_INITIAL_HEAP_SIZE takes it:
   digits only, at most 1 TiB. */
bool agc_gc_heap_parse(const char *text, size_t *bytes) {
  uint64_t value = 0;
  const char *at = text;
  if (!*at) return false;
  for (; *at >= '0' && *at <= '9'; at++) {
    value = value * 10 + (uint64_t)(*at - '0');
    if (value > (UINT64_C(1) << 40)) return false;
  }
  if (at == text) return false;
  unsigned shift = 0;
  if (*at == 'K' || *at == 'k') shift = 10;
  else if (*at == 'M' || *at == 'm') shift = 20;
  else if (*at == 'G' || *at == 'g') shift = 30;
  if (shift) at++;
  if (*at || value > (UINT64_C(1) << 40) >> shift) return false;
  /* A size_t of 32 bits cannot hold every size up to 1 TiB. */
  size_t size = (size_t)(value << shift);
  if ((uint64_t)size != value << shift) return false;
  *bytes = size;
  return true;
}

void agc_init(void) {
#ifndef AGC_NO_GC
  if (GC_is_init_called()) return;
  own_signal_table();
  GC_set_all_interior_pointers(1);
  /* libgc lets about twice the live bytes / divisor be allocated between two collections, so a lower divisor collects
     less often and keeps a bigger heap. With its default, 3, libgc took about half of the self-compile's time; 2 made
     it 10% faster for 13% more peak memory (docs/vm/05-values-execution-builtins.md §5.3). Set before GC_INIT, which
     reads GC_FREE_SPACE_DIVISOR from the environment, so a value set there still wins. */
  GC_set_free_space_divisor(FREE_SPACE_DIVISOR);
  GC_INIT();
  GC_set_oom_fn(on_gc_oom);
  GC_set_abort_func(on_gc_abort);
  GC_set_warn_proc(GC_ignore_warn_proc);
  /* The heap floor. libgc collects once about (live bytes / divisor) were allocated, but it counts pointer-free
     bytes (strings) at a quarter, so a server whose heap is mostly text collected every 2 MB and stopped every
     thread for a third of the wall time. A heap that starts at 32 MB is only collected once its free space is used
     up: Campfire's routes ran 12-36% faster (64 MB and more gave longer pauses). The cost is memory: a program that
     allocates a lot touches up to the whole floor before its first collection. GC_INITIAL_HEAP_SIZE, libgc's own
     variable, wins when it is set, even to a value libgc refuses (GC_INIT has used it); AGENTICA_GC_HEAP sets the
     floor, and 0 turns it off. A bad value keeps the default here: agc_launch_env reports it before anything runs.
     After the warn proc, so a floor the system cannot give (64G) is skipped without libgc's warning: the heap then
     grows as it would without one. */
  const char *initial = getenv("GC_INITIAL_HEAP_SIZE"), *floor_text = getenv("AGENTICA_GC_HEAP");
  size_t heap_floor = HEAP_FLOOR_DEFAULT;
  if (floor_text && *floor_text && !agc_gc_heap_parse(floor_text, &heap_floor)) heap_floor = HEAP_FLOOR_DEFAULT;
  size_t heap = GC_get_heap_size();
  if (!(initial && *initial) && heap_floor > heap) (void)GC_expand_hp(heap_floor - heap);
  /* Finalizers (only the TLS.Context's) run when agc_gc_finalize_pending calls them, between turns, so OpenSSL is
     never entered from inside a collection or in the middle of a builtin. */
  GC_set_finalize_on_demand(1);
#endif
}

void agc_gc_finalize_pending(void) {
#ifndef AGC_NO_GC
  if (GC_should_invoke_finalizers()) (void)GC_invoke_finalizers();
#endif
}

/* Threads other than the main one: libuv starts them, so Boehm does not know them until they register
   (docs/vm/10-io-multicore.md §10.2.3). The main thread calls agc_gc_allow_threads once, after agc_init and before
   the first thread starts; it also starts Boehm's mark threads. A thread calls agc_gc_thread_enter before it
   allocates or holds a GC pointer, and agc_gc_thread_leave before it ends: a thread that ends registered leaves a
   stack for the collector to scan. */
void agc_gc_allow_threads(void) {
#ifndef AGC_NO_GC
  GC_allow_register_threads();
#endif
}

bool agc_gc_thread_enter(void) {
#ifdef AGC_NO_GC
  return true;
#else
  struct GC_stack_base base;
  if (GC_get_stack_base(&base) != GC_SUCCESS) return false;
  own_signal_table();
  /* GC_DUPLICATE: the collector knows the thread already (it started it, or it was registered before). */
  int status = GC_register_my_thread(&base);
  return status == GC_SUCCESS || status == GC_DUPLICATE;
#endif
}

void agc_gc_thread_leave(void) {
#ifndef AGC_NO_GC
  GC_unregister_my_thread();
#endif
}

#ifndef AGC_NO_GC
/* GC_do_blocking takes a function that returns a pointer. */
static void *run_blocking(void *data) {
  const blocking_call *call = data;
  call->fn(call->arg);
  return NULL;
}

/* GC_do_blocking with the caller's callee-saved registers stored in this frame. libgc 8.2 records the low end of a
   blocked thread's stack scan as the frame address of GC_do_blocking; when the compiler inlines the register save of
   GC_with_callee_saves_pushed into it (clang on macOS, where libgc has no getcontext), the saves land below that
   address and are not scanned, so a value the caller keeps only in a register (an an_term across an_blocking) can be
   collected (#1328). This frame is above GC_do_blocking's, so the scan covers its saves; the asm after the call keeps
   it from becoming a tail call, which would drop the frame. GC_do_blocking must stay an out-of-line call into libgc:
   with libgc in the same LTO unit it would be inlined here and the bug would come back. bdwgc commit 68622845ad fixes
   this by marking GC_with_callee_saves_pushed noinline; no release has it yet (8.2.12 is the newest): drop this
   function once the vendored bdwgc and the minimum system libgc (GC_MIN in mk/vm.mk) include it. */
__attribute__((noinline)) static void *blocking_with_registers_saved(blocking_call *call) {
  __builtin_unwind_init();
  void *result = GC_do_blocking(run_blocking, call);
  __asm__ volatile("" : : "r"(result) : "memory");
  return result;
}
#endif

/* Runs FN(ARG) with this thread marked blocked: the collector does not stop it with a signal and scans its stack only
   down to this call, so FN may switch to a stack of its own, and must not touch GC memory. A thread that is not
   registered (the compute pool) is never stopped, so it runs FN as is; so does the build without the collector. */
void agc_gc_blocking(void (*fn)(void *arg), void *arg) {
#ifdef AGC_NO_GC
  fn(arg);
#else
  if (!GC_thread_is_registered()) {
    fn(arg);
    return;
  }
  blocking_call call = {fn, arg};
  (void)blocking_with_registers_saved(&call);
#endif
}

unsigned agc_gc_version(void) {
#ifdef AGC_NO_GC
  return 0;
#else
  return GC_get_version();
#endif
}

/* The loader holds the collector off while it builds a program: everything it allocates stays live until the load ends
 * (or fails and the program is dropped), so a collection can only mark it again, and the program is megabytes for the
 * front end. Pauses nest. The GC-stress build ignores them, so it still collects while loading. */
void agc_gc_pause(void) {
#if !defined(AGC_NO_GC) && !defined(AGC_GC_STRESS)
  GC_disable();
#endif
}

void agc_gc_resume(void) {
#if !defined(AGC_NO_GC) && !defined(AGC_GC_STRESS)
  GC_enable();
#endif
}

bool agc_gc_stats(agc_gc_info *info) {
#ifdef AGC_NO_GC
  (void)info;
  return false;
#else
  info->collections = (uint64_t)GC_get_gc_no();
  info->heap = (uint64_t)GC_get_heap_size();
  info->free = (uint64_t)GC_get_free_bytes();
  info->since = (uint64_t)GC_get_bytes_since_gc();
  info->total_ms = (uint64_t)GC_get_full_gc_total_time();
  return true;
#endif
}

/* Starts Boehm's clock for the collections; agc_gc_stats then reports their total time (the profile trace category). */
void agc_gc_measure(void) {
#ifndef AGC_NO_GC
  GC_start_performance_measurement();
#endif
}

void agc_gc_collect(void) {
#ifndef AGC_NO_GC
  GC_gcollect();
#endif
}

void agc_free(void *object) {
#ifdef AGC_NO_GC
  if (!on_limit) free(object);
#else
  if (__builtin_expect(counting, 0)) {
    counts.freed_objects++;
    counts.freed_bytes += GC_size(object);
  }
  GC_FREE(object);
#endif
}

#ifndef AGC_NO_GC
static size_t pause_bucket(uint64_t us) {
  if (us < PAUSE_EXACT) return (size_t)us;
  unsigned top = 63u - (unsigned)__builtin_clzll(us);
  return PAUSE_EXACT + (size_t)(top - 4) * 4 + (size_t)((us >> (top - 2)) & 3);
}

static uint64_t pause_bucket_end(size_t bucket) {
  if (bucket < PAUSE_EXACT) return bucket;
  unsigned top = (unsigned)((bucket - PAUSE_EXACT) / 4) + 4;
  uint64_t quarter = (bucket - PAUSE_EXACT) % 4;
  return ((5 + quarter) << (top - 2)) - 1;
}

/* Runs in the collecting thread with the collector's lock held, the world stopped or not: it reads a clock and the
   collector's counters (the _unsafe getter, as the lock is held) and allocates nothing. */
static void GC_CALLBACK on_gc_event(GC_EventType event) {
  pause_record *r = &pause_log;
  if (event == GC_EVENT_PRE_STOP_WORLD) {
    r->stop_ns = agc_trace_now();
  } else if (event == GC_EVENT_POST_START_WORLD && r->stop_ns) {
    uint64_t ns = agc_trace_now() - r->stop_ns;
    r->stop_ns = 0;
    r->pauses++;
    r->total_ns += ns;
    if (ns > r->max_ns) r->max_ns = ns;
    r->buckets[pause_bucket(ns / 1000)]++;
  } else if (event == GC_EVENT_RECLAIM_END) {
    struct GC_prof_stats_s stats;
    (void)GC_get_prof_stats_unsafe(&stats, sizeof stats);
    r->used_last = stats.heapsize_full > stats.free_bytes_full ? stats.heapsize_full - stats.free_bytes_full : 0;
    if (r->used_last > r->used_max) r->used_max = r->used_last;
  }
}

static void *clear_record(void *unused) {
  (void)unused;
  memset(&pause_log, 0, sizeof pause_log);
  pause_log.start_ns = agc_trace_now();
  pause_log.start_cpu_us = agc_trace_cpu_us();
  return NULL;
}

static void *copy_record(void *out) {
  memcpy(out, &pause_log, sizeof pause_log);
  return NULL;
}

static uint64_t pause_rank(const pause_record *r, uint64_t rank) {
  uint64_t seen = 0;
  for (size_t b = 0; b < PAUSE_BUCKETS; b++) {
    seen += r->buckets[b];
    if (seen >= rank) return pause_bucket_end(b);
  }
  return r->max_ns / 1000;
}
#endif

void agc_gc_record_start(void) {
#ifndef AGC_NO_GC
  (void)GC_call_with_alloc_lock(clear_record, NULL);
  GC_set_on_collection_event(on_gc_event);
#endif
}

bool agc_gc_record(agc_gc_pauses *out) {
#ifdef AGC_NO_GC
  (void)out;
  return false;
#else
  pause_record r;
  (void)GC_call_with_alloc_lock(copy_record, &r);
  uint64_t max_us = r.max_ns / 1000;
  uint64_t p50 = pause_rank(&r, (r.pauses + 1) / 2), p99 = pause_rank(&r, r.pauses - r.pauses / 100);
  uint64_t cpu_us = agc_trace_cpu_us();
  *out = (agc_gc_pauses){r.total_ns / 1000,
                         (agc_trace_now() - r.start_ns) / 1000,
                         cpu_us > r.start_cpu_us ? cpu_us - r.start_cpu_us : 0,
                         r.pauses,
                         p50 < max_us ? p50 : max_us,
                         p99 < max_us ? p99 : max_us,
                         max_us,
                         r.used_last,
                         r.used_max};
  return true;
#endif
}

#ifndef AGC_NO_GC
/* Reads the link under the collector's lock (GC_call_with_alloc_lock): the collector clears links after it has marked,
   with that lock held and the other threads running, so a read without it could see the pointer of an object the
   collection has already found unreachable. A pointer read under the lock is on this thread's stack before the next
   collection marks, so it stays live. */
static void *reveal(void *data) {
  const agc_weak *w = data;
  return w->hidden ? (void *)GC_REVEAL_POINTER(w->hidden) : NULL;
}
#endif

agc_weak *agc_weak_new(void *object) {
  agc_weak *w = agc_alloc_atomic(sizeof *w);
#ifdef AGC_NO_GC
  w->hidden = (uintptr_t)object;
#else
  w->hidden = GC_HIDE_POINTER(object);
  /* The macro, as GC_REGISTER_FINALIZER_NO_ORDER: under GC_DEBUG (the GC-stress build) it passes the block's base. */
  if (GC_GENERAL_REGISTER_DISAPPEARING_LINK((void **)&w->hidden, object) == GC_NO_MEMORY) agc_out_of_memory();
#endif
  return w;
}

void *agc_weak_get(agc_weak *w) {
#ifdef AGC_NO_GC
  return (void *)w->hidden;
#else
  return GC_call_with_alloc_lock(reveal, w);
#endif
}

#ifdef AGC_NO_GC
/* The limit is soft up to twice its size: past it, an allocation still succeeds and only marks the run. The
   interpreter sees the mark at the next step taken after a charge or at a turn start (set_counter) and jumps there
   (agc_alloc_limit_check), outside any builtin that holds malloc'd memory, so the fuzzer's leak check sees no false
   leak. Past twice the limit the allocation jumps at once: a builtin that allocates without charging (AGC_OP_LIST,
   say) can still get there midway, a known hole. */
static void *own(size_t size) {
  if (heap_limit && (size > heap_limit || atomic_fetch_add(&heap_used, size) > heap_limit - size))
    agc_heap_limit_reached();
  if (!on_limit) return calloc(1, size);
  size_t cost = size > SIZE_MAX - BLOCK_COST ? SIZE_MAX : size + BLOCK_COST;
  size_t hard = limit_bytes > SIZE_MAX / 2 ? SIZE_MAX : limit_bytes * 2;
  if (owned_bytes > hard || cost > hard - owned_bytes) longjmp(*on_limit, 1);
  if (cost > limit_bytes - (owned_bytes < limit_bytes ? owned_bytes : limit_bytes)) over_limit = true;
  void *p = calloc(1, size);
  if (!p) agc_out_of_memory();
  owned_bytes += cost;
  if (owned_count == owned_cap) {
    size_t cap = owned_cap ? owned_cap * 2 : 1024;
    void **bigger = realloc(owned, cap * sizeof *owned);
    if (!bigger) agc_out_of_memory();
    owned = bigger;
    owned_cap = cap;
  }
  owned[owned_count++] = p;
  return p;
}
#endif

void agc_set_alloc_limit(jmp_buf *target, size_t limit) {
#ifdef AGC_NO_GC
  on_limit = target;
  limit_bytes = limit;
#else
  (void)target;
  (void)limit;
#endif
}

void agc_release_all(void) {
#ifdef AGC_NO_GC
  for (size_t i = 0; i < owned_count; i++) free(owned[i]);
  owned_count = 0;
  owned_bytes = 0;
  on_limit = NULL;
  over_limit = false;
#endif
}

#ifdef AGC_NO_GC
bool agc_alloc_over_limit(void) { return over_limit; }

void agc_alloc_limit_check(void) {
  if (over_limit && on_limit) longjmp(*on_limit, 1);
}
#endif

#ifdef AGC_GC_STRESS
static void stress(void) {
  static _Atomic unsigned count;
  if (++count % 64 == 0) GC_gcollect();
}
#else
static void stress(void) {}
#endif

static __attribute__((noinline, cold)) void count_alloc(size_t size, bool atomic) {
  if (atomic) {
    counts.atomic_objects++;
    counts.atomic_bytes += size;
  } else {
    counts.scanned_objects++;
    counts.scanned_bytes += size;
  }
  if (size >= AGC_LARGE_OBJECT) {
    counts.large_objects++;
    counts.large_bytes += size;
  }
}

void agc_alloc_count_start(void) {
  memset(&counts, 0, sizeof counts);
  counting = true;
}

agc_alloc_counts agc_alloc_count_end(void) {
  counting = false;
  return counts;
}

void *agc_alloc(size_t size) {
  stress();
  if (__builtin_expect(counting, 0)) count_alloc(size, false);
#ifdef AGC_NO_GC
  void *p = own(size ? size : 1);
#else
  void *p = GC_MALLOC(size ? size : 1);
#endif
  if (!p) agc_out_of_memory();
  return p;
}

void *agc_alloc_atomic(size_t size) {
  stress();
  if (__builtin_expect(counting, 0)) count_alloc(size, true);
#ifdef AGC_NO_GC
  void *p = own(size ? size : 1);
#else
  void *p = GC_MALLOC_ATOMIC(size ? size : 1);
#endif
  if (!p) agc_out_of_memory();
  return p;
}

size_t agc_size_add(size_t a, size_t b) {
  size_t r;
  if (__builtin_add_overflow(a, b, &r)) agc_out_of_memory();
  return r;
}

size_t agc_size_mul(size_t a, size_t b) {
  size_t r;
  if (__builtin_mul_overflow(a, b, &r)) agc_out_of_memory();
  return r;
}

agc_value agc_result_value(bool ok, agc_value value) {
  agc_result *r = agc_alloc(sizeof(agc_result));
  r->ok = ok;
  r->value = value;
  agc_value v;
  v.tag = AGC_T_RESULT;
  v.as.p = r;
  return v;
}

/* some(value) or none of the builtin Optional, for a caller that knows p has the enum (the loader rejects a Types
   section with an Optional and no enum). */
agc_value agc_optional_make(const agc_program *p, bool some, agc_value value) {
  if (!some) return agc_enum_value(p->variants[p->optional].shared);
  agc_enum *e = agc_new_enum(p->optional + 1, 1);
  e->payload[0] = value;
  return agc_enum_value(e);
}

/* agc_optional_make for a builtin. A program whose lowering calls a builtin that returns an Optional has the enum (its
   type is an expression type there), so only hand-made bytecode lacks it. */
agc_value agc_optional_value(agc_vm *vm, bool some, agc_value value, uint32_t span) {
  const agc_program *p = vm->rt->program;
  if (p->optional == UINT32_MAX || p->optional >= p->variant_count)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: no Optional enum", span);
  return agc_optional_make(p, some, value);
}

agc_value agc_range_value(int64_t start, int64_t end, bool exclusive) {
  agc_range *r = agc_alloc_atomic(sizeof(agc_range));
  r->start = start;
  r->end = end;
  r->exclusive = exclusive;
  agc_value v;
  v.tag = AGC_T_RANGE;
  v.as.p = r;
  return v;
}

agc_value agc_handle_value(agc_resource *r) {
  agc_value v;
  v.tag = AGC_T_HANDLE;
  v.as.p = r;
  return v;
}

agc_value agc_task_value(agc_task *t) {
  agc_value v;
  v.tag = AGC_T_TASK;
  v.as.p = t;
  return v;
}

agc_value agc_process_value(agc_process *p) {
  agc_value v;
  v.tag = AGC_T_PROCESS;
  v.as.p = p;
  return v;
}

agc_value agc_socket_value(agc_socket *s) {
  agc_value v;
  v.tag = AGC_T_SOCKET;
  v.as.p = s;
  return v;
}

agc_value agc_listener_value(agc_listener *l) {
  agc_value v;
  v.tag = AGC_T_LISTENER;
  v.as.p = l;
  return v;
}

agc_value agc_http_client_value(agc_http_client *c) {
  agc_value v;
  v.tag = AGC_T_HTTP_CLIENT;
  v.as.p = c;
  return v;
}

#ifndef AGC_NO_GC
static void finalize_tls_context(void *object, void *data) {
  (void)data;
  agc_tls_context *c = object;
  c->release(c->config);
  c->config = NULL;
}
#endif

agc_value agc_tls_context_value(void *config, void (*release)(void *config), bool server) {
  agc_tls_context *c = agc_alloc_atomic(sizeof *c);
  c->config = config;
  c->release = release;
  c->server = server;
#ifndef AGC_NO_GC
  GC_REGISTER_FINALIZER_NO_ORDER(c, finalize_tls_context, NULL, NULL, NULL);
#endif
  agc_value v;
  v.tag = AGC_T_TLS_CONTEXT;
  v.as.p = c;
  return v;
}

agc_value agc_test_case_value(agc_test_case *c) {
  agc_value v;
  v.tag = AGC_T_TEST;
  v.as.p = c;
  return v;
}

agc_value agc_http_server_value(agc_http_server *s) {
  agc_value v;
  v.tag = AGC_T_HTTP_SERVER;
  v.as.p = s;
  return v;
}

agc_value agc_channel_value(agc_channel *c) {
  agc_value v;
  v.tag = AGC_T_CHANNEL;
  v.as.p = c;
  return v;
}

agc_value agc_lazy_value(const void *node) {
  agc_value v;
  v.tag = AGC_T_LAZY;
  v.as.p = (void *)node;
  return v;
}

agc_value agc_ats_value(void *table) {
  agc_value v;
  v.tag = AGC_T_ATS;
  v.as.p = table;
  return v;
}

agc_value agc_mutex_value(void *mutex) {
  agc_value v;
  v.tag = AGC_T_MUTEX;
  v.as.p = mutex;
  return v;
}

agc_value agc_builder_value(void *builder) {
  agc_value v;
  v.tag = AGC_T_BUILDER;
  v.as.p = builder;
  return v;
}

agc_value agc_address_value(const void *address) {
  agc_value v;
  v.tag = AGC_T_ADDRESS;
  v.as.p = (void *)address;
  return v;
}

agc_value agc_c_pointer_value(void *pointer) {
  agc_value v;
  v.tag = AGC_T_C_POINTER;
  v.as.p = pointer;
  return v;
}

agc_value agc_c_resource_value(agc_c_resource *r) {
  agc_value v;
  v.tag = AGC_T_C_RESOURCE;
  v.as.p = r;
  return v;
}

uint64_t agc_value_units(agc_value v) {
  while (v.tag == AGC_T_RESULT) v = ((const agc_result *)v.as.p)->value;
  switch (v.tag) {
    case AGC_T_STRING: return ((const agc_string *)v.as.p)->bytes / AGC_COST_BYTES;
    case AGC_T_BYTES: return ((const agc_bytes *)v.as.p)->len / AGC_COST_BYTES;
    case AGC_T_LIST: return agc_list_len(v.as.p);
    case AGC_T_MAP:
    case AGC_T_SET: return ((const agc_map *)v.as.p)->size;
    case AGC_T_JSON: {
      /* The count of a float leaf is the side hint of agc_json_to_float32, not a size. */
      const agc_json *j = v.as.p;
      return j->kind == AGC_JSON_FLOAT ? 0 : j->count;
    }
    default: return 0;
  }
}

bool agc_range_bounds(const agc_range *r, int64_t *first, int64_t *last) {
  *first = r->start;
  *last = r->end;
  if (r->exclusive) {
    if (r->end <= r->start) return false;
    *last = r->end - 1;
    return true;
  }
  return r->start <= r->end;
}

agc_fn *agc_new_fn(uint32_t function, uint32_t n) {
  agc_fn *f = agc_alloc(agc_size_add(sizeof(agc_fn), agc_size_mul(n, sizeof(agc_value))));
  f->function = function;
  f->n = n;
  return f;
}

agc_struct *agc_new_struct(uint32_t type, uint32_t n) {
  agc_struct *s = agc_alloc(agc_size_add(sizeof(agc_struct), agc_size_mul(n, sizeof(agc_value))));
  s->type = type;
  s->n = n;
  return s;
}

agc_enum *agc_new_enum(uint32_t variant, uint32_t n) {
  agc_enum *e = agc_alloc(agc_size_add(sizeof(agc_enum), agc_size_mul(n, sizeof(agc_value))));
  e->variant = variant;
  e->n = n;
  return e;
}

agc_string *agc_new_string(size_t bytes, size_t chars) {
  agc_string *s = agc_alloc_atomic(agc_size_add(sizeof(agc_string), bytes));
  s->bytes = bytes;
  s->chars = chars;
  return s;
}

agc_string *agc_make_string(const char *data, size_t bytes, size_t chars) {
  agc_string *s = agc_new_string(bytes, chars);
  if (bytes) memcpy(s->data, data, bytes);
  return s;
}

agc_string *agc_small_string(agc_vm *vm, const char *data, size_t bytes, size_t chars) {
  if (bytes == 0) return vm->rt->empty_string;
  if (bytes == 1 && (uint8_t)data[0] < AGC_ASCII_CHARS) return vm->rt->chars[(uint8_t)data[0]];
  return agc_make_string(data, bytes, chars);
}

agc_bytes *agc_new_bytes(size_t len) {
  agc_bytes *b = agc_alloc_atomic(agc_size_add(sizeof(agc_bytes), len));
  b->len = len;
  return b;
}

static const agc_bytes empty_bytes = {0};

const agc_bytes *agc_empty_bytes(void) { return &empty_bytes; }

const agc_bytes *agc_make_bytes(const uint8_t *data, size_t len) {
  if (len == 0) return agc_empty_bytes();
  agc_bytes *b = agc_new_bytes(len);
  memcpy(b->data, data, len);
  return b;
}

agc_value agc_error_value(const char *message) {
  size_t n = strlen(message);
  return agc_result_value(false, agc_string_value(agc_make_string(message, n, n)));
}

const char *agc_error_kind_name(agc_error_kind kind) { return kind_names[kind]; }

agc_string **agc_error_kinds(void) {
  agc_string **kinds = agc_alloc(sizeof(agc_string *) * AGC_KIND_COUNT);
  for (size_t k = 0; k < AGC_KIND_COUNT; k++) {
    size_t n = strlen(kind_names[k]);
    kinds[k] = agc_make_string(kind_names[k], n, n);
  }
  return kinds;
}

/* The empty map, none and the kinds are the run's shared values (agc_vm_init and the loader made them before any
   thread), so an error built on any scheduler allocates only its struct, its location and a code that it has. */
static agc_value error_of(agc_vm *vm, agc_error_kind kind, agc_string *named, agc_string *message, bool coded,
                          int64_t code) {
  const agc_runtime *rt = vm->rt;
  if (rt->error_struct == UINT32_MAX) return agc_result_value(false, agc_string_value(message));
  agc_value none = agc_optional_make(rt->program, false, agc_void());
  agc_struct *e = agc_new_struct(rt->error_struct, AGC_ERROR_FIELDS);
  e->fields[AGC_ERROR_KIND] = agc_string_value(named ? named : rt->kinds[kind]);
  e->fields[AGC_ERROR_MESSAGE] = agc_string_value(message);
  e->fields[AGC_ERROR_CODE] = coded ? agc_optional_make(rt->program, true, agc_int(code)) : none;
  e->fields[AGC_ERROR_DETAILS] = rt->empty_map;
  e->fields[AGC_ERROR_CAUSE] = none;
  e->fields[AGC_ERROR_LOCATION] = agc_string_value(agc_error_location(vm));
  return agc_result_value(false, agc_struct_value(e));
}

agc_value agc_error_string(agc_vm *vm, agc_error_kind kind, agc_string *message) {
  return error_of(vm, kind, NULL, message, false, 0);
}

agc_value agc_error_named(agc_vm *vm, agc_string *kind, agc_string *message) {
  return error_of(vm, AGC_KIND_ERROR, kind, message, false, 0);
}

agc_value agc_error_code(agc_vm *vm, agc_error_kind kind, agc_string *message, int64_t code) {
  return error_of(vm, kind, NULL, message, true, code);
}

agc_value agc_error(agc_vm *vm, agc_error_kind kind, const char *message) {
  size_t n = strlen(message);
  return agc_error_string(vm, kind, agc_utf8_decode((const uint8_t *)message, n, "\xEF\xBF\xBD"));
}

agc_value agc_error_detail(agc_vm *vm, agc_value result, const char *key, const char *data, size_t len) {
  const agc_result *r = agc_as_result(vm, result);
  if (r->ok || !agc_is_error(vm, r->value)) return result;
  agc_struct *e = agc_as_struct(vm, r->value);
  size_t n = strlen(key);
  agc_value name = agc_string_value(agc_make_string(key, n, n));
  agc_value text = agc_string_value(agc_utf8_decode((const uint8_t *)data, len, "\xEF\xBF\xBD"));
  const agc_map *details = agc_as_map(vm, e->fields[AGC_ERROR_DETAILS]);
  e->fields[AGC_ERROR_DETAILS] = agc_map_value(agc_map_put(vm, details, name, text));
  return result;
}

bool agc_is_error(const agc_vm *vm, agc_value v) {
  uint32_t type = vm->rt->error_struct;
  return type != UINT32_MAX && v.tag == AGC_T_STRUCT && ((const agc_struct *)v.as.p)->type == type &&
         ((const agc_struct *)v.as.p)->n == AGC_ERROR_FIELDS;
}

agc_string *agc_error_message(agc_vm *vm, agc_value payload) {
  if (!agc_is_error(vm, payload)) return agc_as_string(vm, payload);
  return agc_as_string(vm, agc_as_struct(vm, payload)->fields[AGC_ERROR_MESSAGE]);
}

agc_string *agc_error_halt_text(agc_vm *vm, agc_value payload) {
  agc_string *message = agc_error_message(vm, payload);
  if (!agc_is_error(vm, payload)) return message;
  const agc_string *kind = agc_as_string(vm, agc_as_struct(vm, payload)->fields[AGC_ERROR_KIND]);
  if (kind->bytes == 5 && memcmp(kind->data, "error", 5) == 0) return message;
  size_t bytes = agc_size_add(agc_size_add(message->bytes, kind->bytes), 3);
  agc_string *text = agc_new_string(bytes, agc_size_add(agc_size_add(message->chars, kind->chars), 3));
  char *at = text->data;
  memcpy(at, message->data, message->bytes);
  at += message->bytes;
  memcpy(at, " (", 2);
  memcpy(at + 2, kind->data, kind->bytes);
  at[2 + kind->bytes] = ')';
  return text;
}

_Noreturn void agc_wrong_tag(agc_vm *vm) {
  agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: wrong value type", 0);
}

agc_resource *agc_as_handle(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_HANDLE) agc_wrong_tag(vm);
  return v.as.p;
}

agc_task *agc_as_task(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_TASK) agc_wrong_tag(vm);
  return v.as.p;
}

agc_process *agc_as_process(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_PROCESS) agc_wrong_tag(vm);
  return v.as.p;
}

agc_socket *agc_as_socket(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_SOCKET) agc_wrong_tag(vm);
  return v.as.p;
}

agc_listener *agc_as_listener(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_LISTENER) agc_wrong_tag(vm);
  return v.as.p;
}

agc_http_client *agc_as_http_client(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_HTTP_CLIENT) agc_wrong_tag(vm);
  return v.as.p;
}

agc_tls_context *agc_as_tls_context(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_TLS_CONTEXT) agc_wrong_tag(vm);
  return v.as.p;
}

agc_test_case *agc_as_test_case(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_TEST) agc_wrong_tag(vm);
  return v.as.p;
}

agc_http_server *agc_as_http_server(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_HTTP_SERVER) agc_wrong_tag(vm);
  return v.as.p;
}

agc_channel *agc_as_channel(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_CHANNEL) agc_wrong_tag(vm);
  return v.as.p;
}

const void *agc_as_lazy(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_LAZY) agc_wrong_tag(vm);
  return v.as.p;
}

void *agc_as_ats(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_ATS) agc_wrong_tag(vm);
  return v.as.p;
}

void *agc_as_mutex(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_MUTEX) agc_wrong_tag(vm);
  return v.as.p;
}

void *agc_as_builder(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_BUILDER) agc_wrong_tag(vm);
  return v.as.p;
}

const void *agc_as_address(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_ADDRESS) agc_wrong_tag(vm);
  return v.as.p;
}

void *agc_as_c_pointer(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_C_POINTER) agc_wrong_tag(vm);
  return v.as.p;
}

agc_c_resource *agc_as_c_resource(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_C_RESOURCE) agc_wrong_tag(vm);
  return v.as.p;
}

char *agc_cstr(const agc_string *s) {
  if (s->bytes && memchr(s->data, 0, s->bytes)) return NULL;
  char *copy = malloc(agc_size_add(s->bytes, 1));
  if (!copy) agc_out_of_memory();
  if (s->bytes) memcpy(copy, s->data, s->bytes);
  copy[s->bytes] = '\0';
  return copy;
}

size_t agc_utf8_width(uint8_t lead) { return lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4; }

uint32_t agc_utf8_next(const uint8_t *s, size_t len, size_t *at) {
  static const uint8_t lead_mask[] = {0, 0x7F, 0x1F, 0x0F, 0x07};
  size_t width = agc_utf8_width(s[*at]);
  if (width > len - *at) width = len - *at;
  uint32_t cp = s[*at] & lead_mask[width];
  for (size_t k = 1; k < width; k++) cp = (cp << 6) | (s[*at + k] & 0x3Fu);
  *at += width;
  return cp;
}

static inline size_t valid_char(const uint8_t *s, size_t len) {
  if (len == 0) return 0;
  uint8_t c = s[0];
  size_t n;
  uint32_t cp;
  if (c < 0x80) {
    return 1;
  } else if (c >= 0xC2 && c <= 0xDF) {
    n = 1;
    cp = c & 0x1F;
  } else if (c >= 0xE0 && c <= 0xEF) {
    n = 2;
    cp = c & 0x0F;
  } else if (c >= 0xF0 && c <= 0xF4) {
    n = 3;
    cp = c & 0x07;
  } else {
    return 0;
  }
  if (len - 1 < n) return 0;
  for (size_t k = 1; k <= n; k++) {
    uint8_t d = s[k];
    if ((d & 0xC0) != 0x80) return 0;
    cp = (cp << 6) | (d & 0x3F);
  }
  if ((n == 2 && cp < 0x800) || (n == 3 && cp < 0x10000) || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
    return 0;
  return n + 1;
}

size_t agc_utf8_valid(const uint8_t *s, size_t len) { return valid_char(s, len); }

/* The offset (from 0) of the first byte that does not start a valid character, or len when all of it is valid. */
size_t agc_utf8_bad_at(const uint8_t *s, size_t len) {
  size_t at = 0;
  for (size_t n; at < len && (n = valid_char(s + at, len - at)) != 0;) at += n;
  return at;
}

/* The characters of valid UTF-8: every byte but the continuation bytes (10xxxxxx). The inner loops have a fixed count,
 * so the compiler vectorizes them at -O2 (GCC's cheap cost model skips a loop whose count it does not know). */
size_t agc_utf8_count(const uint8_t *s, size_t len) {
  size_t count = 0, i = 0;
  for (; len - i >= 32; i += 32) {
    uint8_t block = 0;
    for (size_t k = 0; k < 32; k++) block += (s[i + k] & 0xC0) != 0x80;
    count += block;
  }
  for (; len - i >= 8; i += 8) {
    uint8_t block = 0;
    for (size_t k = 0; k < 8; k++) block += (s[i + k] & 0xC0) != 0x80;
    count += block;
  }
  for (; i < len; i++) count += (s[i] & 0xC0) != 0x80;
  return count;
}

/* The length of the valid UTF-8 at the start of s, with its characters in *chars. Most text is ASCII, so a run of it
 * is skipped eight bytes at a time (no byte with the high bit set) and the characters are decoded one by one only
 * where a word has a byte of 0x80 or more. */
static size_t valid_run(const uint8_t *s, size_t len, size_t *chars) {
  size_t count = 0, i = 0;
  while (i < len) {
    uint64_t word;
    while (len - i >= sizeof word) {
      memcpy(&word, s + i, sizeof word);
      if (word & UINT64_C(0x8080808080808080)) break;
      i += sizeof word;
      count += sizeof word;
    }
    if (i == len) break;
    size_t n = valid_char(s + i, len - i);
    if (n == 0) break;
    i += n;
    count++;
  }
  *chars = count;
  return i;
}

bool agc_utf8_chars(const uint8_t *s, size_t len, size_t *chars) { return valid_run(s, len, chars) == len; }

/* The length of the bad sequence at s, where no valid character starts: its longest start that a valid character
   could have, at least the first byte. Each one gets one replacement (Unicode §3.9, "U+FFFD Substitution of Maximal
   Subparts"), as in the WHATWG decoder and Python's decode("utf-8", "replace"); a cut character at the end is one. */
static size_t maximal_subpart(const uint8_t *s, size_t len) {
  uint8_t c = s[0];
  size_t width = c >= 0xC2 && c <= 0xDF ? 2 : c >= 0xE0 && c <= 0xEF ? 3 : c >= 0xF0 && c <= 0xF4 ? 4 : 1;
  uint8_t lo = c == 0xE0 ? 0xA0 : c == 0xF0 ? 0x90 : 0x80, hi = c == 0xED ? 0x9F : c == 0xF4 ? 0x8F : 0xBF;
  size_t n = 1;
  for (; n < width && n < len; n++) {
    if (s[n] < (n == 1 ? lo : 0x80) || s[n] > (n == 1 ? hi : 0xBF)) break;
  }
  return n;
}

size_t agc_utf8_cut_tail(const uint8_t *data, size_t len) {
  for (size_t k = 1; k <= 3 && k <= len; k++) {
    const uint8_t *s = data + len - k;
    if (*s >= 0x80 && *s <= 0xBF) continue;
    bool lead = *s >= 0xC2 && *s <= 0xF4;
    return lead && agc_utf8_width(*s) > k && maximal_subpart(s, k) == k ? k : 0;
  }
  return 0;
}

size_t agc_utf8_scrub(const uint8_t *data, size_t len, const char *replacement, size_t rbytes, size_t rchars,
                      char *out, size_t *chars) {
  size_t bytes = 0, count = 0;
  *chars = 0;
  if (len == 0) return 0;
  for (size_t i = 0;;) {
    size_t run_chars, run = valid_run(data + i, len - i, &run_chars);
    if (out && run) memcpy(out + bytes, data + i, run);
    bytes = agc_size_add(bytes, run);
    count += run_chars;
    i += run;
    if (i == len) break;
    if (out && rbytes) memcpy(out + bytes, replacement, rbytes);
    bytes = agc_size_add(bytes, rbytes);
    count += rchars;
    i += maximal_subpart(data + i, len - i);
  }
  *chars = count;
  return bytes;
}

agc_string *agc_utf8_decode(const uint8_t *data, size_t len, const char *replacement) {
  size_t rbytes = strlen(replacement), rchars = agc_utf8_count((const uint8_t *)replacement, rbytes), chars;
  size_t bytes = agc_utf8_scrub(data, len, replacement, rbytes, rchars, NULL, &chars);
  agc_string *s = agc_new_string(bytes, chars);
  agc_utf8_scrub(data, len, replacement, rbytes, rchars, s->data, &chars);
  return s;
}

static size_t put(char *out, size_t at, const char *text, size_t len) {
  memcpy(out + at, text, len);
  return at + len;
}

/* Shortest round-trip digits, derived from Ryu (github.com/ulfjack/ryu; "Ryu: fast float-to-string conversion", PLDI
   2018), Copyright 2018 Ulf Adams, used under Apache-2.0 (Ryu is dual-licensed). Changed from Ryu's d2s.c: an exact tie
   rounds up, and the small tables were generated again from their definitions: pow5_split[k] is the top 125 bits of
   5^(26k) and pow5_inv_split[k] is 2^(124 + bits(5^(26k))) / 5^(26k) + 1; the 2-bit offsets correct the powers in
   between to the values of Ryu's full tables. */
static const uint64_t pow5_small[26] = {
    1u, 5u, 25u, 125u, 625u, 3125u, 15625u, 78125u, 390625u, 1953125u, 9765625u, 48828125u, 244140625u,
    1220703125u, 6103515625u, 30517578125u, 152587890625u, 762939453125u, 3814697265625u, 19073486328125u,
    95367431640625u, 476837158203125u, 2384185791015625u, 11920928955078125u, 59604644775390625u,
    298023223876953125u,
};
static const uint64_t pow5_split[13][2] = {
    {0x0000000000000000u, 0x1000000000000000u},
    {0x0000000000000000u, 0x14adf4b7320334b9u},
    {0x0e549208b31adb10u, 0x1aba4714957d300du},
    {0x6dc6ad264d8f0866u, 0x1145b7e285bf98f5u},
    {0xeb1dbd923d8596cau, 0x1652efdc6018a1fcu},
    {0xb4c1b80b22ae923cu, 0x1cda62055b2d9d83u},
    {0x5bb28b4e8f7e4c30u, 0x12a5568b9f52f416u},
    {0xf08aed437682d4fbu, 0x1819651531f9e78fu},
    {0xb4ee134ad99bf150u, 0x1f25c186a6f04c28u},
    {0x16499ecb70c25f03u, 0x1420eb449c8842e6u},
    {0x85a56ead360865b0u, 0x1a03fde214caf085u},
    {0x093db1d57999890bu, 0x10cfeb353a97dad8u},
    {0xcf38bb735e3f36acu, 0x15baaf44fa52673eu},
};
static const uint32_t pow5_offsets[21] = {
    0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u,
    0x40000000u, 0x59695995u, 0x55545555u, 0x56555515u,
    0x41150504u, 0x40555410u, 0x44555145u, 0x44504540u,
    0x45555550u, 0x40004000u, 0x96440440u, 0x55565565u,
    0x54454045u, 0x40154151u, 0x55559155u, 0x51405555u,
    0x00000105u,
};
static const uint64_t pow5_inv_split[13][2] = {
    {0x0000000000000001u, 0x2000000000000000u},
    {0x52a6c95fc0655034u, 0x18c240c4aecb13bbu},
    {0x7ca8d50071dfc806u, 0x1327fc58da0f6ff5u},
    {0x6520247d3556476eu, 0x1da48ce468e7c702u},
    {0x6139cdd76802e6e9u, 0x16ef5b40c2fc7779u},
    {0xf951a7ff43de8c79u, 0x11bebdf578b2f391u},
    {0x7be8bee8d6e957e8u, 0x1b758d848fac54b0u},
    {0x8bd3f9e999a423eau, 0x153eda614071a3b7u},
    {0x0848f973cb3ee3ceu, 0x10701bd527b4978cu},
    {0x153285ebb9efbfa2u, 0x196fbb9bb44db44du},
    {0xadeee7f86c07b696u, 0x13ae3591f5b4d936u},
    {0x4d686a4eaf182222u, 0x1e74404f3daada91u},
    {0x98c0a106e09ebd9fu, 0x17900ea4fda7c257u},
};
static const uint32_t pow5_inv_offsets[19] = {
    0x54544554u, 0x04055545u, 0x10041000u, 0x00400414u,
    0x40010000u, 0x41155555u, 0x00000454u, 0x00010044u,
    0x40000000u, 0x44000041u, 0x50454450u, 0x55550054u,
    0x51655554u, 0x40004000u, 0x01000001u, 0x00010500u,
    0x51515411u, 0x05555554u, 0x00000000u,
};

static uint64_t umul128(uint64_t a, uint64_t b, uint64_t *high) {
#ifdef __SIZEOF_INT128__
  unsigned __int128 p = (unsigned __int128)a * b;
  *high = (uint64_t)(p >> 64);
  return (uint64_t)p;
#else
  uint64_t a0 = (uint32_t)a, a1 = a >> 32, b0 = (uint32_t)b, b1 = b >> 32;
  uint64_t p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
  uint64_t mid = p10 + (p00 >> 32) + (uint32_t)p01;
  *high = p11 + (mid >> 32) + (p01 >> 32);
  return (mid << 32) | (uint32_t)p00;
#endif
}

static uint64_t shift128(uint64_t low, uint64_t high, int dist) { return (high << (64 - dist)) | (low >> dist); }

static int pow5bits(int e) { return (int)(((uint32_t)e * 1217359) >> 19) + 1; }

/* m * (mul[1]:mul[0]) as high:mid:low; returns mid and sets high. */
static uint64_t mul_192(uint64_t m, const uint64_t mul[2], uint64_t *low, uint64_t *high) {
  uint64_t high0;
  uint64_t low1 = umul128(m, mul[1], high);
  *low = umul128(m, mul[0], &high0);
  uint64_t mid = high0 + low1;
  *high += mid < high0;
  return mid;
}

static void pow5_at(int i, uint64_t out[2]) {
  int base = i / 26 * 26;
  const uint64_t *mul = pow5_split[i / 26];
  if (base == i) {
    out[0] = mul[0];
    out[1] = mul[1];
    return;
  }
  uint64_t low, high, mid = mul_192(pow5_small[i - base], mul, &low, &high);
  int delta = pow5bits(i) - pow5bits(base);
  out[0] = shift128(low, mid, delta) + ((pow5_offsets[i / 16] >> (i % 16 * 2)) & 3);
  out[1] = shift128(mid, high, delta);
}

static void pow5_inv_at(int i, uint64_t out[2]) {
  int base = (i + 25) / 26 * 26;
  const uint64_t *mul = pow5_inv_split[(i + 25) / 26];
  if (base == i) {
    out[0] = mul[0];
    out[1] = mul[1];
    return;
  }
  uint64_t low, high, mid = mul_192(pow5_small[base - i], (const uint64_t[2]){mul[0] - 1, mul[1]}, &low, &high);
  int delta = pow5bits(base) - pow5bits(i);
  out[0] = shift128(low, mid, delta) + 1 + ((pow5_inv_offsets[i / 16] >> (i % 16 * 2)) & 3);
  out[1] = shift128(mid, high, delta);
}

static uint64_t mul_shift(uint64_t m, const uint64_t mul[2], int j) {
  uint64_t low, high, mid = mul_192(m, mul, &low, &high);
  return shift128(mid, high, j - 64);
}

static unsigned pow5_factor(uint64_t value) {
  unsigned count = 0;
  for (; (value *= 14757395258967641293u) <= 3689348814741910323u; count++) {}
  return count;
}

/* The digits of x > 0 (finite) as mantissa * 10^*exponent, with the fewest digits that read back as x and, among
   those, the nearest to x. */
static uint64_t shortest_decimal(double x, int *exponent) {
  uint64_t bits;
  memcpy(&bits, &x, sizeof bits);
  uint64_t fraction = bits & ((UINT64_C(1) << 52) - 1);
  int biased = (int)(bits >> 52) & 0x7FF;
  uint64_t m2 = biased ? fraction | UINT64_C(1) << 52 : fraction;
  int e2 = (biased ? biased : 1) - 1023 - 52 - 2;
  if (biased && e2 + 2 <= 0 && e2 + 2 >= -52 && (m2 & ((UINT64_C(1) << -(e2 + 2)) - 1)) == 0) {
    *exponent = 0;
    return m2 >> -(e2 + 2);
  }
  bool accept_bounds = (m2 & 1) == 0;
  uint64_t mv = 4 * m2;
  uint64_t mm_shift = fraction != 0 || biased <= 1;
  uint64_t mul[2], vr, vp, vm;
  int e10;
  bool vm_zeros = false;
  if (e2 >= 0) {
    int q = (int)(((uint32_t)e2 * 78913) >> 18) - (e2 > 3);
    e10 = q;
    pow5_inv_at(q, mul);
    int j = -e2 + q + 124 + pow5bits(q);
    vr = mul_shift(mv, mul, j);
    vp = mul_shift(mv + 2, mul, j);
    vm = mul_shift(mv - 1 - mm_shift, mul, j);
    if (q <= 21 && mv % 5 != 0) {
      if (accept_bounds)
        vm_zeros = pow5_factor(mv - 1 - mm_shift) >= (unsigned)q;
      else
        vp -= pow5_factor(mv + 2) >= (unsigned)q;
    }
  } else {
    int q = (int)(((uint32_t)-e2 * 732923) >> 20) - (-e2 > 1);
    e10 = q + e2;
    int i = -e2 - q;
    pow5_at(i, mul);
    int j = q - (pow5bits(i) - 125);
    vr = mul_shift(mv, mul, j);
    vp = mul_shift(mv + 2, mul, j);
    vm = mul_shift(mv - 1 - mm_shift, mul, j);
    if (q <= 1) {
      if (accept_bounds)
        vm_zeros = mm_shift == 1;
      else
        vp--;
    }
  }
  int removed = 0;
  unsigned last = 0;
  for (; vp / 10 > vm / 10; removed++) {
    vm_zeros &= vm % 10 == 0;
    last = (unsigned)(vr % 10);
    vr /= 10;
    vp /= 10;
    vm /= 10;
  }
  if (vm_zeros)
    for (; vm % 10 == 0; removed++) {
      last = (unsigned)(vr % 10);
      vr /= 10;
      vp /= 10;
      vm /= 10;
    }
  *exponent = e10 + removed;
  return vr + ((vr == vm && (!accept_bounds || !vm_zeros)) || last >= 5);
}

/* DIGITS (N of them, the first and last not 0) times 10^E for the first one, written at AT: positional, or scientific
   when that is shorter and the positional text is past 16 characters, or the value is below 1e-4. */
static size_t decimal_text(char *out, size_t at, const char *digits, size_t n, int e) {
  int magnitude = e < 0 ? -e : e;
  int exponent_digits = magnitude >= 100 ? 3 : magnitude >= 10 ? 2 : 1;
  int positional = (int)n > e + 1 ? (int)n + 1 : e + 3;
  int scientific = (int)n + (n > 1) + 2 + exponent_digits;
  if (e < -4 || (e >= 0 && positional > 16 && positional > scientific)) {
    out[at++] = digits[0];
    if (n > 1) {
      out[at++] = '.';
      at = put(out, at, digits + 1, n - 1);
    }
    out[at++] = 'e';
    out[at++] = e < 0 ? '-' : '+';
    for (int k = exponent_digits; k-- > 0; magnitude /= 10) out[at + (size_t)k] = (char)('0' + magnitude % 10);
    return at + (size_t)exponent_digits;
  }
  if (e < 0) {
    at = put(out, at, "0.", 2);
    for (int k = -1; k > e; k--) out[at++] = '0';
    return put(out, at, digits, n);
  }
  size_t whole = (size_t)e + 1;
  if (n > whole) {
    at = put(out, at, digits, whole);
    out[at++] = '.';
    return put(out, at, digits + whole, n - whole);
  }
  at = put(out, at, digits, n);
  for (size_t k = n; k < whole; k++) out[at++] = '0';
  return put(out, at, ".0", 2);
}

size_t agc_float_text(double x, char out[AGC_SCALAR_TEXT]) {
  if (isnan(x)) return put(out, 0, "+nan.0", 6);
  if (isinf(x)) return put(out, 0, x > 0 ? "+inf.0" : "-inf.0", 6);
  size_t at = 0;
  if (signbit(x)) {
    out[at++] = '-';
    x = -x;
  }
  if (x == 0) return put(out, at, "0.0", 3);
  int e;
  uint64_t mantissa = shortest_decimal(x, &e);
  for (; mantissa % 10 == 0; e++) mantissa /= 10;
  char digits[20];
  size_t n = 0;
  for (uint64_t m = mantissa; m; m /= 10) n++;
  for (size_t k = n; k > 0; mantissa /= 10) digits[--k] = (char)('0' + mantissa % 10);
  return decimal_text(out, at, digits, n, e + (int)n - 1);
}

/* Float32: a double that holds a binary32 value. The text of a Float32 is read and written here, exactly: on
   integers, with no libc conversion and no locale, so every system gives the same binary32 for a text and the same
   text for a value. */

/* 2^128 - 2^103, halfway between the largest binary32 and 2^128: a magnitude from here up rounds to infinity. */
#define FLOAT32_OVERFLOW 0x1.ffffffp127

/* The significant digits of a decimal that its binary32 depends on: no binary32 value and no midpoint between two
   has more than 113 ((2^25 - 1) * 2^-150), so a text with more is cut to FLOAT32_DIGITS and a nonzero digit cut off
   becomes one more digit 1, which stays between the same two midpoints. */
#define FLOAT32_DIGITS 128

static void big_set(big *b, uint32_t value) {
  b->limb[0] = value;
  b->n = value != 0;
}

static void big_mul_add(big *b, uint32_t factor, uint32_t add) {
  uint64_t carry = add;
  for (size_t k = 0; k < b->n; k++) {
    uint64_t t = (uint64_t)b->limb[k] * factor + carry;
    b->limb[k] = (uint32_t)t;
    carry = t >> 32;
  }
  if (carry && b->n < BIG_LIMBS) b->limb[b->n++] = (uint32_t)carry;
}

static void big_shl(big *b, unsigned bits) {
  if (b->n == 0) return;
  size_t words = bits / 32, n = b->n + words + 1;
  unsigned shift = bits % 32;
  if (n > BIG_LIMBS) n = BIG_LIMBS;
  for (size_t k = n; k-- > 0;) {
    uint64_t high = k >= words && k - words < b->n ? b->limb[k - words] : 0;
    uint64_t low = shift && k >= words + 1 && k - words - 1 < b->n ? b->limb[k - words - 1] : 0;
    b->limb[k] = (uint32_t)((high << shift) | (low >> (32 - shift)));
  }
  b->n = n;
  while (b->n && b->limb[b->n - 1] == 0) b->n--;
}

static int big_cmp(const big *a, const big *b) {
  if (a->n != b->n) return a->n < b->n ? -1 : 1;
  for (size_t k = a->n; k-- > 0;)
    if (a->limb[k] != b->limb[k]) return a->limb[k] < b->limb[k] ? -1 : 1;
  return 0;
}

/* a -= b, for a >= b. */
static void big_sub(big *a, const big *b) {
  int64_t borrow = 0;
  for (size_t k = 0; k < a->n; k++) {
    int64_t t = (int64_t)a->limb[k] - (k < b->n ? b->limb[k] : 0) - borrow;
    borrow = t < 0;
    a->limb[k] = (uint32_t)(t + (borrow ? INT64_C(1) << 32 : 0));
  }
  while (a->n && a->limb[a->n - 1] == 0) a->n--;
}

static unsigned big_bits(const big *b) {
  if (b->n == 0) return 0;
  unsigned bits = (unsigned)(b->n - 1) * 32;
  for (uint32_t top = b->limb[b->n - 1]; top; top >>= 1) bits++;
  return bits;
}

/* The quotient of a / b, which must be below 2^26; a becomes the remainder. */
static uint32_t big_divide(big *a, const big *b) {
  uint32_t q = 0;
  for (unsigned bit = 26; bit-- > 0;) {
    big t = *b;
    big_shl(&t, bit);
    if (big_cmp(a, &t) >= 0) {
      big_sub(a, &t);
      q |= UINT32_C(1) << bit;
    }
  }
  return q;
}

/* b /= divisor; the remainder. */
static uint32_t big_div_small(big *b, uint32_t divisor) {
  uint64_t rest = 0;
  for (size_t k = b->n; k-- > 0;) {
    uint64_t t = rest << 32 | b->limb[k];
    b->limb[k] = (uint32_t)(t / divisor);
    rest = t % divisor;
  }
  while (b->n && b->limb[b->n - 1] == 0) b->n--;
  return (uint32_t)rest;
}

double agc_round_f32(double x) {
  if (fabs(x) >= FLOAT32_OVERFLOW) return copysign(INFINITY, x);
  return (double)(float)x;
}

bool agc_f32_midpoint(double x) {
  uint64_t bits;
  memcpy(&bits, &x, sizeof bits);
  /* A midpoint has at most 25 significant bits: the low 28 of the 52 are zero. Most doubles stop here. */
  if (bits & ((UINT64_C(1) << 28) - 1)) return false;
  x = fabs(x);
  if (!(x < 0x1p128) || x < 0x1p-150) return false;
  int e;
  frexp(x, &e);
  int half = (e - 24 < -149 ? -149 : e - 24) - 1;
  double scaled = ldexp(x, -half);
  return scaled == floor(scaled) && fmod(scaled, 2.0) == 1.0;
}

/* The binary32 nearest DIGITS (N of them, the first and last not 0) times 10^Q, ties to even, as a double; an infinity
   past the largest binary32. With M * 2^E the result, M of 24 bits (fewer for a subnormal), it takes E from the bit
   lengths, divides, and rounds the quotient on its remainder. */
static double decimal_f32(const char *digits, size_t n, int64_t q) {
  int64_t lead = q + (int64_t)n - 1;
  if (lead >= 39) return INFINITY;
  if (lead <= -47) return 0.0;
  big num, den;
  big_set(&num, 0);
  for (size_t k = 0; k < n; k++) big_mul_add(&num, 10, (uint32_t)(digits[k] - '0'));
  big_set(&den, 1);
  for (int64_t k = q; k > 0; k--) big_mul_add(&num, 10, 0);
  for (int64_t k = q; k < 0; k++) big_mul_add(&den, 10, 0);
  int e = (int)big_bits(&num) - (int)big_bits(&den) - 24;
  if (e < -149) e = -149;
  uint32_t m;
  for (;;) {
    big a = num, b = den;
    if (e < 0)
      big_shl(&a, (unsigned)-e);
    else
      big_shl(&b, (unsigned)e);
    m = big_divide(&a, &b);
    if (m >= UINT32_C(1) << 24) {
      e++;
      continue;
    }
    big_shl(&a, 1);
    int c = big_cmp(&a, &b);
    if (c > 0 || (c == 0 && (m & 1))) m++;
    break;
  }
  if (m == UINT32_C(1) << 24) {
    m >>= 1;
    e++;
  }
  return e > 104 ? INFINITY : ldexp((double)m, e);
}

bool agc_read_float32(const char *s, size_t len, double *out) {
  size_t i = len > 0 && s[0] == '-';
  bool negative = i == 1, cut = false;
  char digits[FLOAT32_DIGITS + 1];
  size_t n = 0, first = i;
  int64_t q = 0;
  for (; i < len && s[i] >= '0' && s[i] <= '9'; i++) {
    if (n == FLOAT32_DIGITS) {
      cut |= s[i] != '0';
      q++;
    } else if (n > 0 || s[i] != '0') {
      digits[n++] = s[i];
    }
  }
  if (i == first) return false;
  if (i < len && s[i] == '.') {
    first = ++i;
    for (; i < len && s[i] >= '0' && s[i] <= '9'; i++) {
      if (n == FLOAT32_DIGITS) {
        cut |= s[i] != '0';
        continue;
      }
      if (n > 0 || s[i] != '0') digits[n++] = s[i];
      q--;
    }
    if (i == first) return false;
  }
  if (i < len && (s[i] == 'e' || s[i] == 'E')) {
    bool down = ++i < len && s[i] == '-';
    i += i < len && (s[i] == '+' || s[i] == '-');
    first = i;
    int64_t e = 0;
    /* Kept exact up to 10^17, past any count of digits, so that a long mantissa can cancel it. */
    for (; i < len && s[i] >= '0' && s[i] <= '9'; i++)
      if (e < INT64_C(100000000000000000)) e = e * 10 + (s[i] - '0');
    if (i == first) return false;
    q += down ? -e : e;
  }
  if (i != len) return false;
  if (cut) {
    digits[n++] = '1';
    q--;
  }
  for (; n > 0 && digits[n - 1] == '0'; n--) q++;
  /* An integer below 10^18 (16777217.0, 3e9) is rounded once from the int64, without the bignum. */
  int64_t whole = 0;
  bool small = n <= 18 && q >= 0 && q <= 18;
  for (size_t k = 0; small && k < n; k++) whole = whole * 10 + (digits[k] - '0');
  for (int64_t k = 0; small && k < q; k++) small = !__builtin_mul_overflow(whole, 10, &whole);
  double x = !n ? 0.0 : small ? (double)(float)whole : decimal_f32(digits, n, q);
  *out = negative ? -x : x;
  return true;
}

/* The digits of x > 0, a finite binary32, exactly, without trailing zeros; *lead is the power of ten of the first.
   With x = m * 2^e and m odd, there are at most 112: m * 5^149 for the smallest e. */
static size_t f32_exact_digits(double x, char *digits, int *lead) {
  int e;
  uint32_t m = (uint32_t)ldexp(frexp(x, &e), 24);
  for (e -= 24; m % 2 == 0; e++) m /= 2;
  big b;
  big_set(&b, m);
  if (e >= 0) {
    big_shl(&b, (unsigned)e);
    e = 0;
  } else {
    for (int k = e; k < 0; k++) big_mul_add(&b, 5, 0);
  }
  char reversed[FLOAT32_DIGITS];
  size_t n = 0;
  for (; b.n; n++) reversed[n] = (char)('0' + big_div_small(&b, 10));
  size_t skip = 0;
  while (skip < n && reversed[skip] == '0') skip++;
  for (size_t k = 0; k < n - skip; k++) digits[k] = reversed[n - 1 - k];
  *lead = e + (int)n - 1;
  return n - skip;
}

/* The digits of the integer v > 0 without trailing zeros, and the power of ten of the first, the last of v being
   at 10^last. */
static size_t integer_digits(uint64_t v, int last, char *digits, int *lead) {
  for (; v % 10 == 0; last++) v /= 10;
  size_t n = 0;
  for (uint64_t t = v; t; t /= 10) n++;
  for (size_t k = n; k > 0; v /= 10) digits[--k] = (char)('0' + v % 10);
  *lead = last + (int)n - 1;
  return n;
}

/* 10^e for 0 <= e <= 66, with at most two roundings. */
static double power_of_ten(unsigned e) {
  static const double exact[] = {1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,  1e8,  1e9,  1e10, 1e11,
                                 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22};
  double p = 1;
  for (; e > 22; e -= 22) p *= exact[22];
  return p * exact[e];
}

/* True when value * 10^last (DIGITS, COUNT of them, the first at 10^first) reads as the binary32 x > 0. A double
   estimate, within a few roundings, decides unless it falls near the midpoint on either side of x; decimal_f32
   decides those. */
static bool reads_as(uint64_t value, int last, double x, const char *digits, size_t count, int first) {
  double v = last >= 0 ? (double)value * power_of_ten((unsigned)last) : (double)value / power_of_ten((unsigned)-last);
  float f = (float)x;
  double below = ((double)nextafterf(f, 0) + x) / 2;
  double above = f == FLT_MAX ? FLOAT32_OVERFLOW : ((double)nextafterf(f, INFINITY) + x) / 2;
  double slack = v * 0x1p-48;
  if (v + slack < below || v - slack > above) return false;
  if (v - slack > below && v + slack < above) return true;
  return decimal_f32(digits, count, first - (int64_t)count + 1) == x;
}

size_t agc_float32_text(double x, char out[AGC_SCALAR_TEXT]) {
  x = agc_round_f32(x);
  if (isnan(x) || isinf(x)) return agc_float_text(x, out);
  size_t at = 0;
  if (signbit(x)) {
    out[at++] = '-';
    x = -x;
  }
  if (x == 0) return put(out, at, "0.0", 3);
  char exact[FLOAT32_DIGITS], digits[24];
  int lead;
  size_t k = f32_exact_digits(x, exact, &lead);
  /* The fewest digits that read back as x and, of two with as many, the nearer; an exact tie takes the upper one,
     as agc_float_text does. Nine digits always read back. */
  for (size_t n = 1; n < k && n <= 9; n++) {
    uint64_t down = 0;
    for (size_t j = 0; j < n; j++) down = down * 10 + (uint64_t)(exact[j] - '0');
    int above = exact[n] > '5' || (exact[n] == '5' && n + 1 < k) ? 1 : exact[n] == '5' ? 0 : -1;
    uint64_t tries[2] = {above >= 0 ? down + 1 : down, above >= 0 ? down : down + 1};
    int last = lead - (int)n + 1;
    for (size_t t = 0; t < 2; t++) {
      int first;
      size_t count = integer_digits(tries[t], last, digits, &first);
      if (reads_as(tries[t], last, x, digits, count, first)) return decimal_text(out, at, digits, count, first);
    }
  }
  return decimal_text(out, at, exact, k < 9 ? k : 9, lead);
}
