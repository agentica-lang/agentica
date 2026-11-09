/*
 * TCP and TLS builtins called on a scheduler thread while the test's thread is the I/O thread (§16.9), against a POSIX
 * peer: a close behind a read's START, deadlines before and after the bytes, cancelled accepts and reads, a cancelled
 * TLS connect, HttpWire.connect_tls on bad options, and the direct send (a close beside it included). Under TSan too.
 */
#include "../core.h"
#include "../tls.h"
#include "io_harness.h"
#include "test_program.h"
#include "test_support.h"

#include <assert.h>
#include <errno.h>
#include <setjmp.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__) || defined(__APPLE__)
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <uv.h>
/* mallinfo2 is glibc 2.33; the release build links against glibc 2.28 (release.yml), where the count is
   skipped. */
#if defined(__GLIBC__) && !defined(AGC_NO_GC) && (__GLIBC__ > 2 || __GLIBC_MINOR__ >= 33)
#include <malloc.h>
#define MALLOC_COUNT 1
#endif

#define CERTS "tests/fixtures/tls/"

static agc_vm vm;

/* The values the test keeps between steps live here, where the collector sees them. */
static agc_value listener, socket_v;

#define on_thread agc_test_on_thread

typedef agc_test_call calling;

/* A builtin call of TASK on the scheduler context CTX, for the cases that run with every lock on (agc_share). */
typedef struct {
  agc_vm *ctx;
  agc_task *task;
  calling c;
} locked_call;

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

/* A String of LEN bytes whose byte k is 'a' + k % 23, so a lost, repeated or moved byte shows. */
static agc_value pattern(size_t len) {
  agc_string *s = agc_new_string(len, len);
  for (size_t k = 0; k < len; k++) s->data[k] = (char)('a' + k % 23);
  return agc_string_value(s);
}

/* Reads what the peer FD has now, without waiting (poll, since MSG_DONTWAIT is not POSIX), and checks it against the
   pattern from *AT on. */
static void peer_drains(int fd, size_t *at) {
  char buf[65536];
  for (;;) {
    struct pollfd p = {fd, POLLIN, 0};
    if (poll(&p, 1, 0) <= 0) return;
    ssize_t got = recv(fd, buf, sizeof buf, 0);
    if (got <= 0) return;
    for (ssize_t k = 0; k < got; k++) assert(buf[k] == (char)('a' + (*at + (size_t)k) % 23));
    *at += (size_t)got;
  }
}

/* At N > 1 a send that the kernel takes at once goes out from the scheduler (#1188): the call returns without a park
   and the peer reads the bytes while the loop does not run. */
static void test_a_send_goes_out_from_the_scheduler(void) {
  int fd = open_pair();
  calling sending = call("TCP.send", 3, socket_v, text("direct\n"), agc_int(5000), agc_void());
  assert(!start(&sending));
  ok_of(sending.result);
  peer_reads(fd, "direct\n", 7);
  close_pair(fd);
}

/* A send larger than the kernel takes: the scheduler sends what fits, and the I/O thread the rest after it, so the
   peer reads every byte once and in order, and the task wakes when the last one is out. */
static void test_the_rest_of_a_direct_send_goes_to_the_io_thread(void) {
  int fd = open_pair();
  size_t len = (size_t)32 << 20, at = 0;
  calling sending = call("TCP.send", 3, socket_v, pattern(len), agc_int(60000), agc_void());
  assert(start(&sending));
  while (vm.task->state == AGC_TASK_PARKED) {
    (void)agc_io_poll(&vm, false);
    peer_drains(fd, &at);
  }
  while (agc_runq_pop(vm.rt->runq)) {}
  ok_of(take(&sending));
  while (at < len) peer_drains(fd, &at);
  assert(at == len);
  close_pair(fd);
}

/* The VM's end of the connection whose peer is the descriptor PEER: the socket whose remote port is PEER's own. */
static int vm_side(int peer) {
  struct sockaddr_in mine, theirs;
  socklen_t len = sizeof mine;
  assert(getsockname(peer, (struct sockaddr *)&mine, &len) == 0);
  for (int fd = 3; fd < 4096; fd++) {
    len = sizeof theirs;
    if (fd == peer || getpeername(fd, (struct sockaddr *)&theirs, &len) != 0 || theirs.sin_family != AF_INET) continue;
    if (theirs.sin_port == mine.sin_port) return fd;
  }
  assert(!"the VM's socket was not found");
  return -1;
}

static void set_blocking(int fd, bool blocking) {
  int flags = fcntl(fd, F_GETFL);
  assert(flags >= 0 && fcntl(fd, F_SETFL, blocking ? flags & ~O_NONBLOCK : flags | O_NONBLOCK) == 0);
}

/* The zero-byte case needs a send buffer that takes no byte. Only Linux fills it exactly: macOS counts mbufs and a
   low-water mark, so a full buffer may still take a short send. */
#ifdef __linux__
/* Fills the send buffer of the non-blocking descriptor FD with 'z' bytes, down to one byte: their count. */
static size_t fill_send_buffer(int fd) {
  static char junk[65536];
  memset(junk, 'z', sizeof junk);
  size_t sent = 0;
  for (size_t size = sizeof junk; size;) {
    ssize_t n = send(fd, junk, size, 0);
    if (n >= 0) {
      sent += (size_t)n;
      continue;
    }
    assert(errno == EAGAIN || errno == EWOULDBLOCK);
    size /= 2;
  }
  return sent;
}

/* The peer FD reads COUNT 'z' bytes and then TAIL, while the loop runs (the I/O thread writes what is left). */
static void peer_reads_after_junk(int fd, size_t count, const char *tail) {
  size_t want = count + strlen(tail), have = 0;
  char *got = malloc(want);
  assert(got);
  while (have < want) {
    struct pollfd p = {fd, POLLIN, 0};
    if (poll(&p, 1, 0) > 0) {
      ssize_t n = recv(fd, got + have, want - have, 0);
      assert(n > 0);
      have += (size_t)n;
    }
    (void)agc_io_poll(&vm, false);
  }
  for (size_t k = 0; k < count; k++) assert(got[k] == 'z');
  assert(memcmp(got + count, tail, strlen(tail)) == 0);
  free(got);
}
#endif

/* The scheduler's half of the close case: a send larger than the loopback buffers, which blocks in the kernel, beside
   the parked read. */
static calling blocked_send;
static atomic_bool blocked_send_over;

static void send_beside(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  const agc_builtin *b = agc_find_builtin((const uint8_t *)"TCP.send", 8, 3);
  blocked_send.result = b->fn(&vm, blocked_send.args, 0);
  atomic_store(&blocked_send_over, true);
  agc_gc_thread_leave();
}

/* A close that comes while a scheduler is inside its direct send: shut_one leaves the descriptor open, so it is never
   closed (and reused) under the send, and the end of the send closes it. The VM's socket is made blocking so the send
   waits in the kernel until the peer reads; a read with a deadline, parked first, shuts the socket on the I/O thread
   meanwhile, and the descriptor is still open after it. The send still delivers every byte, then the descriptor is
   closed, the peer reads the end of input, and the socket is closed for the next call. The VM is not shared here, so
   rt->sync is not dropped; the last case runs the locked path. */
static void test_a_close_waits_for_a_direct_send(void) {
  int fd = open_pair();
  int mine = vm_side(fd);
  size_t len = (size_t)32 << 20, at = 0;
  calling reading = call("TCP.read_line", 2, socket_v, agc_int(300), agc_void(), agc_void());
  assert(start(&reading));
  set_blocking(mine, true);
  blocked_send = call("TCP.send", 3, socket_v, pattern(len), agc_int(60000), agc_void());
  uv_thread_t sender;
  assert(uv_thread_create(&sender, send_beside, NULL) == 0);
  wait_woken();
  /* The read's deadline shut the socket while the send still waited in the kernel, since the peer has read nothing. */
  assert(!atomic_load(&blocked_send_over));
  assert(fcntl(mine, F_GETFL) >= 0);
  while (at < len) {
    peer_drains(fd, &at);
    (void)agc_io_poll(&vm, false);
  }
  assert(uv_thread_join(&sender) == 0);
  ok_of(blocked_send.result);
  /* The end of the send closed the descriptor (direct_over). */
  wait_eof(fd);
  assert(fcntl(mine, F_GETFL) < 0);
  assert(error_is(take(&reading), "network: operation timed out"));
  agc_value again = step(call("TCP.send", 3, socket_v, text("late\n"), agc_int(1000), agc_void()));
  assert(error_is(again, "network: socket is closed"));
  close_pair(fd);
}

/* Runs a locked_call: TASK on CTX, with rt->sync taken as the interpreter takes it for a shared row. */
static void call_locked(void *arg) {
  locked_call *l = arg;
  l->ctx->task = l->task;
  atomic_store(&l->task->state, AGC_TASK_RUNNING);
  l->task->parking = false;
  const agc_builtin *b = agc_find_builtin((const uint8_t *)l->c.name, strlen(l->c.name), l->c.arity);
  agc_sync_take(l->ctx);
  l->c.result = b->fn(l->ctx, l->c.args, 0);
  agc_sync_drop(l->ctx);
}

/* call_locked, then the park that a scheduler commits at the end of the task's turn, as agc_test_call_builtin does. */
static void park_locked(void *arg) {
  locked_call *l = arg;
  call_locked(l);
  if (!l->task->parked) return;
  assert(l->task->parking);
  l->task->parking = false;
  assert(agc_task_commit_park(l->task));
}

static void send_first(void *arg) {
  assert(agc_gc_thread_enter());
  call_locked(arg);
  agc_gc_thread_leave();
}

static const char *const head_fields[] = {"method",          "target",   "path",   "headers", "length", "chunked",
                                          "expect_continue", "buffered", "status", "reason"};
static const char *const header_fields[] = {"name", "value"};

/* The records that HttpWire.read_head builds, which a loaded program declares. */
static void declare_head_records(void) {
  static agc_struct_def structs[2];
  static agc_program program;
  structs[0] =
      (agc_struct_def){agc_make_string("HttpWire.Head", 13, 13), 10, agc_test_field_names(head_fields, 10), NULL, NULL};
  structs[1] = (agc_struct_def){agc_make_string("Header", 6, 6), 2, agc_test_field_names(header_fields, 2), NULL, NULL};
  program.struct_count = 2;
  program.structs = structs;
  vm.rt->program = &program;
}

/* A send of a second task while the first is inside its direct send waits for the writer lock, which the direct send
   holds although no job does: it posts nothing, so it cannot overtake the rest of the first send, and it goes out
   when the first send ends, after its last byte. Then the same when the kernel takes no byte of the first send: its
   whole text parks on a job that takes the hold over, and the waiting task is not handed the lock between (it would
   then send ahead, and two sends would share the socket's one libuv write); Linux only. It runs last: it turns every
   lock on (agc_share) for good, and calls the builtins with rt->sync as the schedulers do. */
static void test_a_send_waits_for_a_direct_send_of_another_task(void) {
  int fd = open_pair();
  int mine = vm_side(fd);
  size_t len = (size_t)32 << 20, at = 0;
  static agc_vm other;
  agc_vm_init_context(&other, vm.rt);
  /* A task for each case: the harness resumes a woken task without its scheduler, which would take its lock timer. */
  agc_task *second = agc_new_task(&vm);
  agc_resource *writer = agc_as_socket(&vm, socket_v)->writer;
  set_blocking(mine, true);
  agc_share(&vm);
  locked_call first = {&vm, vm.task, call("TCP.send", 3, socket_v, pattern(len), agc_int(60000), agc_void())};
  /* Every call is made before the sender starts: call() reads vm.task, which call_locked sets on the sender's
     thread. */
  locked_call behind = {&other, second, call("TCP.send", 3, socket_v, text("behind\n"), agc_int(60000), agc_void())};
  uv_thread_t sender;
  assert(uv_thread_create(&sender, send_first, &first) == 0);
  struct pollfd p = {fd, POLLIN, 0};
  assert(poll(&p, 1, 60000) == 1);
  on_thread(call_locked, &behind);
  assert(second->lock_wait == writer && second->parked == NULL);
  while (at < len) {
    peer_drains(fd, &at);
    (void)agc_io_poll(&vm, false);
  }
  assert(uv_thread_join(&sender) == 0);
  ok_of(first.c.result);
  while (agc_runq_pop(vm.rt->runq)) {}
  on_thread(call_locked, &behind);
  ok_of(behind.c.result);
  peer_reads(fd, "behind\n", 7);

#ifdef __linux__
  /* A small send buffer of its own, filled until a pause frees no room: the peer's window is shut too, so no byte
     leaves it. The peer's receive buffer is set as well, which stops Linux from growing it and opening the window
     while the send waits. */
  agc_task *third = agc_new_task(&vm);
  int small = 4096;
  assert(setsockopt(mine, SOL_SOCKET, SO_SNDBUF, &small, sizeof small) == 0);
  assert(setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, sizeof small) == 0);
  set_blocking(mine, false);
  size_t junk = 0;
  for (size_t more = 1; more;) {
    more = fill_send_buffer(mine);
    junk += more;
    wait_ms(100);
  }
  set_blocking(mine, true);
  struct timeval give_up = {1, 0};
  assert(setsockopt(mine, SOL_SOCKET, SO_SNDTIMEO, &give_up, sizeof give_up) == 0);
  first.c = call("TCP.send", 3, socket_v, text("first\n"), agc_int(60000), agc_void());
  behind = (locked_call){&other, third, call("TCP.send", 3, socket_v, text("second\n"), agc_int(60000), agc_void())};
  assert(uv_thread_create(&sender, send_first, &first) == 0);
  /* The first send holds the lock: it is inside send(), which gives up after a second. */
  for (bool held = false; !held;) {
    agc_sync_take(&other);
    held = writer->holder == writer;
    agc_sync_drop(&other);
  }
  on_thread(call_locked, &behind);
  assert(third->lock_wait == writer && third->parked == NULL);
  assert(uv_thread_join(&sender) == 0);
  assert(vm.task->parked != NULL && writer->holder == vm.task->parked && writer->next_owner == NULL);
  set_blocking(mine, false);
  peer_reads_after_junk(fd, junk, "first\n");
  wait_woken();
  ok_of(take(&first.c));
  while (agc_runq_pop(vm.rt->runq)) {}
  on_thread(call_locked, &behind);
  ok_of(behind.c.result);
  peer_reads(fd, "second\n", 7);
#endif
  /* A WebSocket upgrade head that HttpWire.read_head lets through: the socket's later sends park for the I/O thread
     although the kernel has room, where test_a_send_goes_out_from_the_scheduler returns at once. */
  const char *upgrade = "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
  assert(send(fd, upgrade, strlen(upgrade), 0) == (ssize_t)strlen(upgrade));
  declare_head_records();
  agc_value rest = agc_bytes_value(agc_make_bytes((const uint8_t *)"", 0));
  /* A task of its own: the harness resumes a woken task without its scheduler, which would take a timer of its last
     park. */
  agc_task *upgraded = agc_new_task(&vm);
  locked_call queued = {&vm, upgraded,
                        agc_test_call_of(&vm, upgraded, "HttpWire.read_head.bytes", 4, socket_v, rest, agc_int(1024),
                                         agc_int(60000))};
  on_thread(park_locked, &queued);
  agc_test_wait_woken(&vm, upgraded);
  ok_of(take(&queued.c));
  queued.c = agc_test_call_of(&vm, upgraded, "TCP.send", 3, socket_v, text("queued\n"), agc_int(60000), agc_void());
  on_thread(park_locked, &queued);
  assert(upgraded->parked != NULL);
  agc_test_wait_woken(&vm, upgraded);
  ok_of(take(&queued.c));
  peer_reads(fd, "queued\n", 7);
  locked_call closing = {&vm, vm.task, call("TCP.close", 1, socket_v, agc_void(), agc_void(), agc_void())};
  on_thread(call_locked, &closing);
  closing.c = call("TCP.close_listener", 1, listener, agc_void(), agc_void(), agc_void());
  on_thread(call_locked, &closing);
  close(fd);
  agc_test_pump_until_idle(&vm);
  agc_test_settle_loop(&vm);
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
   connect is std/http's name for it, HttpWire.connect_context.
   The case waits out the deadline after the cancel, so the deadline is kept short, but the connect must reach the peer
   before it passes: the host is resolved on the libuv pool first, which a loaded runner can hold back, and a deadline
   that passes first ends the connect before it dials, which left the wait below spinning until the alarm (#1174). So
   the deadline leaves room for that, the wait sleeps in poll() instead of spinning, which leaves the core to the pool
   thread, and a task woken before the peer has its connection fails the case at once. */
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
                      agc_int(3000));
  assert(start(&dial));
  struct pollfd p = {silent, POLLIN, 0};
  while (poll(&p, 1, 10) == 0) {
    assert(vm.task->state == AGC_TASK_PARKED);
    (void)agc_io_poll(&vm, false);
  }
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

/* An HttpClient as http_service.c lays it out, with no pool behind it: HttpWire.upgrade_tls only reads its lazy context. */
static agc_value new_client(bool dropped) {
  agc_http_client *c = agc_alloc(sizeof *c);
  memset(c, 0, sizeof *c);
  c->tls_dropped = dropped;
  return agc_http_client_value(c);
}

/* HttpWire.upgrade_tls on a client that gave its context back (HttpWire.drop_tls) is an error before anything is
   touched: the plain socket is still the program's, and a count taken for the call would be lost. */
static void test_upgrade_tls_on_a_dropped_client(void) {
  int fd = open_pair();
  agc_value client = new_client(true);
  agc_value out = step(call("HttpWire.upgrade_tls", 4, client, socket_v, text("localhost"), agc_int(1000)));
  assert(error_is(out, "network: the client is closed"));
  assert(send(fd, "still\n", 6, 0) == 6);
  agc_value line = ok_of(step(call("TCP.read_line", 2, socket_v, agc_int(2000), agc_void(), agc_void())));
  assert(agc_as_string(&vm, line)->bytes == 5);
  close_pair(fd);
}

/* HttpWire.upgrade_context with a server-role context fails at its context argument (span + 2: argument i is at span
   + 1 + i), not at `host`, and before anything is touched. The harness passes span 0, so the builtin is called here
   with a span of its own. */
static void test_upgrade_context_names_its_context_argument(void) {
  agc_tls_failure f;
  agc_tls_config *config = agc_tls_server_config(CERTS "server.pem", CERTS "server-key.pem", &f);
  assert(config);
  agc_value args[4] = {socket_v, agc_tls_context_value(config, release_config, true), text("localhost"), agc_int(1000)};
  const char *name = "HttpWire.upgrade_context";
  const agc_builtin *b = agc_find_builtin((const uint8_t *)name, strlen(name), 4);
  assert(b);
  if (setjmp(vm.fail) == 0) {
    (void)b->fn(&vm, args, 100);
    assert(!"the call did not fail");
  }
  assert(strcmp(vm.outcome->code, "RUNTIME-TLS-CONTEXT-ROLE") == 0);
  assert(vm.outcome->span == 102);
}

/* The code of the failure of NAME (arity 1) on OPTIONS, or "nothing" when it returns. */
static const char *context_fails(const char *name, agc_value options) {
  const agc_builtin *b = agc_find_builtin((const uint8_t *)name, strlen(name), 1);
  assert(b);
  agc_value args[1] = {options};
  if (setjmp(vm.fail) != 0) return vm.outcome->code;
  (void)b->fn(&vm, args, 0);
  return "nothing";
}

/* A TlsClientOptions or TlsServerOptions of N fields: the paths, then an empty alpn list. */
static agc_value tls_options(uint32_t n, agc_value a, agc_value b, agc_value c) {
  agc_struct *s = agc_new_struct(0, n);
  agc_value paths[3] = {a, b, c};
  for (uint32_t k = 0; k + 1 < n; k++) s->fields[k] = paths[k];
  s->fields[n - 1] = agc_list_value(agc_list_from_array(NULL, 0));
  return agc_struct_value(s);
}

/* Hostile bytecode: a path field of the TLS options that is not a String fails with RUNTIME-INTERNAL before the build
   is allocated (#1251), also after a good path that would have been copied into it. With glibc's count of the bytes
   malloc has out (values live on the GC heap, which is not malloc's), a thousand failures grow it by less than 16
   bytes each, where a build alone is more. */
static void test_context_with_a_path_that_is_not_a_string(void) {
  agc_value one = agc_int(1), empty = text(""), path = text(CERTS "ca.pem");
  const char *names[] = {"TLS.client_context", "TLS.client_context", "TLS.client_context", "TLS.server_context"};
  agc_value options[] = {tls_options(4, one, empty, empty), tls_options(4, path, one, empty),
                         tls_options(4, path, path, one), tls_options(3, path, one, empty)};
  for (size_t k = 0; k < 4; k++) {
    assert(strcmp(context_fails(names[k], options[k]), "RUNTIME-INTERNAL") == 0);
#if MALLOC_COUNT
    size_t before = mallinfo2().uordblks;
    for (int n = 0; n < 1000; n++) assert(strcmp(context_fails(names[k], options[k]), "RUNTIME-INTERNAL") == 0);
    assert(mallinfo2().uordblks < before + (size_t)16 * 1000);
#endif
  }
}

/* The first HttpWire.upgrade_tls of a client builds its shared system-trust context (a pool job), waits for it, then
   starts the handshake on the socket it was given: the peer reads a TLS record (0x16, the ClientHello) and closes, the
   call fails, and the client keeps the context until HttpWire.drop_tls gives it back. The call's deadline covers the
   build, which reads the keychain on macOS and can take seconds on a slow runner, so nothing here is timed: the
   deadline is far off, the loop runs until the ClientHello comes, and the peer's close ends the call. A failed build
   wakes the task with nothing sent and the socket open, so the loop checks the task is still parked; a passed
   deadline closes the socket and fails at the recv below. */
static void test_upgrade_tls_builds_the_shared_context_then_handshakes(void) {
  int fd = open_pair();
  agc_value client = new_client(false);
  calling upgrading = call("HttpWire.upgrade_tls", 4, client, socket_v, text("localhost"), agc_int(60000));
  assert(start(&upgrading));
  struct pollfd p = {fd, POLLIN, 0};
  while (poll(&p, 1, 10) <= 0) {
    assert(vm.task->state == AGC_TASK_PARKED);
    (void)agc_io_poll(&vm, false);
  }
  unsigned char first = 0;
  assert(recv(fd, &first, 1, 0) == 1 && first == 0x16);
  close(fd);
  wait_woken();
  assert(!agc_as_result(&vm, take(&upgrading))->ok);
  assert(agc_as_http_client(&vm, client)->tls);
  step(call("HttpWire.drop_tls", 1, client, agc_void(), agc_void(), agc_void()));
  assert(!agc_as_http_client(&vm, client)->tls);
  step(call("TCP.close_listener", 1, listener, agc_void(), agc_void(), agc_void()));
  agc_test_pump_until_idle(&vm);
  agc_test_settle_loop(&vm);
}
#endif

int main(void) {
#if defined(__linux__) || defined(__APPLE__)
  agc_test_deadline(120);
  agc_test_io_vm(&vm);
  AGC_TEST_RUN(test_close_queued_behind_a_read());
  AGC_TEST_RUN(test_deadline_before_the_bytes());
  AGC_TEST_RUN(test_bytes_before_the_deadline());
  AGC_TEST_RUN(test_cancelled_accept_leaves_the_queue());
  AGC_TEST_RUN(test_served_accept_of_a_cancelled_task());
  AGC_TEST_RUN(test_cancelled_read_leaves_the_reader_slot());
  AGC_TEST_RUN(test_cancelled_tls_connect_past_its_deadline(false));
  AGC_TEST_RUN(test_cancelled_tls_connect_past_its_deadline(true));
  AGC_TEST_RUN(test_byte_keys());
  AGC_TEST_RUN(test_a_send_goes_out_from_the_scheduler());
  AGC_TEST_RUN(test_the_rest_of_a_direct_send_goes_to_the_io_thread());
  AGC_TEST_RUN(test_a_close_waits_for_a_direct_send());
  AGC_TEST_RUN(test_upgrade_tls_on_a_dropped_client());
  AGC_TEST_RUN(test_upgrade_context_names_its_context_argument());
  AGC_TEST_RUN(test_context_with_a_path_that_is_not_a_string());
  AGC_TEST_RUN(test_upgrade_tls_builds_the_shared_context_then_handshakes());
  AGC_TEST_RUN(test_a_send_waits_for_a_direct_send_of_another_task());
#endif
  puts("net tests passed");
  return 0;
}
