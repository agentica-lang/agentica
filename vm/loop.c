#include "agc.h"

#include <inttypes.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#ifdef __linux__
#include <signal.h>
#include <uv.h>
#endif

struct agc_registry {
  size_t count, cap;
  uint64_t next_id;
  agc_resource **items;
};

#ifdef __linux__
typedef struct agc_io_job job;

struct agc_loop {
  uv_loop_t uv;
  job *ready, *ready_tail;
};

struct agc_io_job {
  uv_work_t work;
  uv_timer_t timer;
  const agc_io_kind *kind;
  void *data;
  agc_loop *loop;
  job *ready_next;
  size_t slot;
  uint64_t started_ns, ended_ns;
  bool work_done, timer_fired, timer_closing, timer_closed, consumed, queued;
};
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

void agc_unregister(agc_vm *vm, agc_resource *r) {
  agc_registry *reg = vm->registry;
  if (!reg || r->slot >= reg->count || reg->items[r->slot] != r) return;
  agc_resource *last = reg->items[--reg->count];
  reg->items[r->slot] = last;
  last->slot = r->slot;
#ifdef __linux__
  if (last->kind == AGC_RESOURCE_JOB && last->native) ((job *)last->native)->slot = last->slot;
#endif
  reg->items[reg->count] = NULL;
  r->slot = SIZE_MAX;
}

#ifdef __linux__
static job *timer_job(uv_handle_t *handle) { return (job *)(void *)((char *)handle - offsetof(job, timer)); }

static void run_work(uv_work_t *req) {
  job *j = (job *)(void *)req;
  j->kind->work(j->data);
}

static void mark_ready(job *j) {
  if (j->started_ns && !j->ended_ns) j->ended_ns = agc_trace_now();
  if (j->queued) return;
  j->queued = true;
  j->ready_next = NULL;
  agc_loop *loop = j->loop;
  if (loop->ready_tail)
    loop->ready_tail->ready_next = j;
  else
    loop->ready = j;
  loop->ready_tail = j;
}

static void work_finished(uv_work_t *req, int status) {
  (void)status;
  job *j = (job *)(void *)req;
  j->work_done = true;
  mark_ready(j);
}

static void timer_fired(uv_timer_t *timer) {
  job *j = timer_job((uv_handle_t *)timer);
  j->timer_fired = true;
  mark_ready(j);
}

static void timer_closed(uv_handle_t *handle) { timer_job(handle)->timer_closed = true; }

static void close_timer(job *j) {
  if (j->timer_closing) return;
  j->timer_closing = true;
  uv_timer_stop(&j->timer);
  uv_close((uv_handle_t *)&j->timer, timer_closed);
}

static size_t registry_count(const agc_vm *vm) { return vm->registry ? vm->registry->count : 0; }

static job *job_at(const agc_vm *vm, size_t k) {
  const agc_resource *r = vm->registry->items[k];
  return r->kind == AGC_RESOURCE_JOB ? r->native : NULL;
}

static void sweep(agc_vm *vm) {
  for (size_t k = registry_count(vm); k-- > 0;) {
    job *j = job_at(vm, k);
    if (!j || !j->consumed || !j->work_done) continue;
    if (j->data) {
      j->kind->drop(j->data);
      j->data = NULL;
    }
    if (!j->timer_closed) continue;
    agc_resource *r = vm->registry->items[k];
    free(j);
    r->native = NULL;
    agc_unregister(vm, r);
  }
}

static agc_loop *loop_of(agc_vm *vm) {
  if (vm->loop) return vm->loop;
  agc_loop *loop = malloc(sizeof(agc_loop));
  if (!loop) agc_out_of_memory();
  loop->ready = loop->ready_tail = NULL;
  if (uv_loop_init(&loop->uv) != 0) {
    free(loop);
    agc_fail(vm, "RUNTIME-INTERNAL", "cannot start the event loop", 0);
  }
  vm->loop = loop;
  return loop;
}

static void drain(agc_vm *vm) {
  agc_loop *loop = vm->loop;
  job *j = loop->ready;
  loop->ready = loop->ready_tail = NULL;
  agc_registry *reg = vm->registry;
  while (j) {
    job *next = j->ready_next;
    j->ready_next = NULL;
    j->queued = false;
    if (reg && j->slot < reg->count && reg->items[j->slot]->native == j) {
      agc_resource *r = reg->items[j->slot];
      agc_task *t = r->task;
      r->task = NULL;
      if (t) agc_task_wake(vm, t, "job");
    }
    j = next;
  }
}

const int agc_stop_signals[AGC_STOP_SIGNALS] = {SIGINT, SIGTERM, SIGHUP};

void agc_io_block_stop(sigset_t *saved) {
  sigset_t block;
  sigemptyset(&block);
  for (size_t k = 0; k < AGC_STOP_SIGNALS; k++) sigaddset(&block, agc_stop_signals[k]);
  pthread_sigmask(SIG_BLOCK, &block, saved);
}

static int queue_work(agc_loop *loop, job *j) {
  sigset_t saved;
  agc_io_block_stop(&saved);
  int rc = uv_queue_work(&loop->uv, &j->work, run_work, work_finished);
  pthread_sigmask(SIG_SETMASK, &saved, NULL);
  return rc;
}

bool agc_io_init(void) {
  if (getenv("UV_USE_IO_URING")) return false;
  setenv("UV_USE_IO_URING", "0", 1);
  return true;
}

const char *agc_uv_version(void) { return uv_version_string(); }

struct uv_loop_s *agc_io_uv(agc_vm *vm) { return &loop_of(vm)->uv; }

agc_io_job *agc_io_start(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, int64_t timeout_ms) {
  agc_loop *loop = loop_of(vm);
  job *j = calloc(1, sizeof(job));
  if (!j) agc_out_of_memory();
  j->kind = kind;
  j->data = data;
  j->loop = loop;
  agc_resource *r = agc_register(vm, j, NULL);
  r->kind = AGC_RESOURCE_JOB;
  r->context = context;
  j->slot = r->slot;
  const agc_trace *tr = &vm->rt->trace;
  if (AGC_TRACE_ON(tr, AGC_TRACE_IO)) {
    j->started_ns = agc_trace_now();
    AGC_TRACE(tr, AGC_TRACE_IO, "start job=%" PRIu64 " kind=%s task=%" PRIu64 " timeout_ms=%" PRId64, r->id,
              kind->name, vm->task->id, timeout_ms);
  }
  if (timeout_ms >= 0) {
    uv_update_time(&loop->uv);
    uv_timer_init(&loop->uv, &j->timer);
    uv_timer_start(&j->timer, timer_fired, (uint64_t)timeout_ms, 0);
  } else {
    j->timer_closing = j->timer_closed = true;
  }
  if (!kind->work) {
    j->work_done = !kind->external;
  } else if (queue_work(loop, j) != 0) {
    j->work_done = true;
    j->consumed = true;
    if (!j->timer_closing) close_timer(j);
    agc_fail(vm, "RUNTIME-INTERNAL", "cannot queue file work", 0);
  }
  if (agc_is(context, AGC_T_HANDLE)) agc_as_handle(vm, context)->holder = r;
  r->task = vm->task;
  vm->task->parked = r;
  agc_task_park(vm, false);
  return j;
}

void agc_io_ready(agc_io_job *j) {
  if (j->consumed || j->work_done) return;
  j->work_done = true;
  mark_ready(j);
}

bool agc_io_poll(agc_vm *vm, bool wait) {
  if (!vm->loop || !uv_loop_alive(&vm->loop->uv)) return false;
  const agc_trace *tr = &vm->rt->trace;
  uint64_t before = AGC_TRACE_ON(tr, AGC_TRACE_IO) ? agc_trace_now() : 0;
  uv_run(&vm->loop->uv, wait ? UV_RUN_ONCE : UV_RUN_NOWAIT);
  if (wait || vm->loop->ready)
    AGC_TRACE(tr, AGC_TRACE_IO, "poll mode=%s us=%" PRIu64, wait ? "once" : "nowait",
              (agc_trace_now() - before) / 1000u);
  drain(vm);
  return true;
}

static agc_value lock_woken(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_void();
}

static const agc_io_kind lock_io = {NULL, lock_woken, lock_woken, NULL, false, "lock"};

static uint64_t loop_now(agc_vm *vm) {
  agc_loop *loop = loop_of(vm);
  uv_update_time(&loop->uv);
  return uv_now(&loop->uv);
}

agc_lock_status agc_handle_wait(agc_vm *vm, agc_resource *handle, int64_t *timeout_ms) {
  agc_task *t = vm->task;
  uint64_t deadline = t->lock_deadline;
  uint64_t now = deadline ? loop_now(vm) : 0;
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
    now = loop_now(vm);
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
  agc_task_enqueue(&handle->waiters, &handle->waiters_tail, t);
  agc_io_start(vm, &lock_io, NULL, agc_void(), (int64_t)(deadline - now));
  agc_task_park(vm, true);
  return AGC_LOCK_WAIT;
}

static void trace_finish(agc_vm *vm, const agc_resource *r, const job *j, bool done, agc_value result) {
  const agc_trace *tr = &vm->rt->trace;
  if (!AGC_TRACE_ON(tr, AGC_TRACE_IO) || !j->started_ns || j->kind == &lock_io) return;
  uint64_t end = j->ended_ns ? j->ended_ns : agc_trace_now();
  uint64_t us = end > j->started_ns ? (end - j->started_ns) / 1000u : 0;
  const char *outcome = !agc_is(result, AGC_T_RESULT) ? "value" : agc_as_result(vm, result)->ok ? "ok" : "error";
  AGC_TRACE(tr, AGC_TRACE_IO, "%s job=%" PRIu64 " kind=%s us=%" PRIu64 " result=%s", done ? "done" : "timeout", r->id,
            j->kind->name, us, outcome);
}

agc_value agc_io_finish(agc_vm *vm, agc_task *t) {
  agc_resource *r = t->parked;
  t->parked = NULL;
  r->task = NULL;
  job *j = r->native;
  close_timer(j);
  agc_value context = r->context;
  r->context = agc_void();
  j->consumed = true;
  if (agc_is(context, AGC_T_HANDLE)) {
    agc_resource *handle = agc_as_handle(vm, context);
    if (handle->holder == r) {
      handle->holder = NULL;
      agc_task *next = handle->waiters;
      if (next) {
        agc_task_remove(&handle->waiters, &handle->waiters_tail, next);
        handle->next_owner = next;
        AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "lock_handoff handle=%" PRIu64 " task=%" PRIu64, handle->id, next->id);
        agc_task_wake(vm, next, "lock");
      }
    }
  }
  agc_value result;
  bool done = (j->kind->work || j->kind->external) ? j->work_done : j->timer_fired;
  if (done) {
    void *data = j->data;
    j->data = NULL;
    result = j->kind->done(vm, data, context);
  } else {
    result = j->kind->expired(vm, j->data, context);
  }
  trace_finish(vm, r, j, done, result);
  if (j->kind->external) j->work_done = true;
  sweep(vm);
  return result;
}

static bool held(const agc_resource *r) {
  const agc_resource *h = r->holder;
  return h && h->slot != SIZE_MAX && h->native && !((const job *)h->native)->work_done;
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

static bool close_all(agc_vm *vm) {
  for (size_t k = registry_count(vm); k-- > 0;) {
    job *j = job_at(vm, k);
    if (!j) continue;
    j->consumed = true;
    if (j->kind->external) j->work_done = true;
    close_timer(j);
  }
  release_handles(vm);
  if (!vm->loop) return true;
  uv_run(&vm->loop->uv, UV_RUN_NOWAIT);
  vm->loop->ready = vm->loop->ready_tail = NULL;
  sweep(vm);
  release_handles(vm);
  if (registry_count(vm)) return false;
  if (uv_loop_close(&vm->loop->uv) != 0) return false;
  free(vm->loop);
  vm->loop = NULL;
  return true;
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

agc_value agc_io_finish(agc_vm *vm, agc_task *t) {
  (void)t;
  agc_fail(vm, "RUNTIME-INTERNAL", "this builtin needs Linux", 0);
}

bool agc_io_close(agc_vm *vm) {
  (void)vm;
  return true;
}
#endif
