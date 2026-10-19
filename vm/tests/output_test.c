/*
 * vm/output.c with hand-made tasks and a pipe: the order of small prints,
 * writers that wait, the ring wrap-around, and agc_drain. On Windows the pipe
 * has an overlapped write end (full-pipe cases) or a synchronous one.
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
#include <uv.h>
#ifdef _WIN32
#include <io.h>
#include <windows.h>
#else
#include <unistd.h>
#endif

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)

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

#ifdef _WIN32
#define NULL_DEVICE "NUL"
#define dup _dup
#define close _close

/* The write end of the next pipe: overlapped (a full pipe leaves a write pending, so block_pipe can fill it) or
   synchronous, as CreatePipe makes it (what a Python parent gives a child). The read end is synchronous. */
static bool overlapped_end = true;

static int descriptor_flags(int fd) {
  (void)fd;
  return 0;
}

static void open_pipe(void) {
  if (overlapped_end) {
    assert(uv_pipe(pipe_fds, 0, UV_NONBLOCK_PIPE) == 0);
  } else {
    HANDLE read_end, write_end;
    assert(CreatePipe(&read_end, &write_end, NULL, 0));
    pipe_fds[0] = _open_osfhandle((intptr_t)read_end, _O_RDONLY | _O_BINARY);
    pipe_fds[1] = _open_osfhandle((intptr_t)write_end, _O_WRONLY | _O_BINARY);
    assert(pipe_fds[0] >= 0 && pipe_fds[1] >= 0);
  }
  collected_len = 0;
}

/* Fills the pipe with overlapped writes until one stays pending: first by kilobytes, then by bytes. */
static size_t block_pipe(void) {
  assert(overlapped_end);
  static const char junk[1024] = {0};
  HANDLE end = (HANDLE)_get_osfhandle(pipe_fds[1]);
  OVERLAPPED request;
  size_t total = 0;
  for (size_t chunk = sizeof junk; chunk > 0; chunk = chunk == 1 ? 0 : 1) {
    for (;;) {
      memset(&request, 0, sizeof request);
      request.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
      DWORD done = 0;
      if (WriteFile(end, junk, (DWORD)chunk, &done, &request)) {
        total += done;
        CloseHandle(request.hEvent);
        continue;
      }
      assert(GetLastError() == ERROR_IO_PENDING);
      CancelIoEx(end, &request);
      if (GetOverlappedResult(end, &request, &done, TRUE)) total += done;
      CloseHandle(request.hEvent);
      break;
    }
  }
  return total;
}

static size_t read_some(void *into, size_t room) {
  if (pipe_fds[0] < 0) return 0;
  HANDLE end = (HANDLE)_get_osfhandle(pipe_fds[0]);
  DWORD ready = 0, got = 0;
  if (!PeekNamedPipe(end, NULL, 0, NULL, &ready, NULL) || ready == 0) return 0;
  if (ready > room) ready = (DWORD)room;
  return ReadFile(end, into, ready, &got, NULL) ? got : 0;
}
#else
#define NULL_DEVICE "/dev/null"

static int descriptor_flags(int fd) { return fcntl(fd, F_GETFL); }

static void open_pipe(void) {
  assert(pipe(pipe_fds) == 0);
  assert(fcntl(pipe_fds[0], F_SETFL, O_NONBLOCK) == 0);
  collected_len = 0;
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

static size_t read_some(void *into, size_t room) {
  if (pipe_fds[0] < 0) return 0;
  ssize_t n = read(pipe_fds[0], into, room);
  return n > 0 ? (size_t)n : 0;
}
#endif

static void fresh(int fd) {
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  int flags = descriptor_flags(fd);
  agc_output_open(&vm, out(), fd);
  assert(descriptor_flags(fd) == flags);
}

static void finish(void) { assert(agc_io_close(&vm)); }

static void close_reader(void) {
  close(pipe_fds[0]);
  pipe_fds[0] = -1;
}

static void close_pipe(void) {
  if (pipe_fds[0] >= 0) close(pipe_fds[0]);
  close(pipe_fds[1]);
}

static size_t read_pipe(void) {
  size_t before = collected_len;
  for (;;) {
    size_t n = read_some(collected + collected_len, sizeof collected - collected_len);
    if (n == 0) break;
    collected_len += n;
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

/* The junk of block_pipe comes out first. A Windows write request pending behind it completes while the reader
   reads, so only the junk is counted, not what follows it. */
static void read_junk(size_t junk) {
  size_t got = read_pipe();
#ifdef _WIN32
  assert(got >= junk);
#else
  assert(got == junk);
#endif
}

static void pump(void) {
  agc_io_poll(&vm, false);
  read_pipe();
  uv_sleep(1);
}

static void pump_until(size_t want) {
  for (int round = 0; round < 1000 && collected_len < want; round++) pump();
  assert(collected_len == want);
}

/* A Windows write request is consumed when its completion runs, a poll after the bytes reached the pipe. */
static void pump_idle(void) {
  for (int round = 0; round < 1000 && (out()->len || out()->writing); round++) pump();
  assert(out()->len == 0 && !out()->writing);
}

static void wait_ready(agc_task *t) {
  for (int round = 0; round < 5000 && t->state == AGC_TASK_PARKED; round++) pump();
  assert(t->state == AGC_TASK_READY);
}

static void test_small_prints_keep_order(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  assert(out()->base == out() && (out()->mode == AGC_WRITE_POLL || out()->mode == AGC_WRITE_STREAM));
  agc_task *a = make_task();
  assert(write_as(a, 'a', 5, true));
  assert(write_as(a, 'b', 3, false));
  assert(out()->len == 9);
#ifndef _WIN32
  assert(read_pipe() == 0);
#endif
  pump_until(9);
  assert(memcmp(collected, "aaaaa\nbbb", 9) == 0);
  pump_idle();
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
  read_junk(junk);
  wait_ready(b);
  assert(c->state == AGC_TASK_PARKED);
  assert(retry(b));
  wait_ready(c);
  assert(out()->waiters == c);
  assert(retry(c));
  assert(!out()->waiters && !b->output.out && !c->output.out);
  pump_until(junk + 3 * BLOCK + 2 * BLOCK + 1);
  check_run(junk, 'a', 3 * BLOCK);
  check_run(junk + 3 * BLOCK, 'b', 2 * BLOCK);
  check_run(junk + 5 * BLOCK, 'c', 1);
  finish();
  close_pipe();
}

#ifdef _WIN32
/* A write request takes the ring as it is, so the ring wraps when text is copied behind a request that is out; the
   wrapped ranges then leave in one request, in order. */
static void test_the_buffer_wraps(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  agc_task *a = make_task(), *b = make_task(), *c = make_task();
  assert(write_as(a, 'a', 40000, false));
  assert(write_as(c, 'c', 10000, false));
  assert(!write_as(b, 'b', 30000, false));
  wait_ready(b);
  assert(out()->start == 40000 && out()->len == 10000 && out()->writing);
  assert(retry(b) && out()->start + out()->len > CAP);
  pump_until(80000);
  check_run(0, 'a', 40000);
  check_run(40000, 'c', 10000);
  check_run(50000, 'b', 30000);
  finish();
  close_pipe();
}
#else
static void test_the_buffer_wraps(void) {
  open_pipe();
  size_t junk = block_pipe();
  static uint8_t scratch[BLOCK];
  size_t freed = read_some(scratch, sizeof scratch);
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
  size_t before = junk - freed;
  pump_until(before + 60000 + second);
  check_run(before, 'a', 60000);
  check_run(before + 60000, 'b', second);
  finish();
  close_pipe();
}
#endif

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
  read_junk(junk);
  wait_ready(d);
  assert(drain_as(d) && !out()->waiters && !d->output.out);
  pump_until(junk + 100);
  assert(drain_as(d));
  finish();
  close_pipe();
}

/* The reader leaves after the first text went out. A poller finds the broken pipe when it writes; a Windows request
   reports it, so the flush waits a turn or two before it fails. */
static void test_flush_fails_when_the_reader_left(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  agc_task *a = make_task();
  assert(write_as(a, 'a', 10, false));
  pump_until(10);
  pump_idle();
  close_reader();
  assert(write_as(a, 'a', 10, false));
  vm.task = a;
  a->state = AGC_TASK_RUNNING;
  if (setjmp(vm.fail) == 0) {
    for (int round = 0; round < 1000; round++) {
      drain_as(a);
      pump();
    }
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
  read_junk(junk);
  wait_ready(c);
  assert(retry(c));
  pump_until(junk + CAP + 10);
  check_run(junk, 'a', CAP);
  check_run(junk + CAP, 'c', 10);
  finish();
  close_pipe();
}

static void test_a_file_is_drained_by_the_pool(void) {
  char dir[512], path[600];
  size_t length = sizeof dir;
  assert(uv_os_tmpdir(dir, &length) == 0);
  snprintf(path, sizeof path, "%s/agc-output-XXXXXX", dir);
  uv_fs_t request;
  int fd = uv_fs_mkstemp(NULL, &request, path, NULL);
  assert(fd >= 0);
  snprintf(path, sizeof path, "%s", request.path);
  uv_fs_req_cleanup(&request);
  fresh(fd);
  assert(out()->mode == AGC_WRITE_DISK && out()->fd == fd);
  agc_task *a = make_task();
  assert(write_as(a, 'a', 40000, false));
  while (out()->len || out()->writing) agc_io_poll(&vm, true);
  assert(write_as(a, 'b', 40000, true));
  assert(write_as(a, 'c', 20000, false));
  agc_io_flush_files(&vm);
  assert(out()->len == 0);
  size_t want = 40000 + 40001 + 20000;
  uint8_t *data = malloc(want + 1);
  assert(data);
  uv_buf_t buffer = uv_buf_init((char *)data, (unsigned)(want + 1));
  assert(uv_fs_read(NULL, &request, fd, &buffer, 1, 0, NULL) == (ssize_t)want);
  uv_fs_req_cleanup(&request);
  for (size_t k = 0; k < want; k++) assert(data[k] == (k < 40000 ? 'a' : k < 80000 ? 'b' : k == 80000 ? '\n' : 'c'));
  free(data);
  finish();
  uv_fs_close(NULL, &request, fd, NULL);
  uv_fs_unlink(NULL, &request, path, NULL);
  uv_fs_req_cleanup(&request);
}

static void test_a_device_that_never_waits_is_pooled(void) {
  uv_fs_t request;
  int fd = uv_fs_open(NULL, &request, NULL_DEVICE, UV_FS_O_WRONLY, 0, NULL);
  assert(fd >= 0);
  fresh(fd);
  assert(out()->mode == AGC_WRITE_DISK && out()->fd == fd);
  assert(write_as(make_task(), 'a', 10, true));
  agc_io_flush_files(&vm);
  assert(out()->len == 0 && !out()->failed);
  finish();
  uv_fs_close(NULL, &request, fd, NULL);
}

#ifndef _WIN32
static void test_a_read_only_descriptor_keeps_the_blocking_write(void) {
  int readonly = open("/dev/null", O_RDONLY);
  assert(readonly >= 0);
  fresh(readonly);
  assert(!out()->base && !out()->buf);
  finish();
  close(readonly);
}
#endif

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
  pump_until(12);
  assert(memcmp(collected, "aaa\nbbb\nccc\n", 12) == 0);
  pump_idle();
  finish();
  close_pipe();
}

/* 2>&1 gives stderr a duplicate of the descriptor: another number, the same pipe. */
static void test_a_duplicate_of_the_descriptor_is_the_same_target(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  int again = dup(pipe_fds[1]);
  assert(again >= 0);
  agc_output_open(&vm, err(), again);
  assert(err()->base == out());
  agc_task *a = make_task();
  assert(write_as(a, 'a', 2, true));
  assert(print_as(err(), a, 'b', 2, true));
  pump_until(6);
  assert(memcmp(collected, "aa\nbb\n", 6) == 0);
  pump_idle();
  finish();
  close(again);
  close_pipe();
}

static void test_two_pipes_are_two_targets(void) {
  open_pipe();
  int first_read = pipe_fds[0], first_write = pipe_fds[1];
  open_pipe();
  fresh(first_write);
  agc_output_open(&vm, err(), pipe_fds[1]);
  assert(err()->base == err() && out()->base == out());
  agc_task *a = make_task();
  assert(print_as(err(), a, 'e', 4, true));
  pump_until(5);
  assert(memcmp(collected, "eeee\n", 5) == 0);
  int second_read = pipe_fds[0], second_write = pipe_fds[1];
  pipe_fds[0] = first_read;
  collected_len = 0;
  assert(read_pipe() == 0);
  assert(write_as(a, 'o', 2, true));
  pump_until(3);
  assert(memcmp(collected, "oo\n", 3) == 0);
  finish();
  close(first_read);
  close(first_write);
  close(second_read);
  close(second_write);
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
  read_junk(junk);
  wait_ready(b);
  assert(retry(b));
  pump_until(junk + CAP - 6 + length + 1);
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
  for (int round = 0; round < 1000 && !done; round++) {
    pump();
    if (l->state == AGC_TASK_READY) done = retry(l);
  }
  assert(done);
  pump_until(big + 7);
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
  read_junk(junk);
  wait_ready(l);
  assert(t->state == AGC_TASK_PARKED);
  agc_output_leave(&vm, l);
  wait_ready(t);
  assert(retry(t));
  pump_until(junk + CAP + 7 + CAP);
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
  read_junk(junk);
  wait_ready(l);
  assert(out()->notice_len - out()->notice_at == 7);
  for (int round = 0; round < 1000 && agc_output_busy(&vm); round++) pump();
  assert(!agc_output_busy(&vm));
  pump_until(junk + CAP + 7);
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

static void test_a_final_notice_is_written_straight(void) {
  open_pipe();
  fresh(pipe_fds[1]);
  agc_notice n;
  FILE *file = agc_notice_begin(out(), &n);
  for (int k = 0; k < 3000; k++) fputs("final notice line\n", file);
  agc_notice_end(&n, AGC_NOTICE_FINAL);
#ifndef _WIN32
  read_pipe();
  assert(collected_len + out()->len == (size_t)3000 * 18);
  agc_output_busy(&vm);
#endif
  pump_until((size_t)3000 * 18);
  pump_idle();
  for (size_t k = 0; k < 3000; k++)
    assert(memcmp(collected + k * 18, "final notice line\n", 18) == 0);
  finish();
  close_pipe();
}

static void test_a_final_notice_is_dropped_when_the_pipe_is_stuck(void) {
  open_pipe();
  block_pipe();
  fresh(pipe_fds[1]);
  agc_notice n;
  FILE *file = agc_notice_begin(out(), &n);
  for (int k = 0; k < 20000; k++) fputs("final notice line\n", file);
  agc_notice_end(&n, AGC_NOTICE_FINAL);
  assert(out()->len == CAP && !out()->failed);
  vm.rt->flush_timeout = 50;
  finish();
  close_pipe();
}

/* The stop state is process-wide and stays set, so the tests that need a stop signal run last. On Windows a driver
   process that does not exist counts as a request to stop; elsewhere the signal is raised. */
static void request_stop(void) {
  if (agc_io_stop_signal()) return;
#ifdef _WIN32
  agc_io_watch_stop(&vm, 0x7ffffff0);
#else
  agc_io_watch_stop(&vm, 0);
  raise(SIGTERM);
#endif
  assert(agc_io_stop_signal() != 0);
}

/* With a stop signal set, the end of the run gives a stream that cannot be written one last write and a short, shared
   wait at most: the process has to be able to leave while its reader is silent. */
static void leave_while_stuck(void) {
  request_stop();
  uint64_t started = agc_io_now(&vm);
  assert(!agc_output_busy(&vm));
  assert(agc_io_now(&vm) - started < 1000);
}

/* The reader never reads. */
static void test_a_stop_signal_does_not_wait_for_a_silent_reader(void) {
  open_pipe();
  block_pipe();
  fresh(pipe_fds[1]);
  agc_task *a = make_task();
  assert(write_as(a, 'a', 1000, false));
  leave_while_stuck();
  assert(out()->len > 0 && !out()->failed);
  uint64_t started = agc_io_now(&vm);
  assert(!agc_output_busy(&vm));
  assert(agc_io_now(&vm) - started < 100);
  finish();
  close_pipe();
}

#ifdef _WIN32
/* A connected pair of TCP sockets with small buffers; the writer is filled until a send would block. */
static void full_socket_pair(SOCKET *writer, SOCKET *reader) {
  WSADATA data;
  assert(WSAStartup(MAKEWORD(2, 2), &data) == 0);
  SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  struct sockaddr_in address;
  memset(&address, 0, sizeof address);
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int length = sizeof address, small = 4096;
  setsockopt(listener, SOL_SOCKET, SO_RCVBUF, (const char *)&small, sizeof small);
  assert(bind(listener, (struct sockaddr *)&address, length) == 0);
  assert(getsockname(listener, (struct sockaddr *)&address, &length) == 0);
  assert(listen(listener, 1) == 0);
  *writer = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  setsockopt(*writer, SOL_SOCKET, SO_SNDBUF, (const char *)&small, sizeof small);
  assert(connect(*writer, (struct sockaddr *)&address, length) == 0);
  *reader = accept(listener, NULL, NULL);
  assert(*reader != INVALID_SOCKET);
  closesocket(listener);
  u_long nonblocking = 1;
  assert(ioctlsocket(*writer, FIONBIO, &nonblocking) == 0);
  static const char junk[1024] = {0};
  size_t total = 0;
  while (send(*writer, junk, sizeof junk, 0) > 0) {
    total += sizeof junk;
    assert(total < ((size_t)256 << 20));
  }
  assert(WSAGetLastError() == WSAEWOULDBLOCK);
  nonblocking = 0;
  assert(ioctlsocket(*writer, FIONBIO, &nonblocking) == 0);
}

/* A socket as standard output is not a pipe that libuv takes, so a pool thread writes it. The thread waits for the
   reader; the loop does not, and the stop signal still lets the run end within the short wait. */
static void test_a_handle_that_libuv_refuses_is_written_by_a_pool_thread(void) {
  SOCKET writer, reader;
  full_socket_pair(&writer, &reader);
  int fd = _open_osfhandle((intptr_t)writer, _O_BINARY);
  assert(fd >= 0);
  fresh(fd);
  assert(out()->mode == AGC_WRITE_THREAD && out()->fd == fd);
  agc_task *a = make_task();
  assert(write_as(a, 'a', 1000, false));
  leave_while_stuck();
  /* Wine takes the write at once, so there the thread is never stuck; native Windows blocks it. */
  if (!getenv("AGENTICA_TEST_WINE")) assert(out()->len == 1000 && out()->writing && !out()->failed);
  closesocket(reader);
  CancelIoEx((HANDLE)writer, NULL);
  for (int round = 0; round < 5000 && out()->writing; round++) pump();
  assert(!out()->writing);
  finish();
  close(fd);
  WSACleanup();
}
#endif

/* The tests that fill no pipe, so they run on either kind of write end. */
static void run_unfilled_pipe_tests(void) {
  test_small_prints_keep_order();
  test_flush_fails_when_the_reader_left();
  test_a_stream_on_the_same_target_shares_the_buffer();
  test_a_duplicate_of_the_descriptor_is_the_same_target();
  test_two_pipes_are_two_targets();
  test_a_final_notice_is_written_straight();
}

int main(void) {
#ifdef SIGPIPE
  signal(SIGPIPE, SIG_IGN);
#endif
  agc_init();
  agc_io_init();
  run_unfilled_pipe_tests();
  test_waiters_do_not_jump_the_queue();
  test_the_buffer_wraps();
  test_flush_waits_for_an_empty_buffer();
  test_a_leaving_head_hands_on();
  test_a_file_is_drained_by_the_pool();
  test_a_device_that_never_waits_is_pooled();
#ifndef _WIN32
  test_a_read_only_descriptor_keeps_the_blocking_write();
#endif
  test_a_notice_waits_for_room_and_keeps_its_text();
  test_a_notice_does_not_enter_a_long_print();
  test_a_leaving_long_print_lets_a_notice_and_the_next_writer_through();
  test_the_end_of_run_moves_a_notice_held_by_a_stuck_print();
  test_the_notice_queue_is_bounded_but_a_kept_notice_is_not_dropped();
  test_a_final_notice_is_dropped_when_the_pipe_is_stuck();
#ifdef _WIN32
  overlapped_end = false;
  run_unfilled_pipe_tests();
  overlapped_end = true;
#endif
  test_a_stop_signal_does_not_wait_for_a_silent_reader();
#ifdef _WIN32
  test_a_handle_that_libuv_refuses_is_written_by_a_pool_thread();
#endif
  puts("output tests passed");
  return 0;
}
#else
int main(void) {
  puts("output tests passed");
  return 0;
}
#endif
