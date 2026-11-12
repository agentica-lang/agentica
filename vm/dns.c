/*
 * DNS.lookup: the addresses of a host name from the system resolver, through libuv's getaddrinfo as TCP.connect
 * resolves (the IDNA form of the name, /etc/hosts and the platform's resolver), as text in the resolver's order
 * without duplicates. One external job: the lookup starts and ends on the I/O thread, so only the task parks, and
 * the job's timeout and cancel apply. Service layer. Design: docs/vm/10-io-tls.md §10.3.
 */
#include "net.h"

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
#include <stdlib.h>
#include <string.h>
#include <uv.h>

/* Room for the text of an IPv6 address (INET6_ADDRSTRLEN is 46) and its NUL. */
#define ADDRESS_TEXT 64
#define LOOKUP(ptr) ((lookup *)(void *)((char *)(ptr) - offsetof(lookup, req)))

/* One lookup. The builtin fills `io` and `host`; the I/O thread owns the rest until the job's wait ends
   (agc_io_ready), and only then does `done` read `status` and the addresses. `started` says that `req` is libuv's until
   its callback: a pool thread may still be inside getaddrinfo, writing into `req`, after the job gave up (its deadline
   or a Task.cancel), and libuv calls `resolved` even after a uv_cancel. So a `drop` of a started lookup only sets
   `dropped`, and `resolved` frees it. `started` and `dropped` are read and written on the I/O thread only. */
typedef struct {
  agc_loop *io;
  CC_OWNS char *host;
  uv_getaddrinfo_t req;
  agc_io_job *job;
  bool started, dropped;
  int status;
  size_t count;
  char (*addresses)[ADDRESS_TEXT];
} lookup;

static void free_lookup(CC_FREES lookup *q) {
  free(q->addresses);
  free(q->host);
  free(q);
}

/* The text of an IPv4 or IPv6 address (without an IPv6 scope id, which uv_ip6_name leaves out); false for another
   family. */
static bool address_text(const struct sockaddr *a, char *text) {
  if (a->sa_family == AF_INET) return uv_ip4_name((const struct sockaddr_in *)(const void *)a, text, ADDRESS_TEXT) == 0;
  if (a->sa_family == AF_INET6)
    return uv_ip6_name((const struct sockaddr_in6 *)(const void *)a, text, ADDRESS_TEXT) == 0;
  return false;
}

/* The resolver's answer, copied as text into the lookup. The hints ask for stream sockets, so each address comes
   once per family on most systems, but a resolver may still list one twice (two /etc/hosts lines): kept once, at its
   first place. I/O thread. */
static void resolved(uv_getaddrinfo_t *req, int status, struct addrinfo *res) {
  lookup *q = LOOKUP(req);
  q->started = false;
  /* The job is gone (and maybe freed): nobody reads the answer. */
  if (q->dropped) {
    uv_freeaddrinfo(res);
    free_lookup(q);
    return;
  }
  q->status = status;
  size_t total = 0;
  for (const struct addrinfo *a = res; a; a = a->ai_next) total++;
  if (status == 0 && total) {
    q->addresses = calloc(total, ADDRESS_TEXT);
    if (!q->addresses) agc_out_of_memory();
  }
  for (const struct addrinfo *a = status == 0 ? res : NULL; a; a = a->ai_next) {
    char text[ADDRESS_TEXT];
    if (!a->ai_addr || !address_text(a->ai_addr, text)) continue;
    bool seen = false;
    for (size_t k = 0; k < q->count && !seen; k++) seen = strcmp(q->addresses[k], text) == 0;
    if (!seen) memcpy(q->addresses[q->count++], text, ADDRESS_TEXT);
  }
  uv_freeaddrinfo(res);
  agc_io_ready(q->job);
}

/* The START step, on the I/O thread: a lookup that libuv refuses at once (a name too long for its IDNA buffer) ends
   with that error. */
static bool begin(void *data, agc_io_job *job) {
  lookup *q = data;
  q->job = job;
  struct addrinfo hints;
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  int rc = agc_io_getaddrinfo(agc_loop_uv(q->io), &q->req, resolved, q->host, NULL, &hints);
  if (rc) {
    q->status = rc;
    agc_io_ready(job);
  } else {
    q->started = true;
  }
  return true;
}

/* The deadline passed: a lookup that still waits for a pool thread leaves the queue (its callback then comes with
   UV_EAI_CANCELED), so it frees its slow-I/O slot at once. One that runs cannot be stopped (uv_cancel says UV_EBUSY):
   it goes on on its pool thread, and its callback finds it dropped. I/O thread. */
static void stop(void *data) {
  lookup *q = data;
  if (q->started) (void)uv_cancel((uv_req_t *)&q->req);
}

/* Task.cancel, or the deadline of a detached job: the same stop. The wait can always be given up, since `drop` leaves a
   running lookup to its callback. I/O thread. */
static bool cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  (void)deadline;
  stop(data);
  return true;
}

static agc_value done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  lookup *q = data;
  agc_value result;
  if (q->status) {
    result = agc_host_error(vm, "network: host not found", q->host, -1, q->status);
  } else {
    agc_list_builder b;
    agc_list_builder_sized(&b, q->count);
    for (size_t k = 0; k < q->count; k++) {
      /* An address is ASCII, so its length in bytes is its length in characters. */
      size_t len = strlen(q->addresses[k]);
      agc_list_builder_push(&b, agc_string_value(agc_make_string(q->addresses[k], len, len)));
    }
    result = agc_result_value(true, agc_list_value(agc_list_builder_finish(&b)));
  }
  free_lookup(q);
  return result;
}

/* It reads nothing of the lookup: the getaddrinfo may still be running (`drop` then leaves it to `resolved`). */
static agc_value expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_stream_timed_out(vm, AGC_STREAM_NETWORK);
}

/* I/O thread (§16.5), like `resolved`, or the caller's thread before the job exists, when `started` is still false. A
   started lookup is freed by its callback. */
// cchecker: ignore CC-OWN-LEAK: a started lookup goes to `resolved`, which libuv always calls and which frees it
static void drop(CC_FREES void *data) {
  lookup *q = data;
  if (q->started) {
    q->dropped = true;
    return;
  }
  free_lookup(q);
}

static const agc_io_kind lookup_io = {NULL, done, expired, drop, true, "dns", cancel, false, stop};

/* DNS.lookup(host, timeout_ms). Every check that can raise or refuse comes before the copy of the name. */
static agc_value builtin_lookup(agc_vm *vm, agc_value *args, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-INTERNAL", "network access is off in this run", span);
  const agc_string *host = agc_as_string(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  if (vm->rt->deny_net) return agc_error(vm, "error", AGC_DENIED_NET);
  if (timeout <= 0) return agc_stream_bad_timeout(vm, AGC_STREAM_NETWORK);
  if (host->bytes == 0) return agc_error(vm, "error", "network: the host name is empty");
  agc_task_check_park(vm, "a callback of native code cannot wait for DNS.lookup", span);
  /* It may raise, so it comes before the allocations. */
  agc_loop *io = agc_io_loop(vm);
  char *name = agc_cstr(host);
  if (!name) return agc_error(vm, "error", "network: host cannot contain NUL");
  CC_OWNS lookup *q = calloc(1, sizeof *q);
  if (!q) agc_out_of_memory();
  q->io = io;
  q->host = name;
  (void)agc_io_start_then(vm, &lookup_io, q, agc_void(), timeout, begin);
  return agc_void();
}

const agc_builtin agc_dns_builtins[] = {
  {"DNS.lookup", 2, builtin_lookup, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
};

const size_t agc_dns_builtin_count = sizeof agc_dns_builtins / sizeof agc_dns_builtins[0];
#else
const agc_builtin agc_dns_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false}};

const size_t agc_dns_builtin_count = 0;
#endif
