/*
 * The scheduler: agc_vm_run (a FIFO run queue, one turn per task, libuv polled
 * between turns), park and wake, spawn, task groups, and cancellation (children
 * first). It also reports unobserved crashes. Core layer. Design:
 * docs/vm/10-io-scheduler.md §10.2.1 and docs/vm/14-core-invariants.md.
 */
#include "core.h"

#include <inttypes.h>
#include <string.h>

/* Wakes between schedulers (docs/vm/16-architecture.md §16.9): a scheduler runs the task in its runnext slot at most
   RUNNEXT_LIMIT times in a row before it looks at the global queue, and an idle scheduler spins for SPIN_BUDGET_US
   before it waits on the queue's condvar. */
#define RUNNEXT_LIMIT 3u
#define SPIN_BUDGET_US 10u

/* The state READY means "in the run queue": a task that spawns, yields or is woken is READY before it is pushed. The
   store is sequentially consistent because a cancel of a task that yields is a store-then-load pair like the one at the
   park (cancel_one stores the flag and reads the state; this stores the state and agc_task_next reads the flag): with
   weaker orders both could miss the other on a weakly ordered machine and the cancel would wait for another turn. */
static void enqueue(agc_vm *vm, agc_task *t) {
  atomic_store_explicit(&t->state, AGC_TASK_READY, memory_order_seq_cst);
  agc_runq_push(vm->rt->runq, t);
}

/* A waker acts only on a task that waits (docs/vm/10-io-multicore.md §10.2.3), and the CAS lets one waker win, so a
   task is queued at most once. A PARKED task is in no queue: the winner makes it READY and pushes it. A PARKING task
   is still in its own turn: the winner only marks it WOKEN and queues nothing; the scheduler finds the mark when it
   tries to publish PARKED (agc_task_commit_park) and queues the task itself. acq_rel: whoever runs the task next sees
   what the waker wrote first (a job's result). Any other state is a stale wake and changes nothing. */
void agc_task_wake(agc_vm *vm, agc_task *t, const char *by) {
  agc_task_state seen = atomic_load_explicit(&t->state, memory_order_acquire);
  while (seen == AGC_TASK_PARKING || seen == AGC_TASK_PARKED) {
    agc_task_state next = seen == AGC_TASK_PARKED ? AGC_TASK_READY : AGC_TASK_WOKEN;
    if (!atomic_compare_exchange_weak_explicit(&t->state, &seen, next, memory_order_acq_rel, memory_order_acquire))
      continue;
    if (next == AGC_TASK_READY) {
      AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "wake task=%" PRIu64 " by=%s", t->id, by);
      /* A wake by a scheduler thread keeps the task on that scheduler when its slot is free: the waker's turn ends
         soon, and the task runs next on the same core, with no lock of the queue and no futex wake. A full slot keeps
         its task; the new one goes to the queue. */
      if (vm->runnext_on && !vm->runnext)
        vm->runnext = t;
      else
        agc_runq_push(vm->rt->runq, t);
    } else {
      AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "woken task=%" PRIu64 " by=%s", t->id, by);
    }
    return;
  }
}

bool agc_task_waiting(const agc_task *t) {
  agc_task_state seen = t->state;
  return seen == AGC_TASK_PARKING || seen == AGC_TASK_PARKED;
}

/* A task whose turn has not ended: it runs, is on its way to PARKED, or was woken on that way. */
static bool executing(const agc_task *t) {
  agc_task_state seen = t->state;
  return seen == AGC_TASK_RUNNING || seen == AGC_TASK_PARKING || seen == AGC_TASK_WOKEN;
}

void agc_task_enqueue(agc_task **head, agc_task **tail, agc_task *t) {
  t->wait_next = NULL;
  if (*tail)
    (*tail)->wait_next = t;
  else
    *head = t;
  *tail = t;
}

void agc_task_wake_all(agc_vm *vm, agc_task **head, agc_task **tail, const char *by) {
  agc_sync_assert(vm);
  agc_task *t = *head;
  *head = *tail = NULL;
  while (t) {
    agc_task *next = t->wait_next;
    t->wait_next = NULL;
    agc_task_wake(vm, t, by);
    t = next;
  }
}

void agc_task_remove(agc_task **head, agc_task **tail, const agc_task *t) {
  agc_task *previous = NULL;
  for (agc_task *k = *head; k; previous = k, k = k->wait_next) {
    if (k != t) continue;
    if (previous)
      previous->wait_next = k->wait_next;
    else
      *head = k->wait_next;
    if (*tail == k) *tail = previous;
    k->wait_next = NULL;
    return;
  }
}

/* Starts a wait (§10.2.3): the running task becomes PARKING. It is called BEFORE the wait is registered (before the
   task joins a waiter list, posts a request or starts a job), then the code registers, looks at its condition and
   either parks (agc_task_park) or gives up (agc_task_unpark). From the mark on, a wake finds PARKING and sets WOKEN
   instead of being dropped as the stale wake of a running task, so a wake between the registration and the end of
   the turn cannot be lost. Only the thread that runs the task writes RUNNING, and a waker acts on PARKING and PARKED
   only, so the check and the store cannot race. A second call in the same turn keeps what it finds: a waker may have
   changed PARKING to WOKEN, and a store would erase that. The release store orders the mark before the registration
   that a waker's acquire load reads. */
void agc_task_parking(agc_vm *vm) {
  agc_task *t = vm->task;
  if (atomic_load_explicit(&t->state, memory_order_relaxed) == AGC_TASK_RUNNING)
    atomic_store_explicit(&t->state, AGC_TASK_PARKING, memory_order_release);
}

/* The wait is not needed after all (the condition is already true, or the task was cancelled): back to RUNNING from
   PARKING or from WOKEN, whichever a waker left. A task that was woken has nothing to do with the wake, which was
   only a hint. */
void agc_task_unpark(agc_vm *vm) {
  agc_task *t = vm->task;
  agc_task_state seen = atomic_load_explicit(&t->state, memory_order_acquire);
  while (seen == AGC_TASK_PARKING || seen == AGC_TASK_WOKEN)
    if (atomic_compare_exchange_weak_explicit(&t->state, &seen, AGC_TASK_RUNNING, memory_order_acq_rel,
                                              memory_order_acquire))
      return;
}

/* Says that this turn ends in a wait: the interpreter parks the task when the builtin returns (park_task in
   interp.c), and with `retry` it runs the builtin again when the task resumes. The caller marked the task already
   (agc_task_parking, once per park, before it registered anything), and the state is not touched here or by anything
   after this call: the scheduler publishes PARKED in agc_vm_run, after it has finished with the task. A caller that
   forgot the mark ends its turn as RUNNING; the commit fails and the scheduler queues the task, so it spins instead of
   waiting, which a test shows at once. */
void agc_task_park(agc_vm *vm, bool retry) {
  agc_task *t = vm->task;
  t->parking = true;
  t->retry = retry;
}

/* The end of a turn that waits: PARKING to PARKED, the one CAS that decides. It holds unless a waker got in first,
   and then the state is WOKEN and nobody queued the task: the caller queues it, and its next turn looks at the wait
   again (a job's result is taken by `resume`, a retry runs the builtin again). The CAS is the last access of the
   scheduler to the task: once the task is PARKED a waker may queue it and another scheduler run it. */
bool agc_task_commit_park(agc_task *t) {
  agc_task_state expected = AGC_TASK_PARKING;
  return atomic_compare_exchange_strong_explicit(&t->state, &expected, AGC_TASK_PARKED, memory_order_seq_cst,
                                                 memory_order_seq_cst);
}

/* Takes a PARKED task for the caller, the way a waker does but without queueing it: PARKED to READY. Whoever wins the
   CAS owns the task (nobody else can queue or run it) and either pushes it or ends it. The cancel uses it (cancel_one,
   agc_task_end_turn); a loser finds the state changed by a waker, who queues the task. */
bool agc_task_claim(agc_task *t) {
  agc_task_state expected = AGC_TASK_PARKED;
  return atomic_compare_exchange_strong_explicit(&t->state, &expected, AGC_TASK_READY, memory_order_acq_rel,
                                                 memory_order_acquire);
}

void agc_task_stepper(agc_vm *vm, agc_stepper *stepper) { vm->task->stepper = stepper; }

static void adopt(agc_vm *vm, agc_task *parent, agc_task *child) {
  agc_sync_assert(vm);
  child->parent = parent;
  child->prev_sibling = NULL;
  child->next_sibling = parent->children;
  if (parent->children) parent->children->prev_sibling = child;
  parent->children = child;
}

static void leave_parent(agc_task *t) {
  if (t->prev_sibling)
    t->prev_sibling->next_sibling = t->next_sibling;
  else if (t->parent)
    t->parent->children = t->next_sibling;
  if (t->next_sibling) t->next_sibling->prev_sibling = t->prev_sibling;
  t->parent = t->prev_sibling = t->next_sibling = NULL;
}

void agc_task_close_done(agc_vm *vm, agc_task *t) {
  if (--t->closing != 0) return;
  agc_task_wake_all(vm, &t->waiters, &t->waiters_tail, "await");
  /* An end hook that found a close pending put itself back (Task.map), and now the task has settled. */
  agc_end_fn end = t->end;
  t->end = NULL;
  if (end) end(vm, t);
}

static void finish_task(agc_vm *vm, agc_task *t) {
  agc_sync_assert(vm);
  t->left_children = t->children != NULL;
  agc_close_owned(vm, t);
  atomic_store_explicit(&t->state, AGC_TASK_DONE, memory_order_release);
  t->regs = NULL;
  t->reg_capacity = 0;
  t->frames = NULL;
  t->frame_capacity = 0;
  t->cursor = NULL;
  t->turn_cost = 0;
  /* A service task was counted as done when it was spawned (agc_task_spawn_in). */
  if (!t->group && !t->service) atomic_fetch_add_explicit(&vm->rt->tasks_done, 1, memory_order_relaxed);
  while (t->children) {
    agc_task *child = t->children;
    leave_parent(child);
    if (t->parent) adopt(vm, t->parent, child);
  }
  leave_parent(t);
  if (!t->closing) agc_task_wake_all(vm, &t->waiters, &t->waiters_tail, "await");
  agc_end_fn end = t->end;
  t->end = NULL;
  if (end) end(vm, t);
}

/* The task is out of the run queue already (cancel_one took it out or claimed it PARKED) or was never in it. */
static void unlink_task(agc_vm *vm, agc_task *t) {
  if (t->parked) agc_io_detach(vm, t);
  agc_timers_disarm(vm, t);
  if (t->lock_wait) agc_handle_leave(vm, t);
  if (t->channel.channel) agc_channel_leave(vm, t);
  if (t->output.out) agc_output_leave(vm, t);
  if (t->awaiting) agc_task_remove(&t->awaiting->waiters, &t->awaiting->waiters_tail, t);
  t->awaiting = NULL;
  agc_task_remove(&vm->rt->in.waiters, &vm->rt->in.waiters_tail, t);
  t->parking = t->retry = false;
}

static void end_cancelled(agc_vm *vm, agc_task *t) {
  agc_sync_assert(vm);
  unlink_task(vm, t);
  finish_task(vm, t);
}

/* The ending of a cancelled task by a scheduler at the end of its turn or at the pop: rt->sync is not held there. */
static void end_cancelled_locked(agc_vm *vm, agc_task *t) {
  agc_sync_take(vm);
  end_cancelled(vm, t);
  agc_sync_drop(vm);
}

/* The flag is set first, then the state decides who ends the task, and exactly one party does (§16.11):
   - A task that runs, parks or was woken (RUNNING, PARKING, WOKEN) is on a scheduler's turn. That scheduler reads the
     flag at the end of the turn and again after it publishes PARKED (agc_task_end_turn), so it ends the task within a
     turn; a canceller on the same scheduler only has to end the turn (`yield`).
   - A READY task is in the queue, or a waker set READY and has not pushed yet. The canceller takes it out of the queue
     and ends it. If it is not there, the pusher or a scheduler that popped it ends it: agc_task_next checks the flag.
   - A PARKED task is claimed by a CAS (agc_task_claim), the same race as a waker's. The winner owns it. A loser looks
     at the state again: a waker made it READY. */
static void cancel_one(agc_vm *vm, agc_task *t, const char *why) {
  atomic_store_explicit(&t->cancelled, true, memory_order_seq_cst);
  /* Two calls, not one with a "%s" for " at=": the trace escaper quotes a text value that holds a space or '='. */
  if (!t->group && why)
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "cancel task=%" PRIu64 " at=%s", t->id, why);
  else if (!t->group)
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "cancel task=%" PRIu64, t->id);
  for (;;) {
    switch (atomic_load_explicit(&t->state, memory_order_seq_cst)) {
    case AGC_TASK_RUNNING:
    case AGC_TASK_PARKING:
    case AGC_TASK_WOKEN:
      if (t == vm->task) vm->yield = true;
      return;
    case AGC_TASK_READY:
      /* In the canceller's own runnext slot it is taken out like from the queue; in another scheduler's slot it is
         left there, and that scheduler's agc_task_next ends it, as for a popped task. */
      if (vm->runnext == t) {
        vm->runnext = NULL;
        end_cancelled(vm, t);
      } else if (agc_runq_remove(vm->rt->runq, t))
        end_cancelled(vm, t);
      else
        AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "cancel_deferred task=%" PRIu64, t->id);
      return;
    case AGC_TASK_PARKED:
      if (!agc_task_claim(t)) continue;
      end_cancelled(vm, t);
      return;
    case AGC_TASK_DONE:
      return;
    }
  }
}

/* Children before parents, so each cancelled task has no live child left
   to move; a running task only gets its flag and ends after its builtin. `why`, when set, is the at= reason of the
   root's trace line. */
static void cancel_tree(agc_vm *vm, agc_task *root, const char *why) {
  agc_sync_assert(vm);
  if (root == vm->rt->main || root->state == AGC_TASK_DONE || root->cancelled) return;
  agc_task *t = root;
  uint64_t count = 0;
  for (;;) {
    agc_task *child = t->children;
    while (child && child->cancelled) child = child->next_sibling;
    if (child) {
      t = child;
      continue;
    }
    agc_task *up = t->parent;
    cancel_one(vm, t, t == root ? why : NULL);
    count++;
    if (t == root) break;
    t = up;
  }
  if (vm->task && executing(vm->task)) agc_charge(vm, count);
}

void agc_task_cancel(agc_vm *vm, agc_task *root) { cancel_tree(vm, root, NULL); }

/* The task takes the result of its job. agc_io_finish takes rt->sync itself for the parts that change shared lists (the
   hand-on of a handle's lock, a close) and for the halves of a kind marked `locked`; the rest, such as the text of a
   file read, is built outside the lock. */
static void resume(agc_vm *vm, agc_task *t) {
  if (t->parked) {
    agc_value result = agc_io_finish(vm, t);
    if (!t->retry) t->regs[t->park_reg] = result;
  } else if (t->timer.timed) {
    /* Only a park that armed a timer pays for rt->sync here: the heap fields belong to the lock. A void call's
       register is never read (CHECK-VOID-VALUE), so a sleep writes no result. */
    agc_sync_take(vm);
    agc_timers_disarm(vm, t);
    agc_sync_drop(vm);
    t->timer.timed = false;
  }
  t->retry = false;
}

static void trace_spawn(const agc_vm *vm, const agc_task *t, const agc_task *parent) {
  const agc_trace *tr = &vm->rt->trace;
  if (!AGC_TRACE_ON(tr, AGC_TRACE_SCHED) || !t->frame_count) return;
  const agc_string *name = vm->rt->program->functions[t->frames[0].function].name;
  if (parent && parent->group)
    AGC_TRACE(tr, AGC_TRACE_SCHED, "spawn task=%" PRIu64 " parent=group:%" PRIu64 " fn=%.*s", t->id,
              parent->parent ? parent->parent->id : 0, agc_trace_len(name->bytes), name->data);
  else
    AGC_TRACE(tr, AGC_TRACE_SCHED, "spawn task=%" PRIu64 " parent=%" PRIu64 " fn=%.*s", t->id, parent ? parent->id : 0,
              agc_trace_len(name->bytes), name->data);
}

static void trace_turn(const agc_vm *vm, const agc_task *t, agc_turn_result r, bool ran) {
  const agc_trace *tr = &vm->rt->trace;
  if (!AGC_TRACE_ON(tr, AGC_TRACE_SCHED)) return;
  int64_t used = 0;
  if (__builtin_sub_overflow((int64_t)AGC_TURN_STEPS, vm->turn_left, &used) ||
      __builtin_sub_overflow(used, vm->turn_cost_used, &used) || used < 0)
    used = 0;
  const char *why = !ran ? "fail" : r == AGC_TURN_DONE ? "done" : r == AGC_TURN_PARKED ? "park" : "yield";
  AGC_TRACE(tr, AGC_TRACE_SCHED, "turn task=%" PRIu64 " steps=%" PRId64 " cost=%" PRId64 " why=%s", t->id, used,
            vm->turn_cost_used, why);
}

static void trace_gc(agc_vm *vm, const char *when) {
  const agc_trace *tr = &vm->rt->trace;
  agc_gc_info info;
  if (!AGC_TRACE_ON(tr, AGC_TRACE_GC) || !agc_gc_stats(&info) || info.collections == vm->gc_seen) return;
  vm->gc_seen = info.collections;
  AGC_TRACE(tr, AGC_TRACE_GC,
            "collect at=%s count=%" PRIu64 " heap=%" PRIu64 " free=%" PRIu64 " since=%" PRIu64, when,
            info.collections, info.heap, info.free, info.since);
}

static void trace_end(agc_vm *vm) {
  const agc_trace *tr = &vm->rt->trace;
  const agc_outcome *o = &vm->rt->outcome;
  uint64_t task = vm->rt->over ? vm->rt->over_task : vm->task && executing(vm->task) ? vm->task->id : 0;
  if (o->kind == AGC_FAILED)
    AGC_TRACE(tr, AGC_TRACE_SCHED, "fail task=%" PRIu64 " code=%s", task, o->code);
  else if (o->kind == AGC_EXITED)
    AGC_TRACE(tr, AGC_TRACE_SCHED, "exit task=%" PRIu64 " code=%" PRId64, task, o->exit_code);
  trace_gc(vm, "end");
  agc_profile_report(vm);
}

static uint64_t pending_tasks(const agc_vm *vm) {
  uint64_t made = atomic_load(&vm->rt->next_task_id) - 1;
  uint64_t done = atomic_load_explicit(&vm->rt->tasks_done, memory_order_relaxed);
  return made > done + 1 ? made - done - 1 : 0;
}

/* No await can observe a hidden task (an HTTP connection task), so of its
   unobserved crashes only the first per test is kept; the others are
   counted on it, which bounds the list in a long-running server. */
static agc_task **quiet_slot(agc_vm *vm, const agc_task *t) {
  if (!t->hidden) return NULL;
  return t->test ? &t->test->quiet : &vm->rt->quiet;
}

/* Runs under the run-level target: a failure here ends the run. */
static void crash(agc_vm *vm, agc_task *t) {
  agc_outcome *o = vm->outcome;
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "crash task=%" PRIu64 " code=%s", t->id, o->code);
  t->crash = agc_crash_text(vm->rt->program, o);
  t->crash_code = o->code;
  t->crash_message = agc_utf8_decode((const uint8_t *)o->message, o->message_len, "\xEF\xBF\xBD", false);
  t->crash_span = o->span;
  if (o->stack.shown) {
    t->crash_stack = agc_alloc_atomic(sizeof *t->crash_stack);
    *t->crash_stack = o->stack;
  }
  t->crashed = true;
  vm->rt->crash_count++;
  agc_task **quiet = quiet_slot(vm, t);
  if (quiet && *quiet) {
    (*quiet)->quiet_more++;
  } else {
    if (quiet) *quiet = t;
    t->crash_prev = vm->rt->crashes_tail;
    if (vm->rt->crashes_tail)
      vm->rt->crashes_tail->crash_next = t;
    else
      vm->rt->crashes = t;
    vm->rt->crashes_tail = t;
  }
  agc_notice notice;
  agc_print_diagnostic(agc_notice_begin(&vm->rt->err, &notice), vm->rt->program, o, vm->rt->style, true);
  agc_notice_end(vm, &notice, AGC_NOTICE_QUEUED);
  o->kind = AGC_DONE;
  unlink_task(vm, t);
  for (agc_task *child = t->children, *next; child; child = next) {
    next = child->next_sibling;
    agc_task_cancel(vm, child);
  }
  finish_task(vm, t);
}

static bool fatal(const agc_vm *vm, const agc_task *t) {
  const agc_outcome *o = vm->outcome;
  return t == vm->rt->main || o->kind != AGC_FAILED || strcmp(o->code, "RUNTIME-STEP-LIMIT") == 0 ||
         strcmp(o->code, "RUNTIME-INTERNAL") == 0;
}

static bool run_turn(agc_vm *vm, agc_task *t, agc_turn_result *r) {
  if (setjmp(vm->turn)) {
    vm->in_turn = false;
    agc_sync_reset(vm);
    return false;
  }
  vm->in_turn = true;
  resume(vm, t);
  *r = agc_turn_charge(vm) ? AGC_TURN_YIELD : agc_run_turn(vm);
  vm->in_turn = false;
  return true;
}

static agc_task *first_unobserved(const agc_vm *vm) {
  for (agc_task *t = vm->rt->crashes; t; t = t->crash_next)
    if (!t->observed) return t;
  return NULL;
}

bool agc_report_unobserved(agc_vm *vm) {
  const agc_task *first = first_unobserved(vm);
  if (!first) return false;
  agc_notice notice;
  agc_print_unobserved(agc_notice_begin(&vm->rt->err, &notice), vm->rt->crash_count - vm->rt->observed_count, first->crash,
                       vm->rt->style);
  agc_notice_end(vm, &notice, AGC_NOTICE_QUEUED);
  return true;
}

void agc_task_observe(agc_vm *vm, agc_task *t) {
  if (t->observed) return;
  t->observed = true;
  vm->rt->observed_count += 1 + t->quiet_more;
  agc_task **quiet = quiet_slot(vm, t);
  if (quiet && *quiet == t) *quiet = NULL;
  if (t->crash_prev)
    t->crash_prev->crash_next = t->crash_next;
  else if (vm->rt->crashes == t)
    vm->rt->crashes = t->crash_next;
  if (t->crash_next)
    t->crash_next->crash_prev = t->crash_prev;
  else if (vm->rt->crashes_tail == t)
    vm->rt->crashes_tail = t->crash_prev;
  t->crash_next = t->crash_prev = NULL;
}

/* A stop signal ends the run between turns as an exit with 128 + signal;
   agc_launch_exit (vm/launch.c) then raises it again after the exit path. */
static void check_stop(agc_vm *vm) {
  int sig = agc_io_stop_signal();
  if (sig) agc_stop(vm, sig);
}

/* A popped task that may run, or NULL when it was ended instead (see agc_task_next). */
static agc_task *admit(agc_vm *vm, agc_task *t) {
  if (atomic_load_explicit(&t->state, memory_order_acquire) == AGC_TASK_DONE) return NULL;
  if (!atomic_load_explicit(&t->cancelled, memory_order_seq_cst)) return t;
  vm->task = t;
  end_cancelled_locked(vm, t);
  return NULL;
}

/* The next ready task: the runnext slot first, unless it has run RUNNEXT_LIMIT times in a row; then the global queue
   gets its look, which resets the count, and an empty queue gives the slot's task after all. So a pair of tasks that
   wake each other cannot keep the queue waiting, and the slot never loses its task. With one scheduler the slot is
   always empty and this is the pop. */
static agc_task *next_ready(agc_vm *vm) {
  agc_task *slot = vm->runnext;
  if (slot && vm->runnext_runs < RUNNEXT_LIMIT) {
    vm->runnext = NULL;
    vm->runnext_runs++;
    return slot;
  }
  agc_task *t = agc_runq_pop(vm->rt->runq);
  vm->runnext_runs = 0;
  if (t || !slot) return t;
  vm->runnext = NULL;
  vm->runnext_runs = 1;
  return slot;
}

/* The next task to run. A DONE task is dropped (a cancel that raced a waker's push). So is a cancelled one that is not
   running: the canceller could not take it out of the queue because a waker had set READY and not pushed yet, or a
   scheduler had popped it already (cancel_one), so whoever pops it ends it. A cancel that comes after this check
   is seen at the end of the turn. NULL when the queue is empty. */
agc_task *agc_task_next(agc_vm *vm) {
  /* Between turns vm->task still names the last task, which may be DONE. That is safe for cancel_one: it compares a
     task with vm->task only in the states of a turn (RUNNING, PARKING, WOKEN), which a DONE task never has again. */
  /* A scheduler holds rt->sync only inside a builtin or an ending, never between turns. */
  if (vm->sync_depth) agc_fail(vm, "RUNTIME-INTERNAL", "rt->sync held between turns", 0);
  for (;;) {
    agc_task *t = next_ready(vm);
    if (!t) return NULL;
    if ((t = admit(vm, t))) return t;
  }
}

/* What the scheduler does with a task when its turn is over. Everything it reads or does with the task comes before
   the park is published: the trace, the cancel flag and the end of a cancelled task. Once agc_task_commit_park has
   succeeded the task belongs to its waker, with one more read: a cancel can set the flag after the first look and
   before the commit, and the canceller saw PARKING and left the task to this turn. So after the commit the flag is read
   again, and the task is claimed by a CAS (agc_task_claim), which a waker or a canceller may win instead, and then they
   own it. The cancel and this end of the turn are a store-then-load on both sides (the canceller stores the flag and
   reads the state; the scheduler stores the state with the commit and reads the flag), so all four accesses are
   sequentially consistent: with weaker orders both sides could read the old value and nobody would end the task. A
   cancel that loses to a normal end (cancel_one finds the task DONE) changes nothing: the task keeps its own result. A
   flag set during the turn wins, even when the turn returned or failed (a failure that is not fatal). Returns true
   when `main` has returned. */
bool agc_task_end_turn(agc_vm *vm, agc_task *t, agc_turn_result r, bool ran) {
  trace_turn(vm, t, r, ran);
  trace_gc(vm, "turn");
  bool main_done = false;
  if (!ran) {
    if (fatal(vm, t)) longjmp(vm->fail, 1);
    agc_sync_take(vm);
    /* A task cancelled during its turn ends as cancelled even when the turn failed: the failure may come from the
       cancel itself (Task.await of a child that the walk ended, or that started cancelled), and a task the cancel
       has reached does not report a crash. */
    if (atomic_load_explicit(&t->cancelled, memory_order_acquire)) {
      AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "cancel task=%" PRIu64 " failed=%s", t->id, vm->outcome->code);
      vm->outcome->kind = AGC_DONE;
      end_cancelled(vm, t);
    } else {
      crash(vm, t);
    }
    agc_sync_drop(vm);
  } else if (atomic_load_explicit(&t->cancelled, memory_order_acquire)) {
    end_cancelled_locked(vm, t);
  } else if (r == AGC_TURN_DONE) {
    if (t == vm->rt->main) {
      AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "cancel pending=%" PRIu64, pending_tasks(vm));
      main_done = true;
    } else {
      agc_sync_take(vm);
      finish_task(vm, t);
      agc_sync_drop(vm);
    }
  } else if (r == AGC_TURN_YIELD) {
    enqueue(vm, t);
  } else if (!agc_task_commit_park(t)) {
    enqueue(vm, t);
  } else if (atomic_load_explicit(&t->cancelled, memory_order_seq_cst) && agc_task_claim(t)) {
    end_cancelled_locked(vm, t);
  }
  return main_done;
}

/* The wait of a scheduler whose run queue is empty. With no timer it is agc_io_poll(vm, true), and a loop with nothing
   alive means a stall. With a timer the loop runs once until the nearest deadline at most, alive or not, unless every
   armed timer is a service task's: those only end idle waits that no other task depends on, so the run still stalls
   when the loop has nothing alive. */
static bool idle_wait(agc_vm *vm) {
  uint64_t due = agc_timers_next_due(vm);
  if (due == UINT64_MAX) return agc_io_poll(vm, true);
  uint64_t now = agc_clock_ms();
  return agc_io_run_for(vm, due > now ? due - now : 0, !agc_timers_strong(vm));
}

/* One turn of T on this scheduler and its end. True when `main` has returned. */
static bool run_task(agc_vm *vm, agc_task *t) {
  vm->task = t;
  atomic_store_explicit(&t->state, AGC_TASK_RUNNING, memory_order_relaxed);
  agc_turn_begin(vm);
  agc_turn_result r = AGC_TURN_DONE;
  bool ran = run_turn(vm, t, &r);
  agc_turn_finish(vm);
  return agc_task_end_turn(vm, t, r, ran);
}

/* Several schedulers (docs/vm/16-architecture.md §16.9, "Threads"): N scheduler threads share the run queue, and the
   main thread becomes the I/O thread, the only one that calls libuv. It is reached only under the test switch
   AGENTICA_VM_TEST_MULTICORE until the count is lifted (#345). */

/* The run is over: the first caller records the end in rt->outcome (its own failure, or the end it wrote there), every
   caller ends the run queue, so each scheduler stops at its next turn boundary, and wakes the I/O thread. Nothing reads
   rt->outcome before the I/O thread has joined the schedulers, which orders the copy before the read. */
void agc_run_over(agc_vm *vm) {
  agc_runtime *rt = vm->rt;
  bool expected = false;
  if (atomic_compare_exchange_strong_explicit(&rt->over, &expected, true, memory_order_acq_rel,
                                              memory_order_acquire)) {
    if (vm->outcome != &rt->outcome) rt->outcome = *vm->outcome;
    rt->over_task = vm->task && executing(vm->task) ? vm->task->id : 0;
  }
  agc_runq_end(rt->runq);
  agc_io_wake(vm);
}

/* agc_run_over for an end that no task caused (a stop signal, a stall, a failure of the I/O thread): the trace names
   no task. The I/O context keeps its own task for what runs after (a detached ending reads it). */
void agc_run_over_untasked(agc_vm *vm) {
  agc_task *own = vm->task;
  vm->task = NULL;
  agc_run_over(vm);
  vm->task = own;
}

/* The stall of a run with several schedulers, found by the I/O thread (agc_io_serve): the same end as at N = 1, with
   no stack, since no task is running. */
void agc_run_stall(agc_vm *vm) {
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "stall pending=%" PRIu64, pending_tasks(vm) + 1);
  agc_outcome *o = vm->outcome;
  memset(o, 0, sizeof *o);
  o->kind = AGC_FAILED;
  o->code = "RUNTIME-INTERNAL";
  o->message = "every task is waiting and nothing can wake them";
  o->message_len = strlen(o->message);
  agc_run_over_untasked(vm);
}

/* The entry of a file with Globals slots writes them before it hands over to `main` (docs/vm/10-io-multicore.md
   §10.2.3, "The Globals table"), and nothing orders those writes before a read on another thread. So only scheduler 0
   runs tasks until the entry has handed over: then the frame at the bottom of `main` is no longer the entry's. A
   file without slots has nothing to wait for. */
static bool entry_over(const agc_vm *vm) {
  const agc_program *p = vm->rt->program;
  const agc_task *m = vm->rt->main;
  return p->global_count == 0 || !m->frames || m->frame_count == 0 || m->frames[0].function != p->entry;
}

/* Scheduler 0 starts the others (THREAD, which is sched_main) once the entry is over. Each one is counted by the run
   queue before it starts, so the stall check never sees a run as idle while a thread is still on its way in. */
static void start_others(agc_vm *vm, void (*thread)(void *arg)) {
  agc_runtime *rt = vm->rt;
  atomic_store_explicit(&rt->entry_done, true, memory_order_release);
  for (int64_t k = 1; k < rt->schedulers; k++) {
    agc_runq_add_scheduler(rt->runq);
    if (!agc_thread_start(rt->threads, (size_t)k, thread, rt->scheds[k])) {
      agc_runq_drop_scheduler(rt->runq);
      agc_fail(vm, "RUNTIME-INTERNAL", "cannot start a scheduler thread", 0);
    }
    atomic_fetch_add_explicit(&rt->started, 1, memory_order_release);
  }
}

/* The loop of one scheduler thread. It never touches libuv: the service work that the I/O thread leaves (the end of
   a detached job) is taken on a nudge, at each turn boundary and when idle; a scheduler with no task waits on the run
   queue, until its nearest timer when it has one. */
static void sched_turns(agc_vm *vm, void (*thread)(void *arg)) {
  agc_runtime *rt = vm->rt;
  agc_runq *q = rt->runq;
  if (vm->index == 0 && entry_over(vm)) start_others(vm, thread);
  for (;;) {
    if (atomic_load_explicit(&rt->over, memory_order_acquire)) return;
    agc_task *t = agc_task_next(vm);
    if (!t) {
      if (agc_runq_take_nudge(q)) {
        (void)agc_io_service(vm);
        continue;
      }
      check_stop(vm);
      if (agc_timers_run(vm)) continue;
      /* The slot is empty here (agc_task_next takes it whenever the queue is empty), so the spin and the wait never
         leave a task of this scheduler behind. */
      t = agc_runq_spin(q);
      if (!t) {
        uint64_t due = agc_timers_next_due(vm);
        t = due == UINT64_MAX ? agc_runq_wait(q) : agc_runq_wait_until(q, due);
      }
      if (!t || !(t = admit(vm, t))) continue;
    }
    if (run_task(vm, t)) {
      vm->outcome->kind = AGC_DONE;
      agc_run_over(vm);
      return;
    }
    if (vm->index == 0 && t == rt->main && !atomic_load_explicit(&rt->entry_done, memory_order_relaxed) &&
        entry_over(vm))
      start_others(vm, thread);
    if (agc_runq_nudged(q) && agc_runq_take_nudge(q)) (void)agc_io_service(vm);
    (void)agc_timers_run(vm);
    check_stop(vm);
  }
}

/* A scheduler thread: registered with the collector before its first allocation, with the stop signals blocked (the
   I/O thread handles them), and with its own failure target. A failure that reaches it (a fatal task failure, a stop
   signal, System.exit) ends the run. */
static void sched_main(void *arg) {
  agc_vm *vm = arg;
  agc_io_thread_signals();
  if (!agc_gc_thread_enter()) agc_internal_abort("cannot register a scheduler thread with the collector");
  if (setjmp(vm->fail) == 0) {
    sched_turns(vm, sched_main);
  } else {
    agc_sync_reset(vm);
    agc_io_service_reset(vm);
    agc_run_over(vm);
  }
  agc_gc_thread_leave();
}

static agc_outcome run_threads(agc_vm *vm) {
  agc_runtime *rt = vm->rt;
  size_t n = (size_t)rt->schedulers;
  /* A failure of the setup (the loop cannot be made: no descriptor left) ends the run here, before any scheduler
     starts; agc_io_serve sets its own target once they run. */
  if (setjmp(vm->fail) != 0) {
    agc_sync_reset(vm);
    agc_io_hand_off(vm, false);
    trace_end(vm);
    return rt->outcome;
  }
  rt->program = agc_program_for_threads(rt->program);
  agc_share(vm);
  if (!agc_io_share(vm, true)) agc_internal_abort("cannot start the I/O thread's inbox");
  agc_gc_allow_threads();
  rt->scheds = agc_alloc(agc_size_mul(n, sizeof(agc_vm *)));
  for (size_t k = 0; k < n; k++) {
    agc_vm *s = agc_alloc(sizeof(agc_vm));
    agc_vm_init_context(s, rt);
    s->index = (uint32_t)k;
    s->runnext_on = true;
    rt->scheds[k] = s;
  }
  agc_input_watch(vm);
  rt->threads = agc_threads_new(n);
  agc_runq_on_idle(rt->runq, agc_io_wake_idle, vm);
  /* At most half the schedulers spin, so a burst of wakes still finds some parked to wake and the spin never takes
     every core. */
  agc_runq_spin_setup(rt->runq, n / 2 ? (uint32_t)(n / 2) : 1, (uint64_t)SPIN_BUDGET_US * 1000);
  /* The I/O thread's own failures (agc_io_serve) go to its own record too while the schedulers run. */
  vm->outcome = &vm->own;
  agc_task_enter(vm, rt->main, rt->program->entry);
  trace_spawn(vm, rt->main, NULL);
  enqueue(vm, rt->main);
  agc_runq_add_scheduler(rt->runq);
  /* Counted before it starts: scheduler 0 adds the others to `started` at once, and a later store would hide them
     from the joins below. */
  atomic_store_explicit(&rt->started, 1, memory_order_release);
  if (!agc_thread_start(rt->threads, 0, sched_main, rt->scheds[0]))
    agc_internal_abort("cannot start a scheduler thread");
  agc_io_serve(vm);
  /* Scheduler 0 first: it is the one that starts the others, so once it has ended `started` no longer grows. */
  agc_thread_join(rt->threads, 0);
  uint32_t started = atomic_load_explicit(&rt->started, memory_order_acquire);
  for (uint32_t k = 1; k < started; k++) agc_thread_join(rt->threads, k);
  agc_threads_free(rt->threads);
  rt->threads = NULL;
  vm->outcome = &rt->outcome;
  /* One thread again: what the I/O thread hands over now it ends itself, and the detached jobs still listed. */
  agc_io_hand_off(vm, false);
  if (setjmp(vm->fail) == 0) {
    (void)agc_io_service(vm);
    if (rt->outcome.kind == AGC_DONE && agc_report_unobserved(vm)) {
      rt->outcome.kind = AGC_EXITED;
      rt->outcome.exit_code = 1;
    }
  } else {
    agc_sync_reset(vm);
    agc_io_service_reset(vm);
  }
  trace_end(vm);
  return rt->outcome;
}

agc_outcome agc_vm_run(agc_vm *vm) {
  if (vm->rt->schedulers > 1) return run_threads(vm);
  if (setjmp(vm->fail) == 0) {
    agc_profile_start(vm);
    agc_task_enter(vm, vm->rt->main, vm->rt->program->entry);
    trace_spawn(vm, vm->rt->main, NULL);
    enqueue(vm, vm->rt->main);
    for (;;) {
      agc_task *t = agc_task_next(vm);
      if (!t) {
        check_stop(vm);
        if (agc_timers_run(vm)) continue;
        if (!idle_wait(vm)) {
          check_stop(vm);
          AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "stall pending=%" PRIu64, pending_tasks(vm) + 1);
          agc_fail(vm, "RUNTIME-INTERNAL", "every task is waiting and nothing can wake them", 0);
        }
        continue;
      }
      if (run_task(vm, t)) break;
      agc_io_poll(vm, false);
      (void)agc_timers_run(vm);
      check_stop(vm);
    }
    vm->rt->outcome.kind = AGC_DONE;
    if (agc_report_unobserved(vm)) {
      vm->rt->outcome.kind = AGC_EXITED;
      vm->rt->outcome.exit_code = 1;
    }
  } else {
    agc_sync_reset(vm);
    agc_io_service_reset(vm);
  }
  trace_end(vm);
  return vm->rt->outcome;
}

/* Whether a task made under PARENT would escape a cancel: PARENT, or the task that owns the groups above it, is
   cancelled. Such a task is still finishing its last turn on another scheduler (§10.2.3), after the cancel walk
   over its descendants, so a child it spawns now would be missed by that walk (#392). Read under rt->sync, which
   the walk holds too: a child adopted before the walk is cancelled by it, one adopted after sees the flag here. */
static bool cancelled_parent(const agc_task *parent) {
  for (const agc_task *t = parent; t; t = t->group ? t->parent : NULL)
    if (atomic_load_explicit(&t->cancelled, memory_order_seq_cst)) return true;
  return false;
}

/* HANDED, when not NULL, moves to the child before it can end, so a child that starts cancelled closes it. */
static agc_task *spawn_child(agc_vm *vm, agc_task *parent, agc_value fn, const agc_value *args, uint32_t argc,
                             uint32_t span, agc_resource *handed) {
  agc_task *child = agc_new_task(vm);
  child->input_seen = vm->rt->in.eof_seq;
  child->service = parent->service;
  child->test = child->service ? NULL : vm->task->test;
  /* Counted as done from the start, so Task.pending_count (made - done) never sees it; finish_task skips it. */
  if (child->service) atomic_fetch_add_explicit(&vm->rt->tasks_done, 1, memory_order_relaxed);
  child->spawned = true;
  child->spawn_span = span;
  agc_task_call(vm, child, fn, args, argc, span);
  adopt(vm, parent, child);
  trace_spawn(vm, child, parent);
  if (handed) agc_hand_over(handed, child);
  if (!cancelled_parent(parent)) {
    enqueue(vm, child);
    return child;
  }
  /* The child of a cancelled task starts cancelled: it never runs, and Task.await on it reports the cancel. It is
     counted as made (agc_new_task) and left to finish_task to count as done, like any other end, on purpose. */
  atomic_store_explicit(&child->cancelled, true, memory_order_seq_cst);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "cancel task=%" PRIu64 " at=spawn", child->id);
  end_cancelled(vm, child);
  return child;
}

agc_task *agc_task_spawn_in(agc_vm *vm, agc_task *parent, agc_value fn, const agc_value *args, uint32_t argc,
                            uint32_t span) {
  return spawn_child(vm, parent, fn, args, argc, span, NULL);
}

agc_task *agc_task_spawn(agc_vm *vm, agc_value fn, const agc_value *args, uint32_t argc, uint32_t span) {
  return agc_task_spawn_in(vm, vm->task, fn, args, argc, span);
}

/* A node of the task tree that never runs: the parent of an HTTP server's
   connection tasks, so cancelling it reaches every one of them and their
   descendants. It has no id and is not counted as a task. */
agc_task *agc_task_group(agc_vm *vm) {
  agc_task *g = agc_alloc(sizeof(agc_task));
  g->group = true;
  atomic_store_explicit(&g->state, AGC_TASK_PARKED, memory_order_relaxed);
  g->result = agc_void();
  /* A group inside a service tree is a service task too, so the tasks spawned in it are (agc_task_spawn_in). */
  g->service = vm->task->service;
  g->test = vm->task->test;
  adopt(vm, vm->task, g);
  return g;
}

static agc_task *spawn_seeded(agc_vm *vm, agc_task *parent, agc_value fn, const agc_value *args, uint32_t argc,
                              uint32_t span, agc_resource *handed) {
  uint64_t seed = agc_random_next(&vm->task->random);
  agc_task *child = spawn_child(vm, parent, fn, args, argc, span, handed);
  agc_random_seed(&child->random, seed);
  return child;
}

agc_task *agc_task_spawn_seeded(agc_vm *vm, agc_task *parent, agc_value fn, const agc_value *args, uint32_t argc,
                                uint32_t span) {
  return spawn_seeded(vm, parent, fn, args, argc, span, NULL);
}

static agc_resource *owned_by_caller(agc_vm *vm, agc_value handle) {
  agc_resource *r = agc_owned_of(vm, handle);
  return r && r->owner == vm->task ? r : NULL;
}

bool agc_task_owns(agc_vm *vm, agc_value handle) { return owned_by_caller(vm, handle) != NULL; }

/* The resource that a spawn hands over: a channel nobody owns yet, or a handle the caller owns. */
static agc_resource *claim(agc_vm *vm, agc_value handle, uint32_t span) {
  agc_resource *r = agc_is(handle, AGC_T_CHANNEL) ? agc_channel_claim(vm, agc_as_channel(vm, handle))
                                                  : owned_by_caller(vm, handle);
  if (!r)
    agc_fail(vm, "RUNTIME-HANDLE-NOT-OWNED", "the calling task does not own this handle, or it is closed", span + 2);
  return r;
}

agc_task *agc_task_spawn_owning(agc_vm *vm, agc_task *parent, agc_value fn, agc_value handle, uint32_t span) {
  agc_resource *r = claim(vm, handle, span);
  return spawn_seeded(vm, parent, fn, &handle, 1, span, r);
}

/* Runs fn(arg) as the owner of handle under a service root, the task tree of an HttpClient (HttpWire.service). The
   root is a node like agc_task_group that never runs, but it has no parent, so no task's crash, cancel or end reaches
   it, and Test.test finds no leftover under the caller. Its descendants are service tasks: Task.pending_count leaves
   them out, they are in no test, and their timers do not keep a stalled run waiting (idle_wait). They end by
   themselves or with the run. The seed comes from the task's id, not from the caller's stream, so making a client
   does not change the caller's Random values. */
agc_task *agc_task_service(agc_vm *vm, agc_value fn, agc_value handle, agc_value arg, uint32_t span) {
  agc_resource *r = claim(vm, handle, span);
  agc_task *root = agc_alloc(sizeof(agc_task));
  root->group = true;
  root->service = true;
  atomic_store_explicit(&root->state, AGC_TASK_PARKED, memory_order_relaxed);
  root->result = agc_void();
  agc_task *child = spawn_child(vm, root, fn, &arg, 1, span, r);
  agc_random_seed(&child->random, child->id);
  return child;
}

static agc_value builtin_spawn(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_task_value(agc_task_spawn_seeded(vm, vm->task, args[0], &args[1], 1, span));
}

static agc_value builtin_spawn_owning(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_task_value(agc_task_spawn_owning(vm, vm->task, args[0], args[1], span));
}

bool agc_task_join(agc_vm *vm, agc_task *target) {
  vm->task->awaiting = NULL;
  if (target->state == AGC_TASK_DONE && !target->closing) return false;
  agc_task_parking(vm);
  vm->task->awaiting = target;
  agc_task_enqueue(&target->waiters, &target->waiters_tail, vm->task);
  agc_task_park(vm, true);
  return true;
}

/* A timed waiter holds a timer and ends by itself, so it is not an edge of the chain. */
static bool awaits_caller(agc_vm *vm, const agc_task *target) {
  uint64_t hops = 0;
  const agc_task *t = target;
  while (t && t != vm->task) {
    t = t->await_deadline ? NULL : t->awaiting;
    hops++;
  }
  agc_charge(vm, hops);
  return t != NULL;
}

static agc_value outcome(agc_vm *vm, agc_task *target, uint32_t span, bool result) {
  if (target->crashed) {
    agc_task_observe(vm, target);
    if (result) return agc_result_value(false, agc_string_value(target->crash));
    agc_fail_text(vm, "RUNTIME-TASK-CRASHED", target->crash, span);
  }
  if (target->cancelled) {
    if (result) return agc_error_value("task: cancelled");
    agc_fail(vm, "RUNTIME-TASK-CANCELLED", "task was cancelled", span);
  }
  return target->result;
}

static agc_value await_task(agc_vm *vm, agc_value task, uint32_t span, bool result) {
  agc_task *target = agc_as_task(vm, task);
  if (target->state != AGC_TASK_DONE && awaits_caller(vm, target))
    agc_fail(vm, "RUNTIME-TASK-AWAIT-CYCLE", "this await would wait for a task that is waiting for this task", span);
  if (agc_task_join(vm, target)) return agc_void();
  return outcome(vm, target, span, result);
}

static agc_runtime *await_variants(agc_vm *vm) {
  agc_runtime *rt = vm->rt;
  if (!rt->await_found) {
    rt->await_done = agc_builtin_variant(vm, "Await", "Done", 1);
    rt->await_timed_out = agc_builtin_variant(vm, "Await", "TimedOut", 0);
    rt->await_found = true;
  }
  return rt;
}

static agc_value await_done(agc_vm *vm, agc_value value) {
  agc_enum *e = agc_new_enum(await_variants(vm)->await_done, 1);
  e->payload[0] = value;
  return agc_enum_value(e);
}

static agc_value await_timed_out(agc_vm *vm) {
  return agc_enum_value(vm->rt->program->variants[await_variants(vm)->await_timed_out].shared);
}

static void leave_target(agc_task *t) {
  if (!t->awaiting) return;
  agc_task_remove(&t->awaiting->waiters, &t->awaiting->waiters_tail, t);
  t->awaiting = NULL;
}

static agc_value await_timeout(agc_vm *vm, agc_value *args, uint32_t span, bool result) {
  agc_task *target = agc_as_task(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  if (timeout <= 0) agc_fail(vm, "RUNTIME-INVALID-DURATION", "await timeout must be positive milliseconds", span + 2);
  agc_task *t = vm->task;
  leave_target(t);
  if (target->state == AGC_TASK_DONE && !target->closing) {
    t->await_deadline = 0;
    return await_done(vm, outcome(vm, target, span, result));
  }
  uint64_t now = agc_clock_ms();
  if (!t->await_deadline) t->await_deadline = now + (uint64_t)timeout;
  if (t->await_deadline <= now) {
    t->await_deadline = 0;
    return await_timed_out(vm);
  }
  agc_task_parking(vm);
  t->awaiting = target;
  agc_task_enqueue(&target->waiters, &target->waiters_tail, t);
  agc_task_park_until(vm, t->await_deadline, true);
  return agc_void();
}

static agc_value builtin_await(agc_vm *vm, agc_value *args, uint32_t span) {
  return await_task(vm, args[0], span, false);
}

static agc_value builtin_await_result(agc_vm *vm, agc_value *args, uint32_t span) {
  return await_task(vm, args[0], span, true);
}

static agc_value builtin_await_timeout(agc_vm *vm, agc_value *args, uint32_t span) {
  return await_timeout(vm, args, span, false);
}

static agc_value builtin_await_timeout_result(agc_vm *vm, agc_value *args, uint32_t span) {
  return await_timeout(vm, args, span, true);
}

static agc_value builtin_sleep(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t ms = agc_as_int(vm, args[0]);
  if (ms < 0) agc_fail(vm, "RUNTIME-INVALID-DURATION", "sleep duration must be nonnegative", span + 1);
  if (ms == 0 || vm->rt->no_files) {
    vm->yield = true;
    return agc_void();
  }
  agc_task_parking(vm);
  agc_task_park_until(vm, agc_clock_ms() + (uint64_t)ms, false);
  return agc_void();
}

/* Task.cancel: marks the task and its descendants cancelled and returns at once; it never waits. A task that has
   ended, or was cancelled, is left as it is. A task may cancel itself or an ancestor (it is then a descendant of the
   root and is cancelled too): cancel_one sets `yield` for the caller's own task, so it stops after this call. No
   handle reaches main (a program gets handles only from spawns), and the walk refuses it anyway. */
static agc_value builtin_cancel(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  cancel_tree(vm, agc_as_task(vm, args[0]), "call");
  return agc_void();
}

static agc_value builtin_pending_count(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_int((int64_t)pending_tasks(vm));
}

static agc_value builtin_unobserved_crash(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  const agc_task *t = first_unobserved(vm);
  if (!t) return agc_error_value("no unobserved crash");
  return agc_result_value(true, agc_string_value(t->crash));
}

const agc_builtin agc_task_builtins[] = {
  {"Task.spawn", 2, builtin_spawn, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Task.await", 1, builtin_await, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Task.await", 2, builtin_await_timeout, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Task.sleep", 1, builtin_sleep, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Task.pending_count", 0, builtin_pending_count, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Task.await_result", 1, builtin_await_result, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Task.await_result", 2, builtin_await_timeout_result, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Task.unobserved_crash", 0, builtin_unobserved_crash, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Task.spawn_owning", 2, builtin_spawn_owning, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Task.cancel", 1, builtin_cancel, AGC_NATIVE_NONE, AGC_COST_NONE, true},
};

const size_t agc_task_builtin_count = sizeof agc_task_builtins / sizeof agc_task_builtins[0];
