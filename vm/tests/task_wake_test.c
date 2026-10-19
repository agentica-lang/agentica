/*
 * The wake against the park path (docs/vm/10-io-multicore.md §10.2.3): a task marks itself PARKING, and two wakers on
 * other threads wake it while the scheduler thread ends the turn with agc_task_commit_park. Whatever the interleaving,
 * the task is queued exactly once per round: by the waker that found it PARKED, or by the scheduler when the commit
 * lost to a waker that found it PARKING (the state was WOKEN, and nobody else queued it). A wake that is dropped
 * leaves the queue empty, and a wake that is queued twice leaves two entries; both fail the round.
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

int main(void) {
  agc_test_deadline(300);
  agc_init();
  agc_gc_allow_threads();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  task = agc_new_task(&vm);
  test_states();
  test_wake_against_park();
  puts("task wake tests passed");
  return 0;
}
