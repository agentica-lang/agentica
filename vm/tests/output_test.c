/*
 * vm/output.c with hand-made tasks and a pipe: the order of small prints,
 * writers that wait, the ring wrap-around, and agc_drain.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "../core.h"

#include <assert.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <uv.h>

#if defined(__linux__) || defined(__APPLE__)

#define CAP AGC_OUTPUT_BUFFER
#define BLOCK ((size_t)16384)

static agc_vm vm;
static int pipe_fds[2];
static uint8_t collected[1 << 20];
static size_t collected_len;
static char letters[1 << 19];

static agc_output *out(void) { return &vm.rt->out; }

static agc_output *err(void) { return &vm.rt->err; }

static agc_task *make_task(void) {
  agc_task *t = agc_alloc(sizeof(agc_task));
  t->state = AGC_TASK_RUNNING;
  return t;
}

static void fresh(int fd) {
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  int flags = fcntl(fd, F_GETFL);
  agc_output_open(&vm, out(), fd);
  assert(fcntl(fd, F_GETFL) == flags);
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

static agc_string *letters_of(char letter, size_t len) {
  memset(letters, letter, len);
  return agc_make_string(letters, len, len);
}

static bool print_as(agc_output *stream, agc_task *t, char letter, size_t len, bool newline) {
  vm.task = t;
  t->state = AGC_TASK_RUNNING;
  t->parking = t->retry = false;
  bool done = agc_write(&vm, stream, agc_output_waiting(&vm, stream) ? NULL : letters_of(letter, len), newline);
  assert(done == !t->parking);
  if (t->parking) {
    assert(t->retry);
    t->parking = false;
    t->state = AGC_TASK_PARKED;
  }
  return done;
}

static bool write_as(agc_task *t, char letter, size_t len, bool newline) {
  return print_as(out(), t, letter, len, newline);
}

static bool drain_as(agc_task *t) {
  vm.task = t;
  t->state = AGC_TASK_RUNNING;
  t->parking = t->retry = false;
  bool done = agc_drain(&vm);
  assert(done == !t->parking);
  if (t->parking) {
    t->parking = false;
    t->state = AGC_TASK_PARKED;
  }
  return done;
}

static bool retry(agc_task *t) {
  assert(t->state == AGC_TASK_READY && t->output.out == out());
  return write_as(t, 'x', 0, false);
}

static void check_run(size_t at, char letter, size_t len) {
  assert(at + len <= collected_len);
  for (size_t k = 0; k < len; k++) assert(collected[at + k] == (uint8_t)letter);
}

static void pump(void) {
  agc_io_poll(&vm, false);
  read_pipe();
  uv_sleep(1);
}

static void pump_until(size_t want) {
  for (int round = 0; round < 100 && collected_len < want; round++) pump();
  assert(collected_len == want);
}

static void wait_ready(agc_task *t) {
  for (int round = 0; round < 5000 && t->state == AGC_TASK_PARKED; round++) pump();
  assert(t->state == AGC_TASK_READY);
}

static void test_small_prints_keep_order(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  assert(out()->base == out() && out()->poller && !out()->pooled);
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
  for (int k = 0; k < 3; k++) assert(write_as(a, 'a', BLOCK, false));
  assert(!write_as(b, 'b', 2 * BLOCK, false));
  assert(!write_as(c, 'c', 1, false));
  assert(out()->waiters == b && b->wait_next == c && out()->len == 3 * BLOCK);
  agc_io_poll(&vm, false);
  assert(b->state == AGC_TASK_PARKED && out()->len == 3 * BLOCK);
  assert(read_pipe() == junk);
  wait_ready(b);
  assert(c->state == AGC_TASK_PARKED);
  assert(retry(b));
  assert(c->state == AGC_TASK_READY && out()->waiters == c);
  assert(retry(c));
  assert(!out()->waiters && !b->output.out && !c->output.out);
  pump_until(junk + 3 * BLOCK + 2 * BLOCK + 1);
  check_run(junk, 'a', 3 * BLOCK);
  check_run(junk + 3 * BLOCK, 'b', 2 * BLOCK);
  check_run(junk + 5 * BLOCK, 'c', 1);
  finish();
  close_pipe();
}

static void test_the_buffer_wraps(void) {
  open_pipe();
  size_t junk = block_pipe();
  static uint8_t scratch[BLOCK];
  ssize_t freed = read(pipe_fds[0], scratch, sizeof scratch);
  assert(freed > 0);
  fresh(pipe_fds[1]);
  agc_task *a = make_task();
  assert(write_as(a, 'a', 60000, false));
  agc_io_poll(&vm, false);
  size_t accepted = 60000 - out()->len;
  assert(accepted > 0 && out()->start == accepted);
  size_t second = CAP - 60000 + accepted;
  assert(write_as(a, 'b', second, false));
  assert((out()->start + out()->len) % CAP == out()->start && out()->len == CAP);
  size_t before = junk - (size_t)freed;
  pump_until(before + 60000 + second);
  check_run(before, 'a', 60000);
  check_run(before + 60000, 'b', second);
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
  wait_ready(d);
  assert(drain_as(d) && !out()->waiters && !d->output.out);
  pump();
  assert(collected_len == junk + 100);
  assert(drain_as(d));
  finish();
  close_pipe();
}

static void test_flush_fails_when_the_reader_left(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  agc_task *a = make_task();
  assert(write_as(a, 'a', 10, false));
  close(pipe_fds[0]);
  vm.task = a;
  a->state = AGC_TASK_RUNNING;
  if (setjmp(vm.fail) == 0) {
    agc_drain(&vm);
    assert(false);
  }
  assert(strcmp(vm.rt->outcome.code, "RUNTIME-INTERNAL") == 0 && agc_output_failed(out()));
  finish();
  close(pipe_fds[1]);
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
  wait_ready(c);
  assert(retry(c));
  pump_until(junk + CAP + 10);
  check_run(junk, 'a', CAP);
  check_run(junk + CAP, 'c', 10);
  finish();
  close_pipe();
}

static void test_a_file_is_drained_by_the_pool(void) {
  const char *tmp = getenv("TMPDIR");
  char path[512];
  snprintf(path, sizeof path, "%s/agc-output-XXXXXX", tmp ? tmp : "/tmp");
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

static void test_a_read_only_descriptor_keeps_the_blocking_write(void) {
  int readonly = open("/dev/null", O_RDONLY);
  assert(readonly >= 0);
  fresh(readonly);
  assert(!out()->base && !out()->buf);
  finish();
  close(readonly);
}

static void test_a_stream_on_the_same_target_shares_the_buffer(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  agc_output_open(&vm, err(), pipe_fds[1]);
  assert(err()->base == out() && out()->base == out());
  agc_task *a = make_task();
  assert(write_as(a, 'a', 3, true));
  assert(print_as(err(), a, 'b', 3, true));
  assert(write_as(a, 'c', 3, true));
  assert(out()->len == 12);
  pump();
  assert(collected_len == 12 && memcmp(collected, "aaa\nbbb\nccc\n", 12) == 0);
  finish();
  close_pipe();
}

static void test_a_notice_waits_for_room_and_keeps_its_text(void) {
  static const char text[] = "a notice that does not fit the free space\n";
  const size_t length = sizeof text - 1;
  open_pipe();
  size_t junk = block_pipe();
  fresh(pipe_fds[1]);
  agc_task *a = make_task(), *b = make_task();
  assert(write_as(a, 'a', CAP - 6, false));
  agc_notice n;
  fputs(text, agc_notice_begin(out(), &n));
  agc_notice_end(&n, AGC_NOTICE_QUEUED);
  assert(out()->len == CAP && out()->notice_len - out()->notice_at == length - 6);
  assert(!write_as(b, 'b', 1, false));
  assert(read_pipe() == junk);
  for (int round = 0; round < 10; round++) pump();
  assert(b->state == AGC_TASK_READY && retry(b));
  pump();
  assert(collected_len == junk + CAP - 6 + length + 1);
  check_run(junk, 'a', CAP - 6);
  assert(memcmp(collected + junk + CAP - 6, text, length) == 0);
  check_run(junk + CAP - 6 + length, 'b', 1);
  finish();
  close_pipe();
}

static void test_a_notice_does_not_enter_a_long_print(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  agc_task *l = make_task();
  const size_t big = 2 * CAP + 100;
  assert(!write_as(l, 'l', big, false));
  assert(l->output.done == CAP);
  agc_notice n;
  fputs("notice\n", agc_notice_begin(out(), &n));
  agc_notice_end(&n, AGC_NOTICE_QUEUED);
  assert(out()->notice_len - out()->notice_at == 7);
  bool done = false;
  for (int round = 0; round < 100 && !done; round++) {
    pump();
    if (l->state == AGC_TASK_READY) done = retry(l);
  }
  assert(done);
  for (int round = 0; round < 10; round++) pump();
  assert(collected_len == big + 7);
  check_run(0, 'l', big);
  assert(memcmp(collected + big, "notice\n", 7) == 0);
  finish();
  close_pipe();
}

static void test_a_leaving_long_print_lets_a_notice_and_the_next_writer_through(void) {
  open_pipe();
  size_t junk = block_pipe();
  fresh(pipe_fds[1]);
  agc_task *l = make_task(), *t = make_task();
  assert(!write_as(l, 'l', 2 * CAP + 100, false));
  assert(!write_as(t, 't', CAP, false));
  agc_notice n;
  fputs("notice\n", agc_notice_begin(out(), &n));
  agc_notice_end(&n, AGC_NOTICE_QUEUED);
  assert(out()->notice_len - out()->notice_at == 7);
  assert(read_pipe() == junk);
  for (int round = 0; round < 10; round++) pump();
  assert(l->state == AGC_TASK_READY && t->state == AGC_TASK_PARKED);
  agc_output_leave(&vm, l);
  for (int round = 0; round < 10; round++) pump();
  assert(t->state == AGC_TASK_READY && retry(t));
  for (int round = 0; round < 10; round++) pump();
  assert(collected_len == junk + CAP + 7 + CAP);
  check_run(junk, 'l', CAP);
  assert(memcmp(collected + junk + CAP, "notice\n", 7) == 0);
  check_run(junk + CAP + 7, 't', CAP);
  finish();
  close_pipe();
}

static void test_the_end_of_run_moves_a_notice_held_by_a_stuck_print(void) {
  open_pipe();
  size_t junk = block_pipe();
  fresh(pipe_fds[1]);
  agc_task *l = make_task();
  assert(!write_as(l, 'l', 2 * CAP + 100, false));
  agc_notice n;
  fputs("notice\n", agc_notice_begin(out(), &n));
  agc_notice_end(&n, AGC_NOTICE_QUEUED);
  assert(read_pipe() == junk);
  for (int round = 0; round < 10; round++) pump();
  assert(out()->notice_len - out()->notice_at == 7);
  for (int round = 0; round < 100 && agc_output_busy(&vm); round++) pump();
  assert(!agc_output_busy(&vm));
  assert(collected_len == junk + CAP + 7);
  assert(memcmp(collected + junk + CAP, "notice\n", 7) == 0);
  finish();
  close_pipe();
}

static void notice_of(size_t bytes, agc_notice_mode mode) {
  agc_notice n;
  FILE *file = agc_notice_begin(out(), &n);
  for (size_t k = 0; k < bytes; k++) fputc('n', file);
  agc_notice_end(&n, mode);
}

static void test_the_notice_queue_is_bounded_but_a_kept_notice_is_not_dropped(void) {
  open_pipe();
  block_pipe();
  fresh(pipe_fds[1]);
  agc_task *a = make_task();
  assert(write_as(a, 'a', CAP, false));
  notice_of(AGC_NOTICE_LIMIT + 10, AGC_NOTICE_QUEUED);
  size_t full = out()->notice_len - out()->notice_at;
  assert(full == AGC_NOTICE_LIMIT + 10);
  notice_of(100, AGC_NOTICE_QUEUED);
  assert(out()->notice_len - out()->notice_at == full);
  notice_of(100, AGC_NOTICE_KEPT);
  assert(out()->notice_len - out()->notice_at == full + 100);
  vm.rt->flush_timeout = 50;
  finish();
  close_pipe();
}

static void test_a_final_notice_is_written_straight_or_dropped(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  agc_notice n;
  FILE *file = agc_notice_begin(out(), &n);
  for (int k = 0; k < 3000; k++) fputs("final notice line\n", file);
  agc_notice_end(&n, AGC_NOTICE_FINAL);
  read_pipe();
  assert(collected_len + out()->len == (size_t)3000 * 18);
  agc_output_busy(&vm);
  pump_until((size_t)3000 * 18);
  assert(out()->len == 0);
  for (size_t k = 0; k < 3000; k++)
    assert(memcmp(collected + k * 18, "final notice line\n", 18) == 0);
  finish();
  close_pipe();
  open_pipe();
  block_pipe();
  fresh(pipe_fds[1]);
  file = agc_notice_begin(out(), &n);
  for (int k = 0; k < 20000; k++) fputs("final notice line\n", file);
  agc_notice_end(&n, AGC_NOTICE_FINAL);
  assert(out()->len == CAP && !out()->failed);
  vm.rt->flush_timeout = 50;
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
  test_flush_waits_for_an_empty_buffer();
  test_flush_fails_when_the_reader_left();
  test_a_leaving_head_hands_on();
  test_a_file_is_drained_by_the_pool();
  test_a_device_that_never_waits_is_pooled();
  test_a_read_only_descriptor_keeps_the_blocking_write();
  test_a_stream_on_the_same_target_shares_the_buffer();
  test_a_notice_waits_for_room_and_keeps_its_text();
  test_a_notice_does_not_enter_a_long_print();
  test_a_leaving_long_print_lets_a_notice_and_the_next_writer_through();
  test_the_end_of_run_moves_a_notice_held_by_a_stuck_print();
  test_the_notice_queue_is_bounded_but_a_kept_notice_is_not_dropped();
  test_a_final_notice_is_written_straight_or_dropped();
  puts("output tests passed");
  return 0;
}
#else
int main(void) {
  puts("output tests passed");
  return 0;
}
#endif
