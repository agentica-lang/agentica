/*
 * The private child channel: a libuv stream to read and one to write (two
 * descriptors of one socket on POSIX, two pipes on Windows), with line reads
 * and writes, for a child process that talks to its parent. Service layer.
 * The system part is duplex_os.h. Design: docs/vm/10-io-processes.md §10.4.
 */
#include "services.h"
#include "file_io.h"
#include "duplex_os.h"

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#define LIMIT ((size_t)1048576)
#define OWNER(ptr, field) ((agc_duplex *)(void *)((char *)(ptr) - offsetof(agc_duplex, field)))
#define PIPE_OWNER(handle) ((agc_duplex *)(handle)->data)

typedef struct request request;

struct request {
  agc_duplex *d;
  agc_io_job *job;
  bool sending, retry;
  size_t count;
};

struct agc_duplex {
  uv_pipe_t rd_pipe, wr_pipe;
  uv_write_t write_req;
  uv_shutdown_t shutdown_req;
  uint8_t *write_data;
  agc_inbuf in;
  request *reader, *writer;
  size_t refs;
  const char *overflow;
  int rd_fd, wr_fd, write_status;
  bool attached, rd_live, wr_live, reading, closed, write_closed, sent;
};

static const char closed_text[] = "process: channel is closed";
static const char busy_text[] = "process: the channel is in use";
static const char write_failed[] = "error writing to stream port";

static agc_value ok_void(void) { return agc_result_value(true, agc_void()); }

static void settle(agc_duplex *d) {
  if (d->refs) return;
  agc_inbuf_free(&d->in);
  free(d->write_data);
  free(d);
}

static void unref(agc_duplex *d) {
  d->refs--;
  settle(d);
}

static void handle_closed(uv_handle_t *h) { unref(PIPE_OWNER(h)); }

static void shutdown_done(uv_shutdown_t *req, int status) {
  (void)status;
  unref(OWNER(req, shutdown_req));
}

static agc_duplex *make(int rd_fd, int wr_fd) {
  agc_duplex *d = calloc(1, sizeof(agc_duplex));
  if (!d) agc_out_of_memory();
  d->rd_fd = rd_fd;
  d->wr_fd = wr_fd;
  d->refs = 1;
  return d;
}

/* Opens one libuv handle on *fd, which it takes on success. The handle stays initialized (and counted in refs) on a
   failed open too, until agc_duplex_shut closes it. */
static int open_end(agc_vm *vm, agc_duplex *d, uv_pipe_t *pipe, bool *live, int *fd) {
  int rc = uv_pipe_init(agc_io_uv(vm), pipe, 0);
  if (rc) return rc;
  pipe->data = d;
  *live = true;
  d->refs++;
  rc = uv_pipe_open(pipe, *fd);
  if (!rc) *fd = -1;
  return rc;
}

static int attach(agc_vm *vm, agc_duplex *d) {
  int rc = open_end(vm, d, &d->rd_pipe, &d->rd_live, &d->rd_fd);
  if (!rc) rc = open_end(vm, d, &d->wr_pipe, &d->wr_live, &d->wr_fd);
  d->attached = true;
  if (rc) agc_duplex_shut(d);
  return rc;
}

static void close_end(uv_pipe_t *pipe, bool *live, int *fd) {
  if (*live && !uv_is_closing((uv_handle_t *)pipe)) uv_close((uv_handle_t *)pipe, handle_closed);
  *live = false;
  if (*fd >= 0) {
    agc_fs_close(*fd);
    *fd = -1;
  }
}

void agc_duplex_shut(agc_duplex *d) {
  if (d->closed) return;
  d->closed = true;
  close_end(&d->rd_pipe, &d->rd_live, &d->rd_fd);
  close_end(&d->wr_pipe, &d->wr_live, &d->wr_fd);
  agc_inbuf_free(&d->in);
  if (d->reader) agc_io_ready(d->reader->job);
  if (d->writer) agc_io_ready(d->writer->job);
}

void agc_duplex_overflow(agc_duplex *d, const char *text) {
  if (!d->overflow) d->overflow = text;
  if (d->reader) agc_io_ready(d->reader->job);
}

void agc_duplex_release(agc_duplex *d) {
  agc_duplex_shut(d);
  unref(d);
}

agc_duplex *agc_duplex_new(agc_vm *vm, int read_fd, int write_fd) {
  agc_duplex *d = make(read_fd, write_fd);
  if (attach(vm, d) == 0) return d;
  agc_duplex_release(d);
  return NULL;
}

static void alloc_in(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  (void)suggested;
  agc_duplex *d = PIPE_OWNER(h);
  size_t size = agc_inbuf_want(&d->in, true, 0);
  uint8_t *room = agc_inbuf_room(&d->in, size);
  *buf = room ? uv_buf_init((char *)room, (unsigned)size) : uv_buf_init(NULL, 0);
}

static void stop_reading(agc_duplex *d) {
  if (!d->reading) return;
  uv_read_stop((uv_stream_t *)&d->rd_pipe);
  d->reading = false;
}

static void read_in(uv_stream_t *s, ssize_t n, const uv_buf_t *buf) {
  (void)buf;
  agc_duplex *d = PIPE_OWNER(s);
  agc_inbuf_got(&d->in, n, n == UV_EOF || n == UV_ECONNRESET);
  const request *q = d->reader;
  bool ready = q && agc_inbuf_ready(&d->in, true, 0);
  if (n < 0 || !q || ready) stop_reading(d);
  if (ready) agc_io_ready(q->job);
}

static void start_reading(agc_duplex *d) {
  if (d->reading || d->in.eof || d->in.error) return;
  int rc = uv_read_start((uv_stream_t *)&d->rd_pipe, alloc_in, read_in);
  if (rc)
    d->in.error = -rc;
  else
    d->reading = true;
}

static void wrote(uv_write_t *req, int status) {
  agc_duplex *d = OWNER(req, write_req);
  free(d->write_data);
  d->write_data = NULL;
  d->write_status = status;
  if (d->writer) agc_io_ready(d->writer->job);
}

static request *new_request(agc_duplex *d, bool sending, bool retry) {
  request *q = calloc(1, sizeof(request));
  if (!q) agc_out_of_memory();
  q->d = d;
  q->sending = sending;
  q->retry = retry;
  d->refs++;
  return q;
}

static void unlink_request(request *q) {
  agc_duplex *d = q->d;
  if (d->reader == q) d->reader = NULL;
  if (d->writer == q) d->writer = NULL;
}

static void drop_request(void *data) {
  request *q = data;
  agc_duplex *d = q->d;
  unlink_request(q);
  free(q);
  unref(d);
}

static agc_value take_line(agc_vm *vm, agc_duplex *d) {
  bool over;
  agc_value line = agc_inbuf_line(vm, &d->in, "process: line exceeds 1048576 bytes", "process: end of input", &over);
  if (over) agc_duplex_shut(d);
  return line;
}

static agc_value request_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  request *q = data;
  agc_duplex *d = q->d;
  agc_value result = agc_void();
  unlink_request(q);
  if (q->retry) {
    d->sent = q->sending;
  } else if (d->closed) {
    result = agc_error_value(closed_text);
  } else if (q->sending) {
    agc_charge(vm, q->count);
    result = d->write_status < 0 ? agc_system_error(vm, write_failed, -d->write_status) : ok_void();
  } else {
    result = d->overflow && !agc_inbuf_ready(&d->in, true, 0) ? agc_error_value(d->overflow) : take_line(vm, d);
    agc_charge(vm, agc_value_units(result));
  }
  drop_request(q);
  return result;
}

static agc_value request_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  request *q = data;
  unlink_request(q);
  agc_duplex_shut(q->d);
  return agc_stream_timed_out();
}

static bool request_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  const request *q = data;
  return deadline && !q->sending;
}

static const agc_io_kind duplex_io = {NULL, request_done, request_expired, drop_request, true, "channel", request_cancel, true};

static bool usable(const agc_duplex *d, const request *pending, agc_value *result) {
  if (d->closed) {
    *result = agc_error_value(closed_text);
    return false;
  }
  if (pending) {
    *result = agc_error_value(busy_text);
    return false;
  }
  return true;
}

agc_value agc_duplex_read_line(agc_vm *vm, agc_duplex *d, agc_resource *lock, int64_t timeout) {
  agc_value result;
  if (!agc_stream_lock(vm, lock, &timeout, &result) || !usable(d, d->reader, &result)) return result;
  if (agc_inbuf_ready(&d->in, true, 0)) return take_line(vm, d);
  if (d->overflow) return agc_error_value(d->overflow);
  request *q = new_request(d, false, false);
  d->reader = q;
  q->job = agc_io_start(vm, &duplex_io, q, agc_handle_value(lock), timeout);
  start_reading(d);
  if (agc_inbuf_ready(&d->in, true, 0)) agc_io_ready(q->job);
  return agc_void();
}

agc_value agc_duplex_send(agc_vm *vm, agc_duplex *d, agc_resource *lock, agc_value line, int64_t timeout) {
  agc_value result;
  const agc_string *text = agc_as_string(vm, line);
  if (text->bytes > LIMIT) return agc_error_value("process: send exceeds 1048576 bytes");
  if (!agc_stream_lock(vm, lock, &timeout, &result) || !usable(d, d->writer, &result)) return result;
  if (d->write_closed) return agc_error_value(closed_text);
  d->write_status = 0;
  int rc = agc_stream_write((uv_stream_t *)&d->wr_pipe, &d->write_req, &d->write_data, (const uint8_t *)text->data,
                            text->bytes, wrote);
  if (rc < 0) return agc_system_error(vm, write_failed, -rc);
  if (rc == 0) return ok_void();
  request *q = new_request(d, true, false);
  q->count = (size_t)agc_value_units(line);
  d->writer = q;
  q->job = agc_io_start(vm, &duplex_io, q, agc_handle_value(lock), timeout);
  return agc_void();
}

agc_value agc_duplex_close_write(agc_vm *vm, agc_duplex *d, agc_resource *lock, int64_t timeout) {
  agc_value result;
  if (!agc_stream_lock(vm, lock, &timeout, &result)) return result;
  if (d->closed) return agc_error_value(closed_text);
  if (d->write_closed) return ok_void();
  d->write_closed = true;
  d->refs++;
  if (uv_shutdown(&d->shutdown_req, (uv_stream_t *)&d->wr_pipe, shutdown_done)) d->refs--;
  return ok_void();
}

static agc_duplex *parent_of(agc_vm *vm) {
  agc_duplex *d = vm->parent ? vm->parent->native : NULL;
  if (d && !d->attached && !d->closed) attach(vm, d);
  return d;
}

static void release_parent(void *native) { agc_duplex_release(native); }

static void forget_inherited(int fd, void *data) {
  agc_vm *vm = data;
  agc_files_forget(&vm->rt->inherited, fd);
}

void agc_parent_take(agc_vm *vm) {
  const char *marker = getenv(AGC_CHANNEL_ENV);
  if (!marker || strcmp(marker, agc_chan_value()) != 0) return;
  int read_fd, write_fd;
  if (!agc_chan_take(forget_inherited, vm, &read_fd, &write_fd)) return;
  uv_os_unsetenv(AGC_CHANNEL_ENV);
  vm->parent = agc_register(vm, make(read_fd, write_fd), release_parent);
  vm->parent_locks = (agc_lines){agc_new_lock(vm), agc_new_lock(vm)};
}

bool agc_parent_open(agc_vm *vm) {
  const agc_duplex *d = parent_of(vm);
  return d && !d->closed;
}

static agc_duplex *opened(agc_vm *vm) {
  agc_duplex *d = vm->parent ? vm->parent->native : NULL;
  return d && d->attached && !d->closed ? d : NULL;
}

agc_input_status agc_parent_line(agc_vm *vm, agc_string **line) {
  agc_duplex *d = opened(vm);
  if (!d || d->reader) return AGC_INPUT_FAILED;
  if (!agc_inbuf_ready(&d->in, true, 0)) {
    request *q = new_request(d, false, true);
    d->reader = q;
    q->job = agc_io_start(vm, &duplex_io, q, agc_void(), -1);
    vm->task->retry = true;
    start_reading(d);
    if (agc_inbuf_ready(&d->in, true, 0)) agc_io_ready(q->job);
    return AGC_INPUT_WAIT;
  }
  if (agc_inbuf_pending(&d->in) == 0 && d->in.eof) return AGC_INPUT_EOF;
  agc_value found = take_line(vm, d);
  const agc_result *r = agc_as_result(vm, found);
  if (!r->ok) return AGC_INPUT_FAILED;
  *line = agc_as_string(vm, r->value);
  return AGC_INPUT_OK;
}

bool agc_parent_send(agc_vm *vm, const agc_string *text) {
  agc_duplex *d = opened(vm);
  if (d && d->sent) {
    d->sent = false;
    if (d->write_status >= 0) return true;
  } else if (d && !d->writer && !d->write_closed) {
    d->write_status = 0;
    int rc = agc_stream_write((uv_stream_t *)&d->wr_pipe, &d->write_req, &d->write_data, (const uint8_t *)text->data,
                              text->bytes, wrote);
    if (rc == 0) return true;
    if (rc == 1) {
      request *q = new_request(d, true, true);
      d->writer = q;
      q->job = agc_io_start(vm, &duplex_io, q, agc_void(), -1);
      vm->task->retry = true;
      return false;
    }
  }
  agc_fail(vm, "RUNTIME-INTERNAL", "cannot write to the parent channel", 0);
}

static agc_value builtin_parent_read_line(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t timeout = agc_as_int(vm, args[0]);
  if (timeout <= 0) return agc_stream_bad_timeout();
  agc_duplex *d = parent_of(vm);
  if (!d) return agc_error_value("process: no parent channel");
  return agc_duplex_read_line(vm, d, vm->parent_locks.reader, timeout);
}

static agc_value builtin_parent_send(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t timeout = agc_as_int(vm, args[1]);
  if (timeout <= 0) return agc_stream_bad_timeout();
  agc_duplex *d = parent_of(vm);
  if (!d) return agc_error_value("process: no parent channel");
  return agc_duplex_send(vm, d, vm->parent_locks.writer, args[0], timeout);
}

const agc_builtin agc_duplex_builtins[] = {
  {"Process.parent_read_line", 1, builtin_parent_read_line, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
  {"Process.parent_send", 2, builtin_parent_send, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
};

const size_t agc_duplex_builtin_count = sizeof agc_duplex_builtins / sizeof agc_duplex_builtins[0];
#else
const agc_builtin agc_duplex_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE, false}};

const size_t agc_duplex_builtin_count = 0;

void agc_parent_take(agc_vm *vm) { (void)vm; }

bool agc_parent_open(agc_vm *vm) {
  (void)vm;
  return false;
}

agc_input_status agc_parent_line(agc_vm *vm, agc_string **line) {
  (void)vm;
  (void)line;
  return AGC_INPUT_FAILED;
}

bool agc_parent_send(agc_vm *vm, const agc_string *text) {
  (void)text;
  agc_fail(vm, "RUNTIME-INTERNAL", "cannot write to the parent channel", 0);
}
#endif
