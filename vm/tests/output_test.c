#include "../core.h"

#include <assert.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef __linux__

#define CAP AGC_OUTPUT_BUFFER
#define BLOCK ((size_t)16384)

static agc_vm vm;
static int pipe_fds[2];
static uint8_t collected[1 << 20];
static size_t collected_len;
static uint8_t letters[1 << 19];

static agc_output *out(void) { return &vm.rt->out; }

static agc_task *make_task(void) {
  agc_task *t = agc_alloc(sizeof(agc_task));
  t->state = AGC_TASK_RUNNING;
  return t;
}

static void fresh(int fd) {
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  agc_output_open(&vm, out(), fd);
}

static void finish(void) { assert(agc_io_close(&vm)); }

static void open_pipe(void) {
  assert(pipe(pipe_fds) == 0);
  assert(fcntl(pipe_fds[0], F_SETFL, O_NONBLOCK) == 0);
  collected_len = 0;
}

static void close_pipe(void) {
  close(pipe_fds[0]);
  close(pipe_fds[1]);
}

static size_t block_pipe(void) {
  int flags = fcntl(pipe_fds[1], F_GETFL);
  assert(fcntl(pipe_fds[1], F_SETFL, flags | O_NONBLOCK) == 0);
  static const char junk[1024] = {0};
  size_t total = 0;
  for (;;) {
    ssize_t n = write(pipe_fds[1], junk, sizeof junk);
    if (n < 0) break;
    total += (size_t)n;
  }
  assert(fcntl(pipe_fds[1], F_SETFL, flags) == 0);
  return total;
}

static size_t read_pipe(void) {
  size_t before = collected_len;
  for (;;) {
    ssize_t n = read(pipe_fds[0], collected + collected_len, sizeof collected - collected_len);
    if (n <= 0) break;
    collected_len += (size_t)n;
  }
  return collected_len - before;
}

static bool write_as(agc_task *t, char letter, size_t len, bool newline) {
  memset(letters, letter, len);
  vm.task = t;
  t->state = AGC_TASK_RUNNING;
  t->parking = t->retry = false;
  bool done = agc_write(&vm, out(), letters, len, newline);
  assert(done == !t->parking);
  if (t->parking) {
    assert(t->retry);
    t->parking = false;
    t->state = AGC_TASK_PARKED;
  }
  return done;
}

static bool drain_as(agc_task *t) {
  vm.task = t;
  t->state = AGC_TASK_RUNNING;
  t->parking = t->retry = false;
  bool done = agc_drain(&vm, out());
  assert(done == !t->parking);
  if (t->parking) {
    t->parking = false;
    t->state = AGC_TASK_PARKED;
  }
  return done;
}

static bool retry(agc_task *t, size_t len, bool newline) {
  assert(t->state == AGC_TASK_READY && t->output.out == out());
  return write_as(t, 'x', len, newline);
}

static void check_run(size_t at, char letter, size_t len) {
  assert(at + len <= collected_len);
  for (size_t k = 0; k < len; k++) assert(collected[at + k] == (uint8_t)letter);
}

static void pump(void) {
  agc_io_poll(&vm, false);
  read_pipe();
}

static void pump_until(size_t want) {
  for (int round = 0; round < 100 && collected_len < want; round++) pump();
  assert(collected_len == want);
}

static void test_small_prints_keep_order(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  assert(out()->fd >= 0 && out()->poller && !out()->pooled);
  agc_task *a = make_task();
  assert(write_as(a, 'a', 5, true));
  assert(write_as(a, 'b', 3, false));
  assert(out()->len == 9 && read_pipe() == 0);
  pump();
  assert(collected_len == 9 && memcmp(collected, "aaaaa\nbbb", 9) == 0 && out()->len == 0);
  finish();
  close_pipe();
}

static void test_waiters_do_not_jump_the_queue(void) {
  open_pipe();
  size_t junk = block_pipe();
  fresh(pipe_fds[1]);
  agc_task *a = make_task(), *b = make_task(), *c = make_task();
  for (int k = 0; k < 3; k++) assert(write_as(a, 'a', 16384, false));
  assert(!write_as(b, 'b', 32768, false));
  assert(!write_as(c, 'c', 1, false));
  assert(out()->waiters == b && b->wait_next == c && out()->len == 3 * BLOCK);
  agc_io_poll(&vm, false);
  assert(b->state == AGC_TASK_PARKED && out()->len == 3 * BLOCK);
  assert(read_pipe() == junk);
  agc_io_poll(&vm, false);
  assert(b->state == AGC_TASK_READY && c->state == AGC_TASK_PARKED && out()->len == 0);
  assert(retry(b, 0, false));
  assert(c->state == AGC_TASK_READY && out()->waiters == c);
  assert(retry(c, 0, false));
  assert(!out()->waiters && !b->output.out && !c->output.out);
  pump_until(junk + 3 * BLOCK + 32768 + 1);
  check_run(junk, 'a', 3 * BLOCK);
  check_run(junk + 3 * BLOCK, 'b', 32768);
  check_run(junk + 3 * BLOCK + 32768, 'c', 1);
  finish();
  close_pipe();
}

static void test_the_buffer_wraps(void) {
  open_pipe();
  size_t junk = block_pipe();
  static uint8_t scratch[16384];
  assert(read(pipe_fds[0], scratch, sizeof scratch) == (ssize_t)sizeof scratch);
  fresh(pipe_fds[1]);
  agc_task *a = make_task();
  assert(write_as(a, 'a', 60000, false));
  agc_io_poll(&vm, false);
  size_t accepted = 60000 - out()->len;
  assert(accepted >= 1000 && out()->start == accepted);
  assert(write_as(a, 'b', CAP - 60000 + 1000, false));
  assert((out()->start + out()->len) % CAP < out()->start);
  size_t before = junk - sizeof scratch;
  pump_until(before + 60000 + CAP - 60000 + 1000);
  check_run(before, 'a', 60000);
  check_run(before + 60000, 'b', CAP - 60000 + 1000);
  finish();
  close_pipe();
}

static void test_long_print_holds_the_stream(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  agc_task *l = make_task(), *m = make_task();
  const size_t big = 3 * CAP + 1000;
  assert(!write_as(l, 'l', big, false));
  assert(out()->len == CAP && l->output.done == CAP);
  assert(!write_as(m, 'm', 4, false));
  assert(out()->waiters == l && l->wait_next == m);
  bool l_done = false, m_done = false;
  for (int round = 0; round < 100 && !(l_done && m_done); round++) {
    pump();
    if (!l_done && l->state == AGC_TASK_READY) l_done = retry(l, 0, false);
    if (!m_done && m->state == AGC_TASK_READY) {
      assert(l_done);
      m_done = retry(m, 0, false);
    }
  }
  assert(l_done && m_done);
  pump();
  assert(collected_len == big + 4);
  check_run(0, 'l', big);
  check_run(big, 'm', 4);
  finish();
  close_pipe();
}

static void test_flush_waits_for_an_empty_buffer(void) {
  open_pipe();
  size_t junk = block_pipe();
  fresh(pipe_fds[1]);
  agc_task *a = make_task(), *d = make_task();
  assert(write_as(a, 'a', 100, false));
  assert(!drain_as(d));
  assert(out()->waiters == d && d->output.flush);
  agc_io_poll(&vm, false);
  assert(d->state == AGC_TASK_PARKED);
  assert(read_pipe() == junk);
  agc_io_poll(&vm, false);
  assert(d->state == AGC_TASK_READY);
  assert(drain_as(d) && !out()->waiters && !d->output.out);
  pump();
  assert(collected_len == junk + 100);
  assert(drain_as(d));
  finish();
  close_pipe();
}

static void test_a_leaving_head_hands_on(void) {
  open_pipe();
  size_t junk = block_pipe();
  fresh(pipe_fds[1]);
  agc_task *a = make_task(), *b = make_task(), *c = make_task();
  assert(write_as(a, 'a', CAP, false));
  assert(!write_as(b, 'b', 10, false));
  assert(!write_as(c, 'c', 10, false));
  agc_output_leave(&vm, b);
  assert(out()->waiters == c && !b->output.out && b->wait_next == NULL);
  assert(read_pipe() == junk);
  pump();
  pump();
  assert(c->state == AGC_TASK_READY);
  assert(retry(c, 0, false));
  pump();
  assert(collected_len == junk + CAP + 10);
  check_run(junk, 'a', CAP);
  check_run(junk + CAP, 'c', 10);
  finish();
  close_pipe();
}

static void test_a_reader_that_left(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  agc_task *a = make_task(), *b = make_task();
  assert(write_as(a, 'a', 10, false));
  assert(!write_as(b, 'b', CAP, false));
  close(pipe_fds[0]);
  agc_io_poll(&vm, false);
  assert(out()->failed && b->state == AGC_TASK_READY && out()->len == 0);
  vm.task = b;
  b->state = AGC_TASK_RUNNING;
  if (setjmp(vm.fail) == 0) {
    agc_write(&vm, out(), NULL, 0, false);
    assert(false);
  }
  assert(strcmp(vm.rt->outcome.code, "RUNTIME-INTERNAL") == 0);
  assert(!out()->waiters && !b->output.out);
  vm.task = a;
  if (setjmp(vm.fail) == 0) {
    agc_write(&vm, out(), "x", 1, false);
    assert(false);
  }
  finish();
  close(pipe_fds[1]);
}

static void test_a_file_is_drained_by_the_pool(void) {
  char path[] = "/tmp/agc-output-XXXXXX";
  int fd = mkstemp(path);
  assert(fd >= 0);
  fresh(fd);
  assert(out()->pooled && !out()->poller && out()->fd == fd);
  agc_task *a = make_task();
  assert(write_as(a, 'a', 40000, false));
  while (out()->len || out()->writing) agc_io_poll(&vm, true);
  assert(write_as(a, 'b', 40000, true));
  assert(write_as(a, 'c', 20000, false));
  agc_io_flush_files(&vm);
  assert(out()->len == 0);
  size_t want = 40000 + 40001 + 20000;
  uint8_t *data = malloc(want + 1);
  assert(data && pread(fd, data, want + 1, 0) == (ssize_t)want);
  for (size_t k = 0; k < want; k++) assert(data[k] == (k < 40000 ? 'a' : k < 80000 ? 'b' : k == 80000 ? '\n' : 'c'));
  free(data);
  finish();
  close(fd);
  unlink(path);
}

static void test_a_device_that_never_waits_is_pooled(void) {
  int fd = open("/dev/null", O_WRONLY);
  assert(fd >= 0);
  fresh(fd);
  assert(out()->pooled && !out()->poller && out()->fd == fd);
  assert(write_as(make_task(), 'a', 10, true));
  agc_io_flush_files(&vm);
  assert(out()->len == 0 && !out()->failed);
  finish();
  close(fd);
}

static void test_other_descriptors_keep_the_blocking_write(void) {
  int pair[2];
  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
  fresh(pair[1]);
  assert(out()->fd < 0 && !out()->buf);
  finish();
  int readonly = open("/dev/null", O_RDONLY);
  assert(readonly >= 0);
  fresh(readonly);
  assert(out()->fd < 0);
  finish();
  close(readonly);
  close(pair[0]);
  close(pair[1]);
}

static void test_notices_are_dropped_when_they_do_not_fit(void) {
  open_pipe();
  size_t junk = block_pipe();
  fresh(pipe_fds[1]);
  assert(write_as(make_task(), 'a', CAP - 6, false));
  agc_notice n;
  fputs("too long to fit", agc_notice_begin(out(), &n));
  agc_notice_end(&n, false);
  assert(out()->len == CAP - 6);
  fputs("fits\n", agc_notice_begin(out(), &n));
  agc_notice_end(&n, false);
  assert(out()->len == CAP - 1);
  assert(read_pipe() == junk);
  pump();
  assert(collected_len == junk + CAP - 1 && memcmp(collected + junk + CAP - 6, "fits\n", 5) == 0);
  finish();
  close_pipe();
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  agc_init();
  agc_io_init();
  test_small_prints_keep_order();
  test_waiters_do_not_jump_the_queue();
  test_the_buffer_wraps();
  test_long_print_holds_the_stream();
  test_flush_waits_for_an_empty_buffer();
  test_a_leaving_head_hands_on();
  test_a_reader_that_left();
  test_a_file_is_drained_by_the_pool();
  test_a_device_that_never_waits_is_pooled();
  test_other_descriptors_keep_the_blocking_write();
  test_notices_are_dropped_when_they_do_not_fit();
  puts("output tests passed");
  return 0;
}
#else
int main(void) {
  puts("output tests passed");
  return 0;
}
#endif
