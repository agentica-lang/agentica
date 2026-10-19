/*
 * The global run queue (docs/vm/16-architecture.md §16.3): FIFO order and removal from the middle on one thread (the
 * solo queue, which takes no lock), then the same queue shared by many pushers and poppers on threads, after
 * agc_runq_share. Every pushed task comes out exactly once.
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

static void push_all(void *arg) {
  assert(agc_gc_thread_enter());
  size_t first = (size_t)(uintptr_t)arg * PER_PUSHER;
  for (size_t k = 0; k < PER_PUSHER; k++) agc_runq_push(vm.rt->runq, tasks[first + k]);
  agc_gc_thread_leave();
}

static size_t index_of(const agc_task *t) { return (size_t)(t->id - tasks[0]->id); }

/* Pops until every task has come out. The queue has no blocking pop (one scheduler never waits on it), so a popper
   that finds it empty yields the processor and looks again. */
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

int main(void) {
  agc_test_deadline(300);
  agc_init();
  agc_gc_allow_threads();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_order_and_removal();
  test_threads();
  test_shared_removal();
  puts("run queue tests passed");
  return 0;
}
