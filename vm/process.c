#include "services.h"

#ifdef __linux__
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <uv.h>

#define LIMIT ((size_t)1048576)
#define ERR_CHUNK 4096
#define REAP_MS 1000
#define GRACE_MS 1000
#define URING_ENV "UV_USE_IO_URING="
#define OWNER(ptr, field) ((proc *)(void *)((char *)(ptr) - offsetof(proc, field)))

typedef enum { REQ_LINE, REQ_BYTES, REQ_SEND, REQ_WAIT, REQ_OUTPUT, REQ_CLOSE } req_kind;
typedef enum { STOP_NONE, STOP_TERM, STOP_KILLED } stop_state;

typedef struct proc proc;
typedef struct request request;
typedef struct guard guard;

struct request {
  req_kind kind;
  proc *p;
  agc_io_job *job;
  request *next;
  size_t count;
};

struct guard {
  agc_trace trace;
  uv_loop_t *loop;
  proc *first;
  size_t running;
  bool released, reaping;
};

struct proc {
  agc_trace trace;
  uv_process_t process;
  uv_pipe_t in, out, err;
  uv_timer_t grace;
  uv_write_t write_req;
  FILE *forward;
  guard *g;
  proc *run_prev, *run_next;
  size_t users, handles;
  bool linked, running, exited, err_done, in_closed, closed, reading, forward_failed;
  bool captured, out_cut, err_cut, stop_failed;
  stop_state stop;
  int write_status;
  int64_t status;
  uint8_t *write_data;
  agc_inbuf out_buf, err_kept;
  request *reader, *writer, *waits;
  uint8_t err_buf[ERR_CHUNK];
};

static const char closed_text[] = "process: process is closed";
static const char write_failed[] = "error writing to stream port";
static const char over_text[] = "process: output exceeds 1048576 bytes";

static agc_value ok_void(void) { return agc_result_value(true, agc_void()); }

static void settle(proc *p) {
  if (p->users || p->handles) return;
  agc_inbuf_free(&p->out_buf);
  agc_inbuf_free(&p->err_kept);
  free(p->write_data);
  free(p);
}

static void handle_gone(proc *p) {
  p->handles--;
  settle(p);
}

static void closed_process(uv_handle_t *h) { handle_gone(OWNER(h, process)); }

static void closed_in(uv_handle_t *h) { handle_gone(OWNER(h, in)); }

static void closed_out(uv_handle_t *h) { handle_gone(OWNER(h, out)); }

static void closed_err(uv_handle_t *h) { handle_gone(OWNER(h, err)); }

static void closed_grace(uv_handle_t *h) { handle_gone(OWNER(h, grace)); }

static void close_handle(uv_handle_t *h, uv_close_cb done) {
  if (!uv_is_closing(h)) uv_close(h, done);
}

static void guard_settle(guard *g) {
  if (g->released && !g->running) free(g);
}

static void unlink_child(proc *p) {
  guard *g = p->g;
  p->g = NULL;
  p->linked = false;
  if (p->run_prev)
    p->run_prev->run_next = p->run_next;
  else
    g->first = p->run_next;
  if (p->run_next) p->run_next->run_prev = p->run_prev;
  p->run_prev = p->run_next = NULL;
  if (--g->running) return;
  guard_settle(g);
}

static bool wait_over(const proc *p) { return p->closed || (p->exited && p->err_done); }

static bool output_over(const proc *p) {
  return p->closed || ((p->out_buf.eof || p->out_buf.error) && p->err_done);
}

static bool waits_over(const proc *p, req_kind kind) {
  if (kind == REQ_CLOSE) return !p->running;
  return kind == REQ_WAIT ? wait_over(p) : output_over(p);
}

static void notify_waits(proc *p) {
  for (request *q = p->waits; q; q = q->next)
    if (waits_over(p, q->kind)) agc_io_ready(q->job);
}

static void finished(proc *p, int64_t status) {
  p->running = false;
  p->exited = true;
  p->status = status;
  if (p->linked) unlink_child(p);
}

static int signal_child(proc *p, int sig) {
  int rc = uv_process_kill(&p->process, sig);
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "%s pid=%d rc=%d", sig == SIGKILL ? "kill" : "term", (int)p->process.pid, rc);
  p->stop = sig == SIGTERM && !rc ? STOP_TERM : STOP_KILLED;
  p->stop_failed = rc != 0;
  return rc;
}

/* A captured child's pipes close at once, but its uv_process_t stays open
   until it exits, and its grace timer until it exits or got SIGKILL. */
static void retire(proc *p) {
  if (!p->closed) return;
  if (p->captured && (!p->running || p->stop == STOP_KILLED)) close_handle((uv_handle_t *)&p->grace, closed_grace);
  if (!p->running) close_handle((uv_handle_t *)&p->process, closed_process);
}

static void grace_over(uv_timer_t *t) {
  proc *p = OWNER(t, grace);
  if (p->running && p->stop == STOP_TERM) signal_child(p, SIGKILL);
  retire(p);
}

/* docs/vm/10-io-processes.md §10.4: a captured child gets SIGTERM and one
   second, from a timer, so a child that is a VM can stop its own children;
   the program never waits. A plain child gets SIGKILL and libuv's exit
   callback reaps it. */
static int shut(proc *p) {
  if (p->closed) return 0;
  p->closed = true;
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "close pid=%d running=%d", (int)p->process.pid, p->running ? 1 : 0);
  int err = 0;
  if (p->running && p->captured) {
    if (p->stop == STOP_NONE) {
      err = signal_child(p, SIGTERM);
      if (!err) uv_timer_start(&p->grace, grace_over, GRACE_MS, 0);
    }
  } else if (p->running) {
    err = signal_child(p, SIGKILL);
  }
  close_handle((uv_handle_t *)&p->in, closed_in);
  close_handle((uv_handle_t *)&p->out, closed_out);
  close_handle((uv_handle_t *)&p->err, closed_err);
  agc_inbuf_free(&p->out_buf);
  agc_inbuf_free(&p->err_kept);
  if (p->reader) agc_io_ready(p->reader->job);
  if (p->writer) agc_io_ready(p->writer->job);
  notify_waits(p);
  retire(p);
  return err;
}

static bool in_grace(const proc *p) { return p->captured && p->running && p->stop == STOP_TERM; }

static bool to_await(const proc *p, bool grace) { return grace ? in_grace(p) : !p->stop_failed; }

static bool exits_pending(const guard *g, bool grace) {
  for (const proc *p = g->first; p; p = p->run_next)
    if (to_await(p, grace)) return true;
  return false;
}

static void trace_alive(const proc *p) {
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "reap pid=%d alive=1", (int)p->process.pid);
}

static void bound_over(uv_timer_t *timer) { (void)timer; }

/* The end of the run drives the loop for at most REAP_MS, so the exit
   callbacks reap the children. A child that cannot be killed is not awaited. */
static void await_exits(guard *g, bool grace) {
  if (!exits_pending(g, grace)) return;
  uv_timer_t bound;
  uv_update_time(g->loop);
  uv_timer_init(g->loop, &bound);
  uv_timer_start(&bound, bound_over, REAP_MS, 0);
  while (uv_is_active((uv_handle_t *)&bound) && exits_pending(g, grace)) uv_run(g->loop, UV_RUN_ONCE);
  if (!grace)
    for (const proc *p = g->first; p; p = p->run_next)
      if (to_await(p, grace)) trace_alive(p);
  uv_close((uv_handle_t *)&bound, NULL);
  uv_run(g->loop, UV_RUN_NOWAIT);
}

/* Plain children get SIGKILL at once; captured ones SIGTERM, then SIGKILL
   when the grace wait is over, then one more wait for the exits. */
static void close_children(guard *g) {
  if (g->reaping) return;
  g->reaping = true;
  bool grace = false;
  for (proc *p = g->first; p; p = p->run_next) {
    if (p->running && p->captured && p->stop == STOP_NONE)
      signal_child(p, SIGTERM);
    else if (p->running && !p->captured && !p->closed)
      signal_child(p, SIGKILL);
    grace = grace || in_grace(p);
  }
  if (grace) await_exits(g, true);
  for (proc *p = g->first, *next = NULL; p; p = next) {
    next = p->run_next;
    if (p->captured && p->running && p->stop == STOP_TERM) signal_child(p, SIGKILL);
    shut(p);
  }
  await_exits(g, false);
}

static void release_proc(void *native) {
  proc *p = native;
  if (p->g) close_children(p->g);
  shut(p);
  p->users--;
  settle(p);
}

static request *new_request(proc *p, req_kind kind) {
  request *q = calloc(1, sizeof(request));
  if (!q) agc_out_of_memory();
  q->kind = kind;
  q->p = p;
  p->users++;
  return q;
}

static void unlink_request(request *q) {
  proc *p = q->p;
  if (p->reader == q) p->reader = NULL;
  if (p->writer == q) p->writer = NULL;
  for (request **at = &p->waits; *at; at = &(*at)->next) {
    if (*at != q) continue;
    *at = q->next;
    break;
  }
  q->next = NULL;
}

static void drop_request(void *data) {
  request *q = data;
  proc *p = q->p;
  unlink_request(q);
  free(q);
  p->users--;
  settle(p);
}

static bool read_ready(proc *p, req_kind kind, size_t count) {
  return p->closed || p->out_cut || p->err_cut || agc_inbuf_ready(&p->out_buf, kind == REQ_LINE, count);
}

static agc_value take(agc_vm *vm, proc *p, req_kind kind, size_t count) {
  if (p->closed) return agc_error_value(closed_text);
  if (p->out_cut || p->err_cut) return agc_error_value(over_text);
  if (kind != REQ_LINE) return agc_inbuf_bytes(vm, &p->out_buf, count);
  bool over;
  agc_value line = agc_inbuf_line(vm, &p->out_buf, "process: line exceeds 1048576 bytes", "process: end of input", &over);
  if (over) shut(p);
  return line;
}

static const uint8_t *pending_data(const agc_inbuf *b) {
  return agc_inbuf_pending(b) ? b->data + b->start : (const uint8_t *)"";
}

static uint32_t output_struct(agc_vm *vm) {
  static const char *const fields[] = {"stdout", "stderr", "truncated"};
  return agc_builtin_struct(vm, "ProcessOutput", fields, 3);
}

static agc_value output_value(agc_vm *vm, const proc *p) {
  size_t out = agc_inbuf_pending(&p->out_buf), err = agc_inbuf_pending(&p->err_kept);
  agc_charge_bytes(vm, agc_size_add(out, err));
  agc_struct *s = agc_new_struct(output_struct(vm), 3);
  s->fields[0] = agc_string_value(agc_utf8_decode(pending_data(&p->out_buf), out, "\xEF\xBF\xBD", false));
  s->fields[1] = agc_string_value(agc_utf8_decode(pending_data(&p->err_kept), err, "\xEF\xBF\xBD", false));
  s->fields[2] = agc_bool(p->out_cut || p->err_cut);
  return agc_result_value(true, agc_struct_value(s));
}

static agc_value waited(agc_vm *vm, const proc *p, req_kind kind) {
  return kind == REQ_WAIT ? agc_result_value(true, agc_int(p->status)) : output_value(vm, p);
}

static agc_value request_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  request *q = data;
  proc *p = q->p;
  unlink_request(q);
  if (q->kind == REQ_SEND) agc_charge(vm, q->count);
  agc_value result;
  if (q->kind == REQ_CLOSE) {
    result = agc_void();
  } else if (q->kind == REQ_LINE || q->kind == REQ_BYTES) {
    result = take(vm, p, q->kind, q->count);
    agc_charge(vm, agc_value_units(result));
  } else if (p->closed) {
    result = agc_error_value(closed_text);
  } else if (q->kind == REQ_WAIT || q->kind == REQ_OUTPUT) {
    result = waited(vm, p, q->kind);
  } else {
    result = p->write_status < 0 ? agc_system_error(vm, write_failed, -p->write_status) : ok_void();
  }
  drop_request(q);
  return result;
}

static agc_value request_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  request *q = data;
  unlink_request(q);
  if (q->kind == REQ_CLOSE) {
    trace_alive(q->p);
    return agc_void();
  }
  if (q->kind != REQ_WAIT && q->kind != REQ_OUTPUT) shut(q->p);
  return agc_stream_timed_out();
}

static bool request_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  const request *q = data;
  return deadline && q->kind != REQ_SEND;
}

static const agc_io_kind process_io = {NULL, request_done, request_expired, drop_request, true, "process", request_cancel};

static void wrote(uv_write_t *w, int status) {
  proc *p = OWNER(w, write_req);
  free(p->write_data);
  p->write_data = NULL;
  p->write_status = status;
  if (p->writer) agc_io_ready(p->writer->job);
}

static void exited(uv_process_t *h, int64_t status, int signal) {
  proc *p = OWNER(h, process);
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "exit pid=%d status=%" PRId64 " signal=%d", (int)h->pid, status, signal);
  finished(p, signal ? 128 + signal : status);
  retire(p);
  notify_waits(p);
}

static void link_child(guard *g, proc *p) {
  p->g = g;
  p->linked = true;
  p->run_prev = NULL;
  p->run_next = g->first;
  if (g->first) g->first->run_prev = p;
  g->first = p;
  g->running++;
}

static void release_guard(void *native) {
  guard *g = native;
  AGC_TRACE(&g->trace, AGC_TRACE_PROC, "guard_cleanup running=%zu", g->running);
  close_children(g);
  g->released = true;
  guard_settle(g);
}

void agc_processes_stop(agc_vm *vm) {
  if (vm->process_guard && vm->process_guard->native) close_children(vm->process_guard->native);
}

static bool keep_private(int fd, void *data) {
  (void)data;
  int flags = fd > 2 ? fcntl(fd, F_GETFD) : -1;
  if (flags >= 0 && !(flags & FD_CLOEXEC)) fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
  return false;
}

static guard *guard_of(agc_vm *vm) {
  if (vm->process_guard) return vm->process_guard->native;
  agc_resource *r = agc_register(vm, NULL, release_guard);
  guard *g = calloc(1, sizeof(guard));
  if (!g) agc_out_of_memory();
  g->trace = vm->rt->trace;
  g->loop = agc_io_uv(vm);
  agc_each_fd(keep_private, NULL);
  r->native = g;
  vm->process_guard = r;
  return g;
}

static void alloc_err(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  (void)suggested;
  proc *p = OWNER(h, err);
  *buf = uv_buf_init((char *)p->err_buf, sizeof p->err_buf);
}

static void forward_err(uv_stream_t *s, ssize_t n, const uv_buf_t *buf) {
  proc *p = OWNER(s, err);
  if (n > 0 && !p->forward_failed &&
      (fwrite(buf->base, 1, (size_t)n, p->forward) != (size_t)n || fflush(p->forward) != 0))
    p->forward_failed = true;
  if (n > 0)
    AGC_TRACE(&p->trace, AGC_TRACE_PROC, "stderr pid=%d bytes=%zd failed=%d", (int)p->process.pid, n,
              p->forward_failed ? 1 : 0);
  if (n >= 0) return;
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "eof pid=%d pipe=stderr error=%d", (int)p->process.pid,
            n == UV_EOF ? 0 : (int)-n);
  uv_read_stop(s);
  p->err_done = true;
  notify_waits(p);
}

static void alloc_out(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  (void)suggested;
  proc *p = OWNER(h, out);
  const request *q = p->reader;
  size_t size = agc_inbuf_want(&p->out_buf, !q || q->kind != REQ_BYTES, q ? q->count : 0);
  uint8_t *room = agc_inbuf_room(&p->out_buf, size);
  *buf = room ? uv_buf_init((char *)room, (unsigned)size) : uv_buf_init(NULL, 0);
}

static void stop_reading(proc *p) {
  if (!p->reading) return;
  uv_read_stop((uv_stream_t *)&p->out);
  p->reading = false;
}

static void read_out(uv_stream_t *s, ssize_t n, const uv_buf_t *buf) {
  (void)buf;
  proc *p = OWNER(s, out);
  agc_inbuf_got(&p->out_buf, n, n == UV_EOF);
  if (n < 0)
    AGC_TRACE(&p->trace, AGC_TRACE_PROC, "eof pid=%d pipe=stdout error=%d", (int)p->process.pid, p->out_buf.error);
  request *q = p->reader;
  bool ready = q && read_ready(p, q->kind, q->count);
  if (n < 0 || !q || ready) stop_reading(p);
  if (ready) agc_io_ready(q->job);
}

static void start_reading(proc *p) {
  if (p->captured || p->reading || p->out_buf.eof || p->out_buf.error) return;
  int rc = uv_read_start((uv_stream_t *)&p->out, alloc_out, read_out);
  if (rc)
    p->out_buf.error = -rc;
  else
    p->reading = true;
}

/* Near the limit a chunk goes to the scratch buffer and only what fits is
   copied, so a kept buffer never grows past 1 MiB of capacity. */
static void alloc_kept(proc *p, agc_inbuf *b, bool cut, uv_buf_t *buf) {
  size_t size = sizeof p->err_buf;
  bool near = agc_inbuf_pending(b) > LIMIT - size;
  uint8_t *room = cut || near ? p->err_buf : agc_inbuf_room(b, size);
  *buf = room ? uv_buf_init((char *)room, (unsigned)size) : uv_buf_init(NULL, 0);
}

static void keep_scratch(proc *p, agc_inbuf *b, bool *cut, size_t n, const char *pipe) {
  size_t left = LIMIT - agc_inbuf_pending(b);
  size_t kept = n < left ? n : left;
  uint8_t *to = kept ? agc_inbuf_room(b, kept) : NULL;
  if (to) {
    memcpy(to, p->err_buf, kept);
    agc_inbuf_got(b, (int64_t)kept, false);
  } else if (kept) {
    agc_inbuf_got(b, UV_ENOBUFS, false);
  }
  if (n <= left) return;
  *cut = true;
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "truncated pid=%d pipe=%s", (int)p->process.pid, pipe);
  if (p->reader) agc_io_ready(p->reader->job);
}

/* Once cut, a stream's bytes are dropped; a cut wakes the reader, since
   every stdout read now fails (docs/vm/10-io-processes.md §10.4). */
static bool keep(proc *p, agc_inbuf *b, bool *cut, ssize_t n, const uv_buf_t *buf, const char *pipe) {
  if (n > 0 && !*cut) {
    if (buf->base == (char *)p->err_buf)
      keep_scratch(p, b, cut, (size_t)n, pipe);
    else
      agc_inbuf_got(b, n, false);
  }
  if (n >= 0) return false;
  agc_inbuf_got(b, n, n == UV_EOF);
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "eof pid=%d pipe=%s error=%d", (int)p->process.pid, pipe,
            n == UV_EOF ? 0 : (int)-n);
  return true;
}

static void alloc_kept_out(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  (void)suggested;
  proc *p = OWNER(h, out);
  alloc_kept(p, &p->out_buf, p->out_cut, buf);
}

static void alloc_kept_err(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  (void)suggested;
  proc *p = OWNER(h, err);
  alloc_kept(p, &p->err_kept, p->err_cut, buf);
}

static void read_kept_out(uv_stream_t *s, ssize_t n, const uv_buf_t *buf) {
  proc *p = OWNER(s, out);
  if (keep(p, &p->out_buf, &p->out_cut, n, buf, "stdout")) {
    uv_read_stop(s);
    notify_waits(p);
  }
  const request *q = p->reader;
  if (q && read_ready(p, q->kind, q->count)) agc_io_ready(q->job);
}

static void read_kept_err(uv_stream_t *s, ssize_t n, const uv_buf_t *buf) {
  proc *p = OWNER(s, err);
  if (!keep(p, &p->err_kept, &p->err_cut, n, buf, "stderr")) return;
  uv_read_stop(s);
  p->err_done = true;
  notify_waits(p);
}

static int start_kept(proc *p) {
  int rc = uv_read_start((uv_stream_t *)&p->out, alloc_kept_out, read_kept_out);
  return rc ? rc : uv_read_start((uv_stream_t *)&p->err, alloc_kept_err, read_kept_err);
}

static bool runnable(const char *path) {
  struct stat info;
  return stat(path, &info) == 0 && !S_ISDIR(info.st_mode);
}

static char *candidate(agc_vm *vm, const char *dir, size_t dir_len, const agc_string *name) {
  size_t len = agc_size_add(agc_size_add(dir_len, 1), name->bytes);
  agc_string *joined = agc_new_string(len, 0);
  memcpy(joined->data, dir, dir_len);
  joined->data[dir_len] = '/';
  memcpy(joined->data + dir_len + 1, name->data, name->bytes);
  return agc_host_path(vm, joined);
}

static char *resolve(agc_vm *vm, const agc_string *command) {
  if (memchr(command->data, '/', command->bytes)) {
    char *path = agc_host_path(vm, command);
    if (runnable(path)) return path;
    free(path);
    return NULL;
  }
  const char *search = getenv("PATH");
  for (const char *at = search; at;) {
    const char *end = strchr(at, ':');
    size_t len = end ? (size_t)(end - at) : strlen(at);
    if (len) {
      char *path = candidate(vm, at, len, command);
      if (runnable(path)) return path;
      free(path);
    }
    at = end ? end + 1 : NULL;
  }
  return NULL;
}

static char **child_args(agc_vm *vm, char *path, const agc_list *list) {
  char **argv = calloc(agc_size_add(list->len, 2), sizeof(char *));
  if (!argv) agc_out_of_memory();
  argv[0] = path;
  for (size_t k = 0; k < list->len; k++) argv[k + 1] = agc_cstr(agc_as_string(vm, list->items[k]));
  return argv;
}

static char **child_env(void) {
  extern char **environ; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
  size_t n = 0;
  while (environ[n]) n++;
  char **env = calloc(agc_size_add(n, 1), sizeof(char *));
  if (!env) agc_out_of_memory();
  size_t kept = 0;
  for (size_t k = 0; k < n; k++)
    if (strncmp(environ[k], URING_ENV, sizeof URING_ENV - 1) != 0) env[kept++] = environ[k];
  return env;
}

static void close_fd(int *fd) {
  if (*fd >= 0) close(*fd);
  *fd = -1;
}

static int open_pipe(uv_pipe_t *pipe, int *fd, int rc) {
  if (rc) return rc;
  rc = uv_pipe_open(pipe, *fd);
  if (!rc) *fd = -1;
  return rc;
}

static int start_child(guard *g, proc *p, char **argv, char **env, const char *cwd) {
  int fds[6] = {-1, -1, -1, -1, -1, -1};
  int rc = 0;
  for (size_t k = 0; !rc && k < 3; k++) rc = uv_pipe(fds + 2 * k, 0, 0);
  if (!rc) {
    uv_stdio_container_t stdio[3];
    for (size_t k = 0; k < 3; k++) {
      stdio[k].flags = UV_INHERIT_FD;
      stdio[k].data.fd = fds[2 * k + (k == 0 ? 0 : 1)];
    }
    uv_process_options_t options;
    memset(&options, 0, sizeof options);
    options.exit_cb = exited;
    options.file = argv[0];
    options.args = argv;
    options.env = env;
    options.cwd = cwd;
    options.stdio_count = 3;
    options.stdio = stdio;
    link_child(g, p);
    rc = uv_spawn(g->loop, &p->process, &options);
    p->handles = 1;
    p->running = !rc;
    if (rc) {
      uv_close((uv_handle_t *)&p->process, closed_process);
      unlink_child(p);
    }
  }
  close_fd(&fds[0]);
  close_fd(&fds[3]);
  close_fd(&fds[5]);
  if (!rc) {
    uv_pipe_init(g->loop, &p->in, 0);
    uv_pipe_init(g->loop, &p->out, 0);
    uv_pipe_init(g->loop, &p->err, 0);
    p->handles = 4;
    if (p->captured) {
      uv_timer_init(g->loop, &p->grace);
      p->handles++;
    }
    rc = open_pipe(&p->err, &fds[4], open_pipe(&p->out, &fds[2], open_pipe(&p->in, &fds[1], 0)));
    if (!rc) rc = p->captured ? start_kept(p) : uv_read_start((uv_stream_t *)&p->err, alloc_err, forward_err);
  }
  close_fd(&fds[1]);
  close_fd(&fds[2]);
  close_fd(&fds[4]);
  if (rc && p->running) shut(p);
  return rc;
}

static bool no_nul(const agc_string *s) { return !memchr(s->data, 0, s->bytes); }

static char *child_dir(agc_vm *vm, const agc_string *dir, bool *found) {
  *found = true;
  if (!dir || (dir->bytes == 1 && dir->data[0] == '.')) return NULL;
  char *path = agc_host_path(vm, dir);
  struct stat info;
  *found = stat(path, &info) == 0 && S_ISDIR(info.st_mode);
  return path;
}

static proc *unregister_child(agc_vm *vm, agc_resource *r) {
  proc *p = r->native;
  if (!p) return NULL;
  r->native = NULL;
  agc_unregister(vm, r);
  return p;
}

static void close_child(agc_vm *vm, agc_resource *r) {
  proc *p = unregister_child(vm, r);
  if (!p) return;
  shut(p);
  p->users--;
  settle(p);
}

/* dir is NULL for Process.spawn; "." keeps the VM's directory. The command
   resolves before the child changes directory (§10.4). */
static agc_value spawn_child(agc_vm *vm, const agc_value *args, const agc_string *dir, int64_t timeout) {
  if (!vm->rt->allow_run) return agc_error_value("process: spawning requires --allow-run");
  const agc_string *command = agc_as_string(vm, args[0]);
  const agc_list *list = agc_as_list(vm, args[1]);
  bool valid = command->bytes > 0 && no_nul(command);
  for (size_t k = 0; k < list->len; k++) valid = valid && no_nul(agc_as_string(vm, list->items[k]));
  if (!valid) return agc_error_value("process: command must be nonempty and arguments cannot contain NUL");
  if (dir && (dir->bytes == 0 || !no_nul(dir)))
    return agc_error_value("process: dir must be nonempty and cannot contain NUL");
  if (timeout <= 0) return agc_stream_bad_timeout();
  agc_process *pr = agc_alloc(sizeof(agc_process));
  pr->reader = agc_new_lock(vm);
  pr->writer = agc_new_lock(vm);
  guard *g = guard_of(vm);
  char *path = resolve(vm, command);
  if (!path) {
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_PROC, "spawn_failed reason=unresolved");
    return agc_error_value("process: executable is unavailable");
  }
  bool found;
  char *cwd = child_dir(vm, dir, &found);
  if (!found) {
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_PROC, "spawn_failed reason=dir");
    free(path);
    free(cwd);
    return agc_error_value("process: directory is unavailable");
  }
  char **argv = child_args(vm, path, list);
  char **env = vm->rt->drop_uring_env ? child_env() : NULL;
  proc *p = calloc(1, sizeof(proc));
  if (!p) agc_out_of_memory();
  p->trace = vm->rt->trace;
  p->forward = vm->rt->err.file;
  p->captured = dir != NULL;
  int rc = start_child(g, p, argv, env, cwd);
  if (rc)
    AGC_TRACE(&p->trace, AGC_TRACE_PROC, "spawn_failed path=%s rc=%d", path, rc);
  else
    AGC_TRACE(&p->trace, AGC_TRACE_PROC, "spawn pid=%d path=%s args=%zu captured=%d", (int)p->process.pid, path,
              list->len, p->captured ? 1 : 0);
  for (size_t k = 0; argv[k]; k++) free(argv[k]);
  free(argv);
  free(env);
  free(cwd);
  if (rc) {
    settle(p);
    return agc_system_error(vm, "process: cannot run the executable", -rc);
  }
  p->users = 1;
  pr->state = agc_register(vm, p, release_proc);
  pr->state->keep_detached = true;
  agc_own(vm, pr->state, close_child);
  return agc_result_value(true, agc_process_value(pr));
}

static agc_value builtin_spawn(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return spawn_child(vm, args, NULL, agc_as_int(vm, args[2]));
}

static agc_value builtin_spawn_captured(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return spawn_child(vm, args, agc_as_string(vm, args[2]), agc_as_int(vm, args[3]));
}

static proc *live(const agc_process *pr) {
  proc *p = pr->state->native;
  return p && !p->closed ? p : NULL;
}

static agc_value read_op(agc_vm *vm, agc_value handle, req_kind kind, size_t count, int64_t timeout) {
  agc_process *pr = agc_as_process(vm, handle);
  agc_value result;
  if (!agc_stream_lock(vm, pr->reader, &timeout, &result)) return result;
  proc *p = live(pr);
  if (!p) return agc_error_value(closed_text);
  if (read_ready(p, kind, count)) return take(vm, p, kind, count);
  request *q = new_request(p, kind);
  q->count = count;
  p->reader = q;
  q->job = agc_io_start(vm, &process_io, q, agc_handle_value(pr->reader), timeout);
  start_reading(p);
  if (read_ready(p, kind, count)) agc_io_ready(q->job);
  return agc_void();
}

static agc_value builtin_read_line(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return read_op(vm, args[0], REQ_LINE, 0, agc_as_int(vm, args[1]));
}

static agc_value builtin_read_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t count = agc_as_int(vm, args[1]);
  if (count < 0 || (uint64_t)count > LIMIT) return agc_error_value("process: count must be 0..1048576");
  return read_op(vm, args[0], REQ_BYTES, (size_t)count, agc_as_int(vm, args[2]));
}

static proc *take_writer(agc_vm *vm, agc_value handle, int64_t *timeout, agc_value *result) {
  agc_process *pr = agc_as_process(vm, handle);
  if (!agc_stream_lock(vm, pr->writer, timeout, result)) return NULL;
  proc *p = live(pr);
  if (!p) *result = agc_error_value(closed_text);
  return p;
}

static agc_value write_op(agc_vm *vm, const agc_value *args, uint8_t *data, size_t len) {
  int64_t timeout = agc_as_int(vm, args[2]);
  agc_value result;
  proc *p = take_writer(vm, args[0], &timeout, &result);
  if (!p) return result;
  if (p->in_closed) return agc_error_value("process: stdin is closed");
  p->write_status = 0;
  int rc = agc_stream_write((uv_stream_t *)&p->in, &p->write_req, &p->write_data, data, len, wrote);
  if (rc < 0) return agc_system_error(vm, write_failed, -rc);
  if (rc == 0) return ok_void();
  request *q = new_request(p, REQ_SEND);
  q->count = (size_t)agc_value_units(args[1]);
  p->writer = q;
  q->job = agc_io_start(vm, &process_io, q, agc_handle_value(agc_as_process(vm, args[0])->writer), timeout);
  return agc_void();
}

static agc_value builtin_send(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_string *text = agc_as_string(vm, args[1]);
  if (text->bytes > LIMIT) return agc_error_value("process: send exceeds 1048576 bytes");
  return write_op(vm, args, (uint8_t *)text->data, text->bytes);
}

static agc_value builtin_send_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *values = agc_as_list(vm, args[1]);
  uint8_t *data = agc_byte_list(vm, values, LIMIT);
  if (!data) return agc_error_value("process: bytes must be 0..255 and at most 1048576 per call");
  return write_op(vm, args, data, values->len);
}

static agc_value builtin_close_stdin(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t timeout = agc_as_int(vm, args[1]);
  agc_value result;
  proc *p = take_writer(vm, args[0], &timeout, &result);
  if (!p) return result;
  if (!p->in_closed) AGC_TRACE(&p->trace, AGC_TRACE_PROC, "eof pid=%d pipe=stdin", (int)p->process.pid);
  p->in_closed = true;
  close_handle((uv_handle_t *)&p->in, closed_in);
  return ok_void();
}

static agc_value await_child(agc_vm *vm, const agc_value *args, req_kind kind) {
  agc_process *pr = agc_as_process(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  if (timeout <= 0) return agc_stream_bad_timeout();
  proc *p = live(pr);
  if (!p) return agc_error_value(closed_text);
  if (kind == REQ_OUTPUT && !p->captured) return agc_error_value("process: output is not captured");
  if (waits_over(p, kind)) return waited(vm, p, kind);
  request *q = new_request(p, kind);
  q->next = p->waits;
  p->waits = q;
  q->job = agc_io_start(vm, &process_io, q, agc_void(), timeout);
  return agc_void();
}

static agc_value builtin_wait(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return await_child(vm, args, REQ_WAIT);
}

static agc_value builtin_output(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return await_child(vm, args, REQ_OUTPUT);
}

static agc_value builtin_close(agc_vm *vm, agc_value *args, uint32_t span) {
  proc *p = unregister_child(vm, agc_as_process(vm, args[0])->state);
  if (!p) return agc_void();
  int err = shut(p);
  if (!p->captured && p->running && !p->stop_failed) {
    request *q = new_request(p, REQ_CLOSE);
    q->next = p->waits;
    p->waits = q;
    q->job = agc_io_start(vm, &process_io, q, agc_void(), REAP_MS);
  }
  p->users--;
  settle(p);
  if (err) agc_fail(vm, "RUNTIME-PROCESS-CLOSE", "process: the child cannot be stopped", span);
  return agc_void();
}

const agc_builtin agc_process_builtins[] = {
  {"Process.spawn", 3, builtin_spawn, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Process.send", 3, builtin_send, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Process.send_bytes", 3, builtin_send_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Process.read_line", 2, builtin_read_line, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Process.read_bytes", 3, builtin_read_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Process.close_stdin", 2, builtin_close_stdin, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Process.wait", 2, builtin_wait, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Process.close", 1, builtin_close, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Process.spawn_captured", 4, builtin_spawn_captured, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Process.output", 2, builtin_output, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_process_builtin_count = sizeof agc_process_builtins / sizeof agc_process_builtins[0];
#else
const agc_builtin agc_process_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE}};

const size_t agc_process_builtin_count = 0;

void agc_processes_stop(agc_vm *vm) { (void)vm; }
#endif
