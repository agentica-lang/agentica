/*
 * The global run queue (docs/vm/16-architecture.md §16.3): FIFO order and removal, solo and shared by many threads
 * (every task comes out once); the blocking pop of an idle scheduler (a waiter gets the push before or after it waits,
 * agc_runq_end wakes every waiter); and the spin of an idle scheduler (a push that a spinner takes sends no condvar
 * signal, and no push is lost when a spinner stops).
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
/* A spin that only a push, a nudge or the end stops, so the tests order events by state, not by time. */
#define SPIN_FOREVER_NS UINT64_C(600000000000)

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

/* An ended queue returns NULL from its wait whether or not it is solo, tasks left or not. */
static void test_solo_end(void) {
  agc_vm other;
  agc_vm_init(&other, NULL, stdout, stderr, INT64_MAX);
  agc_runq *q = other.rt->runq;
  agc_runq_push(q, agc_new_task(&other));
  agc_runq_end(q);
  assert(agc_runq_wait(q) == NULL);
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
   push whose signal is lost leaves the waiter blocked, and the deadline of main ends the test. A wait that tests the
   queue outside the lock is a data race that this test does not see in a plain build; make vm-tsan does. */
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

static agc_task *pushed_late;

static void push_late(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  uv_sleep(20);
  agc_runq_push(vm.rt->runq, pushed_late);
  agc_gc_thread_leave();
}

static void nudge_late(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  uv_sleep(20);
  agc_runq_nudge(vm.rt->runq);
  agc_gc_thread_leave();
}

/* The timed wait of a scheduler that has a timer: it returns NULL once the clock reaches the deadline, and not before;
   a push, a nudge or the end before the deadline ends it at once. A wait that ignored the deadline would leave the test
   to its own deadline. */
static void test_wait_until(void) {
  agc_runq *q = vm.rt->runq;
  uint64_t due = agc_clock_ms() + 30;
  assert(agc_runq_wait_until(q, due) == NULL && agc_clock_ms() >= due);
  assert(agc_runq_wait_until(q, agc_clock_ms()) == NULL);
  uv_thread_t thread;
  pushed_late = fresh();
  due = agc_clock_ms() + 60000;
  assert(uv_thread_create(&thread, push_late, NULL) == 0);
  assert(agc_runq_wait_until(q, due) == pushed_late && agc_clock_ms() < due);
  assert(uv_thread_join(&thread) == 0);
  assert(!agc_runq_nudged(q));
  assert(uv_thread_create(&thread, nudge_late, NULL) == 0);
  assert(agc_runq_wait_until(q, due) == NULL && agc_clock_ms() < due);
  assert(uv_thread_join(&thread) == 0);
  assert(agc_runq_take_nudge(q) && !agc_runq_take_nudge(q));
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

static agc_vm spun;
static agc_task *_Atomic spun_task;
static agc_task *_Atomic spun_waited;

/* An idle scheduler: spins, then waits if the spin found no task. */
static void spin_then_wait(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  agc_task *t = agc_runq_spin(spun.rt->runq);
  if (!t) t = agc_runq_wait(spun.rt->runq);
  atomic_store(&spun_task, t);
  agc_gc_thread_leave();
}

static void wait_spun(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  atomic_store(&spun_waited, agc_runq_wait(spun.rt->runq));
  agc_gc_thread_leave();
}

/* Waits until SPINNING schedulers spin and IDLE wait on the queue. It polls the counts, which only those threads
   change, so it waits for a state, not for a time. */
static void await_counts(agc_runq *q, uint32_t spinning, uint32_t idle) {
  for (;;) {
    agc_runq_counts c = agc_runq_stats(q);
    if (c.spinning == spinning && c.idle == idle) return;
    uv_sleep(0);
  }
}

/* The spin (docs/vm/16-architecture.md §16.9, "Wakes between schedulers"). With no setup a queue never spins. A
   spinner takes a push and the push sends no signal; a second spinner past spin_max returns at once. A push while one
   waits and none spins signals once. A spinner that runs out of budget waits, and the push after that wakes it with a
   signal. A spinner that takes one of two pushes while another scheduler waits leaves the other task to it with one
   signal (or a spare one), whichever way the pushes and the spinner's pop fall. The end stops a spinner. */
static void test_spin(void) {
  agc_vm_init(&spun, NULL, stdout, stderr, INT64_MAX);
  agc_runq *q = spun.rt->runq;
  agc_runq_share(q);
  assert(agc_runq_spin(q) == NULL);
  agc_runq_add_scheduler(q);
  agc_runq_add_scheduler(q);
  agc_runq_spin_setup(q, 1, SPIN_FOREVER_NS);
  uv_thread_t spinner, waiter;

  agc_task *a = agc_new_task(&spun);
  atomic_store(&spun_task, NULL);
  assert(uv_thread_create(&spinner, spin_then_wait, NULL) == 0);
  await_counts(q, 1, 0);
  assert(agc_runq_spin(q) == NULL);
  uint64_t signals = agc_runq_stats(q).signals;
  agc_runq_push(q, a);
  assert(uv_thread_join(&spinner) == 0);
  assert(atomic_load(&spun_task) == a);
  assert(agc_runq_stats(q).signals == signals);
  assert(agc_runq_pop(q) == NULL);

  agc_task *b = agc_new_task(&spun);
  assert(uv_thread_create(&waiter, wait_spun, NULL) == 0);
  await_counts(q, 0, 1);
  agc_runq_push(q, b);
  assert(uv_thread_join(&waiter) == 0);
  assert(atomic_load(&spun_waited) == b && agc_runq_stats(q).signals == signals + 1);

  agc_runq_spin_setup(q, 1, 1000);
  agc_task *c = agc_new_task(&spun);
  assert(uv_thread_create(&spinner, spin_then_wait, NULL) == 0);
  await_counts(q, 0, 1);
  agc_runq_push(q, c);
  assert(uv_thread_join(&spinner) == 0);
  assert(atomic_load(&spun_task) == c && agc_runq_stats(q).signals == signals + 2);

  agc_runq_spin_setup(q, 1, SPIN_FOREVER_NS);
  agc_task *d = agc_new_task(&spun), *e = agc_new_task(&spun);
  assert(uv_thread_create(&waiter, wait_spun, NULL) == 0);
  await_counts(q, 0, 1);
  assert(uv_thread_create(&spinner, spin_then_wait, NULL) == 0);
  await_counts(q, 1, 1);
  agc_runq_push(q, d);
  agc_runq_push(q, e);
  assert(uv_thread_join(&spinner) == 0 && uv_thread_join(&waiter) == 0);
  agc_task *got = atomic_load(&spun_task), *other = atomic_load(&spun_waited);
  assert((got == d && other == e) || (got == e && other == d));
  /* One signal, or two when the second push signalled after the spinner left and the spinner's pop still saw the
     waiter idle: a spare signal costs a wake, a missing one would leave the waiter blocked. */
  uint64_t sent = agc_runq_stats(q).signals - signals;
  assert((sent == 3 || sent == 4) && agc_runq_pop(q) == NULL);

  atomic_store(&spun_task, a);
  assert(uv_thread_create(&spinner, spin_then_wait, NULL) == 0);
  await_counts(q, 1, 0);
  agc_runq_end(q);
  assert(uv_thread_join(&spinner) == 0);
  assert(atomic_load(&spun_task) == NULL);
}

int main(void) {
  agc_test_deadline(300);
  agc_init();
  agc_gc_allow_threads();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_order_and_removal();
  test_solo_wait();
  test_solo_end();
  test_threads();
  test_shared_removal();
  test_wait_gets_the_push();
  test_wait_until();
  test_end_wakes_everyone();
  test_spin();
  puts("run queue tests passed");
  return 0;
}
