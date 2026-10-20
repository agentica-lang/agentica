/*
 * The HttpServer task group builtins, called only by
 * stdlib/http.agc: server, accept, spawn, close_server, wait and local_port.
 * std/http reads the requests and writes the responses itself. Service layer.
 * Design: docs/vm/10-io-http.md §10.7.2.
 */
#include "http_fields.h"
#include "net.h"

#include <inttypes.h>
#include <stdatomic.h>
#include <stdlib.h>

#define MAX_CONNECTIONS ((int64_t)65536)

typedef struct waiter waiter;

/* The I/O thread owns `listener`, `open`, `users` and the waiter list: every change is a step there (agc_loop_call,
   inline at N = 1), so the listener's watch, the accepts and the counts never run beside each other. `max`, `loop`
   and `trace` are fixed at creation. `closed` is atomic: a scheduler reads it to refuse a closed server at once, and
   the I/O thread reads it to end the waiters. The struct is freed on the I/O thread when `users` (the resource and
   each waiter whose START ran) reaches zero. A step that a scheduler posts with the struct either holds a count (a
   waiter's START and end) or was posted under rt->sync after reading the resource's native pointer (attach,
   give_back). shut_server clears that pointer under rt->sync before it posts the release that drops the resource's
   count, and steps posted under rt->sync reach the I/O thread in the order of the calls, so every such step runs
   before the release. The registry's release at the end of the run comes after the last builtin. */
typedef struct {
  agc_conn *listener;
  agc_loop *loop;
  agc_trace trace;
  size_t max, open, users;
  _Atomic bool closed;
  waiter *waiters, *waiters_tail;
} server;

/* An accept (or a wait for the close): queued on the I/O thread in arrival order, ended there with agc_io_ready. An
   accept that is served carries its connection to the done half, which makes the socket on the task's scheduler. */
struct waiter {
  server *s;
  agc_loop *loop;
  agc_io_job *job;
  waiter *next;
  agc_conn *child;
  bool accepting, started, linked;
};

typedef struct {
  server *s;
  uint64_t id;
  bool traced;
} release_call;

static const char server_closed[] = "http: server is closed";

static void settle(server *s) {
  if (!s->users) free(s);
}

static void unlink_waiter(waiter *w) {
  server *s = w->s;
  waiter *prev = NULL;
  for (waiter *at = s->waiters; at; prev = at, at = at->next) {
    if (at != w) continue;
    if (prev)
      prev->next = w->next;
    else
      s->waiters = w->next;
    if (s->waiters_tail == w) s->waiters_tail = prev;
    break;
  }
  w->next = NULL;
  w->linked = false;
}

static bool listening(const server *s) { return s->listener && !agc_conn_closed(s->listener); }

/* A connection while there is room, counted as open. I/O thread. */
static agc_conn *take(server *s) {
  if (atomic_load(&s->closed) || !listening(s) || s->open >= s->max) return NULL;
  agc_conn *c = agc_conn_accept(s->listener);
  if (c) s->open++;
  return c;
}

/* Ends every waiter the server's state now answers, oldest first: all of them once the server is closed, an accept
   when the listener is gone or a connection is there for it. I/O thread. */
static void serve(server *s) {
  bool closed = atomic_load(&s->closed);
  for (waiter *w = s->waiters, *next; w; w = next) {
    next = w->next;
    if (!closed && !w->accepting) continue;
    if (!closed && listening(s)) {
      w->child = take(s);
      /* No room or no connection waiting: nothing in this loop changes that, and every waiter still to come needs
         a connection too (a wait for the close is skipped above), so the rest stay queued. */
      if (!w->child) break;
    }
    unlink_waiter(w);
    agc_io_ready(w->job);
  }
}

static void listener_watch(void *watcher) { serve(watcher); }

/* The end of a waiter, on the I/O thread: posted by its done or expired half, or the job's drop. A connection that
   no done half took is closed and gives its room back. A readied job's done half runs even when its task is
   cancelled (the result is then dropped), so that branch is for a job the end of the run sweeps before its task
   resumed. */
static void waiter_end(void *data) {
  waiter *w = data;
  server *s = w->s;
  if (!w->started) {
    free(w);
    return;
  }
  if (w->linked) unlink_waiter(w);
  if (w->child) {
    agc_conn_discard(w->child);
    s->open--;
    serve(s);
  }
  free(w);
  s->users--;
  settle(s);
}

static bool begin_wait(void *data, agc_io_job *job) {
  waiter *w = data;
  server *s = w->s;
  w->job = job;
  w->started = true;
  s->users++;
  if (s->waiters_tail)
    s->waiters_tail->next = w;
  else
    s->waiters = w;
  s->waiters_tail = w;
  w->linked = true;
  serve(s);
  return true;
}

static agc_value waited(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  waiter *w = data;
  agc_value result = agc_result_value(true, agc_void());
  if (w->child) {
    result = agc_result_value(true, agc_conn_socket(vm, w->child));
    w->child = NULL;
  } else if (w->accepting) {
    result = agc_error_value(server_closed);
  }
  agc_loop_call(w->loop, waiter_end, w);
  return result;
}

/* The jobs have no deadline (park passes -1), so this half does not run today. If it did, the wait could still be
   on the server's list, so it reads nothing through `w` and leaves the whole end to the I/O thread. */
static agc_value wait_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  waiter *w = data;
  agc_loop_call(w->loop, waiter_end, w);
  return agc_stream_timed_out();
}

/* On the I/O thread: the waiter leaves the list, so no serve ends a job that is being dropped. */
static bool waiter_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  (void)deadline;
  waiter *w = data;
  if (w->linked) unlink_waiter(w);
  return true;
}

static const agc_io_kind wait_io = {NULL,          waited, wait_expired, waiter_end, true, "http_server",
                                    waiter_cancel, true,   NULL};

static void park(agc_vm *vm, server *s, bool accepting) {
  waiter *w = calloc(1, sizeof(waiter));
  if (!w) agc_out_of_memory();
  w->s = s;
  w->loop = s->loop;
  w->accepting = accepting;
  (void)agc_io_start_then(vm, &wait_io, w, agc_void(), -1, begin_wait);
}

static void attach_step(void *data) {
  server *s = data;
  if (!listening(s)) {
    s->listener = NULL;
    return;
  }
  agc_conn_retain(s->listener);
  agc_conn_observe(s->listener, listener_watch, s);
}

/* The server gives up its listener and its resource's count; every waiter ends. I/O thread. */
static void release_step(void *data) {
  release_call *call = data;
  server *s = call->s;
  if (call->traced) AGC_TRACE(&s->trace, AGC_TRACE_IO, "http_close server=%" PRIu64 " open=%zu", call->id, s->open);
  free(call);
  atomic_store(&s->closed, true);
  serve(s);
  if (s->listener) agc_conn_release(s->listener);
  s->listener = NULL;
  s->users--;
  settle(s);
}

static void post_release(server *s, uint64_t id, bool traced) {
  release_call *call = malloc(sizeof *call);
  if (!call) agc_out_of_memory();
  call->s = s;
  call->id = id;
  call->traced = traced;
  atomic_store(&s->closed, true);
  agc_loop_call(s->loop, release_step, call);
}

/* The registry's release, at the end of the run: a step, as it may come from any thread. */
static void release_server(void *native) { post_release(native, 0, false); }

static void shut_server(agc_vm *vm, agc_http_server *hs) {
  agc_resource *r = hs->state;
  server *s = r->native;
  if (s) {
    r->native = NULL;
    agc_unregister(vm, r);
    post_release(s, r->id, true);
  }
  agc_net_close(vm, agc_as_listener(vm, hs->listener)->state, "close");
  agc_task_cancel(vm, hs->group);
}

static void close_owned(agc_vm *vm, agc_resource *r, agc_task *ender) {
  (void)ender;
  shut_server(vm, agc_as_http_server(vm, r->context));
}

static server *open_server(const agc_http_server *hs) {
  server *s = hs->state->native;
  if (!s || atomic_load(&s->closed) || hs->group->state == AGC_TASK_DONE) return NULL;
  return s;
}

static agc_value builtin_server(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_listener *lv = agc_as_listener(vm, args[0]);
  int64_t max = agc_as_int(vm, args[1]);
  server *s = calloc(1, sizeof(server));
  if (!s) agc_out_of_memory();
  s->max = (size_t)(max < 1 ? 1 : max > MAX_CONNECTIONS ? MAX_CONNECTIONS : max);
  s->users = 1;
  s->loop = agc_io_loop(vm);
  s->trace = vm->rt->trace;
  atomic_init(&s->closed, false);
  /* The listener's resource is alive (the caller holds it, under rt->sync), so its connection is too until a close
     that this builtin's step comes before. */
  s->listener = lv->state->native;
  agc_loop_call(s->loop, attach_step, s);
  agc_http_server *hs = agc_alloc(sizeof(agc_http_server));
  hs->listener = args[0];
  hs->group = agc_task_group(vm);
  hs->state = agc_register(vm, s, release_server);
  hs->state->context = agc_http_server_value(hs);
  agc_own(vm, hs->state, close_owned);
  agc_disown(lv->state);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "http_server server=%" PRIu64 " listener=%" PRIu64 " max=%zu", hs->state->id,
            lv->state->id, s->max);
  agc_value value = agc_http_server_value(hs);
  (void)agc_task_spawn_seeded(vm, hs->group, args[2], &value, 1, span);
  return value;
}

/* A connection at once where the I/O state can be read here (N = 1), else a wait that the I/O thread ends. */
static agc_value builtin_accept(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_http_server *hs = agc_as_http_server(vm, args[0]);
  server *s = open_server(hs);
  if (!s) return agc_error_value(server_closed);
  if (agc_io_here(vm)) {
    agc_conn *c = take(s);
    if (c) return agc_result_value(true, agc_conn_socket(vm, c));
  }
  park(vm, s, true);
  return agc_void();
}

/* The count saturates at zero instead of aborting: HttpWire.spawn takes any socket its caller owns, and bytecode can
   call it with one that no accept counted, whose end still comes here. */
static void give_back_step(void *data) {
  server *s = data;
  if (s->open) s->open--;
  serve(s);
}

static void give_back(const agc_http_server *hs) {
  server *s = hs->state->native;
  if (s) agc_loop_call(s->loop, give_back_step, s);
}

static void connection_ended(agc_vm *vm, agc_task *t) {
  (void)vm;
  const agc_http_server *hs = t->end_data;
  t->end_data = NULL;
  give_back(hs);
}

static agc_value builtin_spawn(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_http_server *hs = agc_as_http_server(vm, args[0]);
  if (!open_server(hs)) {
    agc_net_close(vm, agc_as_socket(vm, args[1])->state, "close");
    give_back(hs);
    return agc_void();
  }
  if (!agc_task_owns(vm, args[1])) give_back(hs);
  agc_task *child = agc_task_spawn_owning(vm, hs->group, args[2], args[1], span);
  child->hidden = true;
  child->end_data = hs;
  child->end = connection_ended;
  return agc_void();
}

static agc_value builtin_close_server(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  shut_server(vm, agc_as_http_server(vm, args[0]));
  return agc_void();
}

static agc_value builtin_wait(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  server *s = agc_as_http_server(vm, args[0])->state->native;
  if (!s || atomic_load(&s->closed)) return agc_result_value(true, agc_void());
  park(vm, s, false);
  return agc_void();
}

static agc_value builtin_local_port(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(agc_as_listener(vm, agc_as_http_server(vm, args[0])->listener)->port);
}

const agc_builtin agc_http_server_builtins[] = {
  {"HttpWire.server", 3, builtin_server, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.accept", 1, builtin_accept, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.spawn", 3, builtin_spawn, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.close_server", 1, builtin_close_server, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.wait", 1, builtin_wait, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.local_port", 1, builtin_local_port, AGC_NATIVE_NONE, AGC_COST_NONE, true},
};

const size_t agc_http_server_builtin_count = sizeof agc_http_server_builtins / sizeof agc_http_server_builtins[0];
