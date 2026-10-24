/*
 * The JIT's Apple arm64 code memory (vm/jit/mem_apple.c): one arena, one write lease per thread. Native Apple arm64
 * runs the real calls including executing 42; elsewhere the same allocator runs against a fake OS, proving the
 * accounting, pairing and ownership rules without claiming Apple proof.
 */
#include "../jit/jit.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <uv.h>

#if defined(__APPLE__) && defined(__aarch64__)
#define MEM_NATIVE 1
#else
/* Portable mode: the test renames the seven entry points onto the shim, so this object never clashes with the Linux
   and Windows memory files it links beside. Test bodies below keep calling the real names. */
#define AGC_JIT_MEM_APPLE_SHIM 1
#define agc_jit_mem_map agc_jit_mem_apple_shim_map
#define agc_jit_mem_seal agc_jit_mem_apple_shim_seal
#define agc_jit_mem_unmap agc_jit_mem_apple_shim_unmap
#define agc_jit_mem_apple_thread_exec agc_jit_mem_apple_shim_thread_exec
#define agc_jit_mem_apple_begin_write agc_jit_mem_apple_shim_begin_write
#define agc_jit_mem_apple_end_write agc_jit_mem_apple_shim_end_write
#define agc_jit_mem_apple_publish agc_jit_mem_apple_shim_publish
#include "../jit/mem_apple.c"
#endif

#ifdef MEM_NATIVE
/* movz w0, #42; ret */
static const uint8_t code_bytes[] = {0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6};
#else
/* Never executed here; only the accounting around it is shared. */
static const uint8_t code_bytes[] = {0xb8, 42, 0, 0, 0, 0xc3};
#endif

/* Reserving never opens a lease: the thread is still executable right after. */
static void *reserve_clean(size_t size) {
  void *p = agc_jit_mem_map(size);
  assert(p);
  assert(agc_jit_mem_apple_thread_exec());
  return p;
}

#ifndef MEM_NATIVE
static void unsupported(void) {
  /* An unsupported host keeps everything interpreted: no reservation, no lease, no entry. */
  apple_shim_supported = false;
  assert(!agc_jit_mem_map(4096));
  assert(!agc_jit_mem_apple_thread_exec());
  assert(!agc_jit_mem_apple_begin_write((void *)(uintptr_t)0x1000));
  apple_shim_supported = true;
  assert(agc_jit_mem_apple_thread_exec());
}
#else
static void unsupported(void) {
  /* The native host supports the toggle: a fresh thread rests executable. */
  assert(agc_jit_mem_apple_thread_exec());
}
#endif

/* 64 one-MiB slices exactly fill the 64 MiB arena; the 65th keeps the function interpreted. Everything comes back. */
static void exhaustion(void) {
  void *held[64];
  for (size_t k = 0; k < 64; k++) held[k] = reserve_clean((size_t)1024 * 1024);
  assert(!agc_jit_mem_map(4096));
  assert(!agc_jit_mem_map((size_t)64 * 1024 * 1024));
  for (size_t k = 0; k < 64; k++) agc_jit_mem_unmap(held[k], (size_t)1024 * 1024);
  /* The whole arena comes back as one run: no growth, no fragmentation. */
  void *all = reserve_clean((size_t)64 * 1024 * 1024);
  assert(agc_jit_mem_apple_begin_write(all));
  assert(agc_jit_mem_apple_end_write(all));
  agc_jit_mem_unmap(all, (size_t)64 * 1024 * 1024);
  /* First fit reuses the freed start. */
  assert(agc_jit_mem_map(4096) == all);
  agc_jit_mem_unmap(all, 4096);
}

static void invalid_ranges(void) {
  assert(!agc_jit_mem_map(0));
  assert(!agc_jit_mem_map(SIZE_MAX));
  assert(!agc_jit_mem_map((size_t)AGC_JIT_CODE_CAP + 1));
  assert(!agc_jit_mem_seal(NULL, 8));
  assert(!agc_jit_mem_seal((void *)(uintptr_t)0x1234, 8));
  void *p = reserve_clean(100);
  assert(!agc_jit_mem_seal(p, 4097));
  assert(!agc_jit_mem_seal((uint8_t *)p + 1, 99));
  assert(!agc_jit_mem_apple_begin_write((uint8_t *)p + 4096));
  assert(!agc_jit_mem_apple_publish(p));
  assert(agc_jit_mem_apple_begin_write(p));
  assert(!agc_jit_mem_seal(p, 4097));
  assert(agc_jit_mem_seal(p, 100));
  assert(agc_jit_mem_apple_end_write(p));
  assert(agc_jit_mem_apple_publish(p));
  agc_jit_mem_unmap(p, 100);
  assert(agc_jit_mem_apple_publish(p));
  void *q = reserve_clean(100);
  assert(q && q != p);
  agc_jit_mem_unmap(q, 100);
  agc_jit_mem_unmap(q, 100);
  agc_jit_mem_unmap(NULL, 100);
}

static void lease_pairing(void) {
  void *p = reserve_clean(8192), *r = reserve_clean(4096);
  assert(agc_jit_mem_apple_begin_write(p));
  /* A nested begin fails without touching the outer lease: the thread still holds p, so no entry. */
  assert(!agc_jit_mem_apple_begin_write(r));
  assert(!agc_jit_mem_apple_begin_write(p));
  assert(!agc_jit_mem_apple_thread_exec());
  /* A mismatched end still restores executable mode, closes the thread's own lease, and reports the mismatch. */
  assert(!agc_jit_mem_apple_end_write(r));
  assert(agc_jit_mem_apple_thread_exec());
  assert(agc_jit_mem_apple_begin_write(r));
  assert(agc_jit_mem_seal(r, 4096));
  assert(agc_jit_mem_apple_end_write(r));
  /* The aborted p survived the mismatched close untouched: it reserves, seals and publishes as usual. */
  assert(agc_jit_mem_apple_begin_write(p));
  assert(agc_jit_mem_seal(p, 8192));
  assert(agc_jit_mem_apple_end_write(p));
  assert(!agc_jit_mem_apple_end_write(p));
  assert(agc_jit_mem_apple_publish(p));
  agc_jit_mem_unmap(p, 8192);
  agc_jit_mem_unmap(r, 4096);
  /* The sealed-but-unpublished r comes straight back; the published p never does. */
  void *back = agc_jit_mem_map(4096);
  assert(back == r && back != p);
  agc_jit_mem_unmap(back, 4096);
}

/* A full publish: fill through a lease, flush at the seal, close, publish, then run (native) or verify (shim). */
static void return_value(void) {
#ifndef MEM_NATIVE
  unsigned off0 = atomic_load(&apple_shim_wp_off), on0 = atomic_load(&apple_shim_wp_on);
#endif
  void *p = reserve_clean(sizeof code_bytes);
  assert(agc_jit_mem_apple_begin_write(p));
  memcpy(p, code_bytes, sizeof code_bytes);
  assert(agc_jit_mem_seal(p, sizeof code_bytes));
  assert(agc_jit_mem_apple_end_write(p));
  assert(agc_jit_mem_apple_publish(p));
  assert(agc_jit_mem_apple_thread_exec());
#ifdef MEM_NATIVE
  assert(((int (*)(void))(uintptr_t)p)() == 42);
#else
  assert(apple_shim_last_flush == p && apple_shim_last_flush_len == sizeof code_bytes);
  assert(memcmp(p, code_bytes, sizeof code_bytes) == 0);
  /* One open, and one close per end/thread_exec call: the mode never sticks. */
  assert(atomic_load(&apple_shim_wp_off) == off0 + 1);
  assert(atomic_load(&apple_shim_wp_on) == on0 + 3);
#endif
}

/* Another thread's slice is untouchable: seal, begin, publish fail and unmap is a no-op, on a held lease too. */
static void *foreign_target;
static _Atomic unsigned foreign_stage;

static void foreign_one(void *arg) {
  (void)arg;
  /* A new thread rests executable before any entry. */
  assert(agc_jit_mem_apple_thread_exec());
  assert(!agc_jit_mem_seal(foreign_target, 4096));
  assert(!agc_jit_mem_apple_begin_write(foreign_target));
  assert(!agc_jit_mem_apple_publish(foreign_target));
  agc_jit_mem_unmap(foreign_target, 4096);
  atomic_store(&foreign_stage, 1);
}

static void ownership_threads(void) {
  foreign_target = reserve_clean(4096);
  atomic_store(&foreign_stage, 0);
  uv_thread_t thread;
  assert(uv_thread_create(&thread, foreign_one, NULL) == 0);
  while (atomic_load(&foreign_stage) != 1) agc_test_yield();
  /* The failed foreign calls changed nothing: the owner still leases, seals and publishes. */
  assert(agc_jit_mem_apple_begin_write(foreign_target));
  assert(agc_jit_mem_seal(foreign_target, 4096));
  assert(agc_jit_mem_apple_end_write(foreign_target));
  assert(agc_jit_mem_apple_publish(foreign_target));
  atomic_store(&foreign_stage, 0);
  assert(uv_thread_join(&thread) == 0);
}

/* Four threads compile at once; the compare-and-swap keeps one slice and abandons the rest to the arena. */
#define RACERS 4
static void *_Atomic race_winner;
static _Atomic unsigned race_go;
static void *race_seen[RACERS];
static bool race_won[RACERS];

static void race_one(void *arg) {
  uintptr_t k = (uintptr_t)arg;
  while (!atomic_load(&race_go)) agc_test_yield();
  void *p = reserve_clean(4096);
  assert(agc_jit_mem_apple_begin_write(p));
  memset(p, (int)(k + 1), 4096);
  assert(agc_jit_mem_seal(p, 4096));
  assert(agc_jit_mem_apple_end_write(p));
  void *expect = NULL;
  if (atomic_compare_exchange_strong(&race_winner, &expect, p)) {
    assert(agc_jit_mem_apple_publish(p));
    race_won[k] = true;
  } else {
    agc_jit_mem_unmap(p, 4096);
  }
  race_seen[k] = p;
}

static void race_loser(void) {
  atomic_store(&race_winner, NULL);
  for (size_t k = 0; k < RACERS; k++) race_seen[k] = NULL, race_won[k] = false;
  atomic_store(&race_go, 0);
  uv_thread_t threads[RACERS];
  for (uintptr_t k = 0; k < RACERS; k++) assert(uv_thread_create(&threads[k], race_one, (void *)k) == 0);
  atomic_store(&race_go, 1);
  for (size_t k = 0; k < RACERS; k++) assert(uv_thread_join(&threads[k]) == 0);
  void *winner = atomic_load(&race_winner);
  assert(winner);
  size_t wins = 0;
  for (size_t k = 0; k < RACERS; k++) {
    assert(race_seen[k]);
    wins += race_won[k] ? 1 : 0;
  }
  assert(wins == 1);
  /* The published winner stays: no lease opens on it, and unmapping it is a no-op. */
  assert(!agc_jit_mem_apple_begin_write(winner));
  agc_jit_mem_unmap(winner, 4096);
  void *reuse = NULL;
  for (size_t k = 0; k < RACERS && !reuse; k++)
    if (!race_won[k]) {
      void *p = agc_jit_mem_map(4096);
      assert(p && p != winner);
      reuse = p;
    }
  assert(reuse);
  bool known = false;
  for (size_t k = 0; k < RACERS; k++) known = known || (!race_won[k] && race_seen[k] == reuse);
  assert(known);
  agc_jit_mem_unmap(reuse, 4096);
}

/* A writer cycling leases against a reader of already-published code: no lock spans a lease, no live code moves. */
static void *shared_code;
static _Atomic unsigned shared_stop;

static void writer_one(void *arg) {
  (void)arg;
  for (unsigned k = 0; k < 200; k++) {
    void *p = reserve_clean(4096);
    assert(agc_jit_mem_apple_begin_write(p));
    memset(p, (int)(k & 0xff), 4096);
    assert(agc_jit_mem_seal(p, 4096));
    assert(agc_jit_mem_apple_end_write(p));
    agc_jit_mem_unmap(p, 4096);
  }
  atomic_store(&shared_stop, 1);
}

static void reader_one(void *arg) {
  (void)arg;
  assert(agc_jit_mem_apple_thread_exec());
  while (!atomic_load(&shared_stop)) {
#ifdef MEM_NATIVE
    assert(((int (*)(void))(uintptr_t)shared_code)() == 42);
#else
    assert(memcmp(shared_code, code_bytes, sizeof code_bytes) == 0);
#endif
  }
}

static void writer_vs_reader(void) {
  shared_code = reserve_clean(sizeof code_bytes);
  assert(agc_jit_mem_apple_begin_write(shared_code));
  memcpy(shared_code, code_bytes, sizeof code_bytes);
  assert(agc_jit_mem_seal(shared_code, sizeof code_bytes));
  assert(agc_jit_mem_apple_end_write(shared_code));
  assert(agc_jit_mem_apple_publish(shared_code));
  atomic_store(&shared_stop, 0);
  uv_thread_t writer, reader;
  assert(uv_thread_create(&writer, writer_one, NULL) == 0);
  assert(uv_thread_create(&reader, reader_one, NULL) == 0);
  assert(uv_thread_join(&writer) == 0);
  assert(uv_thread_join(&reader) == 0);
}

int main(void) {
  agc_test_deadline(120);
  unsupported();
  exhaustion();
  invalid_ranges();
  lease_pairing();
  return_value();
  ownership_threads();
  race_loser();
  writer_vs_reader();
  return 0;
}
