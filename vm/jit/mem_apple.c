/*
 * The JIT's code memory on Apple arm64 (docs/future/22-jit.md §22, "Memory"): one process-lifetime MAP_JIT arena of
 * at most AGC_JIT_CODE_CAP bytes in 4 KiB logical slices (the host page only sizes the mapping, rounded down, never
 * past the cap). A thread writes only with its own lease open (begin_write); the seal flushes the icache without
 * closing the lease, and end_write always restores the thread to executable first. Only the mapping thread may seal,
 * publish or abandon its unpublished slice; the winner's publish is immutable, losers return to the arena, and
 * exhaustion or an unsupported host keeps the function interpreted. Core layer.
 */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE 1
#endif
#include "jit.h"

#if (defined(__APPLE__) && defined(__aarch64__)) || defined(AGC_JIT_MEM_APPLE_SHIM)

#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#if defined(AGC_JIT_MEM_APPLE_SHIM) && !(defined(__APPLE__) && defined(__aarch64__))
/* The portable test shim: the allocator below is the real code, only the operating system is fake, so the tests prove
   the accounting, the lease pairing and the ownership rules without claiming Apple proof (native Mac CI proves the
   real calls). The arena is plain heap, the host page is the Apple arm64 one, and the write-protect calls only count
   pairings. The test renames the seven entry points (see the test file), so this object never clashes with the
   Linux and Windows memory files it links beside. */
#define agc_jit_mem_map agc_jit_mem_apple_shim_map
#define agc_jit_mem_seal agc_jit_mem_apple_shim_seal
#define agc_jit_mem_unmap agc_jit_mem_apple_shim_unmap
#define agc_jit_mem_apple_thread_exec agc_jit_mem_apple_shim_thread_exec
#define agc_jit_mem_apple_begin_write agc_jit_mem_apple_shim_begin_write
#define agc_jit_mem_apple_end_write agc_jit_mem_apple_shim_end_write
#define agc_jit_mem_apple_publish agc_jit_mem_apple_shim_publish
#else
#include <libkern/OSCacheControl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

/* 4 KiB is the logical quantum the budget counts (jit.h), not the host page: the arena holds this many slices. */
#define APPLE_SLICE ((size_t)4096)
#define APPLE_SLICES ((size_t)AGC_JIT_CODE_CAP / APPLE_SLICE)

_Static_assert((size_t)AGC_JIT_CODE_CAP % APPLE_SLICE == 0, "the code cap is a whole number of slices");

/* A slice's state: free, reserved, sealed, or published forever. The lease bit rides on a reservation's first slice
   only; interior slices carry the state without it, so a scan tells free from held on every slice. */
#define APPLE_FREE ((uint8_t)0)
#define APPLE_RESERVED ((uint8_t)1)
#define APPLE_SEALED ((uint8_t)2)
#define APPLE_PUBLISHED ((uint8_t)3)
#define APPLE_LEASED ((uint8_t)0x80)
#define APPLE_STATE_MASK ((uint8_t)0x7f)

/* 16 KiB of states, 32 KiB of reservation lengths, 128 KiB of owners (8 bytes each): 176 KiB of process-lifetime
   metadata for the at most 64 MiB arena. Length and owner are only valid at a reservation's first slice. */
static uint8_t apple_state[APPLE_SLICES];
static uint16_t apple_len[APPLE_SLICES];
static pthread_t apple_owner[APPLE_SLICES];
/* The short mutex: it spans only the metadata scan and mark, never a fill, a flush, a toggle or an execution. */
static pthread_mutex_t apple_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t *apple_base;
static size_t apple_bytes;
static bool apple_failed;

#if defined(AGC_JIT_MEM_APPLE_SHIM) && !(defined(__APPLE__) && defined(__aarch64__))
static long apple_host_page(void) { return 16384; }

static bool apple_shim_supported = true;
static _Atomic unsigned apple_shim_wp_off, apple_shim_wp_on, apple_shim_flushes;
static void *apple_shim_last_flush;
static size_t apple_shim_last_flush_len;

static bool apple_toggle_supported(void) { return apple_shim_supported; }

static void apple_write_protect(int executable) {
  if (executable)
    atomic_fetch_add(&apple_shim_wp_on, 1);
  else
    atomic_fetch_add(&apple_shim_wp_off, 1);
}

static void apple_flush(const void *pages, size_t size) {
  apple_shim_last_flush = (void *)pages;
  apple_shim_last_flush_len = size;
  atomic_fetch_add(&apple_shim_flushes, 1);
}

static void *apple_arena_map(size_t bytes) {
  /* Plain heap is enough for accounting tests; nothing mapped here ever executes. */
  return malloc(bytes);
}
#else
static long apple_host_page(void) {
  /* The running kernel's page size (16 KiB on Apple arm64); a failure keeps everything interpreted. */
  return sysconf(_SC_PAGESIZE);
}

static bool apple_toggle_supported(void) { return pthread_jit_write_protect_supported_np() != 0; }

static void apple_write_protect(int executable) { pthread_jit_write_protect_np(executable); }

static void apple_flush(const void *pages, size_t size) { sys_icache_invalidate((void *)pages, size); }

static void *apple_arena_map(size_t bytes) {
  /* PROT_EXEC authorizes execution up front (MAP_JIT allows the RWX mapping); the per-thread toggle then enforces
     effective write-xor-execute, so no thread ever writes and executes at once. */
  void *pages = mmap(NULL, bytes, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
  return pages == MAP_FAILED ? NULL : pages;
}
#endif

/* The arena, mapped once. The caller holds the lock. */
static bool apple_ensure_locked(void) {
  if (apple_base) return true;
  if (apple_failed) return false;
  if (!apple_toggle_supported()) {
    apple_failed = true;
    return false;
  }
  long page = apple_host_page();
  if (page <= 0 || (size_t)page > (size_t)AGC_JIT_CODE_CAP) {
    apple_failed = true;
    return false;
  }
  /* Round the cap DOWN to whole host pages: the arena never grows past 64 MiB. */
  size_t bytes = (size_t)AGC_JIT_CODE_CAP / (size_t)page * (size_t)page;
  if (!bytes) {
    apple_failed = true;
    return false;
  }
  uint8_t *base = apple_arena_map(bytes);
  if (!base) {
    apple_failed = true;
    return false;
  }
  apple_base = base;
  apple_bytes = bytes;
  return true;
}

/* The first slice of a run of at least NEED free slices. The caller holds the lock. */
static bool apple_first_fit(size_t need, size_t *at) {
  size_t usable = apple_bytes / APPLE_SLICE, run = 0, start = 0;
  for (size_t i = 0; i < usable; i++) {
    if (apple_state[i] != APPLE_FREE) {
      run = 0;
      continue;
    }
    if (!run) start = i;
    if (++run == need) {
      *at = start;
      return true;
    }
  }
  return false;
}

/* A reservation's first slice for PAGES, or (size_t)-1 for anything else: an interior slice (no length), a freed
   slice, or an address outside the arena. Published reservations keep their length, so this still finds them. The
   caller holds the lock. */
static size_t apple_start_of(const void *pages) {
  if (!apple_base) return (size_t)-1;
  uintptr_t addr = (uintptr_t)pages, base = (uintptr_t)apple_base;
  if (addr < base) return (size_t)-1;
  uintptr_t off = addr - base;
  if (off % APPLE_SLICE || off >= apple_bytes) return (size_t)-1;
  size_t at = off / APPLE_SLICE;
  if ((apple_state[at] & APPLE_STATE_MASK) == APPLE_FREE || !apple_len[at]) return (size_t)-1;
  return at;
}

/* This thread's open lease, if any. The caller holds the lock. */
static bool apple_my_lease(size_t *at) {
  pthread_t self = pthread_self();
  size_t usable = apple_bytes / APPLE_SLICE;
  for (size_t i = 0; i < usable; i++) {
    if ((apple_state[i] & APPLE_LEASED) && pthread_equal(apple_owner[i], self)) {
      *at = i;
      return true;
    }
  }
  return false;
}

void *agc_jit_mem_map(size_t size) {
  /* Reserve only: no thread toggle here, so mapping never leaves write protection disabled. */
  if (!size || size > (size_t)AGC_JIT_CODE_CAP || !apple_toggle_supported()) return NULL;
  size_t need = (size + APPLE_SLICE - 1) / APPLE_SLICE;
  pthread_mutex_lock(&apple_lock);
  if (!apple_ensure_locked()) {
    pthread_mutex_unlock(&apple_lock);
    return NULL;
  }
  size_t at = 0;
  if (!apple_first_fit(need, &at)) {
    /* Exhaustion keeps the function interpreted: the arena never grows. */
    pthread_mutex_unlock(&apple_lock);
    return NULL;
  }
  for (size_t i = at; i < at + need; i++) apple_state[i] = APPLE_RESERVED;
  apple_len[at] = (uint16_t)need;
  apple_owner[at] = pthread_self();
  pthread_mutex_unlock(&apple_lock);
  return apple_base + at * APPLE_SLICE;
}

bool agc_jit_mem_seal(void *pages, size_t size) {
  /* Validate the active owned lease and its range, mark sealed, then flush outside the lock. The lease stays open:
     only end_write closes it, so the seal never secretly restores executable mode. */
  if (!pages || !size) return false;
  pthread_mutex_lock(&apple_lock);
  size_t at = apple_start_of(pages), mine = 0;
  bool ok = at != (size_t)-1 && ((apple_state[at] & APPLE_STATE_MASK) == APPLE_RESERVED ||
                                 (apple_state[at] & APPLE_STATE_MASK) == APPLE_SEALED) &&
            (apple_state[at] & APPLE_LEASED) && apple_my_lease(&mine) && mine == at &&
            size <= (size_t)apple_len[at] * APPLE_SLICE;
  if (ok) {
    size_t need = apple_len[at];
    for (size_t i = at; i < at + need; i++)
      apple_state[i] = (uint8_t)((apple_state[i] & APPLE_LEASED) | APPLE_SEALED);
  }
  pthread_mutex_unlock(&apple_lock);
  if (!ok) return false;
  /* Every slice is flushed before it can run; the instruction caches are not coherent with data caches. */
  apple_flush(pages, size);
  return true;
}

void agc_jit_mem_unmap(void *pages, size_t size) {
  /* Reclaim only an unpublished slice of the calling thread. The length comes from the reservation, never from the
     caller (which passes the unrounded size while the budget counts rounded pages). Anything else — unknown,
     interior, foreign, leased, published, or already freed — is a no-op that corrupts nothing, and the arena itself
     is never unmapped while live code stands on it. */
  (void)size;
  if (!pages) return;
  pthread_mutex_lock(&apple_lock);
  size_t at = apple_start_of(pages);
  if (at != (size_t)-1 && pthread_equal(apple_owner[at], pthread_self()) && !(apple_state[at] & APPLE_LEASED) &&
      ((apple_state[at] & APPLE_STATE_MASK) == APPLE_RESERVED ||
       (apple_state[at] & APPLE_STATE_MASK) == APPLE_SEALED)) {
    size_t need = apple_len[at];
    for (size_t i = at; i < at + need; i++) apple_state[i] = APPLE_FREE;
    apple_len[at] = 0;
  }
  pthread_mutex_unlock(&apple_lock);
}

bool agc_jit_mem_apple_thread_exec(void) {
  /* The resting executable state of this thread before any JIT entry: false when the host toggle is unsupported,
     the arena failed, or the thread holds an open lease (which must end first). Never opens a lease itself. */
  if (!apple_toggle_supported()) return false;
  pthread_mutex_lock(&apple_lock);
  bool failed = apple_failed, leased = false;
  if (!failed && apple_base) {
    size_t mine = 0;
    leased = apple_my_lease(&mine);
  }
  pthread_mutex_unlock(&apple_lock);
  if (failed || leased) return false;
  apple_write_protect(1);
  return true;
}

bool agc_jit_mem_apple_begin_write(void *pages) {
  /* A second begin on a thread with an open lease fails without touching the outer lease or the toggle: the thread
     stays writable under the lease it already holds. Any other failure leaves the thread executable. */
  if (!pages || !apple_toggle_supported()) return false;
  pthread_mutex_lock(&apple_lock);
  size_t mine = 0;
  bool nested = apple_my_lease(&mine), ok = false;
  if (!nested) {
    size_t at = apple_start_of(pages);
    if (at != (size_t)-1 && (apple_state[at] & APPLE_STATE_MASK) == APPLE_RESERVED &&
        !(apple_state[at] & APPLE_LEASED) && pthread_equal(apple_owner[at], pthread_self())) {
      apple_state[at] |= APPLE_LEASED;
      ok = true;
    }
  }
  pthread_mutex_unlock(&apple_lock);
  /* Writable, not executable, this thread only; every other thread keeps its own state. */
  if (ok) apple_write_protect(0);
  return ok;
}

bool agc_jit_mem_apple_end_write(void *pages) {
  /* Always back to executable first: even a mismatched pointer must not leave this thread writable. Then close the
     thread's own lease, whatever was passed, and report whether it matched — never another thread's ownership. */
  apple_write_protect(1);
  pthread_mutex_lock(&apple_lock);
  size_t mine = 0;
  bool had = apple_my_lease(&mine), matched = false;
  if (had) {
    apple_state[mine] &= (uint8_t)~APPLE_LEASED;
    if (pages && apple_start_of(pages) == mine) matched = true;
  }
  pthread_mutex_unlock(&apple_lock);
  return matched;
}

bool agc_jit_mem_apple_publish(void *pages) {
  /* The winning slice becomes immutable until the process exits. Only its owner publishes it, and only once sealed
     (so flushed); a foreign or early publish is a no-op, and repeating it stays true. */
  if (!pages) return false;
  pthread_mutex_lock(&apple_lock);
  size_t at = apple_start_of(pages);
  bool ok = false;
  if (at != (size_t)-1 && pthread_equal(apple_owner[at], pthread_self()) && !(apple_state[at] & APPLE_LEASED)) {
    if ((apple_state[at] & APPLE_STATE_MASK) == APPLE_PUBLISHED)
      ok = true;
    else if ((apple_state[at] & APPLE_STATE_MASK) == APPLE_SEALED) {
      size_t need = apple_len[at];
      for (size_t i = at; i < at + need; i++) apple_state[i] = APPLE_PUBLISHED;
      ok = true;
    }
  }
  pthread_mutex_unlock(&apple_lock);
  return ok;
}

#endif
