/*
 * The timers of a task (docs/vm/16-architecture.md §16.9, "Timers"): heap order, disarm from the middle, a fire wakes
 * exactly the due tasks once, a wait parked without a clock starts or drops at the right step, and a fire or a start
 * on one scheduler races a wake and resume on another under rt->sync with no wake or entry left after the resume.
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdbool.h>
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

static agc_task *parked_within(agc_vm *scheduler, int64_t ms) {
  agc_task *t = agc_new_task(scheduler);
  scheduler->task = t;
  atomic_store(&t->state, AGC_TASK_RUNNING);
  agc_task_parking(scheduler);
  agc_task_park_within(scheduler, ms, true);
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
  assert(vm.timers.count == TASKS);
  assert(agc_timers_next_due(&vm) == now - 1000);
  vm.task = vm.rt->main;
  assert(agc_timers_run(&vm));
  assert(vm.timers.count == 0 && agc_timers_next_due(&vm) == UINT64_MAX);
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

/* The heap invariant: no entry comes before its parent in (deadline, arming order), and each entry knows its place. */
static void check_heap(void) {
  const agc_timers *h = &vm.timers;
  for (size_t i = 0; i < h->count; i++) {
    const agc_task *t = h->items[i];
    assert(t->timer.index == i && t->timer.heap == h);
    if (i == 0) continue;
    const agc_task *parent = h->items[(i - 1) / 2];
    assert(parent->timer.deadline < t->timer.deadline ||
           (parent->timer.deadline == t->timer.deadline && parent->timer.seq < t->timer.seq));
  }
}

/* Past and future deadlines are mixed; a third of the timers are disarmed one by one, from anywhere in the heap, and
   the invariant holds after each. A fire wakes exactly the due timers that were not disarmed, and the future ones stay
   armed with the earliest of them as next_due. A disarm that only sifted down would leave a due entry under one that
   is not due, and it would fire late; check_heap catches that at once. */
static void test_disarm_and_future(void) {
  uint64_t now = agc_clock_ms();
  bool due[TASKS], gone[TASKS];
  for (size_t k = 0; k < TASKS; k++) {
    uint64_t r = (uint64_t)((k * 7919) % 1009);
    due[k] = r % 2 == 0;
    gone[k] = (k * 13) % 3 == 0;
    tasks[k] = parked_on_timer(&vm, due[k] ? now - 1000 + r : now + 60000 + r);
    tasks[k]->timer.timed = false;
  }
  check_heap();
  for (size_t k = 0; k < TASKS; k++) {
    if (!gone[k]) continue;
    agc_timers_disarm(&vm, tasks[k]);
    assert(!tasks[k]->timer.heap);
    check_heap();
  }
  size_t woken_expected = 0, left = 0;
  uint64_t earliest = UINT64_MAX;
  for (size_t k = 0; k < TASKS; k++) {
    if (gone[k]) continue;
    if (due[k]) {
      woken_expected++;
    } else {
      left++;
      if (tasks[k]->timer.deadline < earliest) earliest = tasks[k]->timer.deadline;
    }
  }
  assert(vm.timers.count == woken_expected + left);
  vm.task = vm.rt->main;
  assert(agc_timers_run(&vm));
  size_t woken = 0;
  for (agc_task *t; (t = pop_ready()); woken++) {
    size_t k = 0;
    while (tasks[k] != t) k++;
    assert(due[k] && !gone[k] && !t->timer.heap);
  }
  assert(woken == woken_expected);
  check_heap();
  assert(vm.timers.count == left && agc_timers_next_due(&vm) == earliest);
  for (size_t k = 0; k < TASKS; k++) {
    if (gone[k] || due[k]) continue;
    assert(tasks[k]->timer.heap && atomic_load(&tasks[k]->state) == AGC_TASK_PARKED);
    agc_timers_disarm(&vm, tasks[k]);
    check_heap();
  }
  assert(vm.timers.count == 0 && agc_timers_next_due(&vm) == UINT64_MAX);
}

static bool pending_slot(const agc_task *t) {
  return t->timer.pending && t->timer.heap == &vm.timers && atomic_load(&vm.timers.pending) == t;
}

/* agc_task_park_within reads no clock: the wait stays pending through the boundary of its own turn, starts at the end
   of the next turn, at the next such park or before the scheduler sleeps, and a task woken first drops it. A disarm
   (resume or cancel) empties the slot. rt->timers_armed counts a pending wait and ends where it began. */
static void test_pending(void) {
  uint64_t armed = atomic_load(&vm.rt->timers_armed);
  agc_task *a = parked_within(&vm, 60000);
  assert(pending_slot(a) && vm.timers.count == 0 && a->timer.deadline == 60000);
  assert(atomic_load(&vm.rt->timers_armed) == armed + 1);
  assert(!agc_timers_run(&vm));
  assert(pending_slot(a) && agc_timers_next_due(&vm) == UINT64_MAX);
  vm.task = vm.rt->main;
  uint64_t before = agc_clock_ms();
  assert(!agc_timers_run(&vm));
  assert(!a->timer.pending && a->timer.heap == &vm.timers && !atomic_load(&vm.timers.pending));
  assert(a->timer.deadline >= before + 60000 && a->timer.deadline <= agc_clock_ms() + 60000);
  assert(vm.timers.count == 1 && agc_timers_next_due(&vm) == a->timer.deadline);
  agc_task *b = parked_within(&vm, 60000);
  agc_task *c = parked_within(&vm, 60000);
  assert(pending_slot(c) && !b->timer.pending && b->timer.heap == &vm.timers && vm.timers.count == 2);
  agc_task_wake(&vm, c, "test");
  vm.task = vm.rt->main;
  assert(!agc_timers_run(&vm));
  assert(!c->timer.heap && !c->timer.pending && !atomic_load(&vm.timers.pending) && vm.timers.count == 2);
  assert(pop_ready() == c && !pop_ready());
  agc_task *d = parked_within(&vm, 60000);
  agc_timers_settle(&vm);
  assert(!d->timer.pending && d->timer.heap == &vm.timers && vm.timers.count == 3);
  agc_task *e = parked_within(&vm, 60000);
  agc_timers_disarm(&vm, e);
  assert(!e->timer.heap && !e->timer.pending && !atomic_load(&vm.timers.pending));
  agc_timers_disarm(&vm, a);
  agc_timers_disarm(&vm, b);
  agc_timers_disarm(&vm, d);
  assert(vm.timers.count == 0 && agc_timers_next_due(&vm) == UINT64_MAX);
  assert(atomic_load(&vm.rt->timers_armed) == armed);
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
    while (atomic_load_explicit(&go, memory_order_acquire) < round) agc_test_yield();
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

/* The owner runs its turn boundary while another scheduler wakes the task and resumes it, with a due timer (PENDING
   false) or a wait whose clock has not started (PENDING true). A due timer: each round queues the task exactly once
   (one wake wins the state CAS, the other finds it READY or RUNNING), and a later fire finds nothing to wake; without
   the rt->sync take in agc_timers_run the fire and the disarm change the heap at once, which make vm-tsan reports
   (checked by hand when this test was written). A pending wait: the owner finds the task parked (it starts the clock,
   and the resume takes the entry out of the heap), woken (it drops the entry), or gone from the slot. Every round ends
   with no entry, an empty slot and the armed count back. */
static void race_against_wake(bool pending) {
  agc_vm other = vm;
  other.sync_depth = 0;
  racing = agc_new_task(&vm);
  atomic_store(&go, 0);
  atomic_store(&finished, 0);
  uint64_t armed = atomic_load(&vm.rt->timers_armed);
  uv_thread_t thread;
  assert(uv_thread_create(&thread, wake_and_resume, &other) == 0);
  for (int round = 1; round <= ROUNDS; round++) {
    vm.task = racing;
    atomic_store(&racing->state, AGC_TASK_RUNNING);
    agc_task_parking(&vm);
    agc_sync_take(&vm);
    if (pending)
      agc_task_park_within(&vm, 60000, true);
    else
      agc_task_park_until(&vm, agc_clock_ms(), true);
    agc_sync_drop(&vm);
    racing->parking = false;
    assert(agc_task_commit_park(racing));
    vm.task = vm.rt->main;
    atomic_store_explicit(&go, round, memory_order_release);
    for (volatile int k = 0; k < (round * 5) % 29; k++) {}
    (void)agc_timers_run(&vm);
    while (atomic_load_explicit(&finished, memory_order_acquire) < round) agc_test_yield();
    assert(agc_runq_pop(vm.rt->runq) == NULL);
    assert(atomic_load(&racing->state) == AGC_TASK_RUNNING);
    assert(!racing->timer.heap && !racing->timer.pending && vm.timers.count == 0);
    assert(!atomic_load(&vm.timers.pending) && atomic_load(&vm.rt->timers_armed) == armed);
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
  test_pending();
  agc_share(&vm);
  race_against_wake(false);
  race_against_wake(true);
  puts("timers tests passed");
  return 0;
}
