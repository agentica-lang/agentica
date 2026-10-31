/*
 * TCP and TLS builtins called on a scheduler thread while the test's thread is the I/O thread (§16.9), against a POSIX
 * peer, in orders set by the calls: a close behind a read's START, the deadline before and after the bytes, an accept
 * and a read cancelled before anything came, a served accept of a cancelled task, a cancelled TLS connect past its
 * deadline, and HttpWire.connect_tls on bad options. `make vm-tsan` runs it under TSan.
 */
#include "../core.h"
#include "../tls.h"
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

typedef agc_test_call calling;

static calling call(const char *name, uint32_t arity, agc_value a, agc_value b, agc_value c, agc_value d) {
  return agc_test_call_of(&vm, vm.task, name, arity, a, b, c, d);
}

#define call_builtin agc_test_call_builtin
#define start agc_test_start
#define take agc_test_take

static void wait_woken(void) { agc_test_wait_woken(&vm, vm.task); }

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

/* n bytes at data as a Bytes. */
static agc_value byte_arg(const char *data, size_t n) {
  return agc_bytes_value(agc_make_bytes((const uint8_t *)data, n));
}

/* A read's bytes are the n bytes at data. */
static void read_is(agc_value v, const char *data, size_t n) {
  assert(v.tag == AGC_T_BYTES && agc_equal(&vm, v, byte_arg(data, n), 0));
}

static void peer_reads(int fd, const char *data, size_t n) {
  char got[16];
  size_t have = 0;
  assert(n <= sizeof got);
  while (have < n) {
    ssize_t r = recv(fd, got + have, n - have, 0);
    assert(r > 0);
    have += (size_t)r;
  }
  assert(memcmp(got, data, n) == 0);
}

/* TCP.send_bytes and TCP.recv_bytes on Bytes, on the posted path (the I/O thread cuts the read, the done half builds
   its value), and HttpWire.idle?, which takes no byte. A send of more than 1 MiB is refused. */
static void test_byte_keys(void) {
  int fd = open_pair();
  static const char sent[] = "\x00\xff" "a\n";
  ok_of(step(call("TCP.send_bytes.bytes", 3, socket_v, byte_arg(sent, 4), agc_int(5000), agc_void())));
  peer_reads(fd, sent, 4);
  /* Nothing is buffered yet and the input has not ended. */
  assert(agc_as_bool(&vm, ok_of(step(call("HttpWire.idle?", 2, socket_v, agc_int(5000), agc_void(), agc_void())))));
  assert(send(fd, sent, 4, 0) == 4);
  read_is(ok_of(step(call("TCP.recv_bytes.bytes", 3, socket_v, agc_int(4), agc_int(5000), agc_void()))), sent, 4);
  agc_bytes *big = agc_new_bytes(1048577);
  memset(big->data, 0, big->len);
  assert(error_is(step(call("TCP.send_bytes.bytes", 3, socket_v, agc_bytes_value(big), agc_int(5000), agc_void())),
                  "network: bytes exceed 1048576 per call"));
  /* The end of input: no bytes, and the socket is no longer idle. */
  assert(shutdown(fd, SHUT_WR) == 0);
  read_is(ok_of(step(call("TCP.recv_bytes.bytes", 3, socket_v, agc_int(4), agc_int(5000), agc_void()))), "", 0);
  assert(!agc_as_bool(&vm, ok_of(step(call("HttpWire.idle?", 2, socket_v, agc_int(5000), agc_void(), agc_void())))));
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

/* The detached job is handed to a scheduler, which ends it: dropped, or its `done` half run and the result dropped. */
static void end_detached_job(void) {
  agc_test_wait_for_hand_over(&vm);
  on_thread(service_on_thread, NULL);
}

/* The line the peer FD sends is read back on socket_v: the bytes reached a live read. */
static void check_line_arrives(int fd) {
  assert(send(fd, "kept\n", 5, 0) == 5);
  agc_value line = ok_of(step(call("TCP.read_line", 2, socket_v, agc_int(5000), agc_void(), agc_void())));
  const agc_string *s = agc_as_string(&vm, line);
  assert(s->bytes == 4 && memcmp(s->data, "kept", 4) == 0);
}

/* A listener on the shared loop, and the task parked in an accept on it with a far deadline. */
static void start_accept(void) {
  assert(agc_io_share(&vm, false));
  agc_runq_share(vm.rt->runq);
  listener = ok_of(step(call("TCP.listen", 2, text("127.0.0.1"), agc_int(0), agc_void(), agc_void())));
  calling accepting = call("TCP.accept", 2, listener, agc_int(60000), agc_void(), agc_void());
  assert(start(&accepting));
}

/* A task parked in accept is cancelled (detached) before any peer connects. The cancel half on the I/O thread takes
   the accept out of the listener's queue at once (#403), so the job is dropped without waiting for its deadline, and
   the peer that connects next is served by the next live accept, not closed by the dead one. */
static void test_cancelled_accept_leaves_the_queue(void) {
  start_accept();
  (void)agc_io_poll(&vm, false);
  on_thread(detach_task, NULL);
  end_detached_job();
  int fd = raw_connect(agc_as_listener(&vm, listener)->port);
  socket_v = ok_of(step(call("TCP.accept", 2, listener, agc_int(5000), agc_void(), agc_void())));
  check_line_arrives(fd);
  close_pair(fd);
}

/* A peer connects and the accept is served (the I/O thread made the child socket) before its task is cancelled. The
   request has taken the connection, so the cancel leaves it: a scheduler runs `done`, which adopts the child into a
   socket value that is discarded and closed, and the peer reads the end of input. The listener stays open and
   accepts the next peer. */
static void test_served_accept_of_a_cancelled_task(void) {
  start_accept();
  int fd = raw_connect(agc_as_listener(&vm, listener)->port);
  wait_woken();
  on_thread(detach_task, NULL);
  end_detached_job();
  wait_eof(fd);
  close(fd);
  fd = raw_connect(agc_as_listener(&vm, listener)->port);
  socket_v = ok_of(step(call("TCP.accept", 2, listener, agc_int(5000), agc_void(), agc_void())));
  close_pair(fd);
}

/* A task parked in read_line is cancelled before any byte comes. The read leaves the reader slot at once (#403) and
   its job's end hands the reader lock on, so the next read takes the line that arrives later: no byte is lost. */
static void test_cancelled_read_leaves_the_reader_slot(void) {
  int fd = open_pair();
  agc_runq_share(vm.rt->runq);
  calling reading = call("TCP.read_line", 2, socket_v, agc_int(60000), agc_void(), agc_void());
  assert(start(&reading));
  (void)agc_io_poll(&vm, false);
  on_thread(detach_task, NULL);
  end_detached_job();
  check_line_arrives(fd);
  close_pair(fd);
}

static void close_owned(void *arg) {
  (void)arg;
  agc_close_owned(&vm, vm.task);
}

static void release_config(void *config) { agc_tls_config_free(config); }

/* A TLS connect reaches a peer that never answers the handshake; its task is cancelled, then the deadline passes. A
   scheduler finds the job busy and posts its cancel; the I/O thread runs `cancel` (the request leaves its slot and the
   socket is shut, no resource touched), the job comes back dropping and a scheduler ends it with `drop`, which runs on
   the I/O thread. The owner's end then closes the socket resource, and the peer reads the end of input. With STD the
   connect is std/http's name for it, HttpWire.connect_context. */
static void test_cancelled_tls_connect_past_its_deadline(bool std) {
  assert(agc_io_share(&vm, false));
  agc_runq_share(vm.rt->runq);
  int64_t port = 0;
  int silent = raw_listen(&port);
  agc_tls_failure f;
  agc_tls_config *config = agc_tls_client_config(CERTS "ca.pem", NULL, NULL, &f);
  assert(config);
  agc_value tls = agc_tls_context_value(config, release_config, false);
  calling dial = call(std ? "HttpWire.connect_context" : "TLS.connect", 4, text("127.0.0.1"), agc_int(port), tls,
                      agc_int(1000));
  assert(start(&dial));
  /* The loop runs the connect until the peer has the connection; the deadline is far enough off. */
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
#endif

int main(void) {
#if defined(__linux__) || defined(__APPLE__)
  agc_test_deadline(120);
  agc_test_io_vm(&vm);
  test_close_queued_behind_a_read();
  test_deadline_before_the_bytes();
  test_bytes_before_the_deadline();
  test_cancelled_accept_leaves_the_queue();
  test_served_accept_of_a_cancelled_task();
  test_cancelled_read_leaves_the_reader_slot();
  test_cancelled_tls_connect_past_its_deadline(false);
  test_cancelled_tls_connect_past_its_deadline(true);
  test_byte_keys();
#endif
  puts("net tests passed");
  return 0;
}
