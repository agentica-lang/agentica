/*
 * The scheduler: agc_vm_run (a FIFO run queue, one turn per task, libuv polled
 * between turns), park and wake, spawn, task groups, and cancellation (children
 * first). It also reports unobserved crashes. Core layer. Design:
 * docs/vm/10-io-scheduler.md §10.2.1 and docs/vm/14-core-invariants.md.
 */
#include "core.h"

#include <inttypes.h>
#include <string.h>

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
  if (!t->group) atomic_fetch_add_explicit(&vm->rt->tasks_done, 1, memory_order_relaxed);
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
static void cancel_one(agc_vm *vm, agc_task *t) {
  atomic_store_explicit(&t->cancelled, true, memory_order_seq_cst);
  if (!t->group) AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "cancel task=%" PRIu64, t->id);
  for (;;) {
    switch (atomic_load_explicit(&t->state, memory_order_seq_cst)) {
    case AGC_TASK_RUNNING:
    case AGC_TASK_PARKING:
    case AGC_TASK_WOKEN:
      if (t == vm->task) vm->yield = true;
      return;
    case AGC_TASK_READY:
      if (agc_runq_remove(vm->rt->runq, t))
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
   to move; a running task only gets its flag and ends after its builtin. */
void agc_task_cancel(agc_vm *vm, agc_task *root) {
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
    cancel_one(vm, t);
    count++;
    if (t == root) break;
    t = up;
  }
  if (vm->task && executing(vm->task)) agc_charge(vm, count);
}

/* The task takes the result of its job. agc_io_finish takes rt->sync itself for the parts that change shared lists (the
   hand-on of a handle's lock, a close) and for the halves of a kind marked `locked`; the rest, such as the text of a
   file read, is built outside the lock. */
static void resume(agc_vm *vm, agc_task *t) {
  if (t->parked) {
    agc_value result = agc_io_finish(vm, t);
    if (!t->retry) t->regs[t->park_reg] = result;
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
  uint64_t task = vm->task && executing(vm->task) ? vm->task->id : 0;
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
  agc_outcome *o = &vm->rt->outcome;
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
  agc_notice_end(&notice, AGC_NOTICE_QUEUED);
  o->kind = AGC_DONE;
  unlink_task(vm, t);
  for (agc_task *child = t->children, *next; child; child = next) {
    next = child->next_sibling;
    agc_task_cancel(vm, child);
  }
  finish_task(vm, t);
}

static bool fatal(const agc_vm *vm, const agc_task *t) {
  const agc_outcome *o = &vm->rt->outcome;
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
  agc_notice_end(&notice, AGC_NOTICE_QUEUED);
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
    agc_task *t = agc_runq_pop(vm->rt->runq);
    if (!t) return NULL;
    if (atomic_load_explicit(&t->state, memory_order_acquire) == AGC_TASK_DONE) continue;
    if (!atomic_load_explicit(&t->cancelled, memory_order_seq_cst)) return t;
    vm->task = t;
    end_cancelled_locked(vm, t);
  }
}

/* What the scheduler does with a task when its turn is over. Everything it reads or does with the task comes before
   the park is published: the trace, the cancel flag and the end of a cancelled task. Once agc_task_commit_park has
   succeeded the task belongs to its waker, with one more read: a cancel can set the flag after the first look and
   before the commit, and the canceller saw PARKING and left the task to this turn. So after the commit the flag is read
   again, and the task is claimed by a CAS (agc_task_claim), which a waker or a canceller may win instead, and then they
   own it. The cancel and this end of the turn are a store-then-load on both sides (the canceller stores the flag and
   reads the state; the scheduler stores the state with the commit and reads the flag), so all four accesses are
   sequentially consistent: with weaker orders both sides could read the old value and nobody would end the task. Returns
   true when `main` has returned. */
bool agc_task_end_turn(agc_vm *vm, agc_task *t, agc_turn_result r, bool ran) {
  trace_turn(vm, t, r, ran);
  trace_gc(vm, "turn");
  bool main_done = false;
  if (!ran) {
    if (fatal(vm, t)) longjmp(vm->fail, 1);
    agc_sync_take(vm);
    crash(vm, t);
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

agc_outcome agc_vm_run(agc_vm *vm) {
  if (setjmp(vm->fail) == 0) {
    agc_profile_start(vm);
    agc_task_enter(vm, vm->rt->main, vm->rt->program->entry);
    trace_spawn(vm, vm->rt->main, NULL);
    enqueue(vm, vm->rt->main);
    for (;;) {
      agc_task *t = agc_task_next(vm);
      if (!t) {
        check_stop(vm);
        if (!agc_io_poll(vm, true)) {
          check_stop(vm);
          AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "stall pending=%" PRIu64, pending_tasks(vm) + 1);
          agc_fail(vm, "RUNTIME-INTERNAL", "every task is waiting and nothing can wake them", 0);
        }
        continue;
      }
      vm->task = t;
      atomic_store_explicit(&t->state, AGC_TASK_RUNNING, memory_order_relaxed);
      agc_turn_begin(vm);
      agc_turn_result r = AGC_TURN_DONE;
      bool ran = run_turn(vm, t, &r);
      agc_turn_finish(vm);
      if (agc_task_end_turn(vm, t, r, ran)) break;
      agc_io_poll(vm, false);
      check_stop(vm);
    }
    vm->rt->outcome.kind = AGC_DONE;
    if (agc_report_unobserved(vm)) {
      vm->rt->outcome.kind = AGC_EXITED;
      vm->rt->outcome.exit_code = 1;
    }
  } else {
    agc_sync_reset(vm);
  }
  trace_end(vm);
  return vm->rt->outcome;
}

agc_task *agc_task_spawn_in(agc_vm *vm, agc_task *parent, agc_value fn, const agc_value *args, uint32_t argc,
                            uint32_t span) {
  agc_task *child = agc_new_task(vm);
  child->input_seen = vm->rt->in.eof_seq;
  child->test = vm->task->test;
  child->spawned = true;
  child->spawn_span = span;
  agc_task_call(vm, child, fn, args, argc, span);
  adopt(vm, parent, child);
  trace_spawn(vm, child, parent);
  enqueue(vm, child);
  return child;
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
  g->test = vm->task->test;
  adopt(vm, vm->task, g);
  return g;
}

agc_task *agc_task_spawn_seeded(agc_vm *vm, agc_task *parent, agc_value fn, const agc_value *args, uint32_t argc,
                                uint32_t span) {
  uint64_t seed = agc_random_next(&vm->task->random);
  agc_task *child = agc_task_spawn_in(vm, parent, fn, args, argc, span);
  agc_random_seed(&child->random, seed);
  return child;
}

static agc_resource *owned_by_caller(agc_vm *vm, agc_value handle) {
  agc_resource *r = agc_owned_of(vm, handle);
  return r && r->owner == vm->task ? r : NULL;
}

bool agc_task_owns(agc_vm *vm, agc_value handle) { return owned_by_caller(vm, handle) != NULL; }

agc_task *agc_task_spawn_owning(agc_vm *vm, agc_task *parent, agc_value fn, agc_value handle, uint32_t span) {
  agc_resource *r = agc_is(handle, AGC_T_CHANNEL) ? agc_channel_claim(vm, agc_as_channel(vm, handle))
                                                  : owned_by_caller(vm, handle);
  if (!r)
    agc_fail(vm, "RUNTIME-HANDLE-NOT-OWNED", "the calling task does not own this handle, or it is closed", span + 2);
  agc_task *child = agc_task_spawn_seeded(vm, parent, fn, &handle, 1, span);
  agc_hand_over(r, child);
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
  agc_io_start_marked(vm, &agc_wait_io, NULL, agc_void(), (int64_t)(t->await_deadline - now));
  agc_task_park(vm, true);
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

static agc_value slept(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_void();
}

static const agc_io_kind sleep_io = {NULL, slept, slept, NULL, false, "sleep", NULL, false};

static agc_value builtin_sleep(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t ms = agc_as_int(vm, args[0]);
  if (ms < 0) agc_fail(vm, "RUNTIME-INVALID-DURATION", "sleep duration must be nonnegative", span + 1);
  if (ms == 0 || vm->rt->no_files) {
    vm->yield = true;
    return agc_void();
  }
  agc_io_start(vm, &sleep_io, NULL, agc_void(), ms);
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
};

const size_t agc_task_builtin_count = sizeof agc_task_builtins / sizeof agc_task_builtins[0];
