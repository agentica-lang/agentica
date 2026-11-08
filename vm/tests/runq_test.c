/*
 * The global run queue (docs/vm/16-architecture.md §16.3): FIFO order and removal, solo and shared; the blocking pop
 * (a push before or after the wait, the end wakes every waiter); the spin (a push a spinner takes sends no signal, none
 * is lost when it stops); the push of a task whose turn ended; and the on-idle wake, sent without the queue's lock.
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
   one or two signals for this pair, whichever way the pushes and the spinner's pop fall. The end stops a spinner. */
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

/* The push of a task whose turn ended (agc_runq_push_own, #627): into an empty queue it sends no signal, since the
   pusher pops the task next; into a queue that holds a task it signals as agc_runq_push does, since the pusher pops
   that other task first. FIFO order is kept. */
static void test_push_own(void) {
  agc_vm own;
  agc_vm_init(&own, NULL, stdout, stderr, INT64_MAX);
  agc_runq *q = own.rt->runq;
  agc_runq_share(q);
  agc_task *a = agc_new_task(&own), *b = agc_new_task(&own);
  uint64_t signals = agc_runq_stats(q).signals;
  agc_runq_push_own(q, a);
  assert(agc_runq_stats(q).signals == signals);
  agc_runq_push_own(q, b);
  assert(agc_runq_stats(q).signals == signals + 1);
  assert(agc_runq_pop(q) == a && agc_runq_pop(q) == b && agc_runq_pop(q) == NULL);
  /* A kick sends the skipped wake only while the queue holds a task. */
  agc_runq_kick(q);
  assert(agc_runq_stats(q).signals == signals + 1);
  agc_runq_push_own(q, a);
  agc_runq_kick(q);
  assert(agc_runq_stats(q).signals == signals + 2);
  assert(agc_runq_pop(q) == a);
}

static agc_vm burst;
static _Atomic int burst_taken;

/* One idle scheduler of the burst: spins if ARG is non-NULL, else only waits, and takes one task. */
static void burst_one(void *arg) {
  assert(agc_gc_thread_enter());
  agc_runq *q = burst.rt->runq;
  agc_task *t = arg ? agc_runq_spin(q) : NULL;
  if (!t) t = agc_runq_wait(q);
  if (t) atomic_fetch_add(&burst_taken, 1);
  agc_gc_thread_leave();
}

/* A burst while one scheduler spins (without end) and WAITERS wait: WAITERS + 1 pushes, each scheduler takes one task.
   The spinner absorbs the signals of the pushes it sees, so the wake must be passed on by each scheduler that leaves
   with a task while more are queued (take_waited); without that chain a waiter can stay parked beside a queued task
   and the join below blocks until the test's deadline. Many rounds, so the pushes fall at different points of the
   spinner's take. */
static void test_burst_wakes_every_waiter(uint32_t waiters, int rounds) {
  for (int round = 0; round < rounds; round++) {
    agc_vm_init(&burst, NULL, stdout, stderr, INT64_MAX);
    agc_runq *q = burst.rt->runq;
    agc_runq_share(q);
    agc_runq_spin_setup(q, 1, SPIN_FOREVER_NS);
    for (uint32_t k = 0; k <= waiters; k++) agc_runq_add_scheduler(q);
    atomic_store(&burst_taken, 0);
    uv_thread_t threads[4];
    assert(waiters < 4);
    for (uint32_t k = 0; k < waiters; k++) assert(uv_thread_create(&threads[k], burst_one, NULL) == 0);
    await_counts(q, 0, waiters);
    assert(uv_thread_create(&threads[waiters], burst_one, &burst) == 0);
    await_counts(q, 1, waiters);
    for (uint32_t k = 0; k <= waiters; k++) agc_runq_push(q, agc_new_task(&burst));
    for (uint32_t k = 0; k <= waiters; k++) assert(uv_thread_join(&threads[k]) == 0);
    assert(atomic_load(&burst_taken) == (int)waiters + 1 && agc_runq_pop(q) == NULL);
  }
}

static agc_vm idled;
static agc_task *idle_push;
static uv_thread_t idle_prober;
static _Atomic bool idle_quiet, idle_probed, idle_hook_ran, idle_hook_late;

/* The probe of the I/O thread, started by the hook: the stall check's look at the queue, then a push. Both take the
   queue's lock, so they finish while the hook runs only if the hook runs without that lock. */
static void probe_idle(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  uint64_t epoch;
  atomic_store(&idle_quiet, agc_runq_quiet(idled.rt->runq, &epoch));
  agc_runq_push(idled.rt->runq, idle_push);
  atomic_store(&idle_probed, true);
  agc_gc_thread_leave();
}

/* The on-idle hook (the I/O thread's wake in a run): waits up to 5 s for the probe. */
static void idle_hook(void *data) {
  (void)data;
  atomic_store(&idle_hook_ran, true);
  assert(uv_thread_create(&idle_prober, probe_idle, NULL) == 0);
  uint64_t due = agc_clock_ms() + 5000;
  while (!atomic_load(&idle_probed)) {
    if (agc_clock_ms() >= due) {
      atomic_store(&idle_hook_late, true);
      return;
    }
    uv_sleep(1);
  }
}

/* The last scheduler to go idle wakes the I/O thread after it drops the queue's lock (#1216), so the stall check it
   wakes can take the lock at once and sees every scheduler waiting. A push in that gap signals no waiter (none waits
   yet), and the wait still takes it: it tests the queue again under the lock. TIMED uses agc_runq_wait_until, whose
   wait would otherwise sleep until its deadline. A hook run under the lock makes the probe wait out the 5 s and fail. */
static void test_idle_wake_without_lock(bool timed) {
  agc_vm_init(&idled, NULL, stdout, stderr, INT64_MAX);
  agc_runq *q = idled.rt->runq;
  agc_runq_share(q);
  agc_runq_add_scheduler(q);
  agc_runq_on_idle(q, idle_hook, NULL);
  idle_push = agc_new_task(&idled);
  atomic_store(&idle_quiet, false);
  atomic_store(&idle_probed, false);
  atomic_store(&idle_hook_ran, false);
  atomic_store(&idle_hook_late, false);
  uint64_t due = agc_clock_ms() + 60000;
  agc_task *t = timed ? agc_runq_wait_until(q, due) : agc_runq_wait(q);
  assert(uv_thread_join(&idle_prober) == 0);
  assert(atomic_load(&idle_hook_ran) && !atomic_load(&idle_hook_late) && atomic_load(&idle_quiet));
  assert(t == idle_push && agc_clock_ms() < due);
  uint64_t epoch;
  assert(agc_runq_stats(q).idle == 0 && !agc_runq_quiet(q, &epoch) && agc_runq_pop(q) == NULL);
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
  test_push_own();
  test_burst_wakes_every_waiter(2, 300);
  test_burst_wakes_every_waiter(3, 300);
  test_idle_wake_without_lock(false);
  test_idle_wake_without_lock(true);
  puts("run queue tests passed");
  return 0;
}
