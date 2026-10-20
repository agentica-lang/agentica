/*
 * rt->sync (docs/vm/16-architecture.md §16.9): solo until agc_share, then one mutual exclusion that nests per
 * scheduler and is undone by agc_sync_reset. Threads each hold a copy of the vm, as schedulers do.
 */
#include "../core.h"
#include "../services.h"
#include "test_abort.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <uv.h>
#include <setjmp.h>
#ifndef _WIN32
#include <unistd.h>
#endif

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

/* Every row of one table has the given mark. A table of a build without that service has one empty row. */
static void table_marked(const agc_builtin *table, size_t count, bool shared) {
  for (size_t k = 0; k < count; k++) {
    if (!table[k].fn) continue;
    if (table[k].shared != shared) fprintf(stderr, "%s/%u: shared should be %d\n", table[k].name, table[k].arity, shared);
    assert(table[k].shared == shared);
  }
}

/* Which builtins the interpreter locks: marked by row. Every row of the tables of tasks, Task.map, channels, the
   logger, processes, duplex channels, TCP and HTTP is locked; no row of the pure libraries (String, numbers, JSON, Profile) is.
   The mixed tables (the core one and File) are checked by row: stdin, handles and closes are locked, the output and
   the file calls that name a path are not. */
static void test_builtin_classes(void) {
  table_marked(agc_task_builtins, agc_task_builtin_count, true);
  table_marked(agc_task_map_builtins, agc_task_map_builtin_count, true);
  table_marked(agc_channel_builtins, agc_channel_builtin_count, true);
  table_marked(agc_logger_builtins, agc_logger_builtin_count, true);
  table_marked(agc_process_builtins, agc_process_builtin_count, true);
  table_marked(agc_duplex_builtins, agc_duplex_builtin_count, true);
  table_marked(agc_tcp_builtins, agc_tcp_builtin_count, true);
  table_marked(agc_http_service_builtins, agc_http_service_builtin_count, true);
  table_marked(agc_http_server_builtins, agc_http_server_builtin_count, true);
  table_marked(agc_string_builtins, agc_string_builtin_count, false);
  table_marked(agc_number_builtins, agc_number_builtin_count, false);
  table_marked(agc_crypto_builtins, agc_crypto_builtin_count, false);
  table_marked(agc_json_builtins, agc_json_builtin_count, false);
  table_marked(agc_lazy_builtins, agc_lazy_builtin_count, false);
  table_marked(agc_profile_builtins, agc_profile_builtin_count, false);
  struct {
    const char *name;
    uint32_t arity;
    bool shared;
  } expected[] = {
      {"IO.gets", 0, true},          {"IO.read", 0, true},     {"File.read_line", 2, true}, {"File.close", 2, true},
      {"puts", 1, false},            {"File.read_text", 2, false}, {"File.write_text", 3, false},
      {"File.stat", 2, false},       {"Path.join", 1, false},
  };
  for (size_t k = 0; k < sizeof expected / sizeof expected[0]; k++) {
    const agc_builtin *b = agc_find_builtin((const uint8_t *)expected[k].name, strlen(expected[k].name), expected[k].arity);
    assert(b && b->shared == expected[k].shared);
  }
}

/* In a shared VM a mutator of the shared lists that runs without rt->sync fails with a diagnostic, and agc_sync_reset
   gives back what a failed builtin held. */
static void test_assert_and_reset(void) {
  assert(vm.rt->shared);
  if (setjmp(vm.fail) == 0) {
    agc_sync_assert(&vm);
    assert(!"agc_sync_assert let a call without the lock through");
  }
  agc_sync_take(&vm);
  agc_sync_assert(&vm);
  agc_sync_drop(&vm);
  agc_sync_take(&vm);
  agc_sync_take(&vm);
  vm.stream_lock = vm.rt->out.lock;
  agc_lock_take(vm.stream_lock);
  agc_sync_reset(&vm);
  assert(vm.sync_depth == 0 && !vm.stream_lock && !agc_lock_held(vm.rt->out.lock) && !agc_lock_held(vm.rt->sync));
}

#ifndef _WIN32
static void relock(void) {
  agc_lock *l = agc_lock_new("test");
  agc_lock_share(l);
  agc_lock_take(l);
  agc_lock_take(l);
}

/* A thread that takes a lock it holds ends the process (SIGABRT) instead of deadlocking, and the message names the
   lock. */
static void test_relock_aborts(void) { agc_test_aborts_with(relock, "already holds (lock=test"); }
#endif

int main(void) {
  agc_test_deadline(120);
  agc_init();
#ifndef _WIN32
  /* Before the collector may start threads: the child allocates the lock through the GC after the fork. */
  test_relock_aborts();
#endif
  agc_gc_allow_threads();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_builtin_classes();
  test_solo();
  test_exclusion_and_nesting();
  test_reset_frees_the_lock();
  test_assert_and_reset();
  puts("sync tests passed");
  return 0;
}
