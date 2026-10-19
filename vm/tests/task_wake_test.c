/*
 * The wake and the cancel against the park (docs/vm/10-io-multicore.md §10.2.3, docs/vm/16-architecture.md §16.11):
 * threads race the scheduler's agc_task_commit_park and agc_task_end_turn. Per round the task is queued, or ended,
 * exactly once, whichever side sees the flag, and is never left PARKED. A dropped wake or a double queue fails.
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <uv.h>

#define WAKERS 2
#define ROUNDS 20000

static agc_vm vm;
static agc_task *task;
static _Atomic int go;
static _Atomic int finished;

static void spin(int n) {
  for (volatile int k = 0; k < n; k++) {}
}

/* Each round waits for the scheduler's signal, spins a different time so that the wake falls before, inside and after
   the commit, and wakes twice (the second wake is a stale one whatever the first did). */
static void waker(void *arg) {
  int self = (int)(uintptr_t)arg;
  assert(agc_gc_thread_enter());
  for (int round = 1; round <= ROUNDS; round++) {
    while (atomic_load_explicit(&go, memory_order_acquire) < round) {}
    spin((round * 7 + self * 13) % 41);
    agc_task_wake(&vm, task, "test");
    agc_task_wake(&vm, task, "test");
    atomic_fetch_add_explicit(&finished, 1, memory_order_release);
  }
  agc_gc_thread_leave();
}

/* The scheduler thread. Odd rounds signal the wakers before the commit (the wake races the CAS), even rounds after
   it (the task is PARKED, or already queued). */
static void test_wake_against_park(void) {
  agc_runq *q = vm.rt->runq;
  agc_runq_share(q);
  uv_thread_t threads[WAKERS];
  for (uintptr_t k = 0; k < WAKERS; k++) assert(uv_thread_create(&threads[k], waker, (void *)k) == 0);
  vm.task = task;
  for (int round = 1; round <= ROUNDS; round++) {
    atomic_store_explicit(&task->state, AGC_TASK_RUNNING, memory_order_relaxed);
    agc_task_parking(&vm);
    assert(task->state == AGC_TASK_PARKING);
    bool committed;
    if (round & 1) {
      atomic_store_explicit(&go, round, memory_order_release);
      spin(round % 23);
      committed = agc_task_commit_park(task);
    } else {
      committed = agc_task_commit_park(task);
      atomic_store_explicit(&go, round, memory_order_release);
    }
    if (!committed) {
      assert(task->state == AGC_TASK_WOKEN);
      atomic_store_explicit(&task->state, AGC_TASK_READY, memory_order_relaxed);
      agc_runq_push(q, task);
    }
    while (atomic_load_explicit(&finished, memory_order_acquire) < round * WAKERS) {}
    assert(agc_runq_pop(q) == task);
    assert(agc_runq_pop(q) == NULL);
    assert(task->state == AGC_TASK_READY);
  }
  for (size_t k = 0; k < WAKERS; k++) assert(uv_thread_join(&threads[k]) == 0);
}

/* On one thread: the marks and their ends. A wake of a RUNNING task is stale; unpark takes PARKING and WOKEN back to
   RUNNING; a second wake of a PARKED task queues nothing. */
static void test_states(void) {
  agc_runq *q = vm.rt->runq;
  vm.task = task;
  atomic_store(&task->state, AGC_TASK_RUNNING);
  agc_task_wake(&vm, task, "test");
  assert(task->state == AGC_TASK_RUNNING && !agc_runq_pop(q));
  agc_task_parking(&vm);
  agc_task_parking(&vm);
  assert(task->state == AGC_TASK_PARKING && agc_task_waiting(task));
  agc_task_unpark(&vm);
  assert(task->state == AGC_TASK_RUNNING && !agc_task_waiting(task));
  agc_task_parking(&vm);
  agc_task_wake(&vm, task, "test");
  assert(task->state == AGC_TASK_WOKEN && !agc_task_waiting(task) && !agc_runq_pop(q));
  agc_task_parking(&vm);
  assert(task->state == AGC_TASK_WOKEN);
  agc_task_unpark(&vm);
  assert(task->state == AGC_TASK_RUNNING);
  agc_task_parking(&vm);
  assert(agc_task_commit_park(task) && task->state == AGC_TASK_PARKED);
  agc_task_wake(&vm, task, "test");
  agc_task_wake(&vm, task, "test");
  assert(task->state == AGC_TASK_READY && agc_runq_pop(q) == task && !agc_runq_pop(q));
}

#define CANCEL_ROUNDS 20000

static agc_vm canceller_vm;
static agc_task *victim;
static _Atomic int cancel_go;
static _Atomic int cancel_done;

/* The canceller is no task (its vm has no task), like a cancel from a thread that runs none. */
static void canceller(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  for (int round = 1; round <= CANCEL_ROUNDS; round++) {
    while (atomic_load_explicit(&cancel_go, memory_order_acquire) < round) {}
    spin((round * 11) % 53);
    agc_task_cancel(&canceller_vm, victim);
    atomic_fetch_add_explicit(&cancel_done, 1, memory_order_release);
  }
  agc_gc_thread_leave();
}

/* Odd rounds start the cancel before the end of the turn, even rounds after it, and the spins move it through the
   first look at the flag, the commit and the second look. Without the second look a cancel that falls between the
   first look and the commit leaves the task PARKED for ever, and this check fails. The VM is solo on purpose (no
   agc_share): rt->sync would serialize the cancel and the end of the turn, and the test is of the state protocol
   (the CAS and the second look), which must hold without the lock. */
static void test_cancel_against_park(void) {
  canceller_vm = vm;
  canceller_vm.task = NULL;
  uint64_t base = atomic_load(&vm.rt->tasks_done);
  uv_thread_t thread;
  assert(uv_thread_create(&thread, canceller, NULL) == 0);
  for (int round = 1; round <= CANCEL_ROUNDS; round++) {
    agc_task *t = agc_new_task(&vm);
    atomic_store_explicit(&t->state, AGC_TASK_RUNNING, memory_order_relaxed);
    vm.task = t;
    agc_task_parking(&vm);
    victim = t;
    if (round & 1) {
      atomic_store_explicit(&cancel_go, round, memory_order_release);
      spin(round % 29);
      agc_task_end_turn(&vm, t, AGC_TURN_PARKED, true);
    } else {
      agc_task_end_turn(&vm, t, AGC_TURN_PARKED, true);
      atomic_store_explicit(&cancel_go, round, memory_order_release);
    }
    while (atomic_load_explicit(&cancel_done, memory_order_acquire) < round) {}
    assert(t->state == AGC_TASK_DONE && t->cancelled);
    assert(atomic_load(&vm.rt->tasks_done) - base == (uint64_t)round);
    assert(agc_runq_pop(vm.rt->runq) == NULL);
  }
  assert(uv_thread_join(&thread) == 0);
}

/* On one thread: the READY cases of a cancel. A task in the queue is taken out and ended. A READY task that is not in
   the queue (a waker set the state and has not pushed) keeps its flag, and agc_task_next ends it when it is pushed;
   a task that is not cancelled comes out of agc_task_next as it is. A PARKED task is claimed once. */
static void test_cancel_ready(void) {
  agc_runq *q = vm.rt->runq;
  vm.task = NULL;
  uint64_t before = atomic_load(&vm.rt->tasks_done);
  agc_task *queued = agc_new_task(&vm);
  agc_runq_push(q, queued);
  agc_task_cancel(&vm, queued);
  assert(queued->state == AGC_TASK_DONE && agc_runq_pop(q) == NULL);

  agc_task *unpushed = agc_new_task(&vm);
  assert(unpushed->state == AGC_TASK_READY);
  agc_task_cancel(&vm, unpushed);
  assert(unpushed->state == AGC_TASK_READY && unpushed->cancelled && atomic_load(&vm.rt->tasks_done) == before + 1);
  agc_task *plain = agc_new_task(&vm);
  agc_runq_push(q, unpushed);
  agc_runq_push(q, plain);
  assert(agc_task_next(&vm) == plain && unpushed->state == AGC_TASK_DONE && atomic_load(&vm.rt->tasks_done) == before + 2);
  assert(agc_task_next(&vm) == NULL);

  agc_task *parked = agc_new_task(&vm);
  atomic_store(&parked->state, AGC_TASK_PARKED);
  assert(agc_task_claim(parked) && parked->state == AGC_TASK_READY && !agc_task_claim(parked));
  atomic_store(&parked->state, AGC_TASK_PARKED);
  agc_task_cancel(&vm, parked);
  assert(parked->state == AGC_TASK_DONE && agc_runq_pop(q) == NULL && atomic_load(&vm.rt->tasks_done) == before + 3);
}

int main(void) {
  agc_test_deadline(300);
  agc_init();
  agc_gc_allow_threads();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  task = agc_new_task(&vm);
  test_states();
  test_wake_against_park();
  test_cancel_ready();
  test_cancel_against_park();
  puts("task wake tests passed");
  return 0;
}
