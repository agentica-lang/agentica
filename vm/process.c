#include "agc.h"

#ifdef __linux__
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <uv.h>

#define LIMIT ((size_t)1048576)
#define READ_AHEAD ((size_t)4096)
#define ERR_CHUNK 4096
#define REAP_SECONDS 1
#define REAP_STEP_NS 100000L
#define URING_ENV "UV_USE_IO_URING="
#define OWNER(ptr, field) ((proc *)(void *)((char *)(ptr) - offsetof(proc, field)))

typedef enum { REQ_LINE, REQ_BYTES, REQ_SEND, REQ_WAIT } req_kind;

typedef struct proc proc;
typedef struct request request;
typedef struct guard guard;
typedef struct watch watch;

struct request {
  req_kind kind;
  proc *p;
  agc_io_job *job;
  request *next;
  size_t count;
};

struct watch {
  uv_signal_t handle;
  guard *owner;
  bool usable;
};

struct guard {
  agc_trace trace;
  watch watches[AGC_STOP_SIGNALS];
  proc *first;
  size_t running, handles;
  struct timespec deadline;
  bool released, reaping;
  int signal;
};

struct proc {
  agc_trace trace;
  uv_process_t process;
  uv_pipe_t in, out, err;
  uv_write_t write_req;
  FILE *forward;
  guard *g;
  proc *run_prev, *run_next;
  size_t users, handles;
  bool linked, running, exited, err_done, out_eof, in_closed, closed, reading, forward_failed;
  int out_error, write_status;
  int64_t status;
  uint8_t *buf, *write_data;
  size_t start, end, cap;
  request *reader, *writer, *waits;
  uint8_t err_buf[ERR_CHUNK];
};

static const char closed_text[] = "process: process is closed";
static const char timed_out[] = "network: operation timed out";
static const char bad_timeout[] = "network: timeout must be positive milliseconds";
static const char write_failed[] = "error writing to stream port";

static agc_value error_of(const char *message) {
  size_t n = strlen(message);
  return agc_result_value(false, agc_string_value(agc_make_string(message, n, n)));
}

static agc_value ok_void(void) { return agc_result_value(true, agc_void()); }

static void settle(proc *p) {
  if (p->users || p->handles) return;
  free(p->buf);
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

static void close_handle(uv_handle_t *h, uv_close_cb done) {
  if (!uv_is_closing(h)) uv_close(h, done);
}

static void guard_settle(guard *g) {
  if (g->released && !g->handles && !g->running) free(g);
}

static void closed_watch(uv_handle_t *h) {
  guard *g = ((watch *)(void *)h)->owner;
  g->handles--;
  guard_settle(g);
}

static void guard_stop(guard *g, int sig) {
  sigset_t saved;
  agc_io_block_stop(&saved);
  for (size_t k = 0; k < AGC_STOP_SIGNALS; k++) {
    uv_signal_t *h = &g->watches[k].handle;
    if (!g->watches[k].usable || !uv_is_active((uv_handle_t *)h)) continue;
    if (!sig && h->caught_signals != h->dispatched_signals) sig = agc_stop_signals[k];
    uv_signal_stop(h);
  }
  AGC_TRACE(&g->trace, AGC_TRACE_PROC, "guard_stop raise=%d", sig);
  if (sig) raise(sig);
  pthread_sigmask(SIG_SETMASK, &saved, NULL);
}

static void unlink_child(proc *p) {
  guard *g = p->g;
  p->linked = false;
  if (p->run_prev)
    p->run_prev->run_next = p->run_next;
  else
    g->first = p->run_next;
  if (p->run_next) p->run_next->run_prev = p->run_prev;
  p->run_prev = p->run_next = NULL;
  if (--g->running) return;
  guard_stop(g, g->signal);
  guard_settle(g);
}

static size_t pending(const proc *p) { return p->end - p->start; }

static bool wait_over(const proc *p) { return p->closed || (p->exited && p->err_done); }

static void notify_waits(proc *p) {
  if (!wait_over(p)) return;
  for (request *q = p->waits; q; q = q->next) agc_io_ready(q->job);
}

static void finished(proc *p, int64_t status) {
  p->running = false;
  p->exited = true;
  p->status = status;
  if (p->linked) unlink_child(p);
}

static void deadline_in(struct timespec *t) {
  clock_gettime(CLOCK_MONOTONIC, t);
  t->tv_sec += REAP_SECONDS;
}

static bool past(const struct timespec *t) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return now.tv_sec > t->tv_sec || (now.tv_sec == t->tv_sec && now.tv_nsec >= t->tv_nsec);
}

static void reap(proc *p, const struct timespec *deadline) {
  struct timespec pause = {0, REAP_STEP_NS};
  for (;;) {
    int status = 0;
    pid_t pid = waitpid(p->process.pid, &status, WNOHANG);
    if (pid == p->process.pid) {
      finished(p, WIFSIGNALED(status) ? 128 + WTERMSIG(status) : WEXITSTATUS(status));
      AGC_TRACE(&p->trace, AGC_TRACE_PROC, "reap pid=%d status=%" PRId64, (int)pid, p->status);
      return;
    }
    if (pid < 0 && errno == ECHILD) {
      finished(p, p->status);
      AGC_TRACE(&p->trace, AGC_TRACE_PROC, "reap pid=%d status=%" PRId64 " gone=1", (int)p->process.pid, p->status);
      return;
    }
    if (!deadline || past(deadline)) {
      AGC_TRACE(&p->trace, AGC_TRACE_PROC, "reap pid=%d alive=1", (int)p->process.pid);
      return;
    }
    nanosleep(&pause, NULL);
  }
}

static int shut(proc *p, const struct timespec *deadline) {
  if (p->closed) return 0;
  p->closed = true;
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "close pid=%d running=%d", (int)p->process.pid, p->running ? 1 : 0);
  int err = 0;
  if (p->running) {
    err = uv_process_kill(&p->process, SIGKILL);
    AGC_TRACE(&p->trace, AGC_TRACE_PROC, "kill pid=%d rc=%d", (int)p->process.pid, err);
    reap(p, err ? NULL : deadline);
  }
  if (!p->running) close_handle((uv_handle_t *)&p->process, closed_process);
  close_handle((uv_handle_t *)&p->in, closed_in);
  close_handle((uv_handle_t *)&p->out, closed_out);
  close_handle((uv_handle_t *)&p->err, closed_err);
  free(p->buf);
  p->buf = NULL;
  p->start = p->end = p->cap = 0;
  if (p->reader) agc_io_ready(p->reader->job);
  if (p->writer) agc_io_ready(p->writer->job);
  notify_waits(p);
  return err;
}

static int close_proc(proc *p) {
  struct timespec deadline;
  deadline_in(&deadline);
  return shut(p, &deadline);
}

static void close_children(guard *g) {
  if (!g->reaping) {
    g->reaping = true;
    deadline_in(&g->deadline);
  }
  for (proc *p = g->first; p; p = p->run_next) {
    if (!p->running || p->closed) continue;
    int rc = uv_process_kill(&p->process, SIGKILL);
    AGC_TRACE(&g->trace, AGC_TRACE_PROC, "kill pid=%d rc=%d", (int)p->process.pid, rc);
  }
  for (proc *p = g->first, *next = NULL; p; p = next) {
    next = p->run_next;
    shut(p, &g->deadline);
  }
}

static void release_proc(void *native) {
  proc *p = native;
  if (p->g) close_children(p->g);
  close_proc(p);
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

static bool line_ready(const proc *p) {
  size_t have = pending(p);
  size_t window = have < LIMIT + 1 ? have : LIMIT + 1;
  if (have > LIMIT || p->out_eof || p->out_error) return true;
  return window && memchr(p->buf + p->start, '\n', window);
}

static bool read_ready(const proc *p, req_kind kind, size_t count) {
  if (p->closed) return true;
  if (kind == REQ_LINE) return line_ready(p);
  return pending(p) >= count || p->out_eof || p->out_error;
}

static agc_value take_line(agc_vm *vm, proc *p) {
  size_t have = pending(p);
  size_t window = have < LIMIT + 1 ? have : LIMIT + 1;
  const uint8_t *data = have ? p->buf + p->start : NULL;
  const uint8_t *lf = window ? memchr(data, '\n', window) : NULL;
  size_t len = have, consume = have;
  if (lf) {
    len = (size_t)(lf - data);
    consume = len + 1;
    if (len && data[len - 1] == '\r') len--;
  } else if (have > LIMIT) {
    close_proc(p);
    return error_of("process: line exceeds 1048576 bytes");
  } else if (have == 0) {
    if (p->out_error) return agc_system_error(vm, "error reading from stream port", p->out_error);
    return error_of("process: end of input");
  }
  p->start += consume;
  size_t chars;
  if (!agc_utf8_chars(data, len, &chars)) return agc_utf8_error(data, len);
  return agc_result_value(true, agc_string_value(agc_make_string((const char *)data, len, chars)));
}

static agc_value take_bytes(agc_vm *vm, proc *p, size_t count) {
  size_t n = pending(p) < count ? pending(p) : count;
  if (n == 0 && count > 0 && p->out_error) return agc_system_error(vm, "error reading from stream port", p->out_error);
  agc_list *l = agc_new_list(n);
  for (size_t k = 0; k < n; k++) l->items[k] = agc_int(p->buf[p->start + k]);
  p->start += n;
  return agc_result_value(true, agc_list_value(l));
}

static agc_value take(agc_vm *vm, proc *p, req_kind kind, size_t count) {
  if (p->closed) return error_of(closed_text);
  return kind == REQ_LINE ? take_line(vm, p) : take_bytes(vm, p, count);
}

static agc_value request_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  request *q = data;
  proc *p = q->p;
  unlink_request(q);
  agc_value result;
  if (q->kind == REQ_LINE || q->kind == REQ_BYTES) {
    result = take(vm, p, q->kind, q->count);
  } else if (p->closed) {
    result = error_of(closed_text);
  } else if (q->kind == REQ_WAIT) {
    result = agc_result_value(true, agc_int(p->status));
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
  if (q->kind != REQ_WAIT) close_proc(q->p);
  return error_of(timed_out);
}

static const agc_io_kind process_io = {NULL, request_done, request_expired, drop_request, true, "process"};

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
  if (p->closed) close_handle((uv_handle_t *)&p->process, closed_process);
  notify_waits(p);
}

static void interrupted(uv_signal_t *h, int signum) {
  guard *g = ((watch *)(void *)h)->owner;
  AGC_TRACE(&g->trace, AGC_TRACE_PROC, "signal sig=%d running=%zu", signum, g->running);
  g->signal = signum;
  close_children(g);
  guard_stop(g, signum);
}

static void link_child(guard *g, proc *p) {
  p->g = g;
  p->linked = true;
  p->run_prev = NULL;
  p->run_next = g->first;
  if (g->first) g->first->run_prev = p;
  g->first = p;
  if (g->running++) return;
  for (size_t k = 0; k < AGC_STOP_SIGNALS; k++)
    if (g->watches[k].usable) uv_signal_start(&g->watches[k].handle, interrupted, agc_stop_signals[k]);
  AGC_TRACE(&g->trace, AGC_TRACE_PROC, "guard_start watchers=%zu", g->handles);
}

static void release_guard(void *native) {
  guard *g = native;
  AGC_TRACE(&g->trace, AGC_TRACE_PROC, "guard_cleanup running=%zu", g->running);
  close_children(g);
  guard_stop(g, 0);
  g->released = true;
  for (size_t k = 0; k < AGC_STOP_SIGNALS; k++)
    if (g->watches[k].usable) close_handle((uv_handle_t *)&g->watches[k].handle, closed_watch);
  guard_settle(g);
}

static void keep_descriptors_private(void) {
  DIR *dir = opendir("/proc/self/fd");
  if (!dir) return;
  int own = dirfd(dir);
  for (struct dirent *e = readdir(dir); e; e = readdir(dir)) {
    char *end = NULL;
    long fd = strtol(e->d_name, &end, 10);
    if (end == e->d_name || *end || fd < 3 || fd == own || fd > INT32_MAX) continue;
    int flags = fcntl((int)fd, F_GETFD);
    if (flags >= 0 && !(flags & FD_CLOEXEC)) fcntl((int)fd, F_SETFD, flags | FD_CLOEXEC);
  }
  closedir(dir);
}

static guard *guard_of(agc_vm *vm, uv_loop_t *loop) {
  if (vm->process_guard) return vm->process_guard->native;
  agc_resource *r = agc_register(vm, NULL, release_guard);
  guard *g = calloc(1, sizeof(guard));
  if (!g) agc_out_of_memory();
  g->trace = vm->rt->trace;
  for (size_t k = 0; k < AGC_STOP_SIGNALS; k++) {
    watch *w = &g->watches[k];
    w->owner = g;
    struct sigaction now;
    if (sigaction(agc_stop_signals[k], NULL, &now) || now.sa_handler == SIG_IGN || uv_signal_init(loop, &w->handle))
      continue;
    w->usable = true;
    g->handles++;
  }
  keep_descriptors_private();
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

static size_t read_size(const proc *p) {
  const request *q = p->reader;
  size_t have = pending(p);
  if (q && q->kind == REQ_BYTES && q->count > have && q->count - have > READ_AHEAD) return q->count - have;
  return READ_AHEAD;
}

static bool make_room(proc *p, size_t want) {
  if (p->start == p->end) p->start = p->end = 0;
  if (p->cap - p->end >= want) return true;
  size_t used = pending(p);
  if (p->start) {
    memmove(p->buf, p->buf + p->start, used);
    p->start = 0;
    p->end = used;
    if (p->cap - used >= want) return true;
  }
  size_t cap = p->cap ? p->cap : READ_AHEAD;
  while (cap - used < want) cap = agc_size_mul(cap, 2);
  uint8_t *bigger = realloc(p->buf, cap);
  if (!bigger) return false;
  p->buf = bigger;
  p->cap = cap;
  return true;
}

static void alloc_out(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  (void)suggested;
  proc *p = OWNER(h, out);
  size_t size = read_size(p);
  *buf = make_room(p, size) ? uv_buf_init((char *)p->buf + p->end, (unsigned)size) : uv_buf_init(NULL, 0);
}

static void stop_reading(proc *p) {
  if (!p->reading) return;
  uv_read_stop((uv_stream_t *)&p->out);
  p->reading = false;
}

static void read_out(uv_stream_t *s, ssize_t n, const uv_buf_t *buf) {
  (void)buf;
  proc *p = OWNER(s, out);
  if (n > 0) {
    p->end += (size_t)n;
  } else if (n == UV_EOF) {
    p->out_eof = true;
  } else if (n < 0) {
    p->out_error = (int)-n;
  }
  if (n < 0)
    AGC_TRACE(&p->trace, AGC_TRACE_PROC, "eof pid=%d pipe=stdout error=%d", (int)p->process.pid, p->out_error);
  request *q = p->reader;
  bool ready = q && read_ready(p, q->kind, q->count);
  if (n < 0 || !q || ready) stop_reading(p);
  if (ready) agc_io_ready(q->job);
}

static void start_reading(proc *p) {
  if (p->reading || p->out_eof || p->out_error) return;
  int rc = uv_read_start((uv_stream_t *)&p->out, alloc_out, read_out);
  if (rc)
    p->out_error = -rc;
  else
    p->reading = true;
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

static int start_child(uv_loop_t *loop, guard *g, proc *p, char **argv, char **env) {
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
    options.stdio_count = 3;
    options.stdio = stdio;
    link_child(g, p);
    rc = uv_spawn(loop, &p->process, &options);
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
    uv_pipe_init(loop, &p->in, 0);
    uv_pipe_init(loop, &p->out, 0);
    uv_pipe_init(loop, &p->err, 0);
    p->handles = 4;
    rc = open_pipe(&p->err, &fds[4], open_pipe(&p->out, &fds[2], open_pipe(&p->in, &fds[1], 0)));
    if (!rc) rc = uv_read_start((uv_stream_t *)&p->err, alloc_err, forward_err);
  }
  close_fd(&fds[1]);
  close_fd(&fds[2]);
  close_fd(&fds[4]);
  if (rc && p->running) close_proc(p);
  return rc;
}

static agc_resource *new_lock(agc_vm *vm) {
  agc_resource *lock = agc_alloc(sizeof(agc_resource));
  lock->id = agc_resource_id(vm);
  lock->slot = SIZE_MAX;
  lock->context = agc_void();
  return lock;
}

static agc_value builtin_spawn(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  if (!vm->rt->allow_run) return error_of("process: spawning requires --allow-run");
  const agc_string *command = agc_as_string(vm, args[0]);
  const agc_list *list = agc_as_list(vm, args[1]);
  int64_t timeout = agc_as_int(vm, args[2]);
  bool valid = command->bytes > 0 && !memchr(command->data, 0, command->bytes);
  for (size_t k = 0; k < list->len; k++) {
    const agc_string *arg = agc_as_string(vm, list->items[k]);
    valid = valid && !memchr(arg->data, 0, arg->bytes);
  }
  if (!valid) return error_of("process: command must be nonempty and arguments cannot contain NUL");
  if (timeout <= 0) return error_of(bad_timeout);
  agc_process *pr = agc_alloc(sizeof(agc_process));
  pr->reader = new_lock(vm);
  pr->writer = new_lock(vm);
  uv_loop_t *loop = agc_io_uv(vm);
  guard *g = guard_of(vm, loop);
  char *path = resolve(vm, command);
  if (!path) return error_of("process: executable is unavailable");
  char **argv = child_args(vm, path, list);
  char **env = vm->rt->drop_uring_env ? child_env() : NULL;
  proc *p = calloc(1, sizeof(proc));
  if (!p) agc_out_of_memory();
  p->trace = vm->rt->trace;
  p->forward = vm->rt->err;
  int rc = start_child(loop, g, p, argv, env);
  if (rc)
    AGC_TRACE(&p->trace, AGC_TRACE_PROC, "spawn_failed path=%s rc=%d", path, rc);
  else
    AGC_TRACE(&p->trace, AGC_TRACE_PROC, "spawn pid=%d path=%s args=%zu", (int)p->process.pid, path, list->len);
  for (size_t k = 0; argv[k]; k++) free(argv[k]);
  free(argv);
  free(env);
  if (rc) {
    settle(p);
    return agc_system_error(vm, "process: cannot run the executable", -rc);
  }
  p->users = 1;
  pr->state = agc_register(vm, p, release_proc);
  return agc_result_value(true, agc_process_value(pr));
}

static bool locked(agc_vm *vm, agc_resource *lock, int64_t *timeout, agc_value *result) {
  if (*timeout <= 0) {
    *result = error_of(bad_timeout);
    return false;
  }
  agc_lock_status status = agc_handle_wait(vm, lock, timeout);
  if (status == AGC_LOCK_TAKEN) return true;
  *result = status == AGC_LOCK_WAIT ? agc_void() : error_of(timed_out);
  return false;
}

static proc *live(const agc_process *pr) {
  proc *p = pr->state->native;
  return p && !p->closed ? p : NULL;
}

static agc_value read_op(agc_vm *vm, agc_value handle, req_kind kind, size_t count, int64_t timeout) {
  agc_process *pr = agc_as_process(vm, handle);
  agc_value result;
  if (!locked(vm, pr->reader, &timeout, &result)) return result;
  proc *p = live(pr);
  if (!p) return error_of(closed_text);
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
  if (count < 0 || (uint64_t)count > LIMIT) return error_of("process: count must be 0..1048576");
  return read_op(vm, args[0], REQ_BYTES, (size_t)count, agc_as_int(vm, args[2]));
}

static agc_value write_op(agc_vm *vm, agc_value handle, uint8_t *data, size_t len, int64_t timeout) {
  agc_process *pr = agc_as_process(vm, handle);
  agc_value result;
  if (!locked(vm, pr->writer, &timeout, &result)) return result;
  proc *p = live(pr);
  if (!p) return error_of(closed_text);
  if (p->in_closed) return error_of("process: stdin is closed");
  size_t done = 0;
  while (done < len) {
    uv_buf_t b = uv_buf_init((char *)data + done, (unsigned)(len - done));
    int n = uv_try_write((uv_stream_t *)&p->in, &b, 1);
    if (n == UV_EAGAIN) break;
    if (n < 0) return agc_system_error(vm, write_failed, -n);
    done += (size_t)n;
  }
  if (done == len) return ok_void();
  p->write_data = malloc(len - done);
  if (!p->write_data) agc_out_of_memory();
  memcpy(p->write_data, data + done, len - done);
  uv_buf_t rest = uv_buf_init((char *)p->write_data, (unsigned)(len - done));
  p->write_status = 0;
  int rc = uv_write(&p->write_req, (uv_stream_t *)&p->in, &rest, 1, wrote);
  if (rc) {
    free(p->write_data);
    p->write_data = NULL;
    return agc_system_error(vm, write_failed, -rc);
  }
  request *q = new_request(p, REQ_SEND);
  p->writer = q;
  q->job = agc_io_start(vm, &process_io, q, agc_handle_value(pr->writer), timeout);
  return agc_void();
}

static agc_value builtin_send(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_string *text = agc_as_string(vm, args[1]);
  if (text->bytes > LIMIT) return error_of("process: send exceeds 1048576 bytes");
  return write_op(vm, args[0], (uint8_t *)text->data, text->bytes, agc_as_int(vm, args[2]));
}

static agc_value builtin_send_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *values = agc_as_list(vm, args[1]);
  uint8_t *data = agc_byte_list(vm, values, LIMIT);
  if (!data) return error_of("process: bytes must be 0..255 and at most 1048576 per call");
  return write_op(vm, args[0], data, values->len, agc_as_int(vm, args[2]));
}

static agc_value builtin_close_stdin(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_process *pr = agc_as_process(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  agc_value result;
  if (!locked(vm, pr->writer, &timeout, &result)) return result;
  proc *p = live(pr);
  if (!p) return error_of(closed_text);
  if (!p->in_closed) AGC_TRACE(&p->trace, AGC_TRACE_PROC, "eof pid=%d pipe=stdin", (int)p->process.pid);
  p->in_closed = true;
  close_handle((uv_handle_t *)&p->in, closed_in);
  return ok_void();
}

static agc_value builtin_wait(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_process *pr = agc_as_process(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  if (timeout <= 0) return error_of(bad_timeout);
  proc *p = live(pr);
  if (!p) return error_of(closed_text);
  if (wait_over(p)) return agc_result_value(true, agc_int(p->status));
  request *q = new_request(p, REQ_WAIT);
  q->next = p->waits;
  p->waits = q;
  q->job = agc_io_start(vm, &process_io, q, agc_void(), timeout);
  return agc_void();
}

static agc_value builtin_close(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_resource *r = agc_as_process(vm, args[0])->state;
  proc *p = r->native;
  if (!p) return agc_void();
  r->native = NULL;
  agc_unregister(vm, r);
  int err = close_proc(p);
  p->users--;
  settle(p);
  if (err) agc_fail(vm, "RUNTIME-PROCESS-CLOSE", "process: the child cannot be stopped", span);
  return agc_void();
}

const agc_builtin agc_process_builtins[] = {
  {"Process.spawn", 3, builtin_spawn, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Process.send", 3, builtin_send, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Process.send_bytes", 3, builtin_send_bytes, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Process.read_line", 2, builtin_read_line, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Process.read_bytes", 3, builtin_read_bytes, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Process.close_stdin", 2, builtin_close_stdin, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Process.wait", 2, builtin_wait, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Process.close", 1, builtin_close, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_process_builtin_count = sizeof agc_process_builtins / sizeof agc_process_builtins[0];
#else
const agc_builtin agc_process_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE}};

const size_t agc_process_builtin_count = 0;
#endif
