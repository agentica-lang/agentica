/* The pair of one-way pipes that carries the child channel on Windows (and works the same elsewhere): the contract with
   libuv and the system, checked with a plain C child that reads descriptors 3 and 4 with read() and write(). */
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
#include <uv.h>

#include "../file_io.h"

#define TOTAL ((size_t)1048576 + 17)

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
  char data[TOTAL];
  char reply[64];
  size_t reply_size;
  bool eof, shut;
} link_state;

static uv_loop_t loop;
static int exit_status = -1;

static unsigned char pattern(size_t at) { return (unsigned char)(at * 31 + (at >> 8)); }

/* The child: reads descriptor 3 to its end, checks the bytes and answers on descriptor 4 with how many it saw. */
static int child(void) {
#ifdef _WIN32
  _setmode(3, _O_BINARY);
  _setmode(4, _O_BINARY);
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
  return fd_write(4, answer, length) == length ? 0 : 3;
}

static void exited(uv_process_t *p, int64_t status, int signal) {
  (void)signal;
  exit_status = (int)status;
  uv_close((uv_handle_t *)p, NULL);
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
  s->shutdown.data = s;
  assert(uv_shutdown(&s->shutdown, (uv_stream_t *)&s->to, shutdown_done) == 0);
}

static void probe(const char *self) {
  /* The same two pipes as the standard streams of a child: the end the child holds is blocking, the parent's is not. */
  int into[2], outof[2];
#ifdef _WIN32
  assert(uv_pipe(into, 0, UV_NONBLOCK_PIPE) == 0);
  assert(uv_pipe(outof, UV_NONBLOCK_PIPE, 0) == 0);
#else
  /* Elsewhere a pipe cannot be shut down (shutdown(2) wants a socket), and one socket pair per direction can. */
  assert(uv_socketpair(SOCK_STREAM, 0, into, 0, 0) == 0);
  assert(uv_socketpair(SOCK_STREAM, 0, outof, 0, 0) == 0);
  int swap = into[0];
  into[0] = into[1];
  into[1] = swap;
  swap = outof[0];
  outof[0] = outof[1];
  outof[1] = swap;
#endif
  uv_stdio_container_t stdio[5];
  for (int k = 0; k < 3; k++) stdio[k].flags = UV_IGNORE;
  stdio[3].flags = UV_INHERIT_FD;
  stdio[3].data.fd = into[0];
  stdio[4].flags = UV_INHERIT_FD;
  stdio[4].data.fd = outof[1];
  char *argv[] = {(char *)self, (char *)"--child", NULL};
  uv_process_options_t options;
  memset(&options, 0, sizeof options);
  options.exit_cb = exited;
  options.file = self;
  options.args = argv;
  options.stdio_count = 5;
  options.stdio = stdio;
  uv_process_t process;
  assert(uv_spawn(&loop, &process, &options) == 0);
  agc_fs_close(into[0]);
  agc_fs_close(outof[1]);

  link_state *s = calloc(1, sizeof *s);
  assert(s);
  assert(uv_pipe_init(&loop, &s->to, 0) == 0);
  assert(uv_pipe_init(&loop, &s->from, 0) == 0);
  assert(uv_pipe_open(&s->to, into[1]) == 0);
  assert(uv_pipe_open(&s->from, outof[0]) == 0);
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
