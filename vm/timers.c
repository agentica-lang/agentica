/*
 * The timed waits of tasks (docs/vm/16-architecture.md §16.9, "Timers"): a task that waits for a deadline is its own
 * entry in the min-heap of the scheduler that armed it, so the wait needs no job, no registry slot, no reference count
 * and no libuv call. agc_task_park_until arms and parks; agc_timers_run wakes the due tasks at the turn boundary and
 * when the run queue is empty; agc_timers_disarm takes a task out when it resumes or is cancelled. Core layer.
 */
#include "core.h"

#include <inttypes.h>

/* Locking: rt->sync protects every heap. A heap is armed and fired by its own scheduler, but a removal can come from
   any scheduler (the task resumes on whichever pops it), and the fire and the resume exclude each other under the
   lock, so a fire never wakes a task that has left the wait. When rt->sync is split, a removal from another scheduler
   becomes lazy (the CAS of the state decides, the owner drops the dead entry when it pops it and rebuilds the heap
   when the dead entries are twice the live ones); until then the entry is removed at once, in O(log n). */

static bool before(const agc_task *a, const agc_task *b) {
  if (a->timer.deadline != b->timer.deadline) return a->timer.deadline < b->timer.deadline;
  return a->timer.seq < b->timer.seq;
}

static void place(agc_timers *h, size_t index, agc_task *t) {
  h->items[index] = t;
  t->timer.index = index;
}

static void sift_up(agc_timers *h, size_t index) {
  agc_task *t = h->items[index];
  while (index > 0) {
    size_t parent = (index - 1) / 2;
    if (!before(t, h->items[parent])) break;
    place(h, index, h->items[parent]);
    index = parent;
  }
  place(h, index, t);
}

static void sift_down(agc_timers *h, size_t index) {
  agc_task *t = h->items[index];
  for (;;) {
    size_t child = 2 * index + 1;
    if (child >= h->count) break;
    if (child + 1 < h->count && before(h->items[child + 1], h->items[child])) child++;
    if (!before(h->items[child], t)) break;
    place(h, index, h->items[child]);
    index = child;
  }
  place(h, index, t);
}

static void publish(agc_timers *h) {
  atomic_store_explicit(&h->next_due, h->count ? h->items[0]->timer.deadline : UINT64_MAX, memory_order_relaxed);
}

static uint64_t remaining(uint64_t deadline) {
  uint64_t now = agc_clock_ms();
  return deadline > now ? deadline - now : 0;
}

static void arm(agc_vm *vm, agc_task *t, uint64_t deadline) {
  agc_sync_assert(vm);
  agc_timers *h = &vm->timers;
  if (t->timer.heap) agc_fail(vm, "RUNTIME-INTERNAL", "a task armed two timers", 0);
  /* A job carries its own deadline, and `resume` takes a job's result before it looks at the timer. */
  if (t->parked) agc_fail(vm, "RUNTIME-INTERNAL", "a task parked on a job armed a timer", 0);
  if (h->count == h->cap) {
    size_t cap = h->cap ? agc_size_mul(h->cap, 2) : 16;
    agc_task **items = agc_alloc(agc_size_mul(cap, sizeof(agc_task *)));
    if (h->count) memcpy(items, h->items, h->count * sizeof(agc_task *));
    h->items = items;
    h->cap = cap;
  }
  t->timer.deadline = deadline;
  t->timer.seq = ++h->seq;
  t->timer.heap = h;
  t->timer.timed = true;
  place(h, h->count++, t);
  sift_up(h, t->timer.index);
  publish(h);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "timer_arm task=%" PRIu64 " in_ms=%" PRIu64, t->id, remaining(deadline));
}

/* Takes the entry out of whichever heap holds it. A task that is not armed is left alone. */
void agc_timers_disarm(agc_vm *vm, agc_task *t) {
  agc_timers *h = t->timer.heap;
  if (!h) return;
  agc_sync_assert(vm);
  size_t index = t->timer.index;
  agc_task *last = h->items[--h->count];
  h->items[h->count] = NULL;
  t->timer.heap = NULL;
  if (last != t) {
    place(h, index, last);
    sift_up(h, last->timer.index);
    sift_down(h, last->timer.index);
  }
  publish(h);
}

/* The task has marked itself PARKING and registered its other waits: the deadline is the one more thing that can wake
   it. `retry` is that of agc_task_park. */
void agc_task_park_until(agc_vm *vm, uint64_t deadline_ms, bool retry) {
  arm(vm, vm->task, deadline_ms);
  agc_task_park(vm, retry);
}

bool agc_timers_run(agc_vm *vm) {
  agc_timers *h = &vm->timers;
  uint64_t due = atomic_load_explicit(&h->next_due, memory_order_relaxed);
  if (due == UINT64_MAX) return false;
  uint64_t now = agc_clock_ms();
  if (now < due) return false;
  bool woke = false;
  agc_sync_take(vm);
  while (h->count && h->items[0]->timer.deadline <= now) {
    agc_task *t = h->items[0];
    agc_timers_disarm(vm, t);
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "timer_fire task=%" PRIu64 " late_ms=%" PRIu64, t->id,
              now - t->timer.deadline);
    agc_task_wake(vm, t, "timer");
    woke = true;
  }
  agc_sync_drop(vm);
  return woke;
}

uint64_t agc_timers_next_due(const agc_vm *vm) {
  return atomic_load_explicit(&vm->timers.next_due, memory_order_relaxed);
}
