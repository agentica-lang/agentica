/*
 * The private child channel: a libuv stream to read and one to write (two
 * descriptors of one socket on POSIX, two pipes on Windows), with line reads
 * and writes, for a child process that talks to its parent. The I/O thread
 * owns the streams and the buffer; with several schedulers a call posts its
 * step there and parks. Service layer. The system part is duplex_os.h.
 * Design: docs/vm/10-io-processes.md §10.4, docs/vm/16-architecture.md §16.9.
 */
#include "net_os.h"
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

typedef enum { DX_READ, DX_SEND, DX_SHUT } dx_kind;

typedef struct request request;

/* A request's count on the channel and its slot are taken by its START step, on the I/O thread. A POSTED request
   (several schedulers) carries its result: `finish` fills it there and the done half reads only the request. */
struct request {
  agc_duplex *d;
  agc_io_job *job;
  dx_kind kind;
  bool retry, posted, counted, finished, stopped;
  bool closed, busy, write_closed;
  const char *overflow;
  int write_status;
  size_t count;
  agc_inbuf_cut cut;
  uint8_t *data;
  size_t len;
};

struct agc_duplex {
  agc_loop *io;
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
  /* The schedulers' side of the parent channel with several schedulers (under rt->sync, never read by the I/O
     thread): the line a retry read brought (`got`), the status of a retry send, and `gone` once the channel was seen
     closed. */
  agc_inbuf_cut got;
  bool got_ready, got_closed, got_busy, gone;
  int sent_status;
};

static const char closed_text[] = "process: channel is closed";
static const char busy_text[] = "process: the channel is in use";
static const char too_long[] = "process: line exceeds 1048576 bytes";
static const char at_end[] = "process: end of input";

static agc_value ok_void(void) { return agc_result_value(true, agc_void()); }

static void settle(agc_duplex *d) {
  if (d->refs) return;
  agc_inbuf_free(&d->in);
  agc_inbuf_cut_free(&d->got);
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

static agc_duplex *make(agc_loop *io, int rd_fd, int wr_fd) {
  agc_duplex *d = calloc(1, sizeof(agc_duplex));
  if (!d) agc_out_of_memory();
  d->io = io;
  d->rd_fd = rd_fd;
  d->wr_fd = wr_fd;
  d->refs = 1;
  return d;
}

/* Opens one libuv handle on *fd, which it takes on success. The handle stays initialized (and counted in refs) on a
   failed open too, until agc_duplex_shut closes it. */
static int open_end(agc_duplex *d, uv_pipe_t *pipe, bool *live, int *fd) {
  int rc = uv_pipe_init(agc_loop_uv(d->io), pipe, 0);
  if (rc) return rc;
  pipe->data = d;
  *live = true;
  d->refs++;
  rc = uv_pipe_open(pipe, *fd);
  if (!rc) *fd = -1;
  return rc;
}

static int attach(agc_duplex *d) {
  int rc = open_end(d, &d->rd_pipe, &d->rd_live, &d->rd_fd);
  if (!rc) rc = open_end(d, &d->wr_pipe, &d->wr_live, &d->wr_fd);
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

static void unlink_request(request *q) {
  agc_duplex *d = q->d;
  if (d->reader == q) d->reader = NULL;
  if (d->writer == q) d->writer = NULL;
}

/* A posted request is over: its result goes into it, it leaves its slot and its job is readied; a read cuts its line
   out of the buffer here. I/O thread only. True when the line was longer than the limit: the caller then shuts the
   channel (agc_duplex_shut readies the reader itself, so it is not called from here). */
static bool finish(request *q) {
  if (q->finished) return false;
  agc_duplex *d = q->d;
  q->finished = true;
  unlink_request(q);
  q->closed = d->closed;
  bool cut = false;
  if (q->kind == DX_SEND) {
    q->write_status = d->write_status;
  } else if (q->kind == DX_READ && !q->closed && !q->busy) {
    if (d->overflow && !agc_inbuf_ready(&d->in, true, 0)) {
      q->overflow = d->overflow;
    } else {
      agc_inbuf_cut_line(&d->in, &q->cut);
      cut = true;
    }
  }
  agc_io_ready(q->job);
  return cut && q->cut.status == AGC_CUT_OVER;
}

/* A request's wait is over: one made at N = 1 reads the channel in its done half, a posted one is finished here. */
static void ready(request *q) {
  if (q->posted)
    (void)finish(q);
  else
    agc_io_ready(q->job);
}

void agc_duplex_shut(agc_duplex *d) {
  if (d->closed) return;
  d->closed = true;
  close_end(&d->rd_pipe, &d->rd_live, &d->rd_fd);
  close_end(&d->wr_pipe, &d->wr_live, &d->wr_fd);
  agc_inbuf_free(&d->in);
  if (d->reader) ready(d->reader);
  if (d->writer) ready(d->writer);
}

/* The reader's input is ready (a line, the end, an error or an overflow of the child's stdout). */
static void reader_ready(agc_duplex *d, request *q) {
  if (!q->posted) {
    agc_io_ready(q->job);
    return;
  }
  if (finish(q)) agc_duplex_shut(d);
}

void agc_duplex_overflow(agc_duplex *d, const char *text) {
  if (!d->overflow) d->overflow = text;
  if (d->reader) reader_ready(d, d->reader);
}

void agc_duplex_release(agc_duplex *d) {
  agc_duplex_shut(d);
  unref(d);
}

/* On the I/O thread: from the spawn of the child that gets the channel. */
agc_duplex *agc_duplex_new(agc_loop *io, int read_fd, int write_fd) {
  agc_duplex *d = make(io, read_fd, write_fd);
  if (attach(d) == 0) return d;
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
  request *q = d->reader;
  bool done = q && agc_inbuf_ready(&d->in, true, 0);
  if (n < 0 || !q || done) stop_reading(d);
  if (done) reader_ready(d, q);
}

static void start_reading(agc_duplex *d) {
  if (d->reading || d->in.eof || d->in.error) return;
  int rc = uv_read_start((uv_stream_t *)&d->rd_pipe, alloc_in, read_in);
  if (rc)
    d->in.error = agc_net_errno(rc);
  else
    d->reading = true;
}

static void wrote(uv_write_t *req, int status) {
  agc_duplex *d = OWNER(req, write_req);
  free(d->write_data);
  d->write_data = NULL;
  d->write_status = status;
  if (d->writer) ready(d->writer);
}

static request *new_request(agc_vm *vm, agc_duplex *d, dx_kind kind, bool retry) {
  request *q = calloc(1, sizeof(request));
  if (!q) agc_out_of_memory();
  q->d = d;
  q->kind = kind;
  q->retry = retry;
  q->posted = !agc_io_here(vm);
  return q;
}

/* The START step's count on the channel (I/O thread; at once at N = 1). The slot is the caller's. */
static void link_request(request *q, agc_io_job *job) {
  q->job = job;
  q->counted = true;
  q->d->refs++;
}

/* The end of a request, on the I/O thread: from its done half, or the job's drop. */
static void drop_request(void *data) {
  request *q = data;
  agc_duplex *d = q->d;
  agc_inbuf_cut_free(&q->cut);
  free(q->data);
  bool counted = q->counted;
  if (counted) unlink_request(q);
  free(q);
  if (counted) unref(d);
}

static agc_value take_line(agc_vm *vm, agc_duplex *d) {
  bool over;
  agc_value line = agc_inbuf_line(vm, &d->in, too_long, at_end, &over);
  if (over) agc_duplex_shut(d);
  return line;
}

/* A posted retry request of the parent channel hands its result to the schedulers' side of the channel, where the
   retried call finds it (agc_parent_line, agc_parent_send). */
static void keep_retry(agc_duplex *d, request *q) {
  if (q->kind == DX_SEND) {
    d->sent = true;
    d->sent_status = q->closed || q->busy || q->write_closed ? UV_EPIPE : q->write_status;
    return;
  }
  agc_inbuf_cut_free(&d->got);
  d->got = q->cut;
  q->cut = (agc_inbuf_cut){AGC_CUT_DATA, 0, NULL, 0};
  d->got_ready = true;
  d->got_closed = q->closed;
  d->got_busy = q->busy;
}

static agc_value posted_result(agc_vm *vm, agc_duplex *d, request *q) {
  if (q->retry) {
    keep_retry(d, q);
    return agc_void();
  }
  if (q->closed) return agc_error_value(closed_text);
  if (q->busy) return agc_error_value(busy_text);
  if (q->kind == DX_SHUT) return ok_void();
  if (q->kind == DX_SEND) {
    if (q->write_closed) return agc_error_value(closed_text);
    agc_charge(vm, q->count);
    return agc_stream_written(vm, q->write_status);
  }
  agc_value result = q->overflow ? agc_error_value(q->overflow) : agc_inbuf_cut_line_value(vm, &q->cut, too_long, at_end);
  agc_charge(vm, agc_value_units(result));
  return result;
}

static agc_value request_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  request *q = data;
  agc_duplex *d = q->d;
  if (q->posted) {
    agc_value posted = posted_result(vm, d, q);
    agc_loop_call(agc_io_loop(vm), drop_request, q);
    return posted;
  }
  agc_value result = agc_void();
  unlink_request(q);
  if (q->retry) {
    d->sent = q->kind == DX_SEND;
  } else if (d->closed) {
    result = agc_error_value(closed_text);
  } else if (q->kind == DX_SEND) {
    agc_charge(vm, q->count);
    result = agc_stream_written(vm, d->write_status);
  } else {
    result = d->overflow && !agc_inbuf_ready(&d->in, true, 0) ? agc_error_value(d->overflow) : take_line(vm, d);
    agc_charge(vm, agc_value_units(result));
  }
  drop_request(q);
  return result;
}

static bool request_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  const request *q = data;
  return deadline && q->kind != DX_SEND;
}

/* A deadline stops a posted request on the I/O thread: the kind's `pause`, and the step that `expired` posts (a no-op
   then). The channel closes, as request_expired does at N = 1. */
static void stop_request(void *data) {
  request *q = data;
  if (q->posted && !q->stopped && q->counted) {
    q->stopped = true;
    unlink_request(q);
    agc_duplex_shut(q->d);
  }
}

static agc_value request_expired(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  request *q = data;
  if (!q->posted) {
    unlink_request(q);
    agc_duplex_shut(q->d);
  } else {
    agc_loop_call(agc_io_loop(vm), stop_request, q);
  }
  return agc_stream_timed_out();
}

static const agc_io_kind duplex_io = {NULL,           request_done, request_expired, drop_request, true, "channel",
                                      request_cancel, true,         stop_request};

static void start_request(agc_vm *vm, request *q, agc_value context, int64_t timeout, agc_more_fn begin) {
  (void)agc_io_start_then(vm, &duplex_io, q, context, timeout, begin);
}

/* A read's START. The closed and busy checks are the caller's at N = 1; a posted read makes them here, where the
   channel's state is. */
static bool begin_read(void *data, agc_io_job *job) {
  request *q = data;
  agc_duplex *d = q->d;
  link_request(q, job);
  if (d->closed || d->reader) {
    q->busy = !d->closed;
    ready(q);
    return true;
  }
  d->reader = q;
  if (!agc_inbuf_ready(&d->in, true, 0)) {
    if (q->posted && d->overflow) {
      ready(q);
      return true;
    }
    start_reading(d);
  }
  if (agc_inbuf_ready(&d->in, true, 0)) reader_ready(d, q);
  return true;
}

/* A send's START. At N = 1 the caller started the write and the request only waits for its end; a posted send makes
   the checks and the write here, from its copy of the bytes. */
static bool begin_send(void *data, agc_io_job *job) {
  request *q = data;
  agc_duplex *d = q->d;
  link_request(q, job);
  if (!q->posted) {
    d->writer = q;
    return true;
  }
  if (d->closed || d->writer || d->write_closed) {
    q->busy = !d->closed && d->writer;
    q->write_closed = !d->closed && !d->writer;
    (void)finish(q);
    return true;
  }
  d->writer = q;
  d->write_status = 0;
  int rc = agc_stream_write((uv_stream_t *)&d->wr_pipe, &d->write_req, &d->write_data, q->data, q->len, wrote);
  /* agc_stream_write keeps its own copy of what it could not write at once. */
  free(q->data);
  q->data = NULL;
  if (rc < 0) d->write_status = rc;
  if (rc != 1) (void)finish(q);
  return true;
}

static void shut_write(agc_duplex *d) {
  d->write_closed = true;
  d->refs++;
  if (uv_shutdown(&d->shutdown_req, (uv_stream_t *)&d->wr_pipe, shutdown_done)) d->refs--;
}

static bool begin_shut(void *data, agc_io_job *job) {
  request *q = data;
  agc_duplex *d = q->d;
  link_request(q, job);
  if (!d->closed && !d->write_closed) shut_write(d);
  (void)finish(q);
  return true;
}

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
  if (!agc_stream_lock(vm, lock, &timeout, &result)) return result;
  if (agc_io_here(vm)) {
    if (!usable(d, d->reader, &result)) return result;
    if (agc_inbuf_ready(&d->in, true, 0)) return take_line(vm, d);
    if (d->overflow) return agc_error_value(d->overflow);
  }
  start_request(vm, new_request(vm, d, DX_READ, false), agc_handle_value(lock), timeout, begin_read);
  return agc_void();
}

/* A posted send carries its own copy of the bytes: the I/O thread writes from it after the call has returned. */
static void copy_text(request *q, const agc_string *text) {
  q->len = text->bytes;
  if (!q->len) return;
  q->data = malloc(q->len);
  if (!q->data) agc_out_of_memory();
  memcpy(q->data, text->data, q->len);
}

agc_value agc_duplex_send(agc_vm *vm, agc_duplex *d, agc_resource *lock, agc_value line, int64_t timeout) {
  agc_value result;
  const agc_string *text = agc_as_string(vm, line);
  if (text->bytes > LIMIT) return agc_error_value("process: send exceeds 1048576 bytes");
  if (!agc_stream_lock(vm, lock, &timeout, &result)) return result;
  request *q = new_request(vm, d, DX_SEND, false);
  q->count = (size_t)agc_value_units(line);
  if (q->posted) {
    copy_text(q, text);
  } else {
    int rc = usable(d, d->writer, &result) ? 1 : -1;
    if (rc > 0 && d->write_closed) {
      result = agc_error_value(closed_text);
      rc = -1;
    }
    if (rc > 0) {
      d->write_status = 0;
      rc = agc_stream_write((uv_stream_t *)&d->wr_pipe, &d->write_req, &d->write_data, (const uint8_t *)text->data,
                            text->bytes, wrote);
      if (rc <= 0) result = agc_stream_written(vm, rc);
    }
    if (rc != 1) {
      free(q);
      return result;
    }
  }
  start_request(vm, q, agc_handle_value(lock), timeout, begin_send);
  return agc_void();
}

agc_value agc_duplex_close_write(agc_vm *vm, agc_duplex *d, agc_resource *lock, int64_t timeout) {
  agc_value result;
  if (!agc_stream_lock(vm, lock, &timeout, &result)) return result;
  if (!agc_io_here(vm)) {
    start_request(vm, new_request(vm, d, DX_SHUT, false), agc_handle_value(lock), timeout, begin_shut);
    return agc_void();
  }
  if (d->closed) return agc_error_value(closed_text);
  if (!d->write_closed) shut_write(d);
  return ok_void();
}

/* The parent channel opens at its first use while one thread plays both roles; with several schedulers it opens at
   the start of the run (agc_parent_take), on the thread that becomes the I/O thread. */
static agc_duplex *parent_of(agc_vm *vm) {
  agc_duplex *d = vm->rt->parent ? vm->rt->parent->native : NULL;
  if (d && !d->attached && !d->closed) attach(d);
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
  agc_duplex *d = make(agc_io_loop(vm), read_fd, write_fd);
  vm->rt->parent = agc_register(vm, d, release_parent);
  vm->rt->parent_locks = (agc_lines){agc_new_lock(vm), agc_new_lock(vm)};
  if (vm->rt->schedulers > 1) {
    attach(d);
    d->gone = d->closed;
  }
}

/* Whether the parent channel is open, as the calling thread can know it: with several schedulers the I/O thread owns
   `closed`, and the schedulers see it closed once a read has found it so (`gone`). */
static bool parent_live(agc_vm *vm, const agc_duplex *d) { return agc_io_here(vm) ? !d->closed : !d->gone; }

bool agc_parent_open(agc_vm *vm) {
  const agc_duplex *d = parent_of(vm);
  return d && parent_live(vm, d);
}

static agc_duplex *opened(agc_vm *vm) {
  agc_duplex *d = vm->rt->parent ? vm->rt->parent->native : NULL;
  return d && d->attached && parent_live(vm, d) ? d : NULL;
}

/* agc_parent_line with several schedulers: a retry read posts its request and parks; the retried call takes the line
   that the request's done half kept. */
static agc_input_status parent_line_posted(agc_vm *vm, agc_duplex *d, agc_string **line) {
  if (!d->got_ready) {
    start_request(vm, new_request(vm, d, DX_READ, true), agc_void(), -1, begin_read);
    vm->task->retry = true;
    return AGC_INPUT_WAIT;
  }
  d->got_ready = false;
  agc_inbuf_cut cut = d->got;
  d->got = (agc_inbuf_cut){AGC_CUT_DATA, 0, NULL, 0};
  agc_input_status status = AGC_INPUT_FAILED;
  if (d->got_closed || (!d->got_busy && cut.status == AGC_CUT_OVER)) {
    d->gone = true;
  } else if (!d->got_busy && cut.status == AGC_CUT_END) {
    status = AGC_INPUT_EOF;
  } else if (!d->got_busy) {
    const agc_result *r = agc_as_result(vm, agc_inbuf_cut_line_value(vm, &cut, too_long, at_end));
    if (r->ok) {
      *line = agc_as_string(vm, r->value);
      status = AGC_INPUT_OK;
    }
  }
  agc_inbuf_cut_free(&cut);
  return status;
}

agc_input_status agc_parent_line(agc_vm *vm, agc_string **line) {
  agc_duplex *d = opened(vm);
  if (!d) return AGC_INPUT_FAILED;
  if (!agc_io_here(vm)) return parent_line_posted(vm, d, line);
  if (d->reader) return AGC_INPUT_FAILED;
  if (!agc_inbuf_ready(&d->in, true, 0)) {
    start_request(vm, new_request(vm, d, DX_READ, true), agc_void(), -1, begin_read);
    vm->task->retry = true;
    return AGC_INPUT_WAIT;
  }
  if (agc_inbuf_pending(&d->in) == 0 && d->in.eof) return AGC_INPUT_EOF;
  agc_value found = take_line(vm, d);
  const agc_result *r = agc_as_result(vm, found);
  if (!r->ok) return AGC_INPUT_FAILED;
  *line = agc_as_string(vm, r->value);
  return AGC_INPUT_OK;
}

/* A retry send: false parks the task (the call comes back once the send is out), true when the record is sent. */
bool agc_parent_send(agc_vm *vm, const agc_string *text) {
  agc_duplex *d = opened(vm);
  bool here = agc_io_here(vm);
  if (d && d->sent) {
    d->sent = false;
    if ((here ? d->write_status : d->sent_status) >= 0) return true;
  } else if (d && !here) {
    request *q = new_request(vm, d, DX_SEND, true);
    copy_text(q, text);
    start_request(vm, q, agc_void(), -1, begin_send);
    vm->task->retry = true;
    return false;
  } else if (d && !d->writer && !d->write_closed) {
    d->write_status = 0;
    int rc = agc_stream_write((uv_stream_t *)&d->wr_pipe, &d->write_req, &d->write_data, (const uint8_t *)text->data,
                              text->bytes, wrote);
    if (rc == 0) return true;
    if (rc == 1) {
      start_request(vm, new_request(vm, d, DX_SEND, true), agc_void(), -1, begin_send);
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
  return agc_duplex_read_line(vm, d, vm->rt->parent_locks.reader, timeout);
}

static agc_value builtin_parent_send(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t timeout = agc_as_int(vm, args[1]);
  if (timeout <= 0) return agc_stream_bad_timeout();
  agc_duplex *d = parent_of(vm);
  if (!d) return agc_error_value("process: no parent channel");
  return agc_duplex_send(vm, d, vm->rt->parent_locks.writer, args[0], timeout);
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
