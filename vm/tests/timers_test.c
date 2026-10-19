/*
 * The timers of a task (docs/vm/16-architecture.md §16.9, "Timers"): the heap orders by deadline and arming order, a
 * disarm from the middle keeps the order, a fire wakes exactly the due tasks once, and a fire on one scheduler races a
 * wake and resume on another under rt->sync with exactly one queueing and no wake after the resume.
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <uv.h>

#define TASKS 200
#define ROUNDS 20000

static agc_vm vm;
static agc_task *tasks[TASKS];

static agc_task *parked_on_timer(agc_vm *scheduler, uint64_t deadline) {
  agc_task *t = agc_new_task(scheduler);
  scheduler->task = t;
  atomic_store(&t->state, AGC_TASK_RUNNING);
  agc_task_parking(scheduler);
  agc_task_park_until(scheduler, deadline, true);
  t->parking = false;
  assert(agc_task_commit_park(t));
  return t;
}

static agc_task *pop_ready(void) {
  agc_task *t = agc_runq_pop(vm.rt->runq);
  if (t) assert(atomic_load(&t->state) == AGC_TASK_READY);
  return t;
}

/* Deadlines come out in order, equal ones in the order they were armed, and only the due ones come out. */
static void test_order(void) {
  uint64_t now = agc_clock_ms();
  for (size_t k = 0; k < TASKS; k++) {
    uint64_t offset = (uint64_t)((k * 37) % 50);
    tasks[k] = parked_on_timer(&vm, now - 1000 + offset);
  }
  assert(agc_timers_armed(vm.rt) == TASKS);
  assert(agc_timers_next_due(&vm) == now - 1000);
  vm.task = vm.rt->main;
  assert(agc_timers_run(&vm));
  assert(agc_timers_armed(vm.rt) == 0 && agc_timers_next_due(&vm) == UINT64_MAX);
  uint64_t last = 0;
  uint64_t last_seq = 0;
  size_t popped = 0;
  for (agc_task *t; (t = pop_ready()); popped++) {
    assert(t->timer.deadline > last || (t->timer.deadline == last && t->timer.seq > last_seq));
    last = t->timer.deadline;
    last_seq = t->timer.seq;
    assert(!t->timer.heap && t->timer.timed);
  }
  assert(popped == TASKS);
  assert(!agc_timers_run(&vm));
}

/* A deadline that has not come stays; a disarm of any entry keeps the rest in order. */
static void test_disarm_and_future(void) {
  uint64_t now = agc_clock_ms();
  agc_task *later = parked_on_timer(&vm, now + 60000);
  for (size_t k = 0; k < TASKS; k++) tasks[k] = parked_on_timer(&vm, now - 500 + (uint64_t)((k * 53) % 97));
  for (size_t k = 0; k < TASKS; k += 3) agc_timers_disarm(&vm, tasks[k]);
  for (size_t k = 0; k < TASKS; k += 3) assert(!tasks[k]->timer.heap);
  agc_timers_disarm(&vm, tasks[0]);
  size_t live = TASKS - (TASKS + 2) / 3;
  assert(agc_timers_armed(vm.rt) == live + 1);
  vm.task = vm.rt->main;
  assert(agc_timers_run(&vm));
  size_t popped = 0;
  uint64_t last = 0;
  for (agc_task *t; (t = pop_ready()); popped++) {
    assert(t->timer.deadline >= last);
    last = t->timer.deadline;
  }
  assert(popped == live);
  assert(later->timer.heap && agc_timers_armed(vm.rt) == 1 && agc_timers_next_due(&vm) == later->timer.deadline);
  agc_timers_disarm(&vm, later);
  assert(agc_timers_armed(vm.rt) == 0);
}

static agc_task *racing;
static _Atomic int go;
static _Atomic int finished;

/* Another scheduler: a waker (a channel send, a target's end) wakes the task under rt->sync, then the scheduler that
   pops it resumes it, which marks it RUNNING and leaves the timer (`resume`), while the owner may still be firing. */
static void wake_and_resume(void *arg) {
  agc_vm *self = arg;
  assert(agc_gc_thread_enter());
  for (int round = 1; round <= ROUNDS; round++) {
    while (atomic_load_explicit(&go, memory_order_acquire) < round) {}
    for (volatile int k = 0; k < (round * 7) % 31; k++) {}
    agc_sync_take(self);
    agc_task_wake(self, racing, "test");
    agc_sync_drop(self);
    agc_task *popped;
    while (!(popped = agc_runq_pop(self->rt->runq))) {}
    assert(popped == racing);
    atomic_store(&racing->state, AGC_TASK_RUNNING);
    agc_sync_take(self);
    agc_timers_disarm(self, racing);
    agc_sync_drop(self);
    atomic_fetch_add_explicit(&finished, 1, memory_order_release);
  }
  agc_gc_thread_leave();
}

/* The owner fires a due timer while another scheduler wakes the task and resumes it. Each round queues the task
   exactly once (one wake wins the state CAS, the other finds it READY or RUNNING), the resume leaves no entry behind,
   and a later fire finds nothing to wake. Without the rt->sync take in agc_timers_run the fire and the disarm change
   the heap at once, which make vm-tsan reports (checked by hand when this test was written). */
static void test_fire_against_wake(void) {
  agc_share(&vm);
  agc_vm other = vm;
  other.sync_depth = 0;
  racing = agc_new_task(&vm);
  uv_thread_t thread;
  assert(uv_thread_create(&thread, wake_and_resume, &other) == 0);
  for (int round = 1; round <= ROUNDS; round++) {
    vm.task = racing;
    atomic_store(&racing->state, AGC_TASK_RUNNING);
    agc_task_parking(&vm);
    agc_sync_take(&vm);
    agc_task_park_until(&vm, agc_clock_ms(), true);
    agc_sync_drop(&vm);
    racing->parking = false;
    assert(agc_task_commit_park(racing));
    vm.task = vm.rt->main;
    atomic_store_explicit(&go, round, memory_order_release);
    for (volatile int k = 0; k < (round * 5) % 29; k++) {}
    (void)agc_timers_run(&vm);
    while (atomic_load_explicit(&finished, memory_order_acquire) < round) {}
    assert(agc_runq_pop(vm.rt->runq) == NULL);
    assert(atomic_load(&racing->state) == AGC_TASK_RUNNING);
    assert(!racing->timer.heap && agc_timers_armed(vm.rt) == 0);
    assert(!agc_timers_run(&vm));
    racing->timer.timed = false;
  }
  assert(uv_thread_join(&thread) == 0);
}

int main(void) {
  agc_test_deadline(300);
  agc_init();
  agc_gc_allow_threads();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_order();
  test_disarm_and_future();
  test_fire_against_wake();
  puts("timers tests passed");
  return 0;
}
