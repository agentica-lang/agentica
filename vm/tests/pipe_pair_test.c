/* The channel pair of the system (agc_chan_pair): the contract with libuv and the system, checked with a plain C
   child that reads descriptor 3 and writes descriptor 4 (3 again on POSIX) with read() and write(). */
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#else
#include <unistd.h>
#endif
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <assert.h>
#include <signal.h>
#include <uv.h>

#include "chan_spawn.h"

#define TOTAL ((size_t)1048576 + 17)
/* The whole exchange takes well under a second; a run that is still going after this long is stuck (issue #410: one
   macOS arm64 CI run never finished), so it fails with the state it reached instead of hanging the job. */
#define DEADLINE_MS 60000

#ifdef _WIN32
#define fd_read(fd, data, size) _read(fd, data, (unsigned)(size))
#define fd_write(fd, data, size) _write(fd, data, (unsigned)(size))
#else
#define fd_read(fd, data, size) read(fd, data, size)
#define fd_write(fd, data, size) write(fd, data, size)
#endif

typedef struct {
  uv_pipe_t to, from;
  uv_write_t write;
  uv_shutdown_t shutdown;
  uv_process_t process;
  uv_timer_t deadline;
  char data[TOTAL];
  char reply[64];
  size_t reply_size;
  bool written, eof, shut;
} link_state;

static uv_loop_t loop;
static int exit_status = -1;

static unsigned char pattern(size_t at) { return (unsigned char)(at * 31 + (at >> 8)); }

/* The child: reads descriptor 3 to its end, checks the bytes and answers with how many it saw. */
static int child(void) {
  int answer_fd = strchr(agc_chan_value(), ',') ? 4 : 3;
#ifdef _WIN32
  _setmode(3, _O_BINARY);
  _setmode(answer_fd, _O_BINARY);
#endif
  unsigned char buffer[4096];
  size_t seen = 0;
  bool intact = true;
  for (;;) {
    int n = (int)fd_read(3, buffer, sizeof buffer);
    if (n < 0) return 2;
    if (n == 0) break;
    for (int k = 0; k < n; k++) intact = intact && buffer[k] == pattern(seen + (size_t)k);
    seen += (size_t)n;
  }
  char answer[64];
  int length = snprintf(answer, sizeof answer, "%zu %d\n", seen, intact ? 1 : 0);
  return fd_write(answer_fd, answer, length) == length ? 0 : 3;
}

static void exited(uv_process_t *p, int64_t status, int signal) {
  (void)signal;
  exit_status = (int)status;
  uv_close((uv_handle_t *)p, NULL);
}

/* The watchdog: says which step never came (the write, the shutdown, the child's answer and end of file, its exit),
   kills the child and fails. The timer is unreferenced, so it never keeps a finished run alive. */
static void expired(uv_timer_t *timer) {
  link_state *s = timer->data;
  fprintf(stderr,
          "pipe pair test: no end after %d ms: written=%d (bytes left %zu) shut=%d reply=%zu bytes eof=%d "
          "exit_status=%d\n",
          DEADLINE_MS, s->written, s->shut ? (size_t)0 : uv_stream_get_write_queue_size((uv_stream_t *)&s->to),
          s->shut, s->reply_size, s->eof, exit_status);
  if (exit_status == -1) uv_process_kill(&s->process, SIGKILL);
  exit(1);
}

static void alloc(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  link_state *s = h->data;
  (void)suggested;
  *buf = uv_buf_init(s->reply + s->reply_size, (unsigned)(sizeof s->reply - s->reply_size));
}

static void got(uv_stream_t *stream, ssize_t n, const uv_buf_t *buf) {
  link_state *s = stream->data;
  (void)buf;
  if (n > 0) {
    s->reply_size += (size_t)n;
  } else if (n < 0) {
    assert(n == UV_EOF);
    s->eof = true;
    uv_close((uv_handle_t *)stream, NULL);
  }
}

static void shutdown_done(uv_shutdown_t *req, int status) {
  link_state *s = req->data;
  assert(status == 0);
  s->shut = true;
  uv_close((uv_handle_t *)&s->to, NULL);
}

static void written(uv_write_t *req, int status) {
  link_state *s = req->data;
  assert(status == 0);
  s->written = true;
  s->shutdown.data = s;
  assert(uv_shutdown(&s->shutdown, (uv_stream_t *)&s->to, shutdown_done) == 0);
}

static void probe(const char *self) {
  agc_chan_ends ends;
  assert(agc_chan_pair(&ends) == 0);
  link_state *s = calloc(1, sizeof *s);
  assert(s);
  assert(chan_spawn(&loop, &s->process, self, "--child", NULL, &ends, ends.child_count, false, 0, exited) == 0);
  assert(uv_timer_init(&loop, &s->deadline) == 0);
  s->deadline.data = s;
  assert(uv_timer_start(&s->deadline, expired, DEADLINE_MS, 0) == 0);
  uv_unref((uv_handle_t *)&s->deadline);

  assert(uv_pipe_init(&loop, &s->to, 0) == 0);
  assert(uv_pipe_init(&loop, &s->from, 0) == 0);
  assert(uv_pipe_open(&s->to, ends.write) == 0);
  assert(uv_pipe_open(&s->from, ends.read) == 0);
#ifdef _WIN32
  /* libuv must see the direction of each end: a write end that looked readable could not be shut down for good. */
  assert(uv_is_writable((uv_stream_t *)&s->to) && !uv_is_readable((uv_stream_t *)&s->to));
  assert(uv_is_readable((uv_stream_t *)&s->from) && !uv_is_writable((uv_stream_t *)&s->from));
#endif
  s->to.data = s;
  s->from.data = s;
  s->write.data = s;
  for (size_t k = 0; k < TOTAL; k++) s->data[k] = (char)pattern(k);
  uv_buf_t buf = uv_buf_init(s->data, (unsigned)TOTAL);
  assert(uv_write(&s->write, (uv_stream_t *)&s->to, &buf, 1, written) == 0);
  assert(uv_read_start((uv_stream_t *)&s->from, alloc, got) == 0);
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  uv_close((uv_handle_t *)&s->deadline, NULL);
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);

  /* Shutting down the write end ended the child's reads, after every byte; its answer and its exit came back. */
  assert(s->shut && s->eof);
  char expected[64];
  snprintf(expected, sizeof expected, "%zu 1\n", TOTAL);
  assert(s->reply_size == strlen(expected) && memcmp(s->reply, expected, s->reply_size) == 0);
  assert(exit_status == 0);
  free(s);
}


int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--child") == 0) return child();
  assert(uv_loop_init(&loop) == 0);
  char self[32768];
  size_t size = sizeof self;
  assert(uv_exepath(self, &size) == 0);
  probe(self);
  assert(uv_loop_close(&loop) == 0);
  puts("pipe pair tests passed");
  return 0;
}
