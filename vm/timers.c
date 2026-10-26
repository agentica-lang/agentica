/*
 * The timed waits of tasks (docs/vm/16-architecture.md §16.9, "Timers"): a task that waits for a deadline is its own
 * entry in the min-heap of the scheduler that armed it, so the wait needs no job, no registry slot, no reference count
 * and no libuv call. agc_task_park_until arms and parks, agc_task_park_within parks and starts the clock later;
 * agc_timers_run wakes the due tasks at the turn boundary and when the run queue is empty; agc_timers_disarm takes a
 * task out when it resumes or is cancelled. Core layer.
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

/* Checks that T may wait on a timer and counts it as armed. A timer is counted as armed before it is counted as weak
   (agc_timers_strong reads them in the other order). */
static void claim(agc_vm *vm, agc_task *t) {
  agc_sync_assert(vm);
  if (t->timer.heap) agc_fail(vm, "RUNTIME-INTERNAL", "a task armed two timers", 0);
  /* A job carries its own deadline, and `resume` takes a job's result before it looks at the timer. */
  if (t->parked) agc_fail(vm, "RUNTIME-INTERNAL", "a task parked on a job armed a timer", 0);
  t->timer.timed = true;
  atomic_fetch_add_explicit(&vm->rt->timers_armed, 1, memory_order_relaxed);
  if (t->service) atomic_fetch_add_explicit(&vm->rt->timers_weak, 1, memory_order_relaxed);
}

static void unclaim(agc_vm *vm, const agc_task *t) {
  if (t->service) atomic_fetch_sub_explicit(&vm->rt->timers_weak, 1, memory_order_relaxed);
  atomic_fetch_sub_explicit(&vm->rt->timers_armed, 1, memory_order_relaxed);
}

static void insert(agc_vm *vm, agc_timers *h, agc_task *t, uint64_t deadline) {
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
  place(h, h->count++, t);
  sift_up(h, t->timer.index);
  publish(h);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "timer_arm task=%" PRIu64 " in_ms=%" PRIu64, t->id, remaining(deadline));
}

/* Starts the clock of this scheduler's pending wait, with rt->sync held. A task still parked gets its deadline from
   *NOW, read here once if the caller has not read it (0). A task that was woken already has its wake: its resume ends
   the wait, so it needs no deadline and the entry is dropped, which is what spares the clock in a ping-pong. */
static void start_pending(agc_vm *vm, uint64_t *now) {
  agc_timers *h = &vm->timers;
  agc_task *t = atomic_load_explicit(&h->pending, memory_order_relaxed);
  if (!t) return;
  atomic_store_explicit(&h->pending, NULL, memory_order_relaxed);
  t->timer.pending = false;
  if (atomic_load_explicit(&t->state, memory_order_acquire) != AGC_TASK_PARKED) {
    t->timer.heap = NULL;
    unclaim(vm, t);
    return;
  }
  if (!*now) *now = agc_clock_ms();
  insert(vm, h, t, *now + t->timer.deadline);
}

static void arm(agc_vm *vm, agc_task *t, uint64_t deadline) {
  claim(vm, t);
  insert(vm, &vm->timers, t, deadline);
}

/* Takes the entry out of whichever heap or pending slot holds it. A task that is not armed is left alone. */
void agc_timers_disarm(agc_vm *vm, agc_task *t) {
  agc_timers *h = t->timer.heap;
  if (!h) return;
  agc_sync_assert(vm);
  t->timer.heap = NULL;
  if (t->timer.pending) {
    t->timer.pending = false;
    atomic_store_explicit(&h->pending, NULL, memory_order_relaxed);
    unclaim(vm, t);
    return;
  }
  size_t index = t->timer.index;
  agc_task *last = h->items[--h->count];
  h->items[h->count] = NULL;
  if (last != t) {
    place(h, index, last);
    sift_up(h, last->timer.index);
    sift_down(h, last->timer.index);
  }
  publish(h);
  unclaim(vm, t);
}

/* True when some armed timer is not a service task's: the stall checks wait for those only. A timer is counted as
   armed before it is counted as weak and stops being weak before it stops being armed, and the weak count is read
   first, so a change in between can only make this true, which delays a stall to the next check. The relaxed loads
   are enough only because of the two callers: stalled() runs once every run queue is quiet, and timers are armed
   only by running tasks, so it sees no change; idle_wait uses the answer only to pick alive_required for one wait,
   where a stale answer costs one more turn of the loop. */
bool agc_timers_strong(const agc_vm *vm) {
  uint64_t weak = atomic_load_explicit(&vm->rt->timers_weak, memory_order_relaxed);
  return atomic_load_explicit(&vm->rt->timers_armed, memory_order_relaxed) > weak;
}

/* The task has marked itself PARKING and registered its other waits: the deadline is the one more thing that can wake
   it. `retry` is that of agc_task_park. */
void agc_task_park_until(agc_vm *vm, uint64_t deadline_ms, bool retry) {
  arm(vm, vm->task, deadline_ms);
  agc_task_park(vm, retry);
}

/* A wait that ends within a turn or two never needs its deadline, and on a host whose clock is a system call (an HPET
   clock source) reading it cost more than the channel operation (#629). So the clock starts late, at the first of: the
   end of the scheduler's next turn (agc_timers_run), the next park of this kind on the scheduler, which takes the slot,
   and the moment it goes idle (agc_timers_settle). So the timeout is late by at most one more turn than another
   timer's, which also waits for a turn boundary to fire. Only one wait is pending per scheduler: a turn parks at most
   one task. */
void agc_task_park_within(agc_vm *vm, int64_t timeout_ms) {
  agc_task *t = vm->task;
  agc_timers *h = &vm->timers;
  claim(vm, t);
  uint64_t now = 0;
  start_pending(vm, &now);
  t->timer.deadline = (uint64_t)timeout_ms;
  t->timer.pending = true;
  t->timer.heap = h;
  atomic_store_explicit(&h->pending, t, memory_order_relaxed);
  agc_task_park(vm, true);
}

/* Starts the pending wait under rt->sync, and returns the clock it read, or 0. */
static uint64_t settle(agc_vm *vm) {
  uint64_t now = 0;
  if (!atomic_load_explicit(&vm->timers.pending, memory_order_relaxed)) return 0;
  agc_sync_take(vm);
  start_pending(vm, &now);
  agc_sync_drop(vm);
  return now;
}

void agc_timers_settle(agc_vm *vm) { (void)settle(vm); }

bool agc_timers_run(agc_vm *vm) {
  agc_timers *h = &vm->timers;
  /* The task that just ran parked in its own turn: its peer has not run yet, so its clock waits one more turn. */
  const agc_task *pending = atomic_load_explicit(&h->pending, memory_order_relaxed);
  uint64_t now = pending && pending != vm->task ? settle(vm) : 0;
  uint64_t due = atomic_load_explicit(&h->next_due, memory_order_relaxed);
  if (due == UINT64_MAX) return false;
  if (!now) now = agc_clock_ms();
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
