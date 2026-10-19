/*
 * Standard output and standard error: one writer per stream, with a 64 KiB
 * ring and a FIFO of waiting writers, so that a print waits its turn instead
 * of interleaving. Core layer. Design: docs/vm/10-io-scheduler.md §10.2.2.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "core.h"

#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <poll.h>
#endif

#if defined(__linux__) || defined(__APPLE__)
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
  bool to_err;
  int fd, status;
  const uint8_t *part[2];
  size_t length[2], written;
} drain_request;

typedef struct {
  bool to_err;
  int status;
  agc_poller *poller;
  agc_io_job *job;
} poll_request;
#endif

static _Noreturn void fail_write(agc_vm *vm, const agc_output *out) {
  agc_fail(vm, "RUNTIME-INTERNAL",
           out == &vm->rt->err ? "cannot write to standard error" : "cannot write to standard output", 0);
}

static _Noreturn void write_failed(agc_vm *vm, agc_output *out) {
  int sig = agc_io_stop_signal();
  if (errno == EINTR && sig) {
    clearerr(out->file);
    agc_stop(vm, sig);
  }
  fail_write(vm, out);
}

bool agc_output_waiting(const agc_vm *vm, const agc_output *out) { return vm->task->output.out == out; }

bool agc_output_failed(const agc_output *out) { return out->base && out->base->failed; }

#if defined(__linux__) || defined(__APPLE__)
static size_t smaller(size_t a, size_t b) { return a < b ? a : b; }

static size_t room(const agc_output *s) { return AGC_OUTPUT_BUFFER - s->len; }

static size_t run_length(const agc_output *s) { return smaller(AGC_OUTPUT_BUFFER - s->start, s->len); }

static size_t queued(const agc_output *s) { return s->notice_len - s->notice_at; }

static size_t total(const agc_output_wait *w) {
  return w->text ? w->text->bytes + (w->newline ? 1 : 0) : 0;
}

static size_t need(const agc_output_wait *w) {
  return w->flush ? AGC_OUTPUT_BUFFER : smaller(total(w) - w->done, AGC_OUTPUT_BUFFER);
}

static bool holds(const agc_output *s) {
  const agc_task *head = s->waiters;
  return head && !head->output.flush && head->output.done > 0 && head->output.done < total(&head->output);
}

static agc_output *stream_of(agc_vm *vm, bool to_err) { return to_err ? &vm->rt->err : &vm->rt->out; }

static void trace_run(const agc_output *s, const char *what) {
  if (s->vm && !s->pooled)
    AGC_TRACE(&s->vm->rt->trace, AGC_TRACE_IO, "output_%s stream=%s", what, s == &s->vm->rt->out ? "stdout" : "stderr");
}

static void put_bytes(agc_output *s, const void *data, size_t n) {
  if (!n) return;
  if (!s->len) trace_run(s, "start");
  size_t end = (s->start + s->len) % AGC_OUTPUT_BUFFER;
  size_t first = smaller(AGC_OUTPUT_BUFFER - end, n);
  memcpy(s->buf + end, data, first);
  if (n > first) memcpy(s->buf, (const uint8_t *)data + first, n - first);
  s->len += n;
}

static void consumed(agc_output *s, size_t n) {
  s->start = (s->start + n) % AGC_OUTPUT_BUFFER;
  s->len -= n;
  if (!s->len) {
    s->start = 0;
    trace_run(s, "done");
  }
}

static void drop_notices(agc_output *s) {
  free(s->notice);
  s->notice = NULL;
  s->notice_at = s->notice_len = 0;
}

static void pump(agc_output *s, bool force) {
  size_t left = queued(s);
  if (!left || s->failed || (!force && holds(s))) return;
  size_t n = smaller(left, room(s));
  put_bytes(s, s->notice + s->notice_at, n);
  s->notice_at += n;
  if (s->notice_at == s->notice_len) drop_notices(s);
}

static void stop_waiting(agc_output *s, agc_task *t) {
  agc_task_remove(&s->waiters, &s->waiters_tail, t);
  t->output = (agc_output_wait){0};
}

static void fail_stream(agc_output *s) {
  s->failed = true;
  s->start = s->len = 0;
  drop_notices(s);
  for (agc_task *t = s->waiters; t; t = t->wait_next) agc_task_wake(s->vm, t, "output");
}

static void write_now(agc_output *s) {
  while (s->len) {
    size_t n = run_length(s);
#ifdef __APPLE__
    if (!s->socket) {
      struct pollfd fd = {.fd = s->fd, .events = POLLOUT};
      int rc = poll(&fd, 1, 0);
      if (rc == 0 || (rc < 0 && errno == EINTR)) return;
      if (rc < 0) {
        fail_stream(s);
        return;
      }
      if (n > PIPE_BUF) n = PIPE_BUF;
    }
#endif
    ssize_t done = s->socket ? send(s->fd, s->buf + s->start, n, MSG_DONTWAIT | MSG_NOSIGNAL)
                             : write(s->fd, s->buf + s->start, n);
    if (done > 0) {
      consumed(s, (size_t)done);
      continue;
    }
    if (done < 0 && errno == EINTR) continue;
    if (done < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
    fail_stream(s);
    return;
  }
}

static void drain_work(void *data) {
  drain_request *q = data;
  for (int k = 0; k < 2; k++) {
    size_t at = 0;
    while (at < q->length[k]) {
      ssize_t n = write(q->fd, q->part[k] + at, q->length[k] - at);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) {
        q->status = n < 0 ? errno : EIO;
        return;
      }
      at += (size_t)n;
      q->written += (size_t)n;
    }
  }
}

static void request_drop(void *data) { free(data); }

static void polled(void *data, int status) {
  poll_request *q = data;
  agc_poller_pause(q->poller);
  q->status = status;
  agc_io_ready(q->job);
}

static const agc_io_kind drain_io;
static const agc_io_kind poll_io;

static void kick(agc_output *s) {
  if (s->failed || !s->len) return;
  if (s->pooled) {
    if (s->writing) return;
    drain_request *q = calloc(1, sizeof(drain_request));
    if (!q) agc_out_of_memory();
    size_t first = run_length(s);
    q->to_err = s == &s->vm->rt->err;
    q->fd = s->fd;
    q->part[0] = s->buf + s->start;
    q->length[0] = first;
    q->part[1] = s->buf;
    q->length[1] = s->len - first;
    s->writing = true;
    agc_io_detached(s->vm, &drain_io, q, agc_void(), 0);
    return;
  }
  if (s->armed) return;
  poll_request *q = calloc(1, sizeof(poll_request));
  if (!q) agc_out_of_memory();
  q->to_err = s == &s->vm->rt->err;
  q->poller = s->poller;
  s->armed = true;
  q->job = agc_io_detached(s->vm, &poll_io, q, agc_void(), AGC_JOB_QUIET);
  agc_poller_wait(s->poller, true, polled, q);
}

static void wake_head(agc_output *s) {
  agc_task *head = s->waiters;
  if (head && room(s) >= need(&head->output)) agc_task_wake(s->vm, head, "output");
}

static void advance(agc_output *s) {
  pump(s, false);
  wake_head(s);
  kick(s);
}

static agc_value drain_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  drain_request *q = data;
  agc_output *s = stream_of(vm, q->to_err);
  size_t written = q->written;
  int status = q->status;
  free(q);
  s->writing = false;
  if (!s->base) {
    free(s->buf);
    s->buf = NULL;
  } else if (status) {
    fail_stream(s);
  } else {
    consumed(s, written);
    advance(s);
  }
  return agc_void();
}

static agc_value poll_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  poll_request *q = data;
  agc_output *s = stream_of(vm, q->to_err);
  int status = q->status;
  free(q);
  s->armed = false;
  if (!s->base || s->failed) return agc_void();
  write_now(s);
  if (status < 0 && s->len && !s->failed) fail_stream(s);
  advance(s);
  return agc_void();
}

static const agc_io_kind drain_io = {drain_work, drain_done, drain_done, request_drop, false, "output", NULL};
static const agc_io_kind poll_io = {NULL, poll_done, poll_done, request_drop, true, "output", NULL};

static void flush_now(agc_output *s) {
  if (s->failed) return;
  if (!s->pooled) write_now(s);
  advance(s);
}

static void copy_piece(agc_output *s, const agc_output_wait *w, size_t n) {
  size_t at = w->done;
  size_t end = at + n;
  if (at < end && at < w->text->bytes) {
    size_t k = smaller(end - at, w->text->bytes - at);
    put_bytes(s, w->text->data + at, k);
    at += k;
  }
  if (at < end) put_bytes(s, "\n", 1);
}

/* One look at the wait of the running task. The mark comes first (a turn that resumes marks here, a task that joins
   the FIFO marked before it linked itself), so a drain that frees room after the check below finds PARKING and sets
   WOKEN instead of being dropped; a turn that ends the wait puts the state back. */
static bool wait_turn(agc_vm *vm, agc_output *out) {
  agc_output *s = out->base;
  agc_task *t = vm->task;
  agc_output_wait *w = &t->output;
  agc_task_parking(vm);
  if (s->failed) {
    stop_waiting(s, t);
    fail_write(vm, out);
  }
  if (s->waiters != t || room(s) < need(w)) {
    agc_task_park(vm, true);
    return false;
  }
  if (!w->flush) {
    size_t n = smaller(total(w) - w->done, room(s));
    copy_piece(s, w, n);
    w->done += n;
    kick(s);
    if (w->done < total(w)) {
      agc_task_park(vm, true);
      return false;
    }
  }
  stop_waiting(s, t);
  advance(s);
  agc_task_unpark(vm);
  return true;
}

static bool put(agc_vm *vm, agc_output *out, const agc_string *text, bool newline) {
  agc_output *s = out->base;
  agc_task *t = vm->task;
  if (t->output.out != out) {
    if (s->failed) fail_write(vm, out);
    agc_output_wait w = {.out = out, .text = text, .newline = newline};
    if (total(&w) == 0) return true;
    if (!s->waiters && !queued(s) && total(&w) <= room(s)) {
      copy_piece(s, &w, total(&w));
      kick(s);
      return true;
    }
    t->output = w;
    agc_task_parking(vm);
    agc_task_enqueue(&s->waiters, &s->waiters_tail, t);
  }
  return wait_turn(vm, out);
}

bool agc_drain(agc_vm *vm) {
  agc_output *out = &vm->rt->out;
  if (!out->base) {
    if (fflush(out->file) != 0) write_failed(vm, out);
    return true;
  }
  agc_output *s = out->base;
  agc_task *t = vm->task;
  if (t->output.out != out) {
    if (s->failed) fail_write(vm, out);
    flush_now(s);
    if (s->failed) fail_write(vm, out);
    if (!s->len && !s->waiters && !queued(s)) return true;
    t->output = (agc_output_wait){.out = out, .flush = true};
    agc_task_parking(vm);
    agc_task_enqueue(&s->waiters, &s->waiters_tail, t);
  }
  return wait_turn(vm, out);
}

void agc_output_leave(agc_vm *vm, agc_task *t) {
  (void)vm;
  agc_output *s = t->output.out->base;
  stop_waiting(s, t);
  advance(s);
}

bool agc_output_busy(agc_vm *vm) {
  bool stopping = agc_io_stop_signal() != 0;
  bool busy = false;
  agc_output *streams[2] = {&vm->rt->out, &vm->rt->err};
  for (size_t k = 0; k < 2; k++) {
    agc_output *s = streams[k];
    if (s->base != s || (!s->len && !queued(s))) continue;
    if (!stopping) {
      pump(s, true);
      kick(s);
      busy = true;
    } else if (!s->writing) {
      pump(s, true);
      write_now(s);
    }
  }
  return busy;
}

void agc_output_open(agc_vm *vm, agc_output *out, int fd) {
  struct stat info;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || (flags & O_ACCMODE) == O_RDONLY || fstat(fd, &info) != 0) return;
  const agc_output *first = out == &vm->rt->err ? &vm->rt->out : NULL;
  if (first && first->base && first->dev == (uint64_t)info.st_dev && first->ino == (uint64_t)info.st_ino) {
    out->base = first->base;
    return;
  }
  bool pooled = S_ISREG(info.st_mode) || S_ISBLK(info.st_mode);
#ifdef __APPLE__
  if (S_ISCHR(info.st_mode)) {
    const char *devices[] = {"/dev/null", "/dev/zero"};
    for (size_t k = 0; k < sizeof devices / sizeof devices[0]; k++) {
      struct stat device;
      if (stat(devices[k], &device) == 0 && info.st_rdev == device.st_rdev) pooled = true;
    }
  }
#endif
  bool socket = S_ISSOCK(info.st_mode);
  int use = fd;
  agc_poller *poller = NULL;
  if (!pooled) {
    if (!socket && !S_ISFIFO(info.st_mode) && !S_ISCHR(info.st_mode)) return;
    int again = socket ? fcntl(fd, F_DUPFD_CLOEXEC, 3) : agc_fd_reopen(fd, O_WRONLY);
    if (again < 0) return;
    int err = 0;
    poller = agc_poller_open(vm, again, &err);
    if (socket) fcntl(again, F_SETFL, flags);
    if (poller) {
      use = again;
    } else {
      close(again);
      if (err != EPERM || socket) return;
      pooled = true;
    }
  }
  out->buf = malloc(AGC_OUTPUT_BUFFER);
  if (!out->buf) agc_out_of_memory();
  out->vm = vm;
  out->fd = use;
  out->dev = (uint64_t)info.st_dev;
  out->ino = (uint64_t)info.st_ino;
  out->poller = poller;
  out->pooled = pooled;
  out->socket = socket && poller;
  out->base = out;
}

static void close_stream(agc_output *s) {
  if (!s->base) return;
  if (s->base == s) {
    if (s->poller) {
      agc_poller_pause(s->poller);
      agc_poller_close(s->poller);
      s->poller = NULL;
    }
    if (!s->writing) {
      free(s->buf);
      s->buf = NULL;
    }
    drop_notices(s);
    s->armed = false;
    s->len = 0;
  }
  s->base = NULL;
}

void agc_output_close(agc_vm *vm) {
  close_stream(&vm->rt->out);
  close_stream(&vm->rt->err);
}

FILE *agc_notice_begin(agc_output *out, agc_notice *n) {
  n->out = out;
  n->file = NULL;
  n->text = NULL;
  n->len = 0;
  if (out->base) n->file = open_memstream(&n->text, &n->len);
  return n->file ? n->file : out->file;
}

static void queue_notice(agc_output *s, const char *text, size_t n, bool kept) {
  if (!kept && queued(s) >= AGC_NOTICE_LIMIT) return;
  if (s->notice_at) {
    memmove(s->notice, s->notice + s->notice_at, queued(s));
    s->notice_len -= s->notice_at;
    s->notice_at = 0;
  }
  uint8_t *grown = realloc(s->notice, s->notice_len + n);
  if (!grown) return;
  memcpy(grown + s->notice_len, text, n);
  s->notice = grown;
  s->notice_len += n;
}

static void finish_text(agc_output *s, const char *text, size_t n) {
  if (s->writing) return;
  pump(s, true);
  size_t at = 0;
  while (at < n && !s->failed) {
    write_now(s);
    size_t k = smaller(n - at, room(s));
    if (!k) break;
    put_bytes(s, text + at, k);
    at += k;
  }
  write_now(s);
}

void agc_notice_end(agc_notice *n, agc_notice_mode mode) {
  agc_output *out = n->out;
  if (!n->file) {
    fflush(out->file);
    return;
  }
  fclose(n->file);
  agc_output *s = out->base;
  bool write = !s->failed && n->len;
  if (write && mode == AGC_NOTICE_FINAL)
    finish_text(s, n->text, n->len);
  else if (write)
    queue_notice(s, n->text, n->len, mode == AGC_NOTICE_KEPT);
  free(n->text);
  if (write && mode != AGC_NOTICE_FINAL) flush_now(s);
}
#else
bool agc_drain(agc_vm *vm) {
  if (fflush(vm->rt->out.file) != 0) write_failed(vm, &vm->rt->out);
  return true;
}

void agc_output_leave(agc_vm *vm, agc_task *t) {
  (void)vm;
  (void)t;
}

bool agc_output_busy(agc_vm *vm) {
  (void)vm;
  return false;
}

void agc_output_open(agc_vm *vm, agc_output *out, int fd) {
  (void)vm;
  (void)out;
  (void)fd;
}

void agc_output_close(agc_vm *vm) { (void)vm; }

FILE *agc_notice_begin(agc_output *out, agc_notice *n) {
  n->out = out;
  n->file = NULL;
  return out->file;
}

void agc_notice_end(agc_notice *n, agc_notice_mode mode) {
  (void)mode;
  fflush(n->out->file);
}
#endif

bool agc_write(agc_vm *vm, agc_output *out, const agc_string *text, bool newline) {
#if defined(__linux__) || defined(__APPLE__)
  if (out->base) return put(vm, out, text, newline);
#endif
  if (text->bytes && fwrite(text->data, 1, text->bytes, out->file) != text->bytes) write_failed(vm, out);
  if (newline && fputc('\n', out->file) == EOF) write_failed(vm, out);
  return true;
}

void agc_flush(agc_vm *vm) {
  agc_output *out = &vm->rt->out;
#if defined(__linux__) || defined(__APPLE__)
  if (out->base) {
    flush_now(out->base);
    return;
  }
#endif
  if (fflush(out->file) != 0) write_failed(vm, out);
}
