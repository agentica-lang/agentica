/*
 * The event loop and the resource registry: the libuv loop that the scheduler
 * runs, jobs on the thread pool with their timeouts, GC resources that own
 * malloc'd memory, and the close and stop paths. Core layer. Design:
 * docs/vm/10-io-scheduler.md §10.2.2 and docs/vm/14-core-invariants.md.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "core.h"

#include <inttypes.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
#include <errno.h>
#include <fcntl.h>
#include <uv.h>
#include <signal.h>
#ifdef __APPLE__
#include <poll.h>
#include <sys/stat.h>
#endif
#if defined(_WIN32)
#include <windows.h>
#include <io.h>
#else
#include <unistd.h>
#endif
#endif

struct agc_registry {
  size_t count, cap;
  uint64_t next_id;
  agc_resource **items;
};

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
typedef struct agc_io_job job;

/* The libuv steps a scheduler asks of the I/O thread (§16.4): start the pieces of a job, move its timer, close its
   timer, and give back a reference. */
typedef enum { REQ_START, REQ_EXTEND, REQ_CLOSE_TIMER, REQ_RELEASE } request_kind;

typedef struct {
  atomic_int signal, now;
  atomic_bool held;
#if defined(_WIN32)
  HANDLE driver;
#else
  pid_t driver;
  uv_async_t *wake;
#endif
} stop_state;

struct agc_loop {
  uv_loop_t uv;
  uv_timer_t deadline;
  uv_async_t wake;
#if defined(_WIN32)
  uv_signal_t stop_signals[3];
  uv_timer_t stop_grace, parent_check;
  HANDLE driver;
  size_t stop_signal_count;
  bool stop_grace_init, parent_check_init;
#else
  uv_timer_t stop_grace;
  bool stop_grace_init;
#if defined(__APPLE__)
  uv_timer_t parent_check;
  bool parent_check_init;
#endif
#endif
  job *ready, *ready_tail;
  bool expired;
  /* The vm that owns the loop: the I/O role reads its registry and wakes its tasks. NULL inbox: one thread plays both
     roles (N = 1) and every request runs where it is posted. The inbox is made by agc_io_share, before a second thread
     posts, and `owner` is then the thread that runs the loop. */
  agc_vm *vm;
  agc_inbox *inbox;
  uv_thread_t owner;
};

/* A job is malloc memory with up to three libuv pieces (pool work or a wait on the loop, the one timer) and its
   holders, counted in `refs` (docs/vm/16-architecture.md §16.5): the owner (the task until agc_io_finish, or the
   detached ending), the wait piece (while `busy`), the ready list, and each request in flight. The job is freed by
   `sweep` once the count is zero and the timer has closed.
   `outcome` and `refs` are the cross-thread part: the outcome is set once by CAS and the task reads it at its next
   turn; `busy` and `detached` are atomic because both sides read them. The other fields belong to the I/O role. */
struct agc_io_job {
  uv_work_t work;
  uv_timer_t timer;
  const agc_io_kind *kind;
  void *data;
  agc_more_fn more;
  agc_loop *loop;
  job *ready_next;
  size_t slot;
  uint64_t started_ns, ended_ns;
  _Atomic int refs, outcome;
  _Atomic bool busy, detached;
  bool timer_open, timer_live, timer_fired, on_loop, dropping, queued, ended, flush, start_failed;
};

struct agc_poller {
  uv_poll_t handle;
#ifdef __APPLE__
  uv_timer_t timer;
  bool timed, writing, named;
#endif
  int fd;
  void (*ready)(void *data, int status);
  void *data;
};

static stop_state *stop_status(void) {
  static stop_state state;
  return &state;
}
#endif

static agc_registry *registry_of(agc_vm *vm) {
  if (!vm->registry) vm->registry = agc_alloc(sizeof(agc_registry));
  return vm->registry;
}

uint64_t agc_resource_id(agc_vm *vm) { return ++registry_of(vm)->next_id; }

agc_resource *agc_register(agc_vm *vm, void *native, agc_release_fn release) {
  agc_registry *reg = registry_of(vm);
  if (reg->count == reg->cap) {
    size_t cap = reg->cap ? agc_size_mul(reg->cap, 2) : 16;
    agc_resource **items = agc_alloc(agc_size_mul(cap, sizeof(agc_resource *)));
    if (reg->count) memcpy(items, reg->items, reg->count * sizeof(agc_resource *));
    reg->items = items;
    reg->cap = cap;
  }
  agc_resource *r = agc_alloc(sizeof(agc_resource));
  r->kind = AGC_RESOURCE_NATIVE;
  r->native = native;
  r->release = release;
  r->context = agc_void();
  r->task = NULL;
  r->holder = NULL;
  r->next_owner = NULL;
  r->waiters = r->waiters_tail = NULL;
  r->id = agc_resource_id(vm);
  r->slot = reg->count;
  reg->items[reg->count++] = r;
  return r;
}

static void owned_add(agc_task *t, agc_resource *r) {
  r->owner = t;
  r->owned_prev = NULL;
  r->owned_next = t->owned;
  if (t->owned) t->owned->owned_prev = r;
  t->owned = r;
}

static void owned_remove(agc_resource *r) {
  agc_task *t = r->owner;
  if (!t) return;
  if (r->owned_prev)
    r->owned_prev->owned_next = r->owned_next;
  else
    t->owned = r->owned_next;
  if (r->owned_next) r->owned_next->owned_prev = r->owned_prev;
  r->owner = NULL;
  r->owned_prev = r->owned_next = NULL;
}

void agc_own(agc_vm *vm, agc_resource *r, agc_close_fn close) {
  owned_remove(r);
  r->close = close;
  if (vm->in_turn) owned_add(vm->task, r);
}

void agc_disown(agc_resource *r) { owned_remove(r); }

agc_resource *agc_owned_of(agc_vm *vm, agc_value v) {
  if (agc_is(v, AGC_T_HANDLE)) return agc_as_handle(vm, v);
  if (agc_is(v, AGC_T_SOCKET)) return agc_as_socket(vm, v)->state;
  if (agc_is(v, AGC_T_LISTENER)) return agc_as_listener(vm, v)->state;
  if (agc_is(v, AGC_T_PROCESS)) return agc_as_process(vm, v)->state;
  if (agc_is(v, AGC_T_HTTP_SERVER)) return agc_as_http_server(vm, v)->state;
  return NULL;
}

void agc_hand_over(agc_resource *r, agc_task *to) {
  owned_remove(r);
  owned_add(to, r);
}

void agc_close_owned(agc_vm *vm, agc_task *t) {
  while (t->owned) {
    agc_resource *r = t->owned;
    owned_remove(r);
    r->close(vm, r, t);
  }
}

static void hand_on(agc_vm *vm, agc_resource *handle) {
  agc_task *next = handle->waiters;
  if (!next) return;
  agc_task_remove(&handle->waiters, &handle->waiters_tail, next);
  handle->next_owner = next;
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "lock_handoff handle=%" PRIu64 " task=%" PRIu64, handle->id, next->id);
  agc_task_wake(vm, next, "lock");
}

void agc_handle_leave(agc_vm *vm, agc_task *t) {
  agc_resource *handle = t->lock_wait;
  t->lock_wait = NULL;
  t->lock_deadline = 0;
  agc_task_remove(&handle->waiters, &handle->waiters_tail, t);
  if (handle->next_owner != t) return;
  handle->next_owner = NULL;
  hand_on(vm, handle);
}

void agc_unregister(agc_vm *vm, agc_resource *r) {
  owned_remove(r);
  agc_registry *reg = vm->registry;
  if (!reg || r->slot >= reg->count || reg->items[r->slot] != r) return;
  agc_resource *last = reg->items[--reg->count];
  reg->items[r->slot] = last;
  last->slot = r->slot;
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
  if (last->kind == AGC_RESOURCE_JOB && last->native) ((job *)last->native)->slot = last->slot;
#endif
  reg->items[reg->count] = NULL;
  r->slot = SIZE_MAX;
}

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
static job *timer_job(uv_handle_t *handle) { return (job *)(void *)((char *)handle - offsetof(job, timer)); }

static void run_work(uv_work_t *req) {
  job *j = (job *)(void *)req;
  j->kind->work(j->data);
}

/* The ready list is the I/O role's hand-over to the scheduler role (§16.9): a callback or a service marks the job, and
   drain wakes the task (or ends the detached job) after the loop step, so a woken task queues behind the one whose
   turn just ended. The list holds a reference. */
static void mark_ready(job *j) {
  if (j->queued) return;
  j->queued = true;
  agc_job_ref(&j->refs);
  j->ready_next = NULL;
  agc_loop *loop = j->loop;
  if (loop->ready_tail)
    loop->ready_tail->ready_next = j;
  else
    loop->ready = j;
  loop->ready_tail = j;
}

static void note_end(job *j) {
  if (j->started_ns && !j->ended_ns) j->ended_ns = agc_trace_now();
}

/* The I/O role drops a reference. A job at zero is freed by the next sweep, never here: a libuv callback must not
   change the registry that a caller is walking. */
static void drop_ref(job *j) { (void)agc_job_unref(&j->refs); }

/* Whoever clears `busy` ends the wait piece (pool work or a wait on the loop) and owns its reference, so a late
   completion after a give-up drops nothing twice. */
static bool leave_wait(job *j) { return atomic_exchange_explicit(&j->busy, false, memory_order_acq_rel); }

static void abandon_wait(job *j) {
  if (leave_wait(j)) drop_ref(j);
}

/* The wait ended with a result: the first outcome to be set stands (§16.5, rule 3), and the task finds it at its
   next turn. A late end changes only the piece. */
static void end_wait(job *j, agc_job_outcome outcome) {
  if (!leave_wait(j)) return;
  note_end(j);
  (void)agc_job_settle(&j->outcome, outcome);
  mark_ready(j);
  drop_ref(j);
}

/* A job's `more` step (agc_io_start_then) may keep it waiting on the loop after its pool work (a descriptor that can
   wait forever); agc_io_ready ends it. A job that has an outcome already, or no task, does not start another wait. */
static void work_finished(uv_work_t *req, int status) {
  (void)status;
  job *j = (job *)(void *)req;
  if (agc_job_outcome_of(&j->outcome) == AGC_JOB_PENDING && !atomic_load(&j->detached) && j->more &&
      j->more(j->data, j)) {
    j->on_loop = true;
    return;
  }
  end_wait(j, AGC_JOB_DONE);
}

/* The pool threads have the stop signals blocked, so a stop signal is handled on the loop's thread only (unwatch_stop). */
static int queue_work(agc_loop *loop, job *j) {
#if !defined(_WIN32)
  sigset_t saved;
  agc_io_block_stop(&saved);
#endif
  int rc = uv_queue_work(&loop->uv, &j->work, run_work, work_finished);
#if !defined(_WIN32)
  pthread_sigmask(SIG_SETMASK, &saved, NULL);
#endif
  return rc;
}

/* A job that is only a timer is done when the timer fires; a job with work or a wait has timed out. */
static void timer_fired(uv_timer_t *timer) {
  job *j = timer_job((uv_handle_t *)timer);
  j->timer_fired = true;
  note_end(j);
  (void)agc_job_settle(&j->outcome,
                       j->kind->work || j->kind->external ? AGC_JOB_EXPIRED : AGC_JOB_DONE);
  mark_ready(j);
}

static void timer_closed(uv_handle_t *handle) { timer_job(handle)->timer_open = false; }

static void close_timer(job *j) {
  if (!j->timer_live) return;
  j->timer_live = false;
  uv_timer_stop(&j->timer);
  uv_close((uv_handle_t *)&j->timer, timer_closed);
}

/* The libuv steps of agc_io_start: the timer, then the pool work. The counts were taken when the job was made. */
static void start_pieces(job *j, int64_t timeout_ms) {
  agc_loop *loop = j->loop;
  if (timeout_ms >= 0) {
    uv_update_time(&loop->uv);
    uv_timer_init(&loop->uv, &j->timer);
    uv_timer_start(&j->timer, timer_fired, (uint64_t)timeout_ms, 0);
    j->timer_open = j->timer_live = true;
  }
  if (j->kind->work && queue_work(loop, j) != 0) {
    j->start_failed = true;
    end_wait(j, AGC_JOB_EXPIRED);
  }
}

/* The timer counts from the loop's cached time, and nothing else refreshes it now that the schedulers' clock
   (agc_clock_ms) does not. */
static void extend_timer(job *j, int64_t timeout_ms) {
  if (!j->timer_live || j->timer_fired || agc_job_outcome_of(&j->outcome) != AGC_JOB_PENDING) return;
  uv_update_time(&j->loop->uv);
  uv_timer_start(&j->timer, timer_fired, (uint64_t)timeout_ms, 0);
}

static void handle_request(const agc_request *req) {
  job *j = req->subject;
  switch ((request_kind)req->kind) {
  case REQ_START:
    start_pieces(j, req->arg);
    break;
  case REQ_EXTEND:
    extend_timer(j, req->arg);
    break;
  case REQ_CLOSE_TIMER:
    close_timer(j);
    break;
  case REQ_RELEASE:
    drop_ref(j);
    break;
  }
}

static size_t registry_count(const agc_vm *vm) { return vm->registry ? vm->registry->count : 0; }

static job *job_at(const agc_vm *vm, size_t k) {
  const agc_resource *r = vm->registry->items[k];
  return r->kind == AGC_RESOURCE_JOB ? r->native : NULL;
}

/* Frees the jobs nobody holds. The data goes to `drop` as soon as no holder is left, which is after the pool work or
   the wait is over, never while a piece could still use it. The job itself waits for its timer to finish closing. */
static void sweep(agc_vm *vm) {
  for (size_t k = registry_count(vm); k-- > 0;) {
    job *j = job_at(vm, k);
    if (!j || atomic_load_explicit(&j->refs, memory_order_acquire) != 0) continue;
    if (j->data) {
      j->kind->drop(j->data);
      j->data = NULL;
    }
    if (j->timer_open) continue;
    agc_resource *r = vm->registry->items[k];
    free(j);
    r->native = NULL;
    agc_unregister(vm, r);
  }
}

/* The inbox handler, on the loop's thread: the requests of every scheduler in posting order. A request that is not a
   RELEASE carries a reference that the poster took, and the handler gives it back last. */
static void run_inbox(void *owner, agc_request *list) {
  agc_loop *loop = owner;
  while (list) {
    agc_request *next = list->next;
    job *j = list->subject;
    handle_request(list);
    if (list->kind != REQ_RELEASE) drop_ref(j);
    free(list);
    list = next;
  }
  sweep(loop->vm);
}

/* True where the loop's thread is the caller: always while the inbox does not exist (one thread plays both roles). */
static bool on_io_thread(const agc_loop *loop) {
  if (!loop->inbox) return true;
  uv_thread_t self = uv_thread_self();
  return uv_thread_equal(&self, &loop->owner) != 0;
}

/* A libuv step on a job, asked of the I/O role (§16.4). On the loop's thread it runs at once, with no entry and no
   extra reference: the caller holds one. From another thread it is a malloc'd entry in the inbox, with a reference
   taken first and given back by the handler (a RELEASE carries the caller's own reference instead). */
static void post(job *j, request_kind kind, int64_t arg) {
  agc_loop *loop = j->loop;
  if (on_io_thread(loop)) {
    agc_request req = {NULL, (int)kind, j, arg};
    handle_request(&req);
    return;
  }
  agc_request *req = malloc(sizeof *req);
  if (!req) agc_out_of_memory();
  *req = (agc_request){NULL, (int)kind, j, arg};
  if (kind != REQ_RELEASE) agc_job_ref(&j->refs);
  agc_inbox_post(loop->inbox, req);
}

/* Gives back a reference from any thread. The last one is freed on the I/O thread, because `drop` may call libuv. */
static void release(job *j) { post(j, REQ_RELEASE, 0); }

static agc_loop *new_loop(agc_vm *vm) {
  if (vm->loop) return vm->loop;
  agc_loop *loop = malloc(sizeof(agc_loop));
  if (!loop) agc_out_of_memory();
  loop->ready = loop->ready_tail = NULL;
  loop->vm = vm;
  loop->inbox = NULL;
  loop->owner = uv_thread_self();
#if defined(_WIN32)
  loop->driver = NULL;
  loop->stop_signal_count = 0;
  loop->stop_grace_init = loop->parent_check_init = false;
#else
  loop->stop_grace_init = false;
#if defined(__APPLE__)
  loop->parent_check_init = false;
#endif
#endif
  if (uv_loop_init(&loop->uv) != 0) {
    free(loop);
    return NULL;
  }
  vm->loop = loop;
  return loop;
}

static agc_loop *loop_of(agc_vm *vm) {
  agc_loop *loop = new_loop(vm);
  if (!loop) agc_fail(vm, "RUNTIME-INTERNAL", "cannot start the event loop", 0);
  return loop;
}

static agc_value wait_woken(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_void();
}

const agc_io_kind agc_wait_io = {NULL, wait_woken, wait_woken, NULL, false, "lock", NULL};

static void trace_finish(agc_vm *vm, const agc_resource *r, const job *j, bool done, agc_value result) {
  const agc_trace *tr = &vm->rt->trace;
  if (!AGC_TRACE_ON(tr, AGC_TRACE_IO) || !j->started_ns || j->kind == &agc_wait_io) return;
  uint64_t end = j->ended_ns ? j->ended_ns : agc_trace_now();
  uint64_t us = end > j->started_ns ? (end - j->started_ns) / 1000u : 0;
  const char *outcome = !agc_is(result, AGC_T_RESULT) ? "value" : agc_as_result(vm, result)->ok ? "ok" : "error";
  AGC_TRACE(tr, AGC_TRACE_IO, "%s job=%" PRIu64 " kind=%s us=%" PRIu64 " result=%s", done ? "done" : "timeout", r->id,
            j->kind->name, us, outcome);
}

static agc_value take_context(agc_vm *vm, agc_resource *r) {
  agc_value context = r->context;
  r->context = agc_void();
  if (agc_is(context, AGC_T_HANDLE)) {
    agc_resource *handle = agc_as_handle(vm, context);
    if (handle->holder == r) {
      handle->holder = NULL;
      hand_on(vm, handle);
    }
  }
  return context;
}

static void close_pending(agc_vm *vm, agc_value context) {
  if (!agc_is(context, AGC_T_HANDLE)) return;
  agc_resource *handle = agc_as_handle(vm, context);
  if (handle->closing && handle->native && !handle->holder) handle->close(vm, handle, NULL);
}

static void discard(agc_vm *vm, agc_value result) {
  if (!agc_is(result, AGC_T_RESULT) || !agc_as_result(vm, result)->ok) return;
  agc_resource *r = agc_owned_of(vm, agc_as_result(vm, result)->value);
  if (!r || !r->native || r->holder || r->keep_detached) return;
  r->release(r->native);
  r->native = NULL;
  agc_unregister(vm, r);
}

/* Only a loop wait can be cancelled: a pool job's work runs to its end
   (docs/vm/14-core-invariants.md, 14.3). */
static bool cancellable(const job *j) { return j->kind->cancel && (!j->kind->work || j->on_loop); }

/* A detached job (its task was cancelled) ends here, between turns: its
   result is dropped, its `expired` half never runs, so it never closes a
   task's handle, and the turn cost of `done` is not charged to the current
   task. The owner's reference goes at the end, as the task's does in agc_io_finish. */
static void end_detached(agc_vm *vm, agc_resource *r) {
  job *j = r->native;
  if (j->start_failed) j->dropping = true;
  if (!j->dropping && atomic_load(&j->busy)) {
    if (!j->timer_fired || !cancellable(j) || !j->kind->cancel(vm, j->data, r->context, true)) return;
    j->dropping = true;
  }
  post(j, REQ_CLOSE_TIMER, 0);
  j->ended = true;
  agc_value context = take_context(vm, r);
  void *data = j->data;
  j->data = NULL;
  if (j->dropping) {
    abandon_wait(j);
    if (data) j->kind->drop(data);
  } else {
    int64_t cost = vm->task->turn_cost;
    agc_value result = j->kind->done(vm, data, context);
    vm->task->turn_cost = cost;
    trace_finish(vm, r, j, true, result);
    discard(vm, result);
  }
  close_pending(vm, context);
  release(j);
  sweep(vm);
}

static void drain(agc_vm *vm) {
  agc_loop *loop = vm->loop;
  agc_registry *reg = vm->registry;
  size_t batch = 0;
  for (const job *k = loop->ready; k; k = k->ready_next) batch++;
  while (batch-- && loop->ready) {
    job *j = loop->ready;
    loop->ready = j->ready_next;
    if (!loop->ready) loop->ready_tail = NULL;
    j->ready_next = NULL;
    j->queued = false;
    if (!j->ended && reg && j->slot < reg->count && reg->items[j->slot]->native == j) {
      agc_resource *r = reg->items[j->slot];
      agc_task *t = r->task;
      r->task = NULL;
      if (t)
        agc_task_wake(vm, t, "job");
      else if (atomic_load(&j->detached))
        end_detached(vm, r);
    }
    drop_ref(j);
  }
}

#if !defined(_WIN32)
#define STOP_SIGNALS 3
#define STOP_GRACE_SECONDS 3

static const int stop_signals[STOP_SIGNALS] = {SIGINT, SIGTERM, SIGHUP};

void agc_io_block_stop(sigset_t *saved) {
  sigset_t block;
  sigemptyset(&block);
  for (size_t k = 0; k < STOP_SIGNALS; k++) sigaddset(&block, stop_signals[k]);
  pthread_sigmask(SIG_BLOCK, &block, saved);
}

/* A signal handler gets no context, so the stop state is the one
   process-wide variable. `held` is true until the children are stopped:
   till then a second signal is only recorded in `now`. */
_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_BOOL_LOCK_FREE == 2, "the stop state is read in a signal handler");

static void stop_at_once(int sig) {
  signal(sig, SIG_DFL);
  kill(getpid(), sig);
}

static void stop_overdue(uv_timer_t *timer) {
  (void)timer;
  int now = atomic_load(&stop_status()->now);
  if (now) stop_at_once(now);
}

static void stop_requested(int sig) {
  int saved = errno;
  int none = 0;
  bool first = atomic_compare_exchange_strong(&stop_status()->signal, &none, sig);
  bool orphan = stop_status()->driver && getppid() != stop_status()->driver;
  if (first && !orphan) {
    if (stop_status()->wake)
      uv_async_send(stop_status()->wake);
    else
      _exit(128 + sig);
  } else if (atomic_load(&stop_status()->held)) {
    none = 0;
    if (atomic_compare_exchange_strong(&stop_status()->now, &none, sig)) {
      if (stop_status()->wake)
        uv_async_send(stop_status()->wake);
      else
        _exit(128 + sig);
    }
  } else {
    none = 0;
    if (atomic_compare_exchange_strong(&stop_status()->now, &none, sig) && stop_status()->wake)
      uv_async_send(stop_status()->wake);
    else if (!stop_status()->wake)
      _exit(128 + sig);
  }
  errno = saved;
}

static void stop_woken(uv_async_t *wake) {
  agc_loop *loop = wake->data;
  int sig = atomic_load(&stop_status()->now);
  if (!sig) return;
  if (!atomic_load(&stop_status()->held) || !loop->stop_grace_init) {
    stop_at_once(sig);
    _exit(128 + sig);
  }
  if (uv_timer_start(&loop->stop_grace, stop_overdue, (uint64_t)STOP_GRACE_SECONDS * 1000, 0) != 0) {
    stop_at_once(sig);
    _exit(128 + sig);
  }
}

#if defined(__APPLE__)
static void stop_parent_check(uv_timer_t *timer) {
  (void)timer;
  if (stop_status()->driver <= 0 || getppid() == stop_status()->driver) return;
  int none = 0;
  if (atomic_compare_exchange_strong(&stop_status()->signal, &none, SIGTERM) && stop_status()->wake) uv_async_send(stop_status()->wake);
}
#endif

void agc_io_watch_stop(agc_vm *vm, int64_t driver) {
  agc_loop *loop = new_loop(vm);
  if (loop && uv_async_init(&loop->uv, &loop->wake, stop_woken) == 0) {
    uv_unref((uv_handle_t *)&loop->wake);
    loop->wake.data = loop;
    stop_status()->wake = &loop->wake;
  }
  stop_status()->driver = (pid_t)driver;
  atomic_store(&stop_status()->held, true);
  if (loop && uv_timer_init(&loop->uv, &loop->stop_grace) == 0) {
    loop->stop_grace.data = loop;
    loop->stop_grace_init = true;
  }
#if defined(__APPLE__)
  if (loop && driver > 0 && uv_timer_init(&loop->uv, &loop->parent_check) == 0) {
    loop->parent_check_init = true;
    uv_timer_start(&loop->parent_check, stop_parent_check, 250, 250);
  }
#endif
  struct sigaction act;
  memset(&act, 0, sizeof act);
  act.sa_handler = stop_requested;
  sigemptyset(&act.sa_mask);
  for (size_t k = 0; k < STOP_SIGNALS; k++) sigaddset(&act.sa_mask, stop_signals[k]);
  for (size_t k = 0; k < STOP_SIGNALS; k++) {
    struct sigaction now;
    if (sigaction(stop_signals[k], NULL, &now) == 0 && now.sa_handler != SIG_IGN)
      sigaction(stop_signals[k], &act, NULL);
  }
}

int agc_io_stop_signal(void) { return atomic_load(&stop_status()->signal); }

void agc_io_children_stopped(void) {
  atomic_store(&stop_status()->held, false);
  int now = atomic_load(&stop_status()->now);
  if (!now) return;
  sigset_t set;
  sigemptyset(&set);
  sigaddset(&set, now);
  pthread_sigmask(SIG_UNBLOCK, &set, NULL);
  stop_at_once(now);
  _exit(128 + now);
}
#else
static const int stop_signal_numbers[] = {SIGINT, SIGBREAK, SIGHUP};

static void stop_force_exit(uv_timer_t *timer) {
  (void)timer;
  int sig = atomic_load(&stop_status()->now);
  if (sig) ExitProcess((UINT)(128 + sig));
}

static void stop_parent_check(uv_timer_t *timer) {
  agc_loop *loop = timer->data;
  if (!loop->driver) return;
  DWORD result = WaitForSingleObject(loop->driver, 0);
  if (result != WAIT_OBJECT_0) return;
  int none = 0;
  atomic_compare_exchange_strong(&stop_status()->signal, &none, SIGTERM);
  uv_timer_stop(timer);
}

static void stop_received(uv_signal_t *handle, int sig) {
  agc_loop *loop = handle->data;
  int none = 0;
  if (atomic_compare_exchange_strong(&stop_status()->signal, &none, sig)) return;
  if (!atomic_load(&stop_status()->held)) ExitProcess((UINT)(128 + sig));
  none = 0;
  if (atomic_compare_exchange_strong(&stop_status()->now, &none, sig) && loop->stop_grace_init)
    uv_timer_start(&loop->stop_grace, stop_force_exit, 3000, 0);
  else if (!loop->stop_grace_init)
    ExitProcess((UINT)(128 + sig));
}

void agc_io_watch_stop(agc_vm *vm, int64_t driver) {
  agc_loop *loop = new_loop(vm);
  if (!loop) return;
  atomic_store(&stop_status()->signal, 0);
  atomic_store(&stop_status()->now, 0);
  atomic_store(&stop_status()->held, true);
  loop->stop_signal_count = 0;
  for (size_t k = 0; k < sizeof stop_signal_numbers / sizeof stop_signal_numbers[0]; k++) {
    uv_signal_t *handle = &loop->stop_signals[k];
    if (uv_signal_init(&loop->uv, handle) != 0) break;
    handle->data = loop;
    if (uv_signal_start(handle, stop_received, stop_signal_numbers[k]) != 0) {
      uv_close((uv_handle_t *)handle, NULL);
      break;
    }
    loop->stop_signal_count++;
  }
  if (uv_timer_init(&loop->uv, &loop->stop_grace) == 0) {
    loop->stop_grace.data = loop;
    loop->stop_grace_init = true;
  }
  if (driver > 0) {
    loop->driver = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)driver);
    if (!loop->driver) atomic_store(&stop_status()->signal, SIGTERM);
    if (loop->driver && uv_timer_init(&loop->uv, &loop->parent_check) == 0) {
      loop->parent_check.data = loop;
      loop->parent_check_init = true;
      uv_timer_start(&loop->parent_check, stop_parent_check, 250, 250);
    }
  }
}

int agc_io_stop_signal(void) { return atomic_load(&stop_status()->signal); }

void agc_io_children_stopped(void) {
  atomic_store(&stop_status()->held, false);
  int sig = atomic_load(&stop_status()->now);
  if (sig) ExitProcess((UINT)(128 + sig));
}
#endif

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
static void poll_ready(uv_poll_t *handle, int status, int events) {
  (void)events;
  agc_poller *p = (agc_poller *)(void *)handle;
  p->ready(p->data, status);
}

static void poller_closed(uv_handle_t *handle) {
  agc_poller *p = handle->data;
#ifdef _WIN32
  _close(p->fd);
#else
  close(p->fd);
#endif
  free(p);
}

#ifdef __APPLE__
static void poll_tick(uv_timer_t *timer) {
  agc_poller *p = timer->data;
  struct pollfd fd = {.fd = p->fd, .events = p->writing ? POLLOUT : POLLIN};
  int rc = poll(&fd, 1, 0);
  if (rc < 0 && errno != EINTR) p->ready(p->data, -errno);
  else if (rc > 0 || (rc == 0 && p->named))
    p->ready(p->data, fd.revents & POLLNVAL ? UV_EBADF : 0);
}
#endif

#if defined(__linux__) || defined(__APPLE__)
int agc_fd_reopen(int fd, int access) {
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0) return -1;
  int given = flags & O_ACCMODE, wanted = access & O_ACCMODE;
  if ((given == O_RDONLY && wanted != O_RDONLY) || (given == O_WRONLY && wanted != O_WRONLY)) {
    errno = EBADF;
    return -1;
  }
#ifdef __APPLE__
  struct stat info;
  if (fstat(fd, &info) != 0) return -1;
  if (S_ISFIFO(info.st_mode)) return fcntl(fd, F_DUPFD_CLOEXEC, 3);
  char path[1024];
  if (fcntl(fd, F_GETPATH, path) != 0) return -1;
#else
  char path[32];
  snprintf(path, sizeof path, "/proc/self/fd/%d", fd);
#endif
  return open(path, access | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
}
#endif

agc_poller *agc_poller_open(agc_vm *vm, int fd, int *err) {
  agc_poller *p = calloc(1, sizeof(agc_poller));
  if (!p) agc_out_of_memory();
  int rc;
#ifdef __APPLE__
  struct stat info;
  p->timed = fstat(fd, &info) == 0 && S_ISFIFO(info.st_mode);
  if (p->timed) {
    char path[1024];
    p->named = fcntl(fd, F_GETPATH, path) == 0;
    rc = uv_timer_init(&loop_of(vm)->uv, &p->timer);
    p->timer.data = p;
  } else
#endif
  {
    rc = uv_poll_init(&loop_of(vm)->uv, &p->handle, fd);
    p->handle.data = p;
  }
  if (rc != 0) {
    free(p);
    *err = -rc;
    return NULL;
  }
  p->fd = fd;
  return p;
}

void agc_poller_wait(agc_poller *p, bool writing, void (*ready)(void *data, int status), void *data) {
  p->ready = ready;
  p->data = data;
#ifdef __APPLE__
  if (p->timed) {
    p->writing = writing;
    if (uv_timer_start(&p->timer, poll_tick, 0, 1) != 0) ready(data, UV_EBADF);
    return;
  }
#endif
  if (uv_poll_start(&p->handle, writing ? UV_WRITABLE : UV_READABLE, poll_ready) != 0) ready(data, UV_EBADF);
}

void agc_poller_pause(agc_poller *p) {
#ifdef __APPLE__
  if (p->timed) {
    uv_timer_stop(&p->timer);
    return;
  }
#endif
  uv_poll_stop(&p->handle);
}

void agc_poller_close(agc_poller *p) {
#ifdef __APPLE__
  if (p->timed) {
    uv_close((uv_handle_t *)&p->timer, poller_closed);
    return;
  }
#endif
  uv_close((uv_handle_t *)&p->handle, poller_closed);
}
#endif

bool agc_io_init(void) {
#ifdef __linux__
  if (getenv("UV_USE_IO_URING")) return false;
  setenv("UV_USE_IO_URING", "0", 1);
  return true;
#else
  return false;
#endif
}

const char *agc_uv_version(void) { return uv_version_string(); }

/* From here on the loop belongs to the calling thread, and a request posted by another thread goes through the inbox
   (§16.4). Call it on the thread that will run the loop, before a second thread posts anything. The inbox keeps the
   loop alive while KEEP is true, so an idle I/O thread blocks in the loop (§10.2.3). False when libuv cannot make it. */
bool agc_io_share(agc_vm *vm, bool keep) {
  agc_loop *loop = loop_of(vm);
  if (!loop->inbox) {
    loop->inbox = agc_inbox_open(&loop->uv, run_inbox, loop);
    if (!loop->inbox) return false;
    loop->owner = uv_thread_self();
  }
  agc_inbox_keep(loop->inbox, keep);
  return true;
}

struct uv_loop_s *agc_io_uv(agc_vm *vm) { return &loop_of(vm)->uv; }

static agc_resource *start_job(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context,
                               int64_t timeout_ms, const agc_task *task, agc_more_fn more, bool quiet) {
  if (kind->work && kind->cancel && !more) agc_fail(vm, "RUNTIME-INTERNAL", "a pool job cannot have a cancel half", 0);
  agc_loop *loop = loop_of(vm);
  job *j = calloc(1, sizeof(job));
  if (!j) agc_out_of_memory();
  j->kind = kind;
  j->data = data;
  j->more = more;
  j->loop = loop;
  /* The holders (§16.5): the owner, and the wait piece when the job has pool work or waits on the loop. A job that is
     only a timer has no wait piece. The timer is no holder: it never touches `data`, and sweep waits for its close. */
  atomic_init(&j->refs, 1);
  atomic_init(&j->outcome, AGC_JOB_PENDING);
  atomic_init(&j->detached, false);
  atomic_init(&j->busy, kind->work || kind->external);
  if (kind->work || kind->external) agc_job_ref(&j->refs);
  agc_resource *r = agc_register(vm, j, NULL);
  r->kind = AGC_RESOURCE_JOB;
  r->context = context;
  j->slot = r->slot;
  const agc_trace *tr = &vm->rt->trace;
  if (!quiet && AGC_TRACE_ON(tr, AGC_TRACE_IO)) {
    j->started_ns = agc_trace_now();
    AGC_TRACE(tr, AGC_TRACE_IO, "start job=%" PRIu64 " kind=%s task=%" PRIu64 " timeout_ms=%" PRId64, r->id,
              kind->name, task ? task->id : 0, timeout_ms);
  }
  post(j, REQ_START, timeout_ms);
  if (agc_is(context, AGC_T_HANDLE)) agc_as_handle(vm, context)->holder = r;
  return r;
}

/* The job is the wait of the task, so the task is marked PARKING before the job exists: the job's completion is
   the wake (§10.2.3). A builtin that registers something else first (a waiter list, a request) marks before that and
   calls agc_io_start_marked, so the task is marked once per park. */
static agc_io_job *start_parked(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context,
                                int64_t timeout_ms, agc_more_fn more) {
  agc_resource *r = start_job(vm, kind, data, context, timeout_ms, vm->task, more, false);
  r->task = vm->task;
  vm->task->parked = r;
  agc_task_park(vm, false);
  return r->native;
}

agc_io_job *agc_io_start_then(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, int64_t timeout_ms,
                              agc_more_fn more) {
  agc_task_parking(vm);
  return start_parked(vm, kind, data, context, timeout_ms, more);
}

agc_io_job *agc_io_start_marked(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context,
                                int64_t timeout_ms) {
  return start_parked(vm, kind, data, context, timeout_ms, NULL);
}

agc_io_job *agc_io_start(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, int64_t timeout_ms) {
  return agc_io_start_then(vm, kind, data, context, timeout_ms, NULL);
}

agc_io_job *agc_io_detached(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, unsigned flags) {
  agc_resource *r = start_job(vm, kind, data, context, -1, NULL, NULL, (flags & AGC_JOB_QUIET) != 0);
  job *j = r->native;
  j->detached = true;
  j->flush = (flags & AGC_JOB_FLUSH) != 0;
  return j;
}

/* A wait on the loop is over (a service callback): a pool job's work is not, so it is not ended from here. */
void agc_io_ready(agc_io_job *j) {
  if (j->kind->work && !j->on_loop) return;
  end_wait(j, AGC_JOB_DONE);
}

void agc_io_extend(agc_io_job *j, int64_t timeout_ms) { post(j, REQ_EXTEND, timeout_ms); }

bool agc_io_poll(agc_vm *vm, bool wait) {
  if (!vm->loop) return false;
  if (uv_loop_alive(&vm->loop->uv)) {
    const agc_trace *tr = &vm->rt->trace;
    uint64_t before = AGC_TRACE_ON(tr, AGC_TRACE_IO) ? agc_trace_now() : 0;
    bool once = wait && !vm->loop->ready;
    uv_run(&vm->loop->uv, once ? UV_RUN_ONCE : UV_RUN_NOWAIT);
    if (once || vm->loop->ready)
      AGC_TRACE(tr, AGC_TRACE_IO, "poll mode=%s us=%" PRIu64, once ? "once" : "nowait",
                (agc_trace_now() - before) / 1000u);
  } else if (!vm->loop->ready) {
    return false;
  }
  drain(vm);
  return true;
}

/* libuv owns the platform-specific monotonic clock. Keep its header inside the loop layer, and preserve errno because
   tracing is observational and must not change the error of the operation it records. */
uint64_t agc_trace_now(void) {
  int saved = errno;
  uint64_t now = uv_hrtime();
  errno = saved;
  return now;
}

/* The clock of the schedulers: milliseconds of libuv's monotonic clock. It does not read the loop (uv_now is the
   loop's own cached time, and the loop belongs to the I/O thread), so any thread may call it. */
uint64_t agc_clock_ms(void) { return agc_trace_now() / 1000000u; }

agc_lock_status agc_handle_wait(agc_vm *vm, agc_resource *handle, int64_t *timeout_ms) {
  agc_task *t = vm->task;
  if (handle->closing && !handle->holder) {
    agc_task_remove(&handle->waiters, &handle->waiters_tail, t);
    if (handle->next_owner == t) handle->next_owner = NULL;
    t->lock_wait = NULL;
    t->lock_deadline = 0;
    return AGC_LOCK_TAKEN;
  }
  uint64_t deadline = t->lock_deadline;
  uint64_t now = deadline ? agc_clock_ms() : 0;
  t->lock_wait = NULL;
  if (handle->next_owner == t || (!handle->holder && !handle->next_owner)) {
    if (deadline) agc_task_remove(&handle->waiters, &handle->waiters_tail, t);
    t->lock_deadline = 0;
    if (handle->next_owner == t) {
      handle->next_owner = NULL;
      agc_task_wake_all(vm, &handle->waiters, &handle->waiters_tail, "lock");
    }
    if (!deadline) return AGC_LOCK_TAKEN;
    if (now >= deadline) return AGC_LOCK_TIMEOUT;
    *timeout_ms = (int64_t)(deadline - now);
    return AGC_LOCK_TAKEN;
  }
  if (!deadline) {
    now = agc_clock_ms();
    deadline = t->lock_deadline = now + (uint64_t)*timeout_ms;
  }
  agc_task_remove(&handle->waiters, &handle->waiters_tail, t);
  if (now >= deadline) {
    t->lock_deadline = 0;
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "lock_timeout handle=%" PRIu64 " task=%" PRIu64, handle->id, t->id);
    return AGC_LOCK_TIMEOUT;
  }
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "lock_wait handle=%" PRIu64 " task=%" PRIu64 " wait_ms=%" PRIu64, handle->id,
            t->id, deadline - now);
  agc_task_parking(vm);
  agc_task_enqueue(&handle->waiters, &handle->waiters_tail, t);
  t->lock_wait = handle;
  agc_io_start_marked(vm, &agc_wait_io, NULL, agc_void(), (int64_t)(deadline - now));
  agc_task_park(vm, true);
  return AGC_LOCK_WAIT;
}

/* The task takes the result of its job. The outcome is read with acquire; one that is still PENDING means the task was
   woken by something else (a lock hand-on, an awaited task that ended), so the job gives up and is `expired`. The
   timer is closed by a request, and the task's reference goes last. */
agc_value agc_io_finish(agc_vm *vm, agc_task *t) {
  agc_resource *r = t->parked;
  t->parked = NULL;
  r->task = NULL;
  job *j = r->native;
  post(j, REQ_CLOSE_TIMER, 0);
  j->ended = true;
  (void)agc_job_settle(&j->outcome, AGC_JOB_EXPIRED);
  agc_value context = take_context(vm, r);
  if (j->start_failed) {
    release(j);
    agc_fail(vm, "RUNTIME-INTERNAL", "cannot queue file work", 0);
  }
  agc_value result;
  bool done = agc_job_outcome_of(&j->outcome) == AGC_JOB_DONE;
  if (done) {
    void *data = j->data;
    j->data = NULL;
    result = j->kind->done(vm, data, context);
  } else {
    result = j->kind->expired(vm, j->data, context);
  }
  trace_finish(vm, r, j, done, result);
  if (j->kind->external || j->on_loop) abandon_wait(j);
  close_pending(vm, context);
  release(j);
  sweep(vm);
  return result;
}

void agc_io_detach(agc_vm *vm, agc_task *t) {
  agc_resource *r = t->parked;
  t->parked = NULL;
  r->task = NULL;
  job *j = r->native;
  atomic_store(&j->detached, true);
  (void)agc_job_settle(&j->outcome, AGC_JOB_CANCELLED);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "detach job=%" PRIu64 " kind=%s task=%" PRIu64, r->id, j->kind->name, t->id);
  if (cancellable(j) && j->kind->cancel(vm, j->data, r->context, false)) j->dropping = true;
  if (j->dropping || !atomic_load(&j->busy) || j->timer_fired) mark_ready(j);
}

/* The job still has pool work or a wait on the loop, so the handle that it holds is in use. */
static bool held(const agc_resource *r) {
  const agc_resource *h = r->holder;
  return h && h->slot != SIZE_MAX && h->native && atomic_load(&((const job *)h->native)->busy);
}

static void release_handles(agc_vm *vm) {
  for (size_t k = registry_count(vm); k-- > 0;) {
    agc_resource *r = vm->registry->items[k];
    if (r->kind == AGC_RESOURCE_JOB || held(r)) continue;
    if (r->native) r->release(r->native);
    r->native = NULL;
    agc_unregister(vm, r);
  }
}

void agc_io_goodbye(agc_vm *vm) {
  for (size_t k = registry_count(vm); k-- > 0;) {
    agc_resource *r = vm->registry->items[k];
    if (r->goodbye && r->native) r->goodbye(r->native);
  }
}

static bool flushing(agc_vm *vm) {
  for (size_t k = registry_count(vm); k-- > 0;) {
    const job *j = job_at(vm, k);
    if (j && j->flush && atomic_load(&j->busy)) return true;
  }
  return agc_output_busy(vm);
}

static void close_files(agc_vm *vm) {
  for (size_t k = registry_count(vm); k-- > 0;) {
    if (k >= registry_count(vm)) continue;
    agc_resource *r = vm->registry->items[k];
    if (!r->pool_close || !r->native || held(r)) continue;
    r->holder = NULL;
    r->close(vm, r, NULL);
  }
}

static void flush_expired(uv_timer_t *timer) { ((agc_loop *)timer->data)->expired = true; }

/* Every file close flushes its buffer in a pool job; the run waits for them,
   at most the flush limit (30 seconds, --flush-timeout or AGENTICA_FLUSH_TIMEOUT_MS). */
static void finish_flushes(agc_vm *vm) {
  agc_loop *loop = vm->loop;
  if (!flushing(vm)) return;
  loop->expired = false;
  uv_update_time(&loop->uv);
  uv_timer_init(&loop->uv, &loop->deadline);
  loop->deadline.data = loop;
  uv_timer_start(&loop->deadline, flush_expired, (uint64_t)vm->rt->flush_timeout, 0);
  for (;;) {
    drain(vm);
    if (!flushing(vm) || loop->expired) break;
    uv_run(&loop->uv, UV_RUN_ONCE);
    if (!uv_loop_alive(&loop->uv)) {
      drain(vm);
      break;
    }
  }
  uv_close((uv_handle_t *)&loop->deadline, NULL);
  vm->rt->flush_expired = flushing(vm);
}

void agc_io_flush_files(agc_vm *vm) {
  if (!vm->loop) return;
  close_files(vm);
  finish_flushes(vm);
}

/* The stop state outlives a loop when one process runs two VMs one after the other (the single binary's front end,
 * then the program): the next VM installs its own wake handle. The handler runs on this thread only (the pool
 * threads have the stop signals blocked, see queue_work), so blocking them here keeps it from sending to a handle
 * that is being closed. */
static void unwatch_stop(agc_loop *loop) {
#if !defined(_WIN32)
  if (loop->stop_grace_init) {
    uv_timer_stop(&loop->stop_grace);
    uv_close((uv_handle_t *)&loop->stop_grace, NULL);
    loop->stop_grace_init = false;
  }
#if defined(__APPLE__)
  if (loop->parent_check_init) {
    uv_timer_stop(&loop->parent_check);
    uv_close((uv_handle_t *)&loop->parent_check, NULL);
    loop->parent_check_init = false;
  }
#endif
  if (stop_status()->wake != &loop->wake) return;
  sigset_t saved;
  agc_io_block_stop(&saved);
  stop_status()->wake = NULL;
  pthread_sigmask(SIG_SETMASK, &saved, NULL);
  uv_close((uv_handle_t *)&loop->wake, NULL);
#else
  for (size_t k = 0; k < loop->stop_signal_count; k++) {
    uv_signal_stop(&loop->stop_signals[k]);
    uv_close((uv_handle_t *)&loop->stop_signals[k], NULL);
  }
  loop->stop_signal_count = 0;
  if (loop->stop_grace_init) {
    uv_timer_stop(&loop->stop_grace);
    uv_close((uv_handle_t *)&loop->stop_grace, NULL);
    loop->stop_grace_init = false;
  }
  if (loop->parent_check_init) {
    uv_timer_stop(&loop->parent_check);
    uv_close((uv_handle_t *)&loop->parent_check, NULL);
    loop->parent_check_init = false;
  }
  if (loop->driver) {
    CloseHandle(loop->driver);
    loop->driver = NULL;
  }
#endif
}

static void close_tick(uv_timer_t *timer) { (void)timer; }

static void close_bound(uv_handle_t *handle) { free(handle); }

static bool finish_native_close(agc_loop *loop) {
  uv_timer_t *bound = malloc(sizeof *bound);
  if (!bound) agc_out_of_memory();
  if (uv_timer_init(&loop->uv, bound) != 0) { free(bound); return false; }
  uint64_t deadline = uv_hrtime() + UINT64_C(1000000000);
  while (uv_loop_alive(&loop->uv)) {
    uint64_t now = uv_hrtime();
    if (now >= deadline) break;
    uint64_t remaining = (deadline - now + 999999) / 1000000;
    uv_update_time(&loop->uv);
    if (uv_timer_start(bound, close_tick, remaining, 0) != 0) break;
    uv_run(&loop->uv, UV_RUN_ONCE);
    uv_timer_stop(bound);
  }
  uv_close((uv_handle_t *)bound, close_bound);
  uv_run(&loop->uv, UV_RUN_NOWAIT);
  return uv_loop_close(&loop->uv) == 0;
}

static bool close_all(agc_vm *vm) {
  agc_io_flush_files(vm);
  for (size_t k = registry_count(vm); k-- > 0;) {
    job *j = job_at(vm, k);
    if (!j) continue;
    if (!j->ended) {
      j->ended = true;
      drop_ref(j);
    }
    (void)agc_job_settle(&j->outcome, AGC_JOB_CANCELLED);
    if (j->kind->external || j->on_loop) abandon_wait(j);
    close_timer(j);
  }
  agc_input_close(vm);
  agc_output_close(vm);
  release_handles(vm);
  if (!vm->loop) return true;
  unwatch_stop(vm->loop);
  if (vm->loop->inbox) {
    agc_inbox_close(vm->loop->inbox);
    vm->loop->inbox = NULL;
  }
  for (int attempt = 0; attempt < 4; attempt++) {
    uv_run(&vm->loop->uv, UV_RUN_NOWAIT);
    for (job *j = vm->loop->ready, *next; j; j = next) {
      next = j->ready_next;
      j->ready_next = NULL;
      j->queued = false;
      drop_ref(j);
    }
    vm->loop->ready = vm->loop->ready_tail = NULL;
    sweep(vm);
    release_handles(vm);
    if (registry_count(vm)) continue;
    if (uv_loop_close(&vm->loop->uv) == 0) {
      free(vm->loop);
      vm->loop = NULL;
      return true;
    }
  }
  if (!registry_count(vm) && finish_native_close(vm->loop)) {
    free(vm->loop);
    vm->loop = NULL;
    return true;
  }
  return false;
}

bool agc_io_close(agc_vm *vm) {
  bool settled = close_all(vm);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "close resources=%zu settled=%d", registry_count(vm), settled ? 1 : 0);
  return settled;
}
#else
bool agc_io_init(void) { return false; }

const char *agc_uv_version(void) { return NULL; }

agc_io_job *agc_io_start(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, int64_t timeout_ms) {
  (void)kind;
  (void)data;
  (void)context;
  (void)timeout_ms;
  agc_fail(vm, "RUNTIME-INTERNAL", "this builtin needs Linux", 0);
}

void agc_io_ready(agc_io_job *j) { (void)j; }

void agc_io_extend(agc_io_job *j, int64_t timeout_ms) {
  (void)j;
  (void)timeout_ms;
}

agc_io_job *agc_io_detached(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, unsigned flags) {
  (void)kind;
  (void)data;
  (void)context;
  (void)flags;
  agc_fail(vm, "RUNTIME-INTERNAL", "this builtin needs Linux", 0);
}

bool agc_io_poll(agc_vm *vm, bool wait) {
  (void)vm;
  (void)wait;
  return false;
}

agc_lock_status agc_handle_wait(agc_vm *vm, agc_resource *handle, int64_t *timeout_ms) {
  (void)vm;
  (void)handle;
  (void)timeout_ms;
  return AGC_LOCK_TAKEN;
}

uint64_t agc_clock_ms(void) { return 0; }

const agc_io_kind agc_wait_io = {NULL, NULL, NULL, NULL, false, "lock", NULL};

agc_value agc_io_finish(agc_vm *vm, agc_task *t) {
  (void)t;
  agc_fail(vm, "RUNTIME-INTERNAL", "this builtin needs Linux", 0);
}

void agc_io_detach(agc_vm *vm, agc_task *t) {
  (void)vm;
  t->parked = NULL;
}

bool agc_io_close(agc_vm *vm) {
  (void)vm;
  return true;
}

bool agc_io_share(agc_vm *vm, bool keep) {
  (void)vm;
  (void)keep;
  return false;
}

void agc_io_watch_stop(agc_vm *vm, int64_t driver) {
  (void)vm;
  (void)driver;
}

int agc_io_stop_signal(void) { return 0; }

void agc_io_children_stopped(void) {}

void agc_io_goodbye(agc_vm *vm) { (void)vm; }

void agc_io_flush_files(agc_vm *vm) { (void)vm; }
#endif
