/*
 * TCP and TLS builtins called on a scheduler thread while the test's thread is the I/O thread (§16.9), against a POSIX
 * peer, in orders set by the calls: a close behind a read's START, the deadline before and after the bytes, a served
 * accept of a cancelled task, a cancelled TLS connect past its deadline, and HttpWire.connect_tls on bad options.
 * `make vm-tsan` runs it under TSan.
 */
#include "../core.h"
#include "io_harness.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#if defined(__linux__) || defined(__APPLE__)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <uv.h>

#define CERTS "tests/fixtures/tls/"

static agc_vm vm;

/* The values the test keeps between steps live here, where the collector sees them. */
static agc_value listener, socket_v;

#define on_thread agc_test_on_thread

typedef struct {
  const char *name;
  uint32_t arity;
  agc_value args[4];
  agc_value result;
  bool parked;
} calling;

/* Calls the builtin as a scheduler does. A call made while the task is parked (a close beside a waiting read) leaves
   the task as it is, as a second task's call would. */
static void call_builtin(void *arg) {
  calling *c = arg;
  const agc_builtin *b = agc_find_builtin((const uint8_t *)c->name, strlen(c->name), c->arity);
  assert(b);
  bool beside = vm.task->parked != NULL;
  if (!beside) atomic_store(&vm.task->state, AGC_TASK_RUNNING);
  c->result = b->fn(&vm, c->args, 0);
  c->parked = !beside && vm.task->parked != NULL;
  if (c->parked) {
    assert(vm.task->parking);
    vm.task->parking = false;
    assert(agc_task_commit_park(vm.task));
  }
}

static calling call(const char *name, uint32_t arity, agc_value a, agc_value b, agc_value c, agc_value d) {
  calling made;
  memset(&made, 0, sizeof made);
  made.name = name;
  made.arity = arity;
  made.args[0] = a;
  made.args[1] = b;
  made.args[2] = c;
  made.args[3] = d;
  return made;
}

/* Starts NAME on the scheduler thread; true when the task parked on a job (the START is in the inbox). */
static bool start(calling *c) {
  on_thread(call_builtin, c);
  return c->parked;
}

static void take_on_thread(void *arg) {
  calling *c = arg;
  atomic_store(&vm.task->state, AGC_TASK_RUNNING);
  c->result = agc_io_finish(&vm, vm.task);
  assert(!vm.task->parked);
}

static void wait_woken(void) {
  while (vm.task->state == AGC_TASK_PARKED) assert(agc_io_poll(&vm, true));
  while (agc_runq_pop(vm.rt->runq)) {}
}

/* The task, resumed on the scheduler thread, ends its job there: the `done` half runs on that thread. */
static agc_value take(calling *c) {
  on_thread(take_on_thread, c);
  return c->result;
}

/* A whole call: start, run the loop until the task wakes, and take the result. */
static agc_value step(calling c) {
  if (!start(&c)) return c.result;
  wait_woken();
  return take(&c);
}

static agc_value text(const char *s) { return agc_string_value(agc_make_string(s, strlen(s), strlen(s))); }

static agc_value ok_of(agc_value v) {
  agc_result *r = agc_as_result(&vm, v);
  assert(r->ok);
  return r->value;
}

static bool error_is(agc_value v, const char *message) {
  agc_result *r = agc_as_result(&vm, v);
  if (r->ok) return false;
  const agc_string *s = agc_as_string(&vm, r->value);
  return s->bytes == strlen(message) && memcmp(s->data, message, s->bytes) == 0;
}

static void wait_ms(uint64_t ms) {
  uint64_t due = agc_clock_ms() + ms;
  while (agc_clock_ms() < due) {}
}

static int raw_connect(int64_t port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  assert(fd >= 0);
  struct sockaddr_in a = {0};
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  assert(inet_pton(AF_INET, "127.0.0.1", &a.sin_addr) == 1);
  assert(connect(fd, (struct sockaddr *)&a, sizeof a) == 0);
  return fd;
}

/* A plain listener that accepts nothing: the kernel completes the TCP handshake, and nobody answers on it. */
static int raw_listen(int64_t *port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  assert(fd >= 0);
  struct sockaddr_in a = {0};
  a.sin_family = AF_INET;
  assert(inet_pton(AF_INET, "127.0.0.1", &a.sin_addr) == 1);
  assert(bind(fd, (struct sockaddr *)&a, sizeof a) == 0 && listen(fd, 8) == 0);
  socklen_t len = sizeof a;
  assert(getsockname(fd, (struct sockaddr *)&a, &len) == 0);
  *port = ntohs(a.sin_port);
  return fd;
}

/* Runs the loop until the peer FD reads the end of input: the VM closed its side. */
static void wait_eof(int fd) {
  char buf[64];
  for (;;) {
    struct pollfd p = {fd, POLLIN, 0};
    if (poll(&p, 1, 0) > 0) {
      ssize_t got = recv(fd, buf, sizeof buf, 0);
      if (got == 0) return;
      assert(got > 0);
    }
    (void)agc_io_poll(&vm, false);
  }
}

/* A VM listener and one accepted socket (socket_v) whose peer is the returned descriptor. */
static int open_pair(void) {
  assert(agc_io_share(&vm, false));
  listener = ok_of(step(call("TCP.listen", 2, text("127.0.0.1"), agc_int(0), agc_void(), agc_void())));
  int fd = raw_connect(agc_as_listener(&vm, listener)->port);
  socket_v = ok_of(step(call("TCP.accept", 2, listener, agc_int(5000), agc_void(), agc_void())));
  return fd;
}

static void close_pair(int fd) {
  step(call("TCP.close", 1, socket_v, agc_void(), agc_void(), agc_void()));
  step(call("TCP.close_listener", 1, listener, agc_void(), agc_void(), agc_void()));
  close(fd);
  agc_test_pump_until_idle(&vm);
  agc_test_settle_loop(&vm);
}

/* A read's START waits in the inbox when a second scheduler closes the socket, so the RELEASE is queued behind it.
   The START links the read and starts reading; the RELEASE then shuts the socket, which ends the read with the closed
   error and frees the socket once. The peer reads the end of input. */
static void test_close_queued_behind_a_read(void) {
  int fd = open_pair();
  calling reading = call("TCP.read_line", 2, socket_v, agc_int(60000), agc_void(), agc_void());
  assert(start(&reading));
  calling close_call = call("TCP.close", 1, socket_v, agc_void(), agc_void(), agc_void());
  on_thread(call_builtin, &close_call);
  assert(!close_call.parked);
  wait_woken();
  assert(error_is(take(&reading), "network: socket is closed"));
  wait_eof(fd);
  step(call("TCP.close_listener", 1, listener, agc_void(), agc_void(), agc_void()));
  close(fd);
  agc_test_pump_until_idle(&vm);
  agc_test_settle_loop(&vm);
}

/* The read's deadline passes before any byte: the timer's `pause` takes the read out of its slot and shuts the socket
   before EXPIRED is published. Bytes that come after it reach no request, the task takes the timeout, and the socket is
   closed for the next read. */
static void test_deadline_before_the_bytes(void) {
  int fd = open_pair();
  calling reading = call("TCP.read_line", 2, socket_v, agc_int(5), agc_void(), agc_void());
  assert(start(&reading));
  wait_woken();
  assert(send(fd, "late\n", 5, 0) == 5);
  for (int k = 0; k < 10; k++) (void)agc_io_poll(&vm, false);
  assert(error_is(take(&reading), "network: operation timed out"));
  agc_value again = step(call("TCP.read_line", 2, socket_v, agc_int(1000), agc_void(), agc_void()));
  assert(error_is(again, "network: socket is closed"));
  close_pair(fd);
}

/* The bytes come first: the read ends DONE with the line, its deadline then passes before the task runs and changes
   nothing, and no job timer is left. */
static void test_bytes_before_the_deadline(void) {
  int fd = open_pair();
  calling reading = call("TCP.read_line", 2, socket_v, agc_int(200), agc_void(), agc_void());
  assert(start(&reading));
  assert(send(fd, "early\n", 6, 0) == 6);
  wait_woken();
  wait_ms(250);
  (void)agc_io_poll(&vm, false);
  agc_value line = ok_of(take(&reading));
  const agc_string *s = agc_as_string(&vm, line);
  assert(s->bytes == 5 && memcmp(s->data, "early", 5) == 0);
  (void)agc_io_poll(&vm, false);
  assert(agc_test_armed_timers(&vm) == 0);
  close_pair(fd);
}

static void service_on_thread(void *arg) {
  (void)arg;
  agc_test_service(&vm);
}

static void detach_task(void *arg) {
  (void)arg;
  atomic_store(&vm.task->state, AGC_TASK_RUNNING);
  agc_io_detach(&vm, vm.task);
}

/* A task parked in accept is cancelled (detached); a peer then connects. The I/O thread accepts and makes the child
   socket, the job ends DONE and goes to a scheduler, whose `done` adopts the child into a socket value that is
   discarded and closed: the peer reads the end of input. The listener stays open and accepts the next peer. */
static void test_served_accept_of_a_cancelled_task(void) {
  assert(agc_io_share(&vm, false));
  agc_runq_share(vm.rt->runq);
  listener = ok_of(step(call("TCP.listen", 2, text("127.0.0.1"), agc_int(0), agc_void(), agc_void())));
  calling accepting = call("TCP.accept", 2, listener, agc_int(60000), agc_void(), agc_void());
  assert(start(&accepting));
  (void)agc_io_poll(&vm, false);
  on_thread(detach_task, NULL);
  int fd = raw_connect(agc_as_listener(&vm, listener)->port);
  agc_test_wait_for_hand_over(&vm);
  on_thread(service_on_thread, NULL);
  wait_eof(fd);
  close(fd);
  fd = raw_connect(agc_as_listener(&vm, listener)->port);
  socket_v = ok_of(step(call("TCP.accept", 2, listener, agc_int(5000), agc_void(), agc_void())));
  close_pair(fd);
}

static void close_owned(void *arg) {
  (void)arg;
  agc_close_owned(&vm, vm.task);
}

/* A TLS connect reaches a peer that never answers the handshake; its task is cancelled, then the deadline passes. A
   scheduler finds the job busy and posts its cancel; the I/O thread runs `cancel` (the request leaves its slot and the
   socket is shut, no resource touched), the job comes back dropping and a scheduler ends it with `drop`, which runs on
   the I/O thread. The owner's end then closes the socket resource, and the peer reads the end of input. */
static void test_cancelled_tls_connect_past_its_deadline(void) {
  assert(agc_io_share(&vm, false));
  agc_runq_share(vm.rt->runq);
  int64_t port = 0;
  int silent = raw_listen(&port);
  calling dial = call("TLS.connect", 4, text("127.0.0.1"), agc_int(port), text(CERTS "ca.pem"), agc_int(1000));
  assert(start(&dial));
  /* The loop runs the setup and the connect until the peer has the connection; the deadline is far enough off. */
  struct pollfd p = {silent, POLLIN, 0};
  while (poll(&p, 1, 0) == 0) (void)agc_io_poll(&vm, false);
  int peer = accept(silent, NULL, NULL);
  assert(peer >= 0);
  on_thread(detach_task, NULL);
  agc_test_wait_for_hand_over(&vm);
  on_thread(service_on_thread, NULL);
  agc_test_wait_for_hand_over(&vm);
  on_thread(service_on_thread, NULL);
  on_thread(close_owned, NULL);
  wait_eof(peer);
  close(peer);
  close(silent);
  agc_test_pump_until_idle(&vm);
  agc_test_settle_loop(&vm);
}

/* HttpWire.connect_tls on a client whose options are a one-field struct, as bytecode that skips HttpWire.service's
   check could make: an error result, not a read past the struct. */
static void test_connect_tls_with_short_client_options(void) {
  agc_struct *options = agc_new_struct(0, 1);
  options->fields[0] = agc_int(1);
  agc_http_client *c = agc_alloc(sizeof *c);
  c->options = agc_struct_value(options);
  socket_v = agc_http_client_value(c);
  calling dial = call("HttpWire.connect_tls", 4, socket_v, text("127.0.0.1"), agc_int(443), agc_int(1000));
  assert(!start(&dial));
  assert(error_is(dial.result, "http: invalid client options"));
  assert(!c->tls);
  socket_v = agc_nil();
}
#endif

int main(void) {
#if defined(__linux__) || defined(__APPLE__)
  agc_test_deadline(120);
  agc_init();
  agc_gc_allow_threads();
  agc_io_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_close_queued_behind_a_read();
  test_deadline_before_the_bytes();
  test_bytes_before_the_deadline();
  test_served_accept_of_a_cancelled_task();
  test_cancelled_tls_connect_past_its_deadline();
  test_connect_tls_with_short_client_options();
#endif
  puts("net tests passed");
  return 0;
}
