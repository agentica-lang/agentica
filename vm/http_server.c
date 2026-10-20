/*
 * The HttpServer task group builtins (Linux and macOS), called only by
 * stdlib/http.agc: server, accept, spawn, close_server, wait and local_port.
 * std/http reads the requests and writes the responses itself. Service layer.
 * Design: docs/vm/10-io-http.md §10.7.2.
 */
#include "http_fields.h"
#include "net.h"

#if defined(__linux__) || defined(__APPLE__)
#include <inttypes.h>
#include <stdlib.h>

#define MAX_CONNECTIONS ((int64_t)65536)

typedef struct waiter waiter;

typedef struct {
  agc_conn *listener;
  size_t max, open, users;
  bool closed;
  waiter *waiters;
} server;

struct waiter {
  server *s;
  agc_io_job *job;
  waiter *next;
};

static const char server_closed[] = "http: server is closed";

static void settle(server *s) {
  if (!s->users) free(s);
}

static void poke(const server *s) {
  for (const waiter *w = s->waiters; w; w = w->next) agc_io_ready(w->job);
}

static void listener_watch(void *watcher) { poke(watcher); }

static void free_waiter(waiter *w) {
  server *s = w->s;
  for (waiter **at = &s->waiters; *at; at = &(*at)->next) {
    if (*at != w) continue;
    *at = w->next;
    break;
  }
  free(w);
  s->users--;
  settle(s);
}

static agc_value waited(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  free_waiter(data);
  return agc_void();
}

static void waiter_drop(void *data) { free_waiter(data); }

static bool waiter_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)data;
  (void)context;
  (void)deadline;
  return true;
}

static const agc_io_kind wait_io = {NULL, waited, waited, waiter_drop, true, "http_server", waiter_cancel, true, NULL};

/* accept and wait are retry builtins: the job only wakes the task, which
   then checks the server again. */
static void park(agc_vm *vm, server *s) {
  waiter *w = calloc(1, sizeof(waiter));
  if (!w) agc_out_of_memory();
  w->s = s;
  w->next = s->waiters;
  s->waiters = w;
  s->users++;
  w->job = agc_io_start(vm, &wait_io, w, agc_void(), -1);
  vm->task->retry = true;
}

static void release_server(void *native) {
  server *s = native;
  s->closed = true;
  if (s->listener) agc_conn_release(s->listener);
  s->listener = NULL;
  s->users--;
  settle(s);
}

static void shut_server(agc_vm *vm, agc_http_server *hs) {
  agc_resource *r = hs->state;
  server *s = r->native;
  if (s) {
    r->native = NULL;
    agc_unregister(vm, r);
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "http_close server=%" PRIu64 " open=%zu", r->id, s->open);
    poke(s);
    release_server(s);
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
  if (!s || s->closed || !s->listener || agc_conn_closed(s->listener) || hs->group->state == AGC_TASK_DONE) return NULL;
  return s;
}

static agc_value builtin_server(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_listener *lv = agc_as_listener(vm, args[0]);
  int64_t max = agc_as_int(vm, args[1]);
  server *s = calloc(1, sizeof(server));
  if (!s) agc_out_of_memory();
  s->max = (size_t)(max < 1 ? 1 : max > MAX_CONNECTIONS ? MAX_CONNECTIONS : max);
  s->users = 1;
  agc_conn *l = lv->state->native;
  if (l && !agc_conn_closed(l)) {
    s->listener = l;
    agc_conn_retain(l);
    agc_conn_observe(l, listener_watch, s);
  }
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

static agc_value builtin_accept(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_http_server *hs = agc_as_http_server(vm, args[0]);
  server *s = open_server(hs);
  if (!s) return agc_error_value(server_closed);
  if (s->open < s->max) {
    agc_conn *c = agc_conn_accept(s->listener);
    if (c) {
      s->open++;
      return agc_result_value(true, agc_conn_socket(vm, c));
    }
  }
  park(vm, s);
  return agc_void();
}

static void give_back(const agc_http_server *hs) {
  server *s = hs->state->native;
  if (!s) return;
  if (s->open) s->open--;
  poke(s);
}

static void connection_ended(agc_vm *vm, agc_task *t) {
  (void)vm;
  const agc_http_server *hs = t->end_data;
  t->end_data = NULL;
  give_back(hs);
}

static agc_value builtin_spawn(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_http_server *hs = agc_as_http_server(vm, args[0]);
  agc_socket *sk = agc_as_socket(vm, args[1]);
  server *s = open_server(hs);
  if (!s) {
    agc_net_close(vm, sk->state, "close");
    s = hs->state->native;
    if (s && s->open) s->open--;
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
  if (!s || s->closed) return agc_result_value(true, agc_void());
  park(vm, s);
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
#else
const agc_builtin agc_http_server_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE, false}};

const size_t agc_http_server_builtin_count = 0;
#endif
