/*
 * HttpWire.service, jobs, options and awaited?, called only by
 * stdlib/http.agc: the task tree of an HttpClient. service runs f(jobs), the client's owner task,
 * in a service root (agc_task_service), so no caller's crash, cancel or end
 * reaches it, Task.pending_count and Test.test do not see it, and it owns the
 * jobs channel, which closes when it ends. std/http builds the pool on it.
 * The HttpClient value holds the channel and the options. Linux and macOS,
 * like TCP; a stub table elsewhere. Service layer. Design:
 * docs/vm/10-io-http.md §10.7.1.
 */
#include "services.h"

#if defined(__linux__) || defined(__APPLE__)
/* HttpWire.service(jobs, options, f): jobs is a new channel, which nobody owns yet. */
static agc_value builtin_service(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)agc_task_service(vm, args[2], args[0], span);
  agc_http_client *c = agc_alloc(sizeof(agc_http_client));
  c->jobs = args[0];
  c->options = args[1];
  return agc_http_client_value(c);
}

static agc_value builtin_jobs(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_as_http_client(vm, args[0])->jobs;
}

static agc_value builtin_options(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_as_http_client(vm, args[0])->options;
}

/* HttpWire.awaited?(reply): a worker asks it before it answers; see agc_channel_awaited. */
static agc_value builtin_awaited(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_bool(agc_channel_awaited(vm, agc_as_channel(vm, args[0])));
}

const agc_builtin agc_http_service_builtins[] = {
  {"HttpWire.service", 3, builtin_service, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.awaited?", 1, builtin_awaited, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.jobs", 1, builtin_jobs, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.options", 1, builtin_options, AGC_NATIVE_NONE, AGC_COST_NONE, true},
};

const size_t agc_http_service_builtin_count = sizeof agc_http_service_builtins / sizeof agc_http_service_builtins[0];
#else
const agc_builtin agc_http_service_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE, false}};

const size_t agc_http_service_builtin_count = 0;
#endif
