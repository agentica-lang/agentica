/*
 * The locks of the shared scheduler state (docs/vm/16-architecture.md §16.9, "One coarse lock"): the lock of one stream
 * and `rt->sync`, the one lock for the task tree, the waiter lists, the channels, Task.map groups and the logger table.
 * Both are solo until agc_share: while one thread runs the VM they take nothing, which is what one scheduler costs.
 * Core layer.
 *
 * It includes <uv.h> only for `uv_mutex_t`, as runq.c does (docs/vm/15-layers.md §15.5, rule 5).
 */
#include "core.h"

#include <uv.h>

struct agc_lock {
  uv_mutex_t mutex;
  bool solo;
};

agc_lock *agc_lock_new(void) {
  agc_lock *l = agc_alloc(sizeof *l);
  if (uv_mutex_init(&l->mutex) != 0) agc_out_of_memory();
  l->solo = true;
  return l;
}

/* From here on take and drop lock. Like agc_runq_share it runs before the second thread exists, so thread creation
   orders this write before that thread's first read of `solo`. */
void agc_lock_share(agc_lock *l) { l->solo = false; }

void agc_lock_take(agc_lock *l) {
  if (!l->solo) uv_mutex_lock(&l->mutex);
}

void agc_lock_drop(agc_lock *l) {
  if (!l->solo) uv_mutex_unlock(&l->mutex);
}

/* `rt->sync` is held by many nested calls (a cancel ends a task, which wakes its awaiters, which ends a Task.map item),
   so the scheduler counts how deep it is in and the mutex is taken and dropped once, at the outer level. The count
   also lets agc_sync_reset undo a lock that a failed builtin still held when agc_fail jumped out of it. */
void agc_sync_take_shared(agc_vm *vm) {
  if (vm->sync_depth++ == 0) uv_mutex_lock(&vm->rt->sync->mutex);
}

void agc_sync_drop_shared(agc_vm *vm) {
  if (--vm->sync_depth == 0) uv_mutex_unlock(&vm->rt->sync->mutex);
}

void agc_sync_reset(agc_vm *vm) {
  if (!vm->sync_depth) return;
  vm->sync_depth = 0;
  uv_mutex_unlock(&vm->rt->sync->mutex);
}

/* Turns every lock on. The caller runs it before it starts a second scheduler or the I/O thread. */
void agc_share(agc_vm *vm) {
  agc_runtime *rt = vm->rt;
  if (rt->program && rt->program->builtin_count) {
    rt->builtin_sync = agc_alloc_atomic(agc_size_mul(rt->program->builtin_count, sizeof(bool)));
    for (uint32_t k = 0; k < rt->program->builtin_count; k++)
      rt->builtin_sync[k] = agc_builtin_shared(rt->program->builtins[k]);
  }
  agc_runq_share(rt->runq);
  agc_lock_share(rt->sync);
  agc_lock_share(rt->out.lock);
  agc_lock_share(rt->err.lock);
  rt->shared = true;
}
