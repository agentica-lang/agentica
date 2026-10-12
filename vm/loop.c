#include "agc.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#ifdef __linux__
#include <uv.h>
#endif

struct agc_registry {
  size_t count, cap;
  agc_resource **items;
};

#ifdef __linux__
typedef struct job job;

struct agc_loop {
  uv_loop_t uv;
  job *ready, *ready_tail;
};

struct job {
  uv_work_t work;
  uv_timer_t timer;
  const agc_io_kind *kind;
  void *data;
  agc_loop *loop;
  job *ready_next;
  size_t slot;
  bool work_done, timer_fired, timer_closing, timer_closed, consumed, queued;
};
#endif

static agc_registry *registry_of(agc_vm *vm) {
  if (!vm->registry) vm->registry = agc_alloc(sizeof(agc_registry));
  return vm->registry;
}

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

static void sweep(agc_vm *vm) {
  agc_registry *reg = vm->registry;
  for (size_t k = reg ? reg->count : 0; k-- > 0;) {
    agc_resource *r = reg->items[k];
    if (r->kind != AGC_RESOURCE_JOB) continue;
    job *j = r->native;
    if (!j->consumed || !j->work_done) continue;
    if (j->data) {
      j->kind->drop(j->data);
      j->data = NULL;
    }
    if (!j->timer_closed) continue;
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
      if (t) agc_task_wake(vm, t);
    }
    j = next;
  }
}

void agc_io_init(void) { setenv("UV_USE_IO_URING", "0", 0); }

const char *agc_uv_version(void) { return uv_version_string(); }

void agc_io_start(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, int64_t timeout_ms) {
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
  if (timeout_ms >= 0) {
    uv_update_time(&loop->uv);
    uv_timer_init(&loop->uv, &j->timer);
    uv_timer_start(&j->timer, timer_fired, (uint64_t)timeout_ms, 0);
  } else {
    j->timer_closing = j->timer_closed = true;
  }
  if (!kind->work) {
    j->work_done = true;
  } else if (uv_queue_work(&loop->uv, &j->work, run_work, work_finished) != 0) {
    j->work_done = true;
    j->consumed = true;
    if (!j->timer_closing) close_timer(j);
    agc_fail(vm, "RUNTIME-INTERNAL", "cannot queue file work", 0);
  }
  r->task = vm->task;
  vm->task->parked = r;
  agc_task_park(vm, false);
}

bool agc_io_poll(agc_vm *vm, bool wait) {
  if (!vm->loop || !uv_loop_alive(&vm->loop->uv)) return false;
  uv_run(&vm->loop->uv, wait ? UV_RUN_ONCE : UV_RUN_NOWAIT);
  drain(vm);
  return true;
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
  agc_value result;
  if (j->work_done && (j->kind->work || j->timer_fired)) {
    void *data = j->data;
    j->data = NULL;
    result = j->kind->done(vm, data, context);
  } else {
    result = j->kind->expired(vm, j->data, context);
  }
  sweep(vm);
  return result;
}

bool agc_io_close(agc_vm *vm) {
  agc_registry *reg = vm->registry;
  for (size_t k = reg ? reg->count : 0; k-- > 0;) {
    agc_resource *r = reg->items[k];
    if (r->kind == AGC_RESOURCE_JOB) {
      job *j = r->native;
      j->consumed = true;
      close_timer(j);
      continue;
    }
    if (r->native) r->release(r->native);
    r->native = NULL;
    agc_unregister(vm, r);
  }
  if (!vm->loop) return true;
  uv_run(&vm->loop->uv, UV_RUN_NOWAIT);
  vm->loop->ready = vm->loop->ready_tail = NULL;
  sweep(vm);
  if (vm->registry && vm->registry->count) return false;
  if (uv_loop_close(&vm->loop->uv) != 0) return false;
  free(vm->loop);
  vm->loop = NULL;
  return true;
}
#else
void agc_io_init(void) {}

const char *agc_uv_version(void) { return NULL; }

void agc_io_start(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, int64_t timeout_ms) {
  (void)kind;
  (void)data;
  (void)context;
  (void)timeout_ms;
  agc_fail(vm, "RUNTIME-INTERNAL", "this builtin needs Linux", 0);
}

bool agc_io_poll(agc_vm *vm, bool wait) {
  (void)vm;
  (void)wait;
  return false;
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
