/*
 * The Process builtins: spawning and
 * watching child processes, their pipes, and the environment entries that the VM
 * keeps for itself. The I/O thread owns each child's handles and buffers; with
 * several schedulers a builtin posts its step there and parks. Service layer.
 * Design: docs/vm/10-io-processes.md §10.4, docs/vm/16-architecture.md §16.9.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "net_os.h"
#include "services.h"
#include "file_io.h"
#include "process_os.h"
#include "duplex_os.h"

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif
#include <uv.h>

#define LIMIT ((size_t)1048576)
#define ERR_CHUNK 4096
#define REAP_MS 1000
#define GRACE_MS 1000
#define URING_ENV "UV_USE_IO_URING="
#define CHANNEL_PREFIX AGC_CHANNEL_ENV "="
#define METRICS_ENV "AGENTICA_VM_METRICS="
#define METRICS_FILE_ENV "AGENTICA_VM_METRICS_FILE="
#define DRAIN_LIMIT ((size_t)2097152)
#define STDIO_SLOTS 5
#define OWNER(ptr, field) ((proc *)(void *)((char *)(ptr) - offsetof(proc, field)))

typedef enum {
  REQ_LINE, REQ_BYTES, REQ_SEND, REQ_WAIT, REQ_OUTPUT, REQ_CLOSE, REQ_AVAILABLE, REQ_SPAWN, REQ_STDIN
} req_kind;
typedef enum { STOP_NONE, STOP_TERM, STOP_KILLED } stop_state;

typedef struct proc proc;
typedef struct request request;
typedef struct guard guard;
typedef struct launch launch;

/* What a spawn hands to the I/O thread: malloc'd strings, no VM values. */
struct launch {
  guard *g;
  char **argv, **env;
  char *cwd;
  size_t args;
  bool channel;
};

/* A request's slot and count on its child are taken by its START step (link_request), on the I/O thread. A request
   made where that step does not run at once (POSTED: several schedulers) carries its result too: `finish` fills it on
   the I/O thread and the done half reads only the request, never the child (docs/vm/16-architecture.md §16.9). */
struct request {
  req_kind kind;
  proc *p;
  agc_io_job *job;
  request *next;
  size_t count;
  bool posted, counted, finished, stopped;
  bool closed, over, stdin_closed;
  /* CLOSE: the request holds the count of the resource that the builtin unregistered, until its START gives it back.
     DETACHED: the job lost its task (the cancel half ran), so the done half has no caller to fail. */
  bool holds_resource, detached;
  int rc;
  int64_t status;
  uint32_t span;
  agc_inbuf_cut cut;
  /* SEND: the bytes to write. OUTPUT: copies of the kept stdout and stderr. */
  uint8_t *data, *err_data;
  size_t len, err_len;
  launch *start;
};

struct guard {
  agc_trace trace;
  agc_loop *io;
  proc *first;
  size_t running;
  bool released, reaping;
};

struct proc {
  agc_trace trace;
  agc_loop *io;
  uv_process_t process;
  uv_pipe_t in, out, err;
  uv_timer_t grace;
  uv_write_t write_req;
  /* A plain child's stderr goes to the VM's stderr (agc_output_forward). While the stream's queue is full the read is
     stopped (paused) and the stream holds forward_wait, with one count in `users`, until it resumes the read. */
  agc_output *forward;
  agc_forward_wait forward_wait;
  agc_duplex *channel;
  guard *g;
  proc *run_prev, *run_next;
  size_t users, handles;
  /* begun: the spawn has run, so the handles below are in some state; a child whose spawn never ran has none. */
  bool begun, linked, running, exited, err_done, in_closed, closed, reading;
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
static const char over_text[] = "process: output exceeds 1048576 bytes";

static agc_value ok_void(void) { return agc_result_value(true, agc_void()); }

static void settle(proc *p) {
  if (p->users || p->handles) return;
  agc_inbuf_free(&p->out_buf);
  agc_inbuf_free(&p->err_kept);
  free(p->write_data);
  if (p->channel) agc_duplex_release(p->channel);
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

static const uint8_t *pending_data(const agc_inbuf *b) {
  return agc_inbuf_pending(b) ? b->data + b->start : (const uint8_t *)"";
}

static size_t whole_prefix(const uint8_t *data, size_t n) {
  size_t back = 0;
  while (back < 3 && back < n && (data[n - 1 - back] & 0xC0) == 0x80) back++;
  if (back == n) return n;
  uint8_t lead = data[n - 1 - back];
  size_t need = 1;
  if (lead >= 0xF0 && lead <= 0xF4)
    need = 4;
  else if (lead >= 0xE0 && lead < 0xF0)
    need = 3;
  else if (lead >= 0xC2 && lead < 0xE0)
    need = 2;
  return back + 1 < need ? n - (back + 1) : n;
}

/* What Process.read_available takes now: the pending stdout, without a UTF-8 sequence cut at its end while more may
   come. */
static size_t available_bytes(const agc_inbuf *b) {
  size_t n = agc_inbuf_pending(b);
  return b->eof || b->error ? n : whole_prefix(pending_data(b), n);
}

static void copy_bytes(uint8_t **to, size_t *len, const uint8_t *from, size_t n) {
  *len = n;
  *to = NULL;
  if (!n) return;
  *to = malloc(n);
  if (!*to) agc_out_of_memory();
  memcpy(*to, from, n);
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

/* A posted request is over: its result goes into it, it leaves its slot and its job is readied. A read takes its line
   or bytes out of the buffer here, so the buffers stay the I/O thread's. I/O thread only; once finished the request is
   the job's. True when a line read met a line longer than the limit: the caller then shuts the child (shut readies
   the reader itself, so it is not called from here). */
static bool finish(request *q) {
  if (q->finished) return false;
  proc *p = q->p;
  q->finished = true;
  unlink_request(q);
  q->closed = p->closed;
  q->over = p->out_cut || p->err_cut;
  bool reads = !q->closed && !q->over;
  switch (q->kind) {
    case REQ_LINE:
      if (reads) agc_inbuf_cut_line(&p->out_buf, &q->cut);
      break;
    case REQ_BYTES:
      if (reads) agc_inbuf_cut_bytes(&p->out_buf, q->count, &q->cut);
      break;
    case REQ_AVAILABLE:
      if (reads) {
        size_t n = available_bytes(&p->out_buf);
        copy_bytes(&q->cut.data, &q->cut.len, pending_data(&p->out_buf), n);
        agc_inbuf_take(&p->out_buf, n);
      }
      break;
    case REQ_SEND:
      q->rc = p->write_status;
      break;
    case REQ_WAIT:
      q->status = p->status;
      break;
    case REQ_OUTPUT:
      if (!q->closed) {
        copy_bytes(&q->data, &q->len, pending_data(&p->out_buf), agc_inbuf_pending(&p->out_buf));
        copy_bytes(&q->err_data, &q->err_len, pending_data(&p->err_kept), agc_inbuf_pending(&p->err_kept));
      }
      break;
    default:
      break;
  }
  /* Once readied the request is the job's, and its done half may free it on a scheduler: nothing reads it after. */
  bool over = q->kind == REQ_LINE && reads && q->cut.status == AGC_CUT_OVER;
  agc_io_ready(q->job);
  return over;
}

/* A request's wait is over. One made at N = 1 reads the child in its done half, as before; a posted one is
   finished here. */
static void ready(request *q) {
  if (q->posted)
    (void)finish(q);
  else
    agc_io_ready(q->job);
}

/* `finish` unlinks a posted request from the list, so the next one is read first. */
static void notify_waits(proc *p) {
  for (request *q = p->waits, *next; q; q = next) {
    next = q->next;
    if (waits_over(p, q->kind)) ready(q);
  }
}

static void finished(proc *p, int64_t status) {
  p->running = false;
  p->exited = true;
  p->status = status;
  if (p->linked) unlink_child(p);
}

/* UV_ESRCH means the child has already ended and only its exit callback is
   still to come, which is the state we wanted: it is not a failed stop. The
   mask is deliberate on every system, with no #ifdef. On Windows,
   TerminateProcess on an ended process fails and libuv maps that to
   UV_ESRCH. On POSIX a zombie still takes a signal, so ESRCH there means
   someone else reaped the child (a host with SIGCHLD set to SIG_IGN, or its
   own reaper); no exit status is ever seen then. A narrow race stays: libuv (win/process.c, uv__kill) reports
   UV_EACCES instead when the process has exited with the code 259 or its
   handle is not yet signaled, and that is still a failed stop. If ESRCH ever
   comes while `running` is still true, the exit is awaited, for up to REAP_MS
   at the end of a run. */
static int signal_child(proc *p, int sig) {
  int rc = uv_process_kill(&p->process, sig);
  if (rc == UV_ESRCH) rc = 0;
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
  if (!p->begun) return 0;
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
  if (p->channel) agc_duplex_shut(p->channel);
  if (p->reader) ready(p->reader);
  if (p->writer) ready(p->writer);
  notify_waits(p);
  retire(p);
  return err;
}

/* The reader's input is ready (a line, the bytes, the end, a cut or an error). */
static void reader_ready(proc *p, request *q) {
  if (!q->posted) {
    agc_io_ready(q->job);
    return;
  }
  if (finish(q)) shut(p);
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
  uv_loop_t *loop = agc_loop_uv(g->io);
  uv_timer_t bound;
  uv_update_time(loop);
  uv_timer_init(loop, &bound);
  uv_timer_start(&bound, bound_over, REAP_MS, 0);
  while (uv_is_active((uv_handle_t *)&bound) && exits_pending(g, grace)) uv_run(loop, UV_RUN_ONCE);
  if (!grace)
    for (const proc *p = g->first; p; p = p->run_next)
      if (to_await(p, grace)) trace_alive(p);
  uv_close((uv_handle_t *)&bound, NULL);
  uv_run(loop, UV_RUN_NOWAIT);
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

static void release_step(void *native) {
  proc *p = native;
  if (p->g) close_children(p->g);
  shut(p);
  p->users--;
  settle(p);
}

/* The registry's release: at the end of the run (on the I/O thread), so a step there. */
static void release_proc(void *native) {
  proc *p = native;
  agc_loop_call(p->io, release_step, p);
}

static proc *unregister_child(agc_vm *vm, agc_resource *r) {
  proc *p = r->native;
  if (!p) return NULL;
  r->native = NULL;
  agc_unregister(vm, r);
  return p;
}

static void close_step(void *native) {
  proc *p = native;
  shut(p);
  p->users--;
  settle(p);
}

/* The scheduler's half of a close (the resource, under rt->sync); the child's half is a step on the I/O thread. */
static void close_child(agc_vm *vm, agc_resource *r, agc_task *ender) {
  (void)ender;
  proc *p = unregister_child(vm, r);
  if (p) agc_loop_call(p->io, close_step, p);
}

/* POSTED when the START step will not run at once (several schedulers): the request then carries its result. */
static request *new_request(agc_vm *vm, proc *p, req_kind kind) {
  request *q = calloc(1, sizeof(request));
  if (!q) agc_out_of_memory();
  q->kind = kind;
  q->p = p;
  q->posted = !agc_io_here(vm);
  return q;
}

/* The START step of a request (on the I/O thread, at once at N = 1): its count on the child and its slot. */
static void link_request(request *q, agc_io_job *job) {
  proc *p = q->p;
  q->job = job;
  q->counted = true;
  p->users++;
  if (q->kind == REQ_LINE || q->kind == REQ_BYTES || q->kind == REQ_AVAILABLE) {
    p->reader = q;
  } else if (q->kind == REQ_SEND) {
    p->writer = q;
  } else if (q->kind == REQ_WAIT || q->kind == REQ_OUTPUT || q->kind == REQ_CLOSE) {
    q->next = p->waits;
    p->waits = q;
  }
}

static bool begin_link(void *data, agc_io_job *job) {
  link_request(data, job);
  return true;
}

static void free_launch(launch *l) {
  if (!l) return;
  if (l->argv)
    for (size_t k = 0; l->argv[k]; k++) free(l->argv[k]);
  free(l->argv);
  if (l->env)
    for (size_t k = 0; l->env[k]; k++) free(l->env[k]);
  free(l->env);
  free(l->cwd);
  free(l);
}

/* The end of a request, on the I/O thread: from its done half, or the job's drop. A request whose START never ran
   (the run ended first) holds nothing on the child, except a close: it still holds the resource's count, so the child
   is shut and that count goes back here. */
static void drop_request(void *data) {
  request *q = data;
  proc *p = q->p;
  agc_inbuf_cut_free(&q->cut);
  free(q->data);
  free(q->err_data);
  free_launch(q->start);
  bool counted = q->counted, held = q->holds_resource;
  if (counted) unlink_request(q);
  free(q);
  if (held) {
    (void)shut(p);
    p->users--;
  }
  if (counted) p->users--;
  if (counted || held) settle(p);
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

static uint32_t output_struct(agc_vm *vm) {
  static const char *const fields[] = {"stdout", "stderr", "truncated"};
  return agc_builtin_struct(vm, "ProcessOutput", fields, 3);
}

static agc_value output_of(agc_vm *vm, const uint8_t *out, size_t out_len, const uint8_t *err, size_t err_len,
                           bool truncated) {
  agc_charge_bytes(vm, agc_size_add(out_len, err_len));
  agc_struct *s = agc_new_struct(output_struct(vm), 3);
  s->fields[0] = agc_string_value(agc_utf8_decode(out ? out : (const uint8_t *)"", out_len, "\xEF\xBF\xBD", false));
  s->fields[1] = agc_string_value(agc_utf8_decode(err ? err : (const uint8_t *)"", err_len, "\xEF\xBF\xBD", false));
  s->fields[2] = agc_bool(truncated);
  return agc_result_value(true, agc_struct_value(s));
}

static agc_value output_value(agc_vm *vm, const proc *p) {
  return output_of(vm, pending_data(&p->out_buf), agc_inbuf_pending(&p->out_buf), pending_data(&p->err_kept),
                   agc_inbuf_pending(&p->err_kept), p->out_cut || p->err_cut);
}

static agc_value waited(agc_vm *vm, const proc *p, req_kind kind) {
  return kind == REQ_WAIT ? agc_result_value(true, agc_int(p->status)) : output_value(vm, p);
}

static agc_value available_text(agc_vm *vm, const uint8_t *data, size_t n) {
  agc_charge_bytes(vm, n);
  agc_string *text = agc_utf8_decode(data ? data : (const uint8_t *)"", n, "\xEF\xBF\xBD", false);
  return agc_result_value(true, agc_string_value(text));
}

static agc_value available(agc_vm *vm, proc *p) {
  if (p->out_cut || p->err_cut) return agc_error_value(over_text);
  size_t n = available_bytes(&p->out_buf);
  agc_value result = available_text(vm, pending_data(&p->out_buf), n);
  agc_inbuf_take(&p->out_buf, n);
  return result;
}

/* A posted spawn's end. A failed one gives its resource back, as a close does. */
static agc_value spawned(agc_vm *vm, const request *q, agc_value context) {
  if (!q->rc) return agc_result_value(true, context);
  close_child(vm, agc_as_process(vm, context)->state, NULL);
  return agc_system_error(vm, "process: cannot run the executable", agc_net_errno(q->rc));
}

/* The done half of a posted request: the result that `finish` (or the START step) put in it, in the order of the
   checks at N = 1. */
static agc_value posted_result(agc_vm *vm, const request *q, agc_value context) {
  agc_value result;
  switch (q->kind) {
    case REQ_SPAWN:
      return spawned(vm, q, context);
    case REQ_CLOSE:
      return agc_void();
    case REQ_LINE:
    case REQ_BYTES:
      if (q->closed)
        result = agc_error_value(closed_text);
      else if (q->over)
        result = agc_error_value(over_text);
      else if (q->kind == REQ_LINE)
        result = agc_inbuf_cut_line_value(vm, &q->cut, "process: line exceeds 1048576 bytes", "process: end of input");
      else
        result = agc_inbuf_cut_bytes_value(vm, &q->cut);
      agc_charge(vm, agc_value_units(result));
      return result;
    case REQ_SEND:
      agc_charge(vm, q->count);
      if (q->closed) return agc_error_value(closed_text);
      if (q->stdin_closed) return agc_error_value("process: stdin is closed");
      return agc_stream_written(vm, q->rc);
    case REQ_STDIN:
      return q->closed ? agc_error_value(closed_text) : ok_void();
    case REQ_AVAILABLE:
      if (q->closed) return agc_error_value(closed_text);
      if (q->over) return agc_error_value(over_text);
      return available_text(vm, q->cut.data, q->cut.len);
    case REQ_WAIT:
      return q->closed ? agc_error_value(closed_text) : agc_result_value(true, agc_int(q->status));
    case REQ_OUTPUT:
      if (q->closed) return agc_error_value(closed_text);
      return output_of(vm, q->data, q->len, q->err_data, q->err_len, q->over);
  }
  return agc_void();
}

static agc_value request_done(agc_vm *vm, void *data, agc_value context) {
  request *q = data;
  if (q->posted) {
    agc_value result = posted_result(vm, q, context);
    bool failed = q->kind == REQ_CLOSE && q->rc && !q->detached;
    uint32_t span = q->span;
    /* The request goes back to the I/O thread, which owns its slot and the child's count. */
    agc_loop_call(agc_io_loop(vm), drop_request, q);
    if (failed) agc_fail(vm, "RUNTIME-PROCESS-CLOSE", "process: the child cannot be stopped", span);
    return result;
  }
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
  } else if (q->kind == REQ_AVAILABLE) {
    result = available(vm, p);
  } else if (q->kind == REQ_WAIT || q->kind == REQ_OUTPUT) {
    result = waited(vm, p, q->kind);
  } else {
    result = agc_stream_written(vm, p->write_status);
  }
  drop_request(q);
  return result;
}

/* The kinds whose timeout closes the child, as `request_expired` does at N = 1: a read, a send, and a spawn whose
   task gave it up. */
static bool stops_child(req_kind kind) {
  return kind == REQ_LINE || kind == REQ_BYTES || kind == REQ_AVAILABLE || kind == REQ_SEND || kind == REQ_SPAWN;
}

/* What a deadline does to a posted request, on the I/O thread: the kind's `pause`, before EXPIRED is published, or
   the step that `expired` posts when the task saw the timeout first. The request leaves its slot. A read or a send
   closes the child even when it was finished: its task got the timeout, so the line or the write status it carries
   is lost, and the child must then look closed, as at N = 1. */
static void stop_request(void *data) {
  request *q = data;
  if (!q->posted || q->stopped || !q->counted) return;
  q->stopped = true;
  unlink_request(q);
  if (q->kind == REQ_CLOSE && !q->finished)
    trace_alive(q->p);
  else if (stops_child(q->kind))
    shut(q->p);
}

/* A posted request is stopped on the I/O thread: by the timer's `pause`, or by the step posted here when the task
   gave the wait up for another reason (it then runs before the job's drop, which is posted after this half). */
static agc_value request_expired(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  request *q = data;
  if (q->posted) {
    req_kind kind = q->kind;
    agc_loop_call(agc_io_loop(vm), stop_request, q);
    return kind == REQ_CLOSE ? agc_void() : agc_stream_timed_out();
  }
  unlink_request(q);
  if (q->kind == REQ_CLOSE) {
    trace_alive(q->p);
    return agc_void();
  }
  if (q->kind != REQ_WAIT && q->kind != REQ_OUTPUT) shut(q->p);
  return agc_stream_timed_out();
}

/* The cancel half runs on the I/O thread when the job loses its task (a detach, or the deadline after it). */
static bool request_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  request *q = data;
  q->detached = true;
  return deadline && q->kind != REQ_SEND;
}

static const agc_io_kind process_io = {NULL,           request_done, request_expired, drop_request, true, "process",
                                       request_cancel, true,         stop_request};

/* Parks the task on the request; BEGIN, its START step, runs on the I/O thread (at once at N = 1). */
static void start_request(agc_vm *vm, request *q, agc_value context, int64_t timeout, agc_more_fn begin) {
  (void)agc_io_start_then(vm, &process_io, q, context, timeout, begin);
}

static void wrote(uv_write_t *w, int status) {
  proc *p = OWNER(w, write_req);
  free(p->write_data);
  p->write_data = NULL;
  p->write_status = status;
  if (p->writer) ready(p->writer);
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
  if (vm->rt->process_guard && vm->rt->process_guard->native) close_children(vm->rt->process_guard->native);
}

#ifndef _WIN32
static bool keep_private(int fd, void *data) {
  (void)data;
  int flags = fd > 2 ? fcntl(fd, F_GETFD) : -1;
  if (flags >= 0 && !(flags & FD_CLOEXEC)) fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
  return false;
}

#endif

static guard *guard_of(agc_vm *vm) {
  if (vm->rt->process_guard) return vm->rt->process_guard->native;
  agc_resource *r = agc_register(vm, NULL, release_guard);
  guard *g = calloc(1, sizeof(guard));
  if (!g) agc_out_of_memory();
  g->trace = vm->rt->trace;
  g->io = agc_io_loop(vm);
#ifndef _WIN32
  agc_each_fd(keep_private, NULL);
#endif
  r->native = g;
  vm->rt->process_guard = r;
  return g;
}

static void alloc_err(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  (void)suggested;
  proc *p = OWNER(h, err);
  *buf = uv_buf_init((char *)p->err_buf, sizeof p->err_buf);
}

static void err_over(proc *p, ssize_t n) {
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "eof pid=%d pipe=stderr error=%d", (int)p->process.pid,
            n == UV_EOF ? 0 : agc_net_errno((int)n));
  uv_read_stop((uv_stream_t *)&p->err);
  p->err_done = true;
  notify_waits(p);
}

/* A chunk of a plain child's stderr goes to the VM's stderr through its buffer, never by a write that waits on the
   descriptor (§14.1). When the stream holds too much, the read stops, so the child waits on its own pipe. */
static void forward_err(uv_stream_t *s, ssize_t n, const uv_buf_t *buf) {
  proc *p = OWNER(s, err);
  if (n < 0) {
    err_over(p, n);
    return;
  }
  if (n == 0) return;
  bool more = agc_output_forward(p->forward, (const uint8_t *)buf->base, (size_t)n, &p->forward_wait);
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "stderr pid=%d bytes=%zd", (int)p->process.pid, n);
  if (more) return;
  /* resume_err runs on this thread, after this callback at the earliest, so the stop and the count come first even
     when another scheduler has drained the queue already. */
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "stderr_pause pid=%d", (int)p->process.pid);
  uv_read_stop(s);
  p->users++;
}

/* The VM's stderr has room again (or failed): the paused read goes on, unless the child was closed meanwhile. */
static void resume_err(void *data) {
  proc *p = data;
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "stderr_resume pid=%d", (int)p->process.pid);
  if (!p->err_done && !uv_is_closing((uv_handle_t *)&p->err)) {
    int rc = uv_read_start((uv_stream_t *)&p->err, alloc_err, forward_err);
    if (rc) err_over(p, rc);
  }
  p->users--;
  settle(p);
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
  bool done = q && read_ready(p, q->kind, q->count);
  if (n < 0 || !q || done) stop_reading(p);
  if (done) reader_ready(p, q);
}

static void start_reading(proc *p) {
  if (p->captured || p->reading || p->out_buf.eof || p->out_buf.error) return;
  int rc = uv_read_start((uv_stream_t *)&p->out, alloc_out, read_out);
  if (rc)
    p->out_buf.error = agc_net_errno(rc);
  else
    p->reading = true;
}

/* Near the limit a chunk goes to the scratch buffer and only what fits is
   copied, so a kept buffer never grows past 1 MiB of capacity. */
static void alloc_kept(proc *p, agc_inbuf *b, bool cut, uv_buf_t *buf) {
  size_t size = sizeof p->err_buf;
  bool near_limit = agc_inbuf_pending(b) > LIMIT - size;
  uint8_t *room = cut || near_limit ? p->err_buf : agc_inbuf_room(b, size);
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
  if (p->reader) ready(p->reader);
  if (p->channel) agc_duplex_overflow(p->channel, over_text);
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
            n == UV_EOF ? 0 : agc_net_errno((int)n));
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
  request *q = p->reader;
  if (q && read_ready(p, q->kind, q->count)) reader_ready(p, q);
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
  agc_fs_info info;
  return agc_fs_stat(path, &info, true) == 0 && !AGC_FS_ISDIR(info.mode);
}

static char *candidate(agc_vm *vm, const char *dir, size_t dir_len, const agc_string *name) {
  size_t len = agc_size_add(agc_size_add(dir_len, 1), name->bytes);
  agc_string *joined = agc_new_string(len, 0);
  memcpy(joined->data, dir, dir_len);
  joined->data[dir_len] = '/';
  memcpy(joined->data + dir_len + 1, name->data, name->bytes);
  return agc_host_path(vm, joined);
}

/* Takes the malloc'd path; returns it, or a copy with a suffix added, when a
   file that may run is there (process_os.h), else NULL. */
static char *executable(char *path) {
  if (agc_proc_suffix_ok(path)) {
    if (runnable(path)) return path;
    free(path);
    return NULL;
  }
  size_t size = strlen(path);
  for (const char *const *suffix = agc_proc_suffixes(); *suffix; suffix++) {
    size_t extra = strlen(*suffix);
    char *with_suffix = malloc(agc_size_add(agc_size_add(size, extra), 1));
    if (!with_suffix) agc_out_of_memory();
    memcpy(with_suffix, path, size);
    memcpy(with_suffix + size, *suffix, extra + 1);
    if (runnable(with_suffix)) {
      free(path);
      return with_suffix;
    }
    free(with_suffix);
  }
  free(path);
  return NULL;
}

static char *resolve(agc_vm *vm, const agc_string *command) {
  if (!agc_proc_name_ok(command->data, command->bytes)) return NULL;
  if (agc_proc_is_path(command->data, command->bytes)) return executable(agc_host_path(vm, command));
  char *search = agc_system_env("PATH");
  char *found = NULL;
  const char *at = search, *dir;
  size_t len;
  while (!found && agc_proc_next_dir(&at, &dir, &len)) found = executable(candidate(vm, dir, len, command));
  free(search);
  return found;
}

static char **child_args(agc_vm *vm, char *path, const agc_list *list) {
  char **argv = calloc(agc_size_add(agc_list_len(list), 2), sizeof(char *));
  if (!argv) agc_out_of_memory();
  argv[0] = path;
  agc_list_cursor cursor;
  agc_value item;
  agc_list_cursor_begin(&cursor, list, 0);
  for (size_t k = 1; agc_list_cursor_next(&cursor, &item); k++) argv[k] = agc_cstr(agc_as_string(vm, item));
  return argv;
}

static bool env_prefix(const char *entry, const char *prefix) {
#ifdef _WIN32
  return _strnicmp(entry, prefix, strlen(prefix)) == 0;
#else
  return strncmp(entry, prefix, strlen(prefix)) == 0;
#endif
}

static bool own_env(bool drop_uring, const char *entry) {
  bool uring = drop_uring && env_prefix(entry, URING_ENV);
  return uring || env_prefix(entry, CHANNEL_PREFIX);
}

/* One VM owns the metrics port and file (docs/future/28-vm-metrics.md 28.5): a child VM, or a runner the BDD
   driver starts, would fight for them. Each name is matched with its "=", so the first never catches the second. */
static bool metrics_env(const char *entry) {
  return env_prefix(entry, METRICS_ENV) ||
         env_prefix(entry, METRICS_FILE_ENV);
}

/* The environment of a child; `channel` is the value of AGENTICA_CHANNEL when the child gets a channel. */
static char **child_env(bool drop_uring, const char *channel) {
  uv_env_item_t *host = NULL;
  int count = 0;
  if (uv_os_environ(&host, &count) != 0) return NULL;
  char **env = calloc(agc_size_add((size_t)count, 2), sizeof(char *));
  if (!env) { uv_os_free_environ(host, count); agc_out_of_memory(); }
  size_t kept = 0;
  for (int k = 0; k < count; k++) {
    size_t name = strlen(host[k].name), value = strlen(host[k].value);
    char *entry = malloc(agc_size_add(agc_size_add(name, value), 2));
    if (!entry) agc_out_of_memory();
    memcpy(entry, host[k].name, name);
    entry[name] = '=';
    memcpy(entry + name + 1, host[k].value, value + 1);
    if (own_env(drop_uring, entry) || metrics_env(entry)) free(entry);
    else env[kept++] = entry;
  }
  uv_os_free_environ(host, count);
  if (channel) {
    size_t size = strlen(CHANNEL_PREFIX) + strlen(channel) + 1;
    env[kept] = malloc(size);
    if (!env[kept]) agc_out_of_memory();
    snprintf(env[kept], size, "%s%s", CHANNEL_PREFIX, channel);
  }
  return env;
}

static void close_fd(int *fd) {
  if (*fd >= 0) agc_fs_close(*fd);
  *fd = -1;
}

static int open_pipe(uv_pipe_t *pipe, int *fd, int rc) {
  if (rc) return rc;
  rc = uv_pipe_open(pipe, *fd);
  if (!rc) *fd = -1;
  return rc;
}

static int start_child(guard *g, proc *p, const launch *l) {
  uv_loop_t *loop = agc_loop_uv(g->io);
  bool channel = l->channel;
  int fds[6] = {-1, -1, -1, -1, -1, -1};
  agc_chan_ends link = {-1, -1, {-1, -1}, 0};
  int rc = 0;
  for (size_t k = 0; !rc && k < 3; k++) {
    int read_flags = 0, write_flags = 0;
#ifdef _WIN32
    read_flags = k == 0 ? 0 : UV_NONBLOCK_PIPE;
    write_flags = k == 0 ? UV_NONBLOCK_PIPE : 0;
#endif
    rc = uv_pipe(fds + 2 * k, read_flags, write_flags);
  }
  if (!rc && channel) rc = agc_chan_pair(&link);
  if (!rc) {
    uv_stdio_container_t stdio[STDIO_SLOTS];
    for (size_t k = 0; k < 3; k++) {
      stdio[k].flags = UV_INHERIT_FD;
      stdio[k].data.fd = fds[2 * k + (k == 0 ? 0 : 1)];
    }
    for (int k = 0; k < link.child_count; k++) {
      stdio[3 + k].flags = UV_INHERIT_FD;
      stdio[3 + k].data.fd = link.child[k];
    }
    uv_process_options_t options;
    memset(&options, 0, sizeof options);
    options.exit_cb = exited;
    options.file = l->argv[0];
    options.args = l->argv;
    options.env = l->env;
    options.cwd = l->cwd;
    options.stdio_count = 3 + link.child_count;
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
  for (int k = 0; k < link.child_count; k++) close_fd(&link.child[k]);
  if (!rc) {
    uv_pipe_init(loop, &p->in, 0);
    uv_pipe_init(loop, &p->out, 0);
    uv_pipe_init(loop, &p->err, 0);
    p->handles = 4;
    if (p->captured) {
      uv_timer_init(loop, &p->grace);
      p->handles++;
    }
    rc = open_pipe(&p->err, &fds[4], open_pipe(&p->out, &fds[2], open_pipe(&p->in, &fds[1], 0)));
    if (!rc && channel) {
      p->channel = agc_duplex_new(p->io, link.read, link.write);
      link.read = link.write = -1;
      if (!p->channel) rc = UV_ENOMEM;
    }
    if (!rc) rc = p->captured ? start_kept(p) : uv_read_start((uv_stream_t *)&p->err, alloc_err, forward_err);
  }
  close_fd(&fds[1]);
  close_fd(&fds[2]);
  close_fd(&fds[4]);
  close_fd(&link.read);
  close_fd(&link.write);
  if (rc && p->running) shut(p);
  return rc;
}

static bool no_nul(const agc_string *s) { return !memchr(s->data, 0, s->bytes); }

static char *child_dir(agc_vm *vm, const agc_string *dir, bool *found) {
  *found = true;
  if (!dir || (dir->bytes == 1 && dir->data[0] == '.')) return NULL;
  char *path = agc_host_path(vm, dir);
  agc_fs_info info;
  *found = agc_fs_stat(path, &info, true) == 0 && AGC_FS_ISDIR(info.mode);
  return path;
}

/* The spawn on the I/O thread (in the builtin at N = 1). */
static int launch_child(proc *p, const launch *l) {
  p->begun = true;
  int rc = start_child(l->g, p, l);
  if (rc)
    AGC_TRACE(&p->trace, AGC_TRACE_PROC, "spawn_failed path=%s rc=%d", l->argv[0], rc);
  else
    AGC_TRACE(&p->trace, AGC_TRACE_PROC, "spawn pid=%d path=%s args=%zu captured=%d channel=%d", (int)p->process.pid,
              l->argv[0], l->args, p->captured ? 1 : 0, l->channel ? 1 : 0);
  return rc;
}

static void own_child(agc_vm *vm, agc_process *pr, proc *p) {
  p->users = 1;
  pr->state = agc_register(vm, p, release_proc);
  pr->state->keep_detached = true;
  agc_own(vm, pr->state, close_child);
}

/* A posted spawn's START. A child whose resource was released before this ran (the end of the run) is not started,
   nor one whose START comes after the end of the run reaped the children (close_children drives the loop, which runs
   what is still in the inbox): nobody would kill it. A failed spawn leaves the child closed, so the close that its
   done half posts does nothing more. */
static bool begin_spawn(void *data, agc_io_job *job) {
  request *q = data;
  proc *p = q->p;
  link_request(q, job);
  q->rc = p->closed || q->start->g->reaping ? UV_ECANCELED : launch_child(p, q->start);
  if (q->rc) p->closed = true;
  free_launch(q->start);
  q->start = NULL;
  (void)finish(q);
  return true;
}

/* dir is NULL for Process.spawn; "." keeps the VM's directory. The command
   resolves before the child changes directory (§10.4). */
static agc_value spawn_child(agc_vm *vm, const agc_value *args, const agc_string *dir, int64_t timeout, bool channel) {
  if (vm->rt->deny_run) return agc_error_value("denied: --deny-run turns off starting programs");
  const agc_string *command = agc_as_string(vm, args[0]);
  const agc_list *list = agc_as_list(vm, args[1]);
  bool valid = command->bytes > 0 && no_nul(command);
  agc_list_cursor cursor;
  agc_value item;
  agc_list_cursor_begin(&cursor, list, 0);
  while (agc_list_cursor_next(&cursor, &item)) valid = valid && no_nul(agc_as_string(vm, item));
  if (!valid) return agc_error_value("process: command must be nonempty and arguments cannot contain NUL");
  if (dir && (dir->bytes == 0 || !no_nul(dir)))
    return agc_error_value("process: dir must be nonempty and cannot contain NUL");
  if (timeout <= 0) return agc_stream_bad_timeout();
  agc_process *pr = agc_alloc(sizeof(agc_process));
  pr->reader = agc_new_lock(vm);
  pr->writer = agc_new_lock(vm);
  if (channel) pr->channel = (agc_lines){agc_new_lock(vm), agc_new_lock(vm)};
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
  launch *l = calloc(1, sizeof(launch));
  if (!l) agc_out_of_memory();
  l->g = g;
  l->argv = child_args(vm, path, list);
  l->env = child_env(vm->rt->drop_uring_env, channel ? agc_chan_value() : NULL);
  l->cwd = cwd;
  l->args = agc_list_len(list);
  l->channel = channel;
  if (!l->env) {
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_PROC, "spawn_failed path=%s rc=%d", path, UV_ENOMEM);
    free_launch(l);
    return agc_system_error(vm, "process: cannot run the executable", agc_net_errno(UV_ENOMEM));
  }
  proc *p = calloc(1, sizeof(proc));
  if (!p) agc_out_of_memory();
  p->trace = vm->rt->trace;
  p->io = agc_io_loop(vm);
  /* rt is GC memory that the malloc'd proc does not keep alive, but it lives for the whole run, past every child. */
  p->forward = &vm->rt->err;
  p->forward_wait = (agc_forward_wait){NULL, p->io, resume_err, p};
  p->captured = dir != NULL;
  if (!agc_io_here(vm)) {
    /* The resource comes first, so the owner's end closes the child whatever happens to the spawn. */
    request *q = new_request(vm, p, REQ_SPAWN);
    q->start = l;
    own_child(vm, pr, p);
    start_request(vm, q, agc_process_value(pr), -1, begin_spawn);
    return agc_void();
  }
  int rc = launch_child(p, l);
  free_launch(l);
  if (rc) {
    settle(p);
    return agc_system_error(vm, "process: cannot run the executable", agc_net_errno(rc));
  }
  own_child(vm, pr, p);
  return agc_result_value(true, agc_process_value(pr));
}

static agc_value builtin_spawn(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return spawn_child(vm, args, NULL, agc_as_int(vm, args[2]), false);
}

static agc_value builtin_spawn_captured(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return spawn_child(vm, args, agc_as_string(vm, args[2]), agc_as_int(vm, args[3]), false);
}

static agc_value builtin_spawn_channel(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return spawn_child(vm, args, agc_as_string(vm, args[2]), agc_as_int(vm, args[3]), true);
}

/* The child of a process value that is not closed. With several schedulers the I/O thread owns `closed`, so only the
   resource is looked at here and the START step of the request finds a closed child. */
static proc *live(agc_vm *vm, const agc_process *pr) {
  proc *p = pr->state->native;
  return p && (!agc_io_here(vm) || !p->closed) ? p : NULL;
}

static bool begin_read(void *data, agc_io_job *job) {
  request *q = data;
  proc *p = q->p;
  link_request(q, job);
  if (!read_ready(p, q->kind, q->count)) start_reading(p);
  if (read_ready(p, q->kind, q->count)) reader_ready(p, q);
  return true;
}

/* Takes LOCK (the reader's or the writer's) under the call's timeout; the open process, or NULL with *result set. */
static proc *take_lock(agc_vm *vm, agc_process *pr, agc_resource *lock, int64_t *timeout, agc_value *result) {
  if (!agc_stream_lock(vm, lock, timeout, result)) return NULL;
  proc *p = live(vm, pr);
  if (!p) *result = agc_error_value(closed_text);
  return p;
}

static agc_value read_op(agc_vm *vm, agc_value handle, req_kind kind, size_t count, int64_t timeout) {
  agc_process *pr = agc_as_process(vm, handle);
  agc_value result;
  proc *p = take_lock(vm, pr, pr->reader, &timeout, &result);
  if (!p) return result;
  /* At N = 1 the buffer is this thread's: what is buffered is taken without a park. */
  if (agc_io_here(vm) && read_ready(p, kind, count)) return take(vm, p, kind, count);
  request *q = new_request(vm, p, kind);
  q->count = count;
  start_request(vm, q, agc_handle_value(pr->reader), timeout, begin_read);
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

/* A posted send carries a copy of its bytes and starts the write here; at N = 1 the builtin started it and the request
   only waits for its end. */
static bool begin_send(void *data, agc_io_job *job) {
  request *q = data;
  proc *p = q->p;
  link_request(q, job);
  if (!q->posted) return true;
  if (!p->closed && p->in_closed) q->stdin_closed = true;
  if (p->closed || q->stdin_closed) {
    (void)finish(q);
    return true;
  }
  p->write_status = 0;
  int rc = agc_stream_write((uv_stream_t *)&p->in, &p->write_req, &p->write_data, q->data, q->len, wrote);
  /* agc_stream_write keeps its own copy of what it could not write at once. */
  free(q->data);
  q->data = NULL;
  if (rc < 0) p->write_status = rc;
  if (rc != 1) (void)finish(q);
  return true;
}

static agc_value write_op(agc_vm *vm, const agc_value *args, const uint8_t *data, size_t len) {
  int64_t timeout = agc_as_int(vm, args[2]);
  agc_process *pr = agc_as_process(vm, args[0]);
  agc_value result;
  proc *p = take_lock(vm, pr, pr->writer, &timeout, &result);
  if (!p) return result;
  if (agc_io_here(vm)) {
    if (p->in_closed) return agc_error_value("process: stdin is closed");
    p->write_status = 0;
    int rc = agc_stream_write((uv_stream_t *)&p->in, &p->write_req, &p->write_data, data, len, wrote);
    if (rc <= 0) return agc_stream_written(vm, rc);
  }
  request *q = new_request(vm, p, REQ_SEND);
  q->count = (size_t)agc_value_units(args[1]);
  if (q->posted) copy_bytes(&q->data, &q->len, data, len);
  start_request(vm, q, agc_handle_value(pr->writer), timeout, begin_send);
  return agc_void();
}

static agc_value builtin_send(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_string *text = agc_as_string(vm, args[1]);
  if (text->bytes > LIMIT) return agc_error_value("process: send exceeds 1048576 bytes");
  return write_op(vm, args, (const uint8_t *)text->data, text->bytes);
}

static agc_value builtin_send_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *values = agc_as_list(vm, args[1]);
  uint8_t *data = agc_byte_list(vm, values, LIMIT);
  if (!data) return agc_error_value("process: bytes must be 0..255 and at most 1048576 per call");
  return write_op(vm, args, data, agc_list_len(values));
}

static void close_stdin_now(proc *p) {
  if (!p->in_closed) AGC_TRACE(&p->trace, AGC_TRACE_PROC, "eof pid=%d pipe=stdin", (int)p->process.pid);
  p->in_closed = true;
  close_handle((uv_handle_t *)&p->in, closed_in);
}

static bool begin_close_stdin(void *data, agc_io_job *job) {
  request *q = data;
  link_request(q, job);
  if (!q->p->closed) close_stdin_now(q->p);
  (void)finish(q);
  return true;
}

static agc_value builtin_close_stdin(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t timeout = agc_as_int(vm, args[1]);
  agc_process *pr = agc_as_process(vm, args[0]);
  agc_value result;
  proc *p = take_lock(vm, pr, pr->writer, &timeout, &result);
  if (p && agc_io_here(vm)) {
    close_stdin_now(p);
    result = ok_void();
  } else if (p) {
    start_request(vm, new_request(vm, p, REQ_STDIN), agc_handle_value(pr->writer), timeout, begin_close_stdin);
    result = agc_void();
  }
  return result;
}

static bool begin_wait(void *data, agc_io_job *job) {
  request *q = data;
  link_request(q, job);
  if (waits_over(q->p, q->kind)) ready(q);
  return true;
}

static agc_value await_child(agc_vm *vm, const agc_value *args, req_kind kind) {
  agc_process *pr = agc_as_process(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  if (timeout <= 0) return agc_stream_bad_timeout();
  proc *p = live(vm, pr);
  if (!p) return agc_error_value(closed_text);
  /* `captured` is fixed before the child is shared, so any thread may read it. */
  if (kind == REQ_OUTPUT && !p->captured) return agc_error_value("process: output is not captured");
  if (agc_io_here(vm) && waits_over(p, kind)) return waited(vm, p, kind);
  start_request(vm, new_request(vm, p, kind), agc_void(), timeout, begin_wait);
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

/* A plain child that got SIGKILL is awaited for up to REAP_MS, so Process.close returns after the exit. */
static bool reaped_on_close(const proc *p) { return !p->captured && p->running && !p->stop_failed; }

/* A posted close's START: the stop, the wait for a plain child's exit, and the resource's count, which the builtin
   gave up when it unregistered the child. The done half fails when the child could not be stopped. */
static bool begin_close(void *data, agc_io_job *job) {
  request *q = data;
  proc *p = q->p;
  q->rc = shut(p);
  link_request(q, job);
  q->holds_resource = false;
  p->users--;
  if (!reaped_on_close(p)) (void)finish(q);
  return true;
}

static agc_value builtin_close(agc_vm *vm, agc_value *args, uint32_t span) {
  proc *p = unregister_child(vm, agc_as_process(vm, args[0])->state);
  if (!p) return agc_void();
  if (!agc_io_here(vm)) {
    request *q = new_request(vm, p, REQ_CLOSE);
    q->span = span;
    q->holds_resource = true;
    start_request(vm, q, agc_void(), REAP_MS, begin_close);
    return agc_void();
  }
  int err = shut(p);
  if (reaped_on_close(p)) start_request(vm, new_request(vm, p, REQ_CLOSE), agc_void(), REAP_MS, begin_link);
  p->users--;
  settle(p);
  if (err) agc_fail(vm, "RUNTIME-PROCESS-CLOSE", "process: the child cannot be stopped", span);
  return agc_void();
}

static agc_duplex *channel_of(agc_vm *vm, agc_value handle, agc_process **pr, agc_value *result) {
  *pr = agc_as_process(vm, handle);
  const proc *p = live(vm, *pr);
  if (!p) *result = agc_error_value(closed_text);
  else if (!p->channel) *result = agc_error_value("process: the child has no channel");
  return p ? p->channel : NULL;
}

static agc_value builtin_channel_read_line(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_process *pr;
  agc_value result;
  agc_duplex *d = channel_of(vm, args[0], &pr, &result);
  return d ? agc_duplex_read_line(vm, d, pr->channel.reader, agc_as_int(vm, args[1])) : result;
}

static agc_value builtin_channel_send(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_process *pr;
  agc_value result;
  agc_duplex *d = channel_of(vm, args[0], &pr, &result);
  return d ? agc_duplex_send(vm, d, pr->channel.writer, args[1], agc_as_int(vm, args[2])) : result;
}

static agc_value builtin_channel_close(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_process *pr;
  agc_value result;
  agc_duplex *d = channel_of(vm, args[0], &pr, &result);
  return d ? agc_duplex_close_write(vm, d, pr->channel.writer, agc_as_int(vm, args[1])) : result;
}

/* Reads what the stdout pipe holds now, so Process.read_available sees output that the child wrote before the call
   even when the loop has not run since. Where libuv's own reads own the pipe nothing is drained (process_os.h). */
static void drain_out(proc *p) {
  uv_os_fd_t fd;
  size_t total = 0;
  if (p->out_buf.eof || p->out_buf.error || uv_fileno((uv_handle_t *)&p->out, &fd) != 0) return;
  while (total < DRAIN_LIMIT) {
    uv_buf_t buf;
    alloc_kept_out((uv_handle_t *)&p->out, 0, &buf);
    int64_t n = buf.base ? agc_proc_read_now((intptr_t)fd, (uint8_t *)buf.base, buf.len) : UV_ENOBUFS;
    if (n == AGC_PROC_NOTHING) return;
    if (n == 0) n = UV_EOF;
    else if (n < 0 && buf.base) n = uv_translate_sys_error((int)-n);
    read_kept_out((uv_stream_t *)&p->out, (ssize_t)n, &buf);
    /* A read can close the child (a line read over the limit), and its descriptor with it. */
    if (n < 0 || p->closed) return;
    total += (size_t)n;
  }
}

/* read_available as a request: posted (the drain, then the text in one step on the I/O thread), or at N = 1 where
   nothing can be drained (the loop runs once first, so the read callbacks have kept what has come). The drain comes
   before the request takes the reader's slot, so it cannot end the request half-way. */
static bool begin_available(void *data, agc_io_job *job) {
  request *q = data;
  proc *p = q->p;
  if (q->posted && !p->closed && agc_proc_drains()) drain_out(p);
  link_request(q, job);
  ready(q);
  return true;
}

static agc_value builtin_read_available(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_process *pr = agc_as_process(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  agc_value result;
  proc *p = take_lock(vm, pr, pr->reader, &timeout, &result);
  if (!p) return result;
  if (!p->captured) return agc_error_value("process: output is not captured");
  if (!agc_io_here(vm) || !agc_proc_drains()) {
    start_request(vm, new_request(vm, p, REQ_AVAILABLE), agc_handle_value(pr->reader), timeout, begin_available);
    return agc_void();
  }
  drain_out(p);
  return available(vm, p);
}

const agc_builtin agc_process_builtins[] = {
  {"Process.spawn", 3, builtin_spawn, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Process.send", 3, builtin_send, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Process.send_bytes", 3, builtin_send_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Process.read_line", 2, builtin_read_line, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Process.read_bytes", 3, builtin_read_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Process.close_stdin", 2, builtin_close_stdin, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"Process.wait", 2, builtin_wait, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"Process.close", 1, builtin_close, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"Process.spawn_captured", 4, builtin_spawn_captured, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Process.output", 2, builtin_output, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"Process.spawn_channel", 4, builtin_spawn_channel, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Process.channel_read_line", 2, builtin_channel_read_line, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Process.channel_send", 3, builtin_channel_send, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Process.channel_close", 2, builtin_channel_close, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"Process.read_available", 2, builtin_read_available, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
};

const size_t agc_process_builtin_count = sizeof agc_process_builtins / sizeof agc_process_builtins[0];
#else
const agc_builtin agc_process_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE, false, false}};

const size_t agc_process_builtin_count = 0;

void agc_processes_stop(agc_vm *vm) { (void)vm; }
#endif
