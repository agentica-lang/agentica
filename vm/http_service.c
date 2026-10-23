/*
 * HttpWire.service, jobs, options and awaited?, for stdlib/http.agc only: the
 * task tree of an HttpClient. service runs f(client), the owner task, in a
 * service root (agc_task_service): no caller's crash, cancel or end reaches it,
 * Task.pending_count and Test.test do not see it, and it owns the jobs channel.
 * The HttpClient holds the channel, the options and the TLS context of its
 * https connections (vm/tcp.c).
 * Service layer. Design: docs/vm/10-io-http.md §10.7.1.
 */
#include "services.h"

/* HttpWire.service(jobs, options, f): jobs is a new channel, which nobody owns yet; f gets the client. Options of
   another shape are bytecode the front end would not write: a wrong-type failure, as for any other argument. */
static agc_value builtin_service(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_struct *o = agc_as_struct(vm, args[1]);
  if (o->n != AGC_HTTP_OPTIONS_FIELDS) agc_wrong_tag(vm);
  for (uint32_t k = 0; k < AGC_HTTP_OPTION_CA_FILE; k++) (void)agc_as_int(vm, o->fields[k]);
  (void)agc_as_string(vm, o->fields[AGC_HTTP_OPTION_CA_FILE]);
  agc_http_client *c = agc_alloc(sizeof(agc_http_client));
  c->jobs = args[0];
  c->options = args[1];
  agc_value client = agc_http_client_value(c);
  (void)agc_task_service(vm, args[2], args[0], client, span);
  return client;
}

static agc_value builtin_jobs(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_as_http_client(vm, args[0])->jobs;
}

static agc_value builtin_options(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_as_http_client(vm, args[0])->options;
}

/* HttpWire.awaited?(reply): false once the caller gave up on its reply (agc_channel_abandoned). The owner asks it
   before it sends a waiting job, and a worker before it pools a connection. */
static agc_value builtin_awaited(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_bool(!agc_channel_abandoned(vm, agc_as_channel(vm, args[0])));
}

const agc_builtin agc_http_service_builtins[] = {
  {"HttpWire.service", 3, builtin_service, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"HttpWire.awaited?", 1, builtin_awaited, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"HttpWire.jobs", 1, builtin_jobs, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"HttpWire.options", 1, builtin_options, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
};

const size_t agc_http_service_builtin_count = sizeof agc_http_service_builtins / sizeof agc_http_service_builtins[0];
