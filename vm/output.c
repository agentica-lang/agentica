/*
 * Standard output and standard error: one writer per stream, with a 64 KiB
 * ring and a FIFO of waiting writers, so that a print waits its turn instead
 * of interleaving. Core layer. Design: docs/vm/10-io-scheduler.md §10.2.2.
 *
 * Each stream has a lock (`lock` in agc_output, the base's when two streams share one; solo until agc_share). The
 * public entry points take it for the whole call and drop it before they return or fail; the static helpers assume it
 * is held, and none of them takes it again. It is never held across a park: a task that must wait is on the stream's
 * FIFO and returns. Lock order: rt->sync, then the stream's lock, then the run queue's (docs/vm/16-architecture.md
 * §16.9).
 */
#include "core.h"

#include <assert.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

/* How long a stop signal and the final diagnostics wait, all together, for a stream that has no non-blocking try: a
   Windows pipe or console, or any handle whose writer is a pool thread or a request. */
#define FINAL_WAIT_MS 200

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
/* One write of a pool job or a stream: the two ranges of the ring and what came of them. A POLL stream has no ranges. */
typedef struct {
  bool to_err;
  int fd, status;
  const uint8_t *part[2];
  size_t length[2], written;
  agc_utf8_cut cut;
  agc_io_job *job;
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

bool agc_output_waiting(const agc_vm *vm, const agc_output *out) { return vm->task->output.out == out; }

bool agc_output_failed(const agc_output *out) { return out->base && out->base->failed; }

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
/* The scheduler remembers the stream lock it holds (vm->stream_lock), so a failure that jumps out of the code that holds
   it gives it back (agc_sync_reset). The streams' locks are never held together. */
static void stream_take(agc_vm *vm, agc_lock *l) {
  agc_lock_take(l);
  vm->stream_lock = l;
}

static void stream_drop(agc_vm *vm, agc_lock *l) {
  vm->stream_lock = NULL;
  agc_lock_drop(l);
}

/* A failure of a call that holds the stream's lock: the lock goes first, because agc_fail jumps out of the call. */
static _Noreturn void fail_locked(agc_vm *vm, agc_output *out) {
  stream_drop(vm, out->base->lock);
  fail_write(vm, out);
}

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

/* The loop may write the ring itself (a final write when the run stops): a file or a device that never waits for a
   reader, or a descriptor that its poller reported ready. */
static bool direct(const agc_output *s) { return s->mode == AGC_WRITE_DISK || s->mode == AGC_WRITE_POLL; }

/* A pool job or a stream holds pointers into the ring and the buffer; a POLL stream only waits for readiness. */
static bool held(const agc_output *s) { return s->writing && s->mode != AGC_WRITE_POLL; }

static agc_output *stream_of(agc_vm *vm, bool to_err) { return to_err ? &vm->rt->err : &vm->rt->out; }

static void trace_run(const agc_output *s, const char *what) {
  if (s->vm && s->mode != AGC_WRITE_DISK)
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
  /* A request in flight points into the ring; only its done half may clear it. */
  assert(!held(s));
  s->failed = true;
  s->start = s->len = 0;
  drop_notices(s);
  for (agc_task *t = s->waiters; t; t = t->wait_next) agc_task_wake(s->vm, t, "output");
}

/* Writes what the descriptor takes without waiting, for a stream the loop may write (direct). */
/* Writes while the descriptor takes data: until it would block, it fails, or a request holds the ring. On macOS every
   pass is one chunk that agc_stdio_try has capped and checked with poll, and the loop goes on while the descriptor
   stays writable, so a ready poll is not one chunk per round trip of the loop. */
static void write_now(agc_output *s) {
  while (s->len && direct(s) && !held(s)) {
    ssize_t done = agc_stdio_try(s, s->buf + s->start, run_length(s));
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
      ssize_t n = agc_stdio_write(q->fd, q->part[k] + at, q->length[k] - at, &q->cut);
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

/* A stream has written its ranges, or a poller reports the descriptor ready: the done half runs on the loop. */
static void request_finished(void *data, int status) {
  drain_request *q = data;
  q->status = status;
  q->written = status ? 0 : q->length[0] + q->length[1];
  agc_io_ready(q->job);
}

static const agc_io_kind drain_io;
static const agc_io_kind watch_io;

/* The request for the bytes in the ring now. The ring only grows at its end while the request is out, so the two
   ranges stay valid until its done half consumes them (see struct agc_output). */
static drain_request *begin_drain(agc_output *s) {
  drain_request *q = calloc(1, sizeof(drain_request));
  if (!q) agc_out_of_memory();
  q->to_err = s == &s->vm->rt->err;
  q->fd = s->fd;
  q->cut = s->cut;
  if (s->mode != AGC_WRITE_POLL) {
    size_t first = run_length(s);
    q->part[0] = s->buf + s->start;
    q->length[0] = first;
    q->part[1] = s->buf;
    q->length[1] = s->len - first;
  }
  s->writing = true;
  return q;
}

/* Starts a write of the ring if none is out: a pool job, or a request that tells the loop when the descriptor can be
   written (POLL) or when the stream has taken the bytes (STREAM). */
static void kick(agc_output *s) {
  if (s->failed || !s->len || s->writing) return;
  drain_request *q = begin_drain(s);
  if (s->mode == AGC_WRITE_DISK || s->mode == AGC_WRITE_THREAD) {
    agc_io_detached(s->vm, &drain_io, q, agc_void(), 0);
    return;
  }
  q->job = agc_io_detached(s->vm, &watch_io, q, agc_void(), AGC_JOB_QUIET);
  agc_stdio_start(s, q->part[0], q->length[0], q->part[1], q->length[1], request_finished, q);
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

/* The done half of every write. A POLL stream is told that the descriptor can be written and writes what it takes;
   the others are told what the pool job or the stream wrote. */
static agc_value drain_done_locked(agc_vm *vm, void *data) {
  drain_request *q = data;
  agc_output *s = stream_of(vm, q->to_err);
  size_t written = q->written;
  int status = q->status;
  agc_utf8_cut cut = q->cut;
  free(q);
  s->writing = false;
  if (!s->base) {
    free(s->buf);
    s->buf = NULL;
    return agc_void();
  }
  if (s->mode == AGC_WRITE_POLL) {
    if (s->failed) return agc_void();
    write_now(s);
    if (status < 0 && s->len && !s->failed) fail_stream(s);
    advance(s);
    return agc_void();
  }
  s->cut = cut;
  if (status) {
    fail_stream(s);
  } else {
    consumed(s, written);
    advance(s);
  }
  return agc_void();
}

static agc_value drain_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  const drain_request *q = data;
  agc_lock *lock = stream_of(vm, q->to_err)->lock;
  stream_take(vm, lock);
  agc_value result = drain_done_locked(vm, data);
  stream_drop(vm, lock);
  return result;
}

static const agc_io_kind drain_io = {drain_work, drain_done, drain_done, request_drop, false, "output", NULL, false};
static const agc_io_kind watch_io = {NULL, drain_done, drain_done, request_drop, true, "output", NULL, false};

static void flush_now(agc_output *s) {
  if (s->failed) return;
  if (s->mode == AGC_WRITE_POLL) write_now(s);
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

/* One look at the wait of the running task, which is marked PARKING already (a task that joins the FIFO marks before
   it links itself, a turn that resumes marks first: `put` and `agc_drain`), so a drain that frees room after the check
   below finds PARKING and sets WOKEN instead of being dropped; a turn that ends the wait puts the state back. */
static bool wait_turn(agc_vm *vm, agc_output *out) {
  agc_output *s = out->base;
  agc_task *t = vm->task;
  agc_output_wait *w = &t->output;
  if (s->failed) {
    stop_waiting(s, t);
    fail_locked(vm, out);
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

/* The start of a print or a flush, with the stream's lock taken: true when the task is not yet in the FIFO (it is a
   new writer; false when it comes back to the call it parked in). */
static bool enter(agc_vm *vm, agc_output *out) {
  stream_take(vm, out->base->lock);
  bool new_writer = vm->task->output.out != out;
  if (new_writer && out->base->failed) fail_locked(vm, out);
  return new_writer;
}

/* The end of a print or a flush that waits its turn: marks the task PARKING before it links itself, looks at its wait
   once and drops the stream's lock. */
static bool take_turn(agc_vm *vm, agc_output *out, bool new_writer) {
  agc_output *s = out->base;
  agc_task_parking(vm);
  if (new_writer) agc_task_enqueue(&s->waiters, &s->waiters_tail, vm->task);
  bool done = wait_turn(vm, out);
  stream_drop(vm, s->lock);
  return done;
}

static bool put(agc_vm *vm, agc_output *out, const agc_string *text, bool newline) {
  agc_output *s = out->base;
  bool new_writer = enter(vm, out);
  if (new_writer) {
    agc_output_wait w = {.out = out, .text = text, .newline = newline};
    if (total(&w) == 0) {
      stream_drop(vm, s->lock);
      return true;
    }
    if (!s->waiters && !queued(s) && total(&w) <= room(s)) {
      copy_piece(s, &w, total(&w));
      kick(s);
      stream_drop(vm, s->lock);
      return true;
    }
    vm->task->output = w;
  }
  return take_turn(vm, out, new_writer);
}

bool agc_drain(agc_vm *vm) {
  agc_output *out = &vm->rt->out;
  if (!out->base) {
    agc_flush(vm);
    return true;
  }
  agc_output *s = out->base;
  bool new_writer = enter(vm, out);
  if (new_writer) {
    flush_now(s);
    if (s->failed) fail_locked(vm, out);
    if (!s->len && !s->waiters && !queued(s)) {
      stream_drop(vm, s->lock);
      return true;
    }
    vm->task->output = (agc_output_wait){.out = out, .flush = true};
  }
  return take_turn(vm, out, new_writer);
}

void agc_output_leave(agc_vm *vm, agc_task *t) {
  agc_output *s = t->output.out->base;
  stream_take(vm, s->lock);
  stop_waiting(s, t);
  advance(s);
  stream_drop(vm, s->lock);
}

/* A pipe or a console has no non-blocking try: the data goes out through a request or a pool job, and the caller gives
   it a moment. The moment is shared (agc_runtime.settle_by): long enough for a reader that is there, short enough that
   a reader that is not cannot hold the exit once per stream and per notice. */
static void settle(agc_output *s) {
  agc_vm *vm = s->vm;
  uint64_t now = agc_clock_ms();
  if (!vm->rt->settle_by) vm->rt->settle_by = now + FINAL_WAIT_MS;
  kick(s);
  while (s->writing && !s->failed && now < vm->rt->settle_by) {
    /* The loop runs the drain of this very stream (drain_done takes the lock), so a caller that holds the lock gives it
       back for the run and takes it again. */
    bool held = agc_lock_held(s->lock);
    if (held) stream_drop(vm, s->lock);
    bool alive = agc_io_run_for(vm, vm->rt->settle_by - now, true);
    if (held) stream_take(vm, s->lock);
    if (!alive) return;
    now = agc_clock_ms();
  }
}

/* The last write of a stream: what the descriptor takes at once, or what a request or a pool job writes in the time
   that settle allows. */
static void write_last(agc_output *s) {
  if (direct(s))
    write_now(s);
  else
    settle(s);
}

/* True while a stream still has data to send. The normal end of the run kicks every stream and the caller waits, up to
   the flush limit, until none is busy. After a stop signal each stream gets one last write and the caller does not
   wait. */
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
    } else if (!(direct(s) && held(s))) {
      pump(s, true);
      write_last(s);
    }
  }
  return busy;
}

void agc_output_open(agc_vm *vm, agc_output *out, int fd) {
  vm->rt->settle_by = 0;
  const agc_output *first = out == &vm->rt->err ? &vm->rt->out : NULL;
  if (first && first->base && agc_stdio_same(first, fd)) {
    out->base = first->base;
    return;
  }
  if (!agc_stdio_open(vm, out, fd)) return;
  out->buf = malloc(AGC_OUTPUT_BUFFER);
  if (!out->buf) agc_out_of_memory();
  out->vm = vm;
  out->base = out;
}

/* With a request in flight (held) the 64 KiB ring is kept on purpose: a pool thread or libuv may still read it, even
   after the stream is cancelled. drain_done frees it once the request has ended; if the job is dropped instead
   (request_drop, at the close of a test harness), only the request is freed and the ring stays until the process
   exits. */
static void close_stream(agc_output *s) {
  if (!s->base) return;
  if (s->base == s) {
    if (s->io) agc_stdio_close(s->io);
    s->io = NULL;
    if (!held(s)) {
      free(s->buf);
      s->buf = NULL;
      s->writing = false;
    }
    drop_notices(s);
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
  n->mem = NULL;
  n->text = NULL;
  n->len = 0;
  n->file = out->base ? agc_memstream_open(&n->mem) : NULL;
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
  if (s->mode == AGC_WRITE_DISK && s->writing) return;
  pump(s, true);
  size_t at = 0;
  while (at < n && !s->failed) {
    write_last(s);
    size_t k = smaller(n - at, room(s));
    if (!k) return;
    put_bytes(s, text + at, k);
    at += k;
  }
  write_last(s);
}

void agc_notice_end(agc_notice *n, agc_notice_mode mode) {
  static const char lost[] = "agentica: a diagnostic was lost: out of memory\n";
  agc_output *out = n->out;
  if (!n->file) {
    fflush(out->file);
    return;
  }
  bool whole = agc_memstream_take(n->file, n->mem, &n->text, &n->len);
  const char *text = n->text;
  size_t len = n->len;
  if (!whole && !len) {
    text = lost;
    len = sizeof lost - 1;
  }
  agc_output *s = out->base;
  agc_vm *vm = s->vm;
  stream_take(vm, s->lock);
  bool write = !s->failed && len;
  if (write && mode == AGC_NOTICE_FINAL)
    finish_text(s, text, len);
  else if (write)
    queue_notice(s, text, len, mode == AGC_NOTICE_KEPT);
  free(n->text);
  if (write && mode != AGC_NOTICE_FINAL) flush_now(s);
  stream_drop(vm, s->lock);
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

/* Drops the lock of the blocking FILE fallback and returns OK, keeping errno for write_failed. */
static bool unlock_keeping_errno(agc_lock *l, bool ok) {
  int saved = errno;
  agc_lock_drop(l);
  errno = saved;
  return ok;
}

/* The blocking FILE fallback: a print is two stdio calls (the text, then the newline), so the stream's own lock keeps
   the lines of two tasks apart. The lock is dropped before a failure, and errno is kept for write_failed. */
bool agc_write(agc_vm *vm, agc_output *out, const agc_string *text, bool newline) {
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
  if (out->base) return put(vm, out, text, newline);
#endif
  agc_lock_take(out->lock);
  bool ok = !text->bytes || fwrite(text->data, 1, text->bytes, out->file) == text->bytes;
  ok = ok && (!newline || fputc('\n', out->file) != EOF);
  if (!unlock_keeping_errno(out->lock, ok)) write_failed(vm, out);
  return true;
}

void agc_flush(agc_vm *vm) {
  agc_output *out = &vm->rt->out;
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
  if (out->base) {
    stream_take(vm, out->base->lock);
    flush_now(out->base);
    stream_drop(vm, out->base->lock);
    return;
  }
#endif
  agc_lock_take(out->lock);
  if (!unlock_keeping_errno(out->lock, fflush(out->file) == 0)) write_failed(vm, out);
}
