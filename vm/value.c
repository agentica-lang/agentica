/*
 * Values in C: allocation through the Boehm GC (with its stress hook), the
 * checked agc_as_* accessors, String allocation, UTF-8 checks and code point
 * counts, and agc_error_value (an error Result from C text). Core layer.
 * Design: docs/vm/05-values-execution-builtins.md §5.
 */
#include "core.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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
#endif

static const char oom_line[] = "agentica: out of memory\n";

#ifdef AGC_NO_GC
static void **owned; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static size_t owned_count, owned_cap, owned_bytes, limit_bytes; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static jmp_buf *on_limit; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static bool over_limit; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
#endif

void agc_out_of_memory(void) {
  ssize_t ignored = write(2, oom_line, sizeof oom_line - 1);
  (void)ignored;
#ifdef AGC_FUZZ
  /* 70 is libFuzzer's timeout exit code, so abort() (a crash) is used instead and the input is saved. */
  abort();
#else
  _Exit(70);
#endif
}

#ifndef AGC_NO_GC
static void *on_gc_oom(size_t size) {
  (void)size;
  agc_out_of_memory();
  return NULL;
}

static const char gc_error_line[] = "agentica: internal GC error\n";

static void on_gc_abort(const char *message) {
  (void)message;
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

void agc_init(void) {
#ifndef AGC_NO_GC
  if (GC_is_init_called()) return;
  own_signal_table();
  GC_set_all_interior_pointers(1);
  GC_INIT();
  GC_set_oom_fn(on_gc_oom);
  GC_set_abort_func(on_gc_abort);
  GC_set_warn_proc(GC_ignore_warn_proc);
  /* Finalizers (only the TlsContext's) run when agc_gc_finalize_pending calls them, between turns, so OpenSSL is
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

#ifdef AGC_NO_GC
/* The limit is soft up to twice its size: past it, an allocation still succeeds and only marks the run. The
   interpreter sees the mark at the next step taken after a charge or at a turn start (set_counter) and jumps there
   (agc_alloc_limit_check), outside any builtin that holds malloc'd memory, so the fuzzer's leak check sees no false
   leak. Past twice the limit the allocation jumps at once: a builtin that allocates without charging (AGC_OP_LIST,
   say) can still get there midway, a known hole. */
static void *own(size_t size) {
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

void *agc_alloc(size_t size) {
  stress();
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
    case AGC_T_JSON: return ((const agc_json *)v.as.p)->count;
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

size_t agc_utf8_valid(const uint8_t *s, size_t len) {
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

/* The characters of valid UTF-8: every byte but the continuation bytes (10xxxxxx). A word of eight ASCII bytes is
 * eight characters. */
size_t agc_utf8_count(const uint8_t *s, size_t len) {
  size_t count = 0, i = 0;
  while (i < len) {
    uint64_t word;
    if (len - i >= sizeof word) {
      memcpy(&word, s + i, sizeof word);
      if (!(word & UINT64_C(0x8080808080808080))) {
        i += sizeof word;
        count += sizeof word;
        continue;
      }
    }
    count += (s[i] & 0xC0) != 0x80;
    i++;
  }
  return count;
}

/* Most text is ASCII, so a run of it is skipped eight bytes at a time (no byte with the high bit set) and the
 * characters are decoded one by one only where a word has a byte of 0x80 or more. */
bool agc_utf8_chars(const uint8_t *s, size_t len, size_t *chars) {
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
    size_t n = agc_utf8_valid(s + i, len - i);
    if (n == 0) return false;
    i += n;
    count++;
  }
  *chars = count;
  return true;
}

static bool incomplete_tail(const uint8_t *s, size_t len) {
  uint8_t c = s[0];
  size_t width = c >= 0xC2 && c <= 0xDF ? 2 : c >= 0xE0 && c <= 0xEF ? 3 : c >= 0xF0 && c <= 0xF4 ? 4 : 0;
  if (width == 0 || len >= width) return false;
  for (size_t k = 1; k < len; k++)
    if ((s[k] & 0xC0) != 0x80) return false;
  if (len > 1 && ((c == 0xE0 && s[1] < 0xA0) || (c == 0xF0 && s[1] < 0x90))) return false;
  return true;
}

static size_t utf8_step(const uint8_t *s, size_t len, bool tail, size_t *valid) {
  size_t n = agc_utf8_valid(s, len);
  *valid = n;
  if (n) return n;
  return tail && incomplete_tail(s, len) ? len : 1;
}

agc_string *agc_utf8_decode(const uint8_t *data, size_t len, const char *replacement, bool tail) {
  size_t rlen = strlen(replacement), bytes = 0, chars = 0, n;
  for (size_t i = 0; i < len; chars++) {
    i += utf8_step(data + i, len - i, tail, &n);
    bytes = agc_size_add(bytes, n ? n : rlen);
  }
  agc_string *s = agc_new_string(bytes, chars);
  size_t at = 0;
  for (size_t i = 0; i < len;) {
    size_t step = utf8_step(data + i, len - i, tail, &n);
    if (n) {
      memcpy(s->data + at, data + i, n);
      at += n;
    } else {
      memcpy(s->data + at, replacement, rlen);
      at += rlen;
    }
    i += step;
  }
  return s;
}

static size_t put(char *out, size_t at, const char *text, size_t len) {
  memcpy(out + at, text, len);
  return at + len;
}

static int decimal_digits(double x, int precision, char *all) {
  char text[800];
  int written = snprintf(text, sizeof text, "%.*e", precision, x);
  char *mark = written > 0 && (size_t)written < sizeof text ? strchr(text, 'e') : NULL;
  int total = 0;
  for (const char *c = text; mark && c < mark; c++)
    if (*c >= '0' && *c <= '9' && total <= precision) all[total++] = *c;
  if (!mark || total != precision + 1) abort();
  return atoi(mark + 1);
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
  char all[768];
  int e = decimal_digits(x, 40, all);
  double scaled = ldexp(x, 34);
  bool carried = !(x < 1e40 && scaled == floor(scaled));
  for (int k = 18; k <= 40 && carried; k++)
    if (all[k] != '0') carried = false;
  if (carried) e = decimal_digits(x, 767, all);
  char digits[20];
  size_t n = 0;
  int digits_e = e;
  bool found = false;
  for (size_t precision = isnormal(x) ? 15 : 1; precision <= 17 && !found; precision++) {
    bool nearest_up = all[precision] >= '5';
    for (int attempt = 0; attempt < 2 && !found; attempt++) {
      memcpy(digits, all, precision);
      n = precision;
      digits_e = e;
      if (nearest_up != (attempt == 1)) {
        size_t k = n;
        while (k > 0 && digits[k - 1] == '9') digits[--k] = '0';
        if (k == 0) {
          digits[0] = '1';
          digits_e++;
        } else {
          digits[k - 1]++;
        }
      }
      char text[AGC_SCALAR_TEXT];
      snprintf(text, sizeof text, "%c.%.*se%d", digits[0], (int)n - 1, digits + 1, digits_e);
      found = strtod(text, NULL) == x;
    }
  }
  while (n > 1 && digits[n - 1] == '0') n--;
  e = digits_e;
  int exponent_digits = snprintf(NULL, 0, "%d", e < 0 ? -e : e);
  int positional = (int)n > e + 1 ? (int)n + 1 : e + 3;
  int scientific = (int)n + (n > 1) + 2 + exponent_digits;
  if (e < -4 || (e >= 0 && positional > 16 && positional > scientific)) {
    out[at++] = digits[0];
    if (n > 1) {
      out[at++] = '.';
      at = put(out, at, digits + 1, n - 1);
    }
    return at + (size_t)snprintf(out + at, AGC_SCALAR_TEXT - at, "e%c%d", e < 0 ? '-' : '+', e < 0 ? -e : e);
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
