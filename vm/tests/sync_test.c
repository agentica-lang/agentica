/*
 * rt->sync (docs/vm/16-architecture.md §16.9): solo until agc_share, then one mutual exclusion that nests per
 * scheduler and is undone by agc_sync_reset. Threads each hold a copy of the vm, as schedulers do.
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <uv.h>

#define THREADS 4
#define ROUNDS 20000

static agc_vm vm;
static agc_vm copies[THREADS];
static long counter;
static _Atomic int inside;
static _Atomic int reset_taken;

/* Before agc_share nothing is taken: the count stays 0 and a drop without a take is harmless. */
static void test_solo(void) {
  agc_sync_take(&vm);
  agc_sync_take(&vm);
  assert(vm.sync_depth == 0 && !vm.rt->shared);
  agc_sync_drop(&vm);
  agc_sync_drop(&vm);
  agc_sync_reset(&vm);
  assert(vm.sync_depth == 0);
}

static void count_up(void *arg) {
  agc_vm *self = arg;
  assert(agc_gc_thread_enter());
  for (int k = 0; k < ROUNDS; k++) {
    agc_sync_take(self);
    agc_sync_take(self);
    assert(atomic_fetch_add(&inside, 1) == 0);
    counter++;
    assert(atomic_fetch_sub(&inside, 1) == 1);
    agc_sync_drop(self);
    assert(self->sync_depth == 1);
    agc_sync_drop(self);
  }
  assert(self->sync_depth == 0);
  agc_gc_thread_leave();
}

/* The lock excludes (the plain counter is exact and only one thread is inside at a time) and a nested take by the
   holder does not block on itself. */
static void test_exclusion_and_nesting(void) {
  agc_share(&vm);
  assert(vm.rt->shared);
  uv_thread_t threads[THREADS];
  for (int k = 0; k < THREADS; k++) {
    copies[k] = vm;
    assert(uv_thread_create(&threads[k], count_up, &copies[k]) == 0);
  }
  for (int k = 0; k < THREADS; k++) assert(uv_thread_join(&threads[k]) == 0);
  assert(counter == (long)THREADS * ROUNDS);
}

static void take_after_reset(void *arg) {
  agc_vm *self = arg;
  assert(agc_gc_thread_enter());
  agc_sync_take(self);
  atomic_store(&reset_taken, 1);
  agc_sync_drop(self);
  agc_gc_thread_leave();
}

/* A failure that jumped out of a builtin leaves the lock held at some depth: the reset frees it for the others. */
static void test_reset_frees_the_lock(void) {
  agc_sync_take(&vm);
  agc_sync_take(&vm);
  agc_sync_take(&vm);
  assert(vm.sync_depth == 3);
  agc_sync_reset(&vm);
  assert(vm.sync_depth == 0);
  agc_vm other = vm;
  uv_thread_t thread;
  assert(uv_thread_create(&thread, take_after_reset, &other) == 0);
  assert(uv_thread_join(&thread) == 0);
  assert(atomic_load(&reset_taken) == 1);
  agc_sync_reset(&vm);
}

/* Which builtins the interpreter locks: the shared libraries and stdin, not the pure ones and not the output. */
static void test_builtin_classes(void) {
  const agc_builtin *send = agc_find_builtin((const uint8_t *)"Channel.send", 12, 3);
  const agc_builtin *spawn = agc_find_builtin((const uint8_t *)"Task.spawn", 10, 2);
  const agc_builtin *gets = agc_find_builtin((const uint8_t *)"IO.gets", 7, 0);
  const agc_builtin *length = agc_find_builtin((const uint8_t *)"String.length", 13, 1);
  const agc_builtin *puts = agc_find_builtin((const uint8_t *)"puts", 4, 1);
  assert(send && spawn && gets && length && puts);
  assert(agc_builtin_shared(send) && agc_builtin_shared(spawn) && agc_builtin_shared(gets));
  assert(!agc_builtin_shared(length) && !agc_builtin_shared(puts));
}

int main(void) {
  agc_test_deadline(120);
  agc_init();
  agc_gc_allow_threads();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_builtin_classes();
  test_solo();
  test_exclusion_and_nesting();
  test_reset_frees_the_lock();
  puts("sync tests passed");
  return 0;
}
