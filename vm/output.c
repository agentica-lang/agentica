#include "core.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#ifdef __linux__
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
  agc_output *out;
  const agc_io_kind *kind;
  int fd, err;
  const uint8_t *part[2];
  size_t length[2], written;
} drain_request;
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

static void track(agc_vm *vm, const agc_output *out, uint8_t last) {
  if (out == &vm->rt->out) vm->rt->out_mid_line = last != '\n';
}

#ifdef __linux__
static size_t room(const agc_output *out) { return AGC_OUTPUT_BUFFER - out->len; }

static size_t run_length(const agc_output *out) {
  size_t to_end = AGC_OUTPUT_BUFFER - out->start;
  return to_end < out->len ? to_end : out->len;
}

static void put_bytes(agc_output *out, const void *data, size_t n) {
  if (!n) return;
  size_t end = (out->start + out->len) % AGC_OUTPUT_BUFFER;
  size_t first = AGC_OUTPUT_BUFFER - end < n ? AGC_OUTPUT_BUFFER - end : n;
  memcpy(out->buf + end, data, first);
  if (n > first) memcpy(out->buf, (const uint8_t *)data + first, n - first);
  out->len += n;
}

static void consumed(agc_output *out, size_t n) {
  out->start = (out->start + n) % AGC_OUTPUT_BUFFER;
  out->len -= n;
  if (!out->len) out->start = 0;
}

static size_t need(const agc_output_wait *w) {
  if (w->flush) return AGC_OUTPUT_BUFFER;
  size_t rest = w->len - w->done;
  return rest < AGC_OUTPUT_BUFFER ? rest : AGC_OUTPUT_BUFFER;
}

static void wake_head(agc_output *out) {
  agc_task *t = out->waiters;
  if (t && room(out) >= need(&t->output)) agc_task_wake(out->vm, t, "output");
}

static void fail_stream(agc_output *out) {
  out->failed = true;
  out->start = out->len = 0;
  if (out->armed) agc_poller_pause(out->poller);
  out->armed = false;
  for (agc_task *t = out->waiters; t; t = t->wait_next) agc_task_wake(out->vm, t, "output");
}

static void write_now(agc_output *out) {
  while (out->len) {
    ssize_t n = write(out->fd, out->buf + out->start, run_length(out));
    if (n > 0) {
      consumed(out, (size_t)n);
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
    fail_stream(out);
    return;
  }
}

static void settle(agc_output *out) {
  if (!out->len && out->armed) {
    out->armed = false;
    agc_poller_pause(out->poller);
  }
  wake_head(out);
}

static void writable(void *data, int status) {
  agc_output *out = data;
  write_now(out);
  if (status < 0 && out->len && !out->failed) fail_stream(out);
  settle(out);
}

static void drain_work(void *data) {
  drain_request *q = data;
  for (int k = 0; k < 2; k++) {
    size_t at = 0;
    while (at < q->length[k]) {
      ssize_t n = write(q->fd, q->part[k] + at, q->length[k] - at);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) {
        q->err = n < 0 ? errno : EIO;
        return;
      }
      at += (size_t)n;
      q->written += (size_t)n;
    }
  }
}

static void start_run(agc_output *out, const agc_io_kind *kind) {
  drain_request *q = calloc(1, sizeof(drain_request));
  if (!q) agc_out_of_memory();
  size_t first = run_length(out);
  q->out = out;
  q->kind = kind;
  q->fd = out->fd;
  q->part[0] = out->buf + out->start;
  q->length[0] = first;
  q->part[1] = out->buf;
  q->length[1] = out->len - first;
  out->writing = true;
  agc_io_detached(out->vm, kind, q);
}

static agc_value drain_done(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  drain_request *q = data;
  agc_output *out = q->out;
  const agc_io_kind *kind = q->kind;
  size_t written = q->written;
  int err = q->err;
  free(q);
  out->writing = false;
  if (err) {
    fail_stream(out);
  } else {
    consumed(out, written);
    if (out->len) start_run(out, kind);
  }
  wake_head(out);
  return agc_void();
}

static void drain_drop(void *data) { free(data); }

static const agc_io_kind drain_io = {drain_work, drain_done, drain_done, drain_drop, false, "output", NULL};

static void kick(agc_output *out) {
  if (out->failed || !out->len) return;
  if (out->pooled) {
    if (!out->writing) start_run(out, &drain_io);
  } else if (!out->armed) {
    out->armed = true;
    agc_poller_wait(out->poller, true, writable, out);
  }
}

static void flush_now(agc_output *out) {
  if (out->failed) return;
  if (!out->pooled) {
    write_now(out);
    settle(out);
  }
  kick(out);
}

static bool wait_turn(agc_vm *vm, agc_output *out) {
  agc_task *t = vm->task;
  agc_output_wait *w = &t->output;
  if (out->failed) {
    agc_task_remove(&out->waiters, &out->waiters_tail, t);
    *w = (agc_output_wait){0};
    fail_write(vm, out);
  }
  if (out->waiters != t || room(out) < need(w)) {
    agc_task_park(vm, true);
    return false;
  }
  if (!w->flush) {
    size_t n = w->len - w->done;
    if (n > room(out)) n = room(out);
    put_bytes(out, w->data + w->done, n);
    w->done += n;
    kick(out);
    if (w->done < w->len) {
      agc_task_park(vm, true);
      return false;
    }
    track(vm, out, w->data[w->len - 1]);
  }
  agc_task_remove(&out->waiters, &out->waiters_tail, t);
  *w = (agc_output_wait){0};
  wake_head(out);
  return true;
}

static bool put(agc_vm *vm, agc_output *out, const void *data, size_t len, bool newline) {
  agc_task *t = vm->task;
  if (t->output.out != out) {
    if (out->failed) fail_write(vm, out);
    size_t total = agc_size_add(len, newline ? 1 : 0);
    if (total == 0) return true;
    if (!out->waiters && total <= room(out)) {
      put_bytes(out, data, len);
      if (newline) put_bytes(out, "\n", 1);
      kick(out);
      track(vm, out, newline ? '\n' : ((const uint8_t *)data)[len - 1]);
      return true;
    }
    uint8_t *copy = agc_alloc_atomic(total);
    if (len) memcpy(copy, data, len);
    if (newline) copy[len] = '\n';
    t->output = (agc_output_wait){out, copy, total, 0, false};
    agc_task_enqueue(&out->waiters, &out->waiters_tail, t);
  }
  return wait_turn(vm, out);
}

bool agc_drain(agc_vm *vm, agc_output *out) {
  if (out->fd < 0) {
    if (fflush(out->file) != 0) write_failed(vm, out);
    return true;
  }
  agc_task *t = vm->task;
  if (t->output.out != out) {
    if (out->failed) fail_write(vm, out);
    flush_now(out);
    if (!out->len && !out->waiters) return true;
    t->output = (agc_output_wait){.out = out, .flush = true};
    agc_task_enqueue(&out->waiters, &out->waiters_tail, t);
  }
  return wait_turn(vm, out);
}

void agc_output_leave(agc_vm *vm, agc_task *t) {
  (void)vm;
  agc_output *out = t->output.out;
  agc_task_remove(&out->waiters, &out->waiters_tail, t);
  t->output = (agc_output_wait){0};
  wake_head(out);
}

bool agc_output_busy(const agc_vm *vm) { return vm->rt->out.len > 0 || vm->rt->err.len > 0; }

void agc_output_open(agc_vm *vm, agc_output *out, int fd) {
  struct stat info;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || (flags & O_ACCMODE) == O_RDONLY || fstat(fd, &info) != 0) return;
  bool pooled = S_ISREG(info.st_mode) || S_ISBLK(info.st_mode);
  int use = fd;
  agc_poller *poller = NULL;
  if (!pooled) {
    if (!S_ISFIFO(info.st_mode) && !S_ISCHR(info.st_mode)) return;
    char path[32];
    snprintf(path, sizeof path, "/proc/self/fd/%d", fd);
    int again = open(path, O_WRONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
    if (again < 0) return;
    int err = 0;
    poller = agc_poller_open(vm, again, &err);
    if (poller) {
      use = again;
    } else {
      close(again);
      if (err != EPERM) return;
      pooled = true;
    }
  }
  out->buf = malloc(AGC_OUTPUT_BUFFER);
  if (!out->buf) agc_out_of_memory();
  out->vm = vm;
  out->fd = use;
  out->poller = poller;
  out->pooled = pooled;
}

static void close_stream(agc_output *out) {
  if (out->fd < 0) return;
  if (out->poller) {
    agc_poller_pause(out->poller);
    agc_poller_close(out->poller);
    out->poller = NULL;
  }
  if (!out->writing) {
    free(out->buf);
    out->buf = NULL;
  }
  out->fd = -1;
  out->armed = false;
  out->len = 0;
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
  if (out->fd >= 0) n->file = open_memstream(&n->text, &n->len);
  return n->file ? n->file : out->file;
}

void agc_notice_end(agc_notice *n, bool final) {
  agc_output *out = n->out;
  if (!n->file) {
    fflush(out->file);
    return;
  }
  fclose(n->file);
  if (!out->failed && n->len <= room(out)) {
    put_bytes(out, n->text, n->len);
    if (!final)
      flush_now(out);
    else if (!out->writing)
      write_now(out);
  }
  free(n->text);
}
#else
bool agc_drain(agc_vm *vm, agc_output *out) {
  if (fflush(out->file) != 0) write_failed(vm, out);
  return true;
}

void agc_output_leave(agc_vm *vm, agc_task *t) {
  (void)vm;
  (void)t;
}

bool agc_output_busy(const agc_vm *vm) {
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

void agc_notice_end(agc_notice *n, bool final) {
  (void)final;
  fflush(n->out->file);
}
#endif

bool agc_write(agc_vm *vm, agc_output *out, const void *data, size_t len, bool newline) {
#ifdef __linux__
  if (out->fd >= 0) return put(vm, out, data, len, newline);
#endif
  if (len && fwrite(data, 1, len, out->file) != len) write_failed(vm, out);
  if (newline && fputc('\n', out->file) == EOF) write_failed(vm, out);
  if (len || newline) track(vm, out, newline ? '\n' : ((const uint8_t *)data)[len - 1]);
  return true;
}

void agc_flush(agc_vm *vm) {
  agc_output *out = &vm->rt->out;
#ifdef __linux__
  if (out->fd >= 0) {
    flush_now(out);
    return;
  }
#endif
  if (fflush(out->file) != 0) write_failed(vm, out);
}
