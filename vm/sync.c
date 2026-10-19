/*
 * The locks of the shared scheduler state (docs/vm/16-architecture.md §16.9, "One coarse lock"): `rt->sync`, the one lock
 * for the task tree, the waiter lists, the channels, the Task.map groups and the logger table, and the lock of each
 * output stream. All are solo until agc_share: while one thread runs the VM they take nothing but a flag
 * test, which is what one scheduler costs. Core layer.
 *
 * It includes <uv.h> only for `uv_mutex_t`, as runq.c does (docs/vm/15-layers.md §15.5, rule 5).
 */
#include "core.h"

#include <uv.h>

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

agc_lock *agc_lock_new(const char *name) {
  agc_lock *l = agc_alloc(sizeof *l);
  l->name = name;
  uv_mutex_t *mutex = agc_alloc(sizeof *mutex);
  if (uv_mutex_init(mutex) != 0) agc_out_of_memory();
  l->mutex = mutex;
  l->solo = true;
  return l;
}

/* From here on take and drop lock. Like agc_runq_share it runs before the second thread exists, so thread creation
   orders this write before that thread's first read of `solo`. */
void agc_lock_share(agc_lock *l) { l->solo = false; }

/* A token that differs for each live thread: its thread id (pthread_t, or the thread's HANDLE on Windows), unique among
   live threads. It used to be the address of a thread-local; on macOS arm64 the relock check then fired with an owner
   that was not the caller (CI job 118126582089), which a working mutex with unique tokens cannot produce. */
static uintptr_t self(void) { return (uintptr_t)uv_thread_self(); }

/* Names the lock, the owner it records and the calling thread's token, so that a failure seen once in CI says which
   lock and whether the owner was this thread. */
static _Noreturn void misuse(const agc_lock *l, const char *what) {
  char message[256];
  int n = snprintf(message, sizeof message,
                   "agentica: internal error: a thread %s (lock=%s owner=%#" PRIxPTR " self=%#" PRIxPTR " pid=%ld)\n",
                   what, l->name ? l->name : "?", atomic_load_explicit(&l->owner, memory_order_relaxed), self(),
                   (long)getpid());
  if (n > 0) (void)!write(2, message, (size_t)n < sizeof message ? (size_t)n : sizeof message - 1);
  abort();
}

bool agc_lock_held(const agc_lock *l) {
  return !l->solo && atomic_load_explicit(&l->owner, memory_order_relaxed) == self();
}

void agc_lock_take_shared(agc_lock *l) {
  if (agc_lock_held(l)) misuse(l, "took a lock it already holds");
  uv_mutex_lock(l->mutex);
  atomic_store_explicit(&l->owner, self(), memory_order_relaxed);
}

void agc_lock_drop_shared(agc_lock *l) {
  if (!agc_lock_held(l)) misuse(l, "dropped a lock it does not hold");
  atomic_store_explicit(&l->owner, 0, memory_order_relaxed);
  uv_mutex_unlock(l->mutex);
}

/* `rt->sync` is held by many nested calls (a cancel ends a task, which wakes its awaiters, which ends a Task.map item),
   so the scheduler counts how deep it is in and the mutex is taken and dropped once, at the outer level. The count
   also lets agc_sync_reset undo a lock that a failed builtin still held when agc_fail jumped out of it. */
void agc_sync_take_shared(agc_vm *vm) {
  if (vm->sync_depth++ == 0) agc_lock_take_shared(vm->rt->sync);
}

void agc_sync_drop_shared(agc_vm *vm) {
  if (--vm->sync_depth == 0) agc_lock_drop_shared(vm->rt->sync);
}

/* A mutator of the shared lists ran with rt->sync not held: a bug in the lock placement. It stops the run with a
   diagnostic, so make test-shared finds it. */
_Noreturn void agc_sync_missing(agc_vm *vm) {
  agc_fail(vm, "RUNTIME-INTERNAL", "shared state changed without rt->sync", 0);
}

/* After a failure that jumped out of locked code: gives back rt->sync and the stream lock that the scheduler held. */
void agc_sync_reset(agc_vm *vm) {
  if (vm->stream_lock) {
    agc_lock_drop(vm->stream_lock);
    vm->stream_lock = NULL;
  }
  if (!vm->sync_depth) return;
  vm->sync_depth = 0;
  agc_lock_drop_shared(vm->rt->sync);
}

/* Turns every lock on. The caller runs it before it starts a second scheduler or the I/O thread. */
void agc_share(agc_vm *vm) {
  agc_runtime *rt = vm->rt;
  agc_runq_share(rt->runq);
  agc_lock_share(rt->sync);
  agc_lock_share(rt->out.lock);
  agc_lock_share(rt->err.lock);
  agc_registry_share(vm);
  rt->shared = true;
}
