/*
 * The global run queue (docs/vm/16-architecture.md §16.3): FIFO order and removal from the middle on one thread (the
 * solo queue, which takes no lock), then the same queue shared by many pushers and poppers on threads, after
 * agc_runq_share. Every pushed task comes out exactly once. Then the blocking pop of an idle scheduler: a waiter gets
 * the task pushed before or after it starts to wait, and agc_runq_end wakes every waiter, now and later.
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <uv.h>

#define PUSHERS 3
#define POPPERS 3
#define PER_PUSHER 2000
#define TASKS 6000 /* PUSHERS * PER_PUSHER */
#define WAIT_ROUNDS 300

static agc_vm vm;
static agc_task *tasks[TASKS];
static _Atomic int popped[TASKS];
static _Atomic int popped_total;

static agc_task *fresh(void) { return agc_new_task(&vm); }

static void test_order_and_removal(void) {
  agc_runq *q = vm.rt->runq;
  assert(!agc_test_ready_head(q) && agc_runq_pop(q) == NULL);
  agc_task *a = fresh(), *b = fresh(), *c = fresh(), *d = fresh();
  agc_runq_push(q, a);
  agc_runq_push(q, b);
  agc_runq_push(q, c);
  agc_runq_push(q, d);
  assert(agc_test_ready_head(q) == a);
  assert(agc_runq_remove(q, c) && !agc_runq_remove(q, c));
  assert(agc_runq_remove(q, d));
  agc_runq_push(q, c);
  assert(agc_runq_remove(q, a));
  assert(agc_runq_pop(q) == b && agc_runq_pop(q) == c && agc_runq_pop(q) == NULL);
  assert(!agc_test_ready_head(q) && !agc_runq_remove(q, a));
  agc_runq_push(q, a);
  assert(agc_runq_pop(q) == a && !a->next && !agc_test_ready_head(q));
}

/* A solo queue has no other thread to push, so its wait never blocks. */
static void test_solo_wait(void) {
  agc_runq *q = vm.rt->runq;
  agc_task *a = fresh();
  assert(agc_runq_wait(q) == NULL);
  agc_runq_push(q, a);
  assert(agc_runq_wait(q) == a && agc_runq_wait(q) == NULL);
}

static void spin(int n) {
  for (volatile int k = 0; k < n; k++) {}
}

static void push_all(void *arg) {
  assert(agc_gc_thread_enter());
  size_t first = (size_t)(uintptr_t)arg * PER_PUSHER;
  for (size_t k = 0; k < PER_PUSHER; k++) agc_runq_push(vm.rt->runq, tasks[first + k]);
  agc_gc_thread_leave();
}

static size_t index_of(const agc_task *t) { return (size_t)(t->id - tasks[0]->id); }

/* Pops until every task has come out. This popper polls: it yields the processor when the queue is empty and looks
   again (the blocking pop has its own tests below). */
static void pop_all(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  while (atomic_load(&popped_total) < TASKS) {
    agc_task *t = agc_runq_pop(vm.rt->runq);
    if (!t) {
      uv_sleep(0);
      continue;
    }
    atomic_fetch_add(&popped[index_of(t)], 1);
    atomic_fetch_add(&popped_total, 1);
  }
  agc_gc_thread_leave();
}

static void test_threads(void) {
  agc_runq *q = vm.rt->runq;
  for (size_t k = 0; k < TASKS; k++) tasks[k] = fresh();
  agc_runq_share(q);
  uv_thread_t pushers[PUSHERS], poppers[POPPERS];
  for (size_t k = 0; k < POPPERS; k++) assert(uv_thread_create(&poppers[k], pop_all, NULL) == 0);
  for (size_t k = 0; k < PUSHERS; k++) assert(uv_thread_create(&pushers[k], push_all, (void *)(uintptr_t)k) == 0);
  for (size_t k = 0; k < PUSHERS; k++) assert(uv_thread_join(&pushers[k]) == 0);
  for (size_t k = 0; k < POPPERS; k++) assert(uv_thread_join(&poppers[k]) == 0);
  for (size_t k = 0; k < TASKS; k++) assert(atomic_load(&popped[k]) == 1);
  assert(agc_runq_pop(q) == NULL);
}

/* A shared queue still orders and removes as the solo one does. */
static void test_shared_removal(void) {
  agc_runq *q = vm.rt->runq;
  agc_task *a = fresh(), *b = fresh(), *c = fresh();
  agc_runq_push(q, a);
  agc_runq_push(q, b);
  agc_runq_push(q, c);
  assert(agc_runq_remove(q, b) && !agc_runq_remove(q, b));
  assert(agc_runq_pop(q) == a && agc_runq_pop(q) == c && agc_runq_pop(q) == NULL);
}

static agc_task *_Atomic waited;

static void wait_one(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  atomic_store(&waited, agc_runq_wait(vm.rt->runq));
  agc_gc_thread_leave();
}

/* The push falls before the waiter starts, while it starts and after it blocks (the spin grows with the round). A
   push whose signal is lost, or a wait that tests the queue outside the lock, leaves the waiter blocked and the
   deadline of main ends the test. */
static void test_wait_gets_the_push(void) {
  agc_runq *q = vm.rt->runq;
  for (int round = 0; round < WAIT_ROUNDS; round++) {
    agc_task *t = fresh();
    atomic_store(&waited, NULL);
    uv_thread_t waiter;
    assert(uv_thread_create(&waiter, wait_one, NULL) == 0);
    spin((round * 977) % 60000);
    agc_runq_push(q, t);
    assert(uv_thread_join(&waiter) == 0);
    assert(atomic_load(&waited) == t && agc_runq_pop(q) == NULL);
  }
}

/* The end wakes all the waiters at once, and a wait after the end returns NULL at once, with tasks left in the queue. */
static void test_end_wakes_everyone(void) {
  agc_runq *q = vm.rt->runq;
  uv_thread_t waiters[POPPERS];
  for (size_t k = 0; k < POPPERS; k++) assert(uv_thread_create(&waiters[k], wait_one, NULL) == 0);
  spin(50000);
  agc_runq_end(q);
  for (size_t k = 0; k < POPPERS; k++) assert(uv_thread_join(&waiters[k]) == 0);
  assert(atomic_load(&waited) == NULL);
  agc_runq_push(q, fresh());
  assert(agc_runq_wait(q) == NULL);
}

int main(void) {
  agc_test_deadline(300);
  agc_init();
  agc_gc_allow_threads();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_order_and_removal();
  test_solo_wait();
  test_threads();
  test_shared_removal();
  test_wait_gets_the_push();
  test_end_wakes_everyone();
  puts("run queue tests passed");
  return 0;
}
