/*
 * Native.Mutex (site/content/library/io-and-system/native/_index.md, "Running"): the lock that a package takes around
 * the calls of a native library that is not thread-safe, since native calls run on several schedulers at once.
 * Native.mutex makes one, and Native.Mutex.synchronize (`lock.synchronize do ... end`) is a stepper that takes it, runs
 * the block and gives it back. A task that waits for it parks, so its scheduler runs other tasks. Core layer: it parks
 * tasks, and the end and the cancel of a task give back what it holds and leave its wait (vm/task.c). The wait rules
 * are those of docs/vm/16-architecture.md §16.9.
 */
#include "core.h"

/* A mutex, in GC memory, changed only under rt->sync (the steps of synchronize run with it held). `holder` is the task
   inside a synchronize block of it. `next` is the waiter that a release woke and gave the lock to: no other task takes
   it until `next` runs and takes it, or leaves the wait (a cancel), which passes it on, so the lock goes to the
   waiters in order. `waiters` is the FIFO of the other parked tasks (agc_task.wait_next), each with its `mutex_wait`
   set to the mutex. The holder lists the mutexes it holds through `held_next` (agc_task.mutexes), newest first, so its
   end, a crash or a cancel included, gives them back. */
struct agc_mutex {
  agc_task *holder, *next, *waiters, *waiters_tail;
  struct agc_mutex *held_next;
};

/* The state of one synchronize call (a stepper): the mutex, the call's span and whether the block runs. */
typedef struct {
  agc_stepper stepper;
  struct agc_mutex *mutex;
  uint32_t span;
  bool running;
} sync_block;

/* Gives M, which nobody holds, to the first waiter, which takes it when it runs. */
static void hand_on(agc_vm *vm, struct agc_mutex *m) {
  agc_task *t = m->waiters;
  if (!t) return;
  m->waiters = t->wait_next;
  if (!m->waiters) m->waiters_tail = NULL;
  t->wait_next = NULL;
  m->next = t;
  agc_task_wake(vm, t, "mutex");
}

/* T gives M back: it leaves T's list and goes to its first waiter. */
static void release(agc_vm *vm, agc_task *t, struct agc_mutex *m) {
  for (struct agc_mutex **at = &t->mutexes; *at; at = &(*at)->held_next) {
    if (*at != m) continue;
    *at = m->held_next;
    break;
  }
  m->held_next = NULL;
  m->holder = NULL;
  hand_on(vm, m);
}

/* The first step takes the mutex, or parks the task in its FIFO until a release gives it the lock, and then calls the
   block; the step after the block gives the mutex back and ends the call with the block's value (an error Result of
   a `try` in it included). A runtime failure in the block never comes back here: the task ends, and its end gives the
   mutex back (agc_mutex_release_held). A task that holds the mutex already fails at once, as Ruby's Mutex#lock does:
   it would wait for itself. */
static agc_step sync_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  sync_block *b = (sync_block *)self;
  struct agc_mutex *m = b->mutex;
  agc_task *t = vm->task;
  agc_sync_assert(vm);
  if (b->running) {
    release(vm, t, m);
    return (agc_step){.kind = AGC_STEP_END, .value = last};
  }
  if (m->holder == t)
    agc_fail(vm, "RUNTIME-NATIVE-MUTEX", "this task holds the mutex already: synchronize does not nest", b->span);
  if (m->holder || (m->next && m->next != t)) {
    /* A callback of native code fails here, before the task joins the FIFO. */
    agc_task_parking(vm);
    if (t->mutex_wait != m) {
      agc_task_enqueue(&m->waiters, &m->waiters_tail, t);
      t->mutex_wait = m;
    }
    agc_task_park(vm, false);
    return (agc_step){.kind = AGC_STEP_WAIT};
  }
  m->next = NULL;
  t->mutex_wait = NULL;
  m->holder = t;
  m->held_next = t->mutexes;
  t->mutexes = m;
  b->running = true;
  return (agc_step){.kind = AGC_STEP_CALL0};
}

/* Native.mutex(): a new mutex, which nobody holds. */
static agc_value builtin_mutex(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)vm;
  (void)args;
  (void)span;
  return agc_mutex_value(agc_alloc(sizeof(struct agc_mutex)));
}

/* lock.synchronize do ... end: runs the block (the last argument) with the mutex held (sync_step). */
static agc_value builtin_synchronize(agc_vm *vm, agc_value *args, uint32_t span) {
  sync_block *b = agc_alloc(sizeof *b);
  b->mutex = agc_as_mutex(vm, args[0]);
  b->span = span;
  b->stepper.step = sync_step;
  agc_task_stepper(vm, &b->stepper);
  return agc_void();
}

/* A cancelled task leaves the FIFO of the mutex it waits for (unlink_task); if a release had given it the lock, the
   lock goes on to the next waiter. Under rt->sync. */
void agc_mutex_leave(agc_vm *vm, agc_task *t) {
  struct agc_mutex *m = t->mutex_wait;
  t->mutex_wait = NULL;
  agc_task_remove(&m->waiters, &m->waiters_tail, t);
  if (m->next != t) return;
  m->next = NULL;
  if (!m->holder) hand_on(vm, m);
}

/* The end of T (finish_task): every mutex it still holds goes to its next waiter. Under rt->sync. */
void agc_mutex_release_held(agc_vm *vm, agc_task *t) {
  while (t->mutexes) release(vm, t, t->mutexes);
}

const agc_builtin agc_mutex_builtins[] = {
  {"Native.mutex", 0, builtin_mutex, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.Mutex.synchronize", 2, builtin_synchronize, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
};

const size_t agc_mutex_builtin_count = sizeof agc_mutex_builtins / sizeof agc_mutex_builtins[0];
