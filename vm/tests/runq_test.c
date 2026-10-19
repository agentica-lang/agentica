/*
 * The global run queue (docs/vm/16-architecture.md §16.3): FIFO order, removal from the middle, and many pushers
 * against many poppers on threads. Every pushed task comes out exactly once, a waiter on an empty queue sleeps until a
 * push, and agc_runq_end wakes all of them.
 */
#include "../core.h"

#include <assert.h>
#include <stdio.h>
#include <uv.h>

#define PUSHERS 3
#define POPPERS 3
#define PER_PUSHER 2000

static agc_vm vm;
static agc_task *tasks[PUSHERS * PER_PUSHER];
static _Atomic int popped[PUSHERS * PER_PUSHER];
static _Atomic int sleepers_woken;

static agc_task *fresh(void) { return agc_new_task(&vm); }

static void test_order_and_removal(void) {
  agc_runq *q = vm.rt->runq;
  assert(!agc_runq_peek(q) && agc_runq_pop(q) == NULL);
  agc_task *a = fresh(), *b = fresh(), *c = fresh(), *d = fresh();
  agc_runq_push(q, a);
  agc_runq_push(q, b);
  agc_runq_push(q, c);
  agc_runq_push(q, d);
  assert(agc_runq_peek(q) == a);
  assert(agc_runq_remove(q, c) && !agc_runq_remove(q, c));
  assert(agc_runq_remove(q, d));
  agc_runq_push(q, c);
  assert(agc_runq_remove(q, a));
  assert(agc_runq_pop(q) == b && agc_runq_pop(q) == c && agc_runq_pop(q) == NULL);
  assert(!agc_runq_peek(q) && !agc_runq_remove(q, a));
  agc_runq_push(q, a);
  assert(agc_runq_pop(q) == a && !a->next && !agc_runq_peek(q));
}

static void push_all(void *arg) {
  assert(agc_gc_thread_enter());
  size_t first = (size_t)(uintptr_t)arg * PER_PUSHER;
  for (size_t k = 0; k < PER_PUSHER; k++) agc_runq_push(vm.rt->runq, tasks[first + k]);
  agc_gc_thread_leave();
}

static size_t index_of(const agc_task *t) { return (size_t)(t->id - tasks[0]->id); }

static void pop_all(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  agc_task *t;
  while ((t = agc_runq_wait(vm.rt->runq))) atomic_fetch_add(&popped[index_of(t)], 1);
  agc_gc_thread_leave();
}

static void test_threads(void) {
  agc_runq *q = vm.rt->runq;
  for (size_t k = 0; k < sizeof tasks / sizeof tasks[0]; k++) tasks[k] = fresh();
  uv_thread_t pushers[PUSHERS], poppers[POPPERS];
  for (size_t k = 0; k < POPPERS; k++) assert(uv_thread_create(&poppers[k], pop_all, NULL) == 0);
  for (size_t k = 0; k < PUSHERS; k++) assert(uv_thread_create(&pushers[k], push_all, (void *)(uintptr_t)k) == 0);
  for (size_t k = 0; k < PUSHERS; k++) assert(uv_thread_join(&pushers[k]) == 0);
  /* Everything is pushed. The poppers drain the queue, then agc_runq_end releases them from the wait. */
  while (agc_runq_peek(q)) uv_sleep(1);
  agc_runq_end(q);
  for (size_t k = 0; k < POPPERS; k++) assert(uv_thread_join(&poppers[k]) == 0);
  for (size_t k = 0; k < sizeof popped / sizeof popped[0]; k++) assert(atomic_load(&popped[k]) == 1);
  assert(!agc_runq_peek(q) && agc_runq_wait(q) == NULL);
}

static void sleep_until_push(void *arg) {
  assert(agc_gc_thread_enter());
  agc_task *t = agc_runq_wait(vm.rt->runq);
  assert(t == arg);
  atomic_fetch_add(&sleepers_woken, 1);
  agc_gc_thread_leave();
}

static void test_wait_and_end(void) {
  agc_runtime *rt = vm.rt;
  rt->runq = agc_runq_new();
  agc_task *t = fresh();
  uv_thread_t sleeper;
  atomic_store(&sleepers_woken, 0);
  assert(uv_thread_create(&sleeper, sleep_until_push, t) == 0);
  uv_sleep(50);
  assert(atomic_load(&sleepers_woken) == 0);
  agc_runq_push(rt->runq, t);
  assert(uv_thread_join(&sleeper) == 0 && atomic_load(&sleepers_woken) == 1);
  /* A wait that starts after the end still returns, with what is left, then NULL. */
  agc_task *left = fresh();
  agc_runq_push(rt->runq, left);
  agc_runq_end(rt->runq);
  assert(agc_runq_wait(rt->runq) == left && agc_runq_wait(rt->runq) == NULL);
}

static void end_wakes_all(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  assert(agc_runq_wait(vm.rt->runq) == NULL);
  atomic_fetch_add(&sleepers_woken, 1);
  agc_gc_thread_leave();
}

static void test_end_wakes_every_waiter(void) {
  agc_runtime *rt = vm.rt;
  rt->runq = agc_runq_new();
  uv_thread_t waiters[POPPERS];
  atomic_store(&sleepers_woken, 0);
  for (size_t k = 0; k < POPPERS; k++) assert(uv_thread_create(&waiters[k], end_wakes_all, NULL) == 0);
  uv_sleep(50);
  assert(atomic_load(&sleepers_woken) == 0);
  agc_runq_end(rt->runq);
  for (size_t k = 0; k < POPPERS; k++) assert(uv_thread_join(&waiters[k]) == 0);
  assert(atomic_load(&sleepers_woken) == POPPERS);
}

int main(void) {
  agc_init();
  agc_gc_allow_threads();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_order_and_removal();
  test_threads();
  test_wait_and_end();
  test_end_wakes_every_waiter();
  puts("run queue tests passed");
  return 0;
}
