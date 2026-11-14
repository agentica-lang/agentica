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
/* glibc declares syscall, for the pidfd calls, only for _GNU_SOURCE. */
#ifdef __linux__
#define _GNU_SOURCE
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
#include <limits.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif
#ifdef __linux__
#include <sys/syscall.h>
#endif
#include <uv.h>

#define LIMIT ((size_t)1048576)
#define ERR_CHUNK 4096
#define REAP_MS 1000
#define GRACE_MS 1000
#define GROUP_POLL_MS 20
#define URING_ENV "UV_USE_IO_URING="
#define CHANNEL_PREFIX AGC_CHANNEL_ENV "="
#define METRICS_ENV "AGENTICA_VM_METRICS="
#define METRICS_FILE_ENV "AGENTICA_VM_METRICS_FILE="
#define DRAIN_LIMIT ((size_t)2097152)
#define STDIO_SLOTS 5
#define OWNER(ptr, field) ((proc *)(void *)((char *)(ptr) - offsetof(proc, field)))

typedef enum {
  REQ_LINE, REQ_BYTES, REQ_SEND, REQ_WAIT, REQ_OUTPUT, REQ_CLOSE, REQ_AVAILABLE, REQ_SPAWN, REQ_STDIN, REQ_SIGNAL,
  REQ_POLL
} req_kind;
typedef enum { STOP_NONE, STOP_TERM, STOP_KILLED } stop_state;

typedef struct proc proc;
typedef struct request request;
typedef struct guard guard;
typedef struct launch launch;

/* Process.Options as compiler/catalog/builtins_data.agc lays it out, read by position; tests/test_process.py
   (test_options_layout) fails when the two orders differ. */
enum { OPTION_TIMEOUT_MS, OPTION_CHDIR, OPTION_ENV, OPTION_OUT, OPTION_ERR, OPTION_PGROUP, OPTION_FIELDS };

/* One pair of the program's `env` map, taken out of the map by env_problem. Both strings are GC memory, and so is the
   array that holds the pairs, which keeps them alive. */
typedef struct {
  const agc_string *name;
  const agc_string *value;
} env_pair;

/* What a spawn hands to the I/O thread: malloc'd strings, no VM values. files[0] and files[1] are the open files of
   `out` and `err` (-1: the pipe), owned by the launch; both are the same descriptor when they name one file. */
struct launch {
  guard *g;
  CC_OWNS char **argv, **env;
  CC_OWNS char *cwd;
  size_t args;
  int files[2];
  bool channel, group, inherit;
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
  /* SIGNAL: the OS number and whether it goes to the child's group. */
  bool to_group;
  int sig;
  int rc;
  int64_t status;
  uint32_t span;
  agc_inbuf_cut cut;
  /* SEND: the bytes to write. OUTPUT: copies of the kept stdout and stderr. */
  uint8_t *data, *err_data;
  size_t len, err_len;
  launch *start;
};

/* first: the children that run. graced: the group children (pgroup) whose stop is in its grace, each with one count
   in `users`, so the end of the run can still kill a group whose leader was reaped meanwhile. */
struct guard {
  agc_trace trace;
  agc_loop *io;
  proc *first, *graced;
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
     stopped (paused) and the stream holds forward_wait, with one count in `users`, until it resumes the read. A stream
     left on its blocking FILE gets each chunk from a libuv pool thread instead (err_work, err_len bytes of err_buf),
     with the read paused the same way until the write is over; file_wait keeps the child in line while another
     child's chunk is being written (agc_output_file_turn). */
  agc_output *forward;
  agc_forward_wait forward_wait, file_wait;
  uv_work_t err_work;
  size_t err_len;
  agc_duplex *channel;
  guard *g, *grace_g;
  proc *run_prev, *run_next, *grace_prev, *grace_next;
  size_t users, handles;
  /* begun: the spawn has run, so the handles below are in some state; a child whose spawn never ran has none. */
  bool begun, linked, running, exited, err_done, in_closed, closed, reading;
  /* group: the child leads its own process group (Process.spawn* with pgroup, where agc_proc_groups), and every
     signal of a stop goes to the group. group_gone: the end-of-run wait found the group empty (ESRCH), so it is not
     probed or signalled again: its id may since name another group. */
  bool captured, out_cut, err_cut, stop_failed, group, group_gone;
  /* inherit: Process.spawn_group, whose child has the VM's stdin, stdout and stderr, so its pipes are never used. */
  bool inherit;
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

static void close_handle(uv_handle_t *h, uv_close_cb done) {
  if (!uv_is_closing(h)) uv_close(h, done);
}

static void guard_settle(guard *g) {
  if (g->released && !g->running && !g->graced) free(g);
}

static void hold_grace(guard *g, proc *p) {
  p->grace_g = g;
  p->grace_prev = NULL;
  p->grace_next = g->graced;
  if (g->graced) g->graced->grace_prev = p;
  g->graced = p;
  p->users++;
}

/* Takes P off the graced list and gives back its count. The caller settles P, and the guard returned (NULL when P was
   not on the list). */
static guard *drop_grace(proc *p) {
  guard *g = p->grace_g;
  if (!g) return NULL;
  p->grace_g = NULL;
  if (p->grace_prev)
    p->grace_prev->grace_next = p->grace_next;
  else
    g->graced = p->grace_next;
  if (p->grace_next) p->grace_next->grace_prev = p->grace_prev;
  p->grace_prev = p->grace_next = NULL;
  p->users--;
  return g;
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

static void closed_grace(uv_handle_t *h) {
  proc *p = OWNER(h, grace);
  guard *g = drop_grace(p);
  if (g) guard_settle(g);
  handle_gone(p);
}

static bool line_kind(req_kind kind) { return kind == REQ_LINE || kind == REQ_POLL; }

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
    case REQ_POLL:
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
  bool over = line_kind(q->kind) && reads && q->cut.status == AGC_CUT_OVER;
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
  /* The group's id is the child's pid: libuv's spawn returns after the child's setsid, so the group exists while the
     child runs. A group that is gone (ESRCH) leaves the child alone to signal, and only while it is unreaped: a reaped
     pid may already be another process's. A group the end-of-run wait found gone (group_gone) is not signalled. */
  int rc = p->group && !p->group_gone && p->process.pid > 0 ? uv_kill(-p->process.pid, sig) : UV_ESRCH;
  if (rc == UV_ESRCH && p->running) rc = uv_process_kill(&p->process, sig);
  if (rc == UV_ESRCH) rc = 0;
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "%s pid=%d group=%d rc=%d", sig == SIGKILL ? "kill" : "term",
            (int)p->process.pid, p->group ? 1 : 0, rc);
  p->stop = sig == SIGTERM && !rc ? STOP_TERM : STOP_KILLED;
  p->stop_failed = rc != 0;
  return rc;
}

/* True while a group child's grace is still to end in a SIGKILL of the group: its leader may exit on the SIGTERM
   while a descendant ignores it or takes longer. */
static bool group_in_grace(const proc *p) { return p->group && p->stop == STOP_TERM; }

/* A captured child's pipes close at once, but its uv_process_t stays open
   until it exits, and its grace timer until it exits or got SIGKILL. The timer of a group child runs to its end even
   after the exit, so grace_over can kill the group. At the end of the run a group child that close_children holds
   (grace_g) keeps it too, timer or not: the wait after the SIGTERM needs it on `graced` until the SIGKILL. */
static void retire(proc *p) {
  if (!p->closed) return;
  bool timed = group_in_grace(p) && (uv_is_active((uv_handle_t *)&p->grace) || p->grace_g);
  if (p->captured && ((!p->running && !timed) || p->stop == STOP_KILLED))
    close_handle((uv_handle_t *)&p->grace, closed_grace);
  if (!p->running) close_handle((uv_handle_t *)&p->process, closed_process);
}

static void grace_over(uv_timer_t *t) {
  proc *p = OWNER(t, grace);
  /* A group gets its SIGKILL even when the leader was reaped during the grace: POSIX does not give the pid to a new
     process while a group with that id exists, so -pid still names this group, or nothing (ESRCH). The risk left is
     an empty group whose id a new group leader took within the grace. */
  if ((p->running || p->group) && p->stop == STOP_TERM) signal_child(p, SIGKILL);
  if (p->stop == STOP_TERM) p->stop = STOP_KILLED;
  retire(p);
  guard *g = drop_grace(p);
  if (g) guard_settle(g);
  settle(p);
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
      if (!err && p->group && p->linked) hold_grace(p->g, p);
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

/* True while a group in its grace still has a process. A leader reaped during the grace leaves `first`, not
   `graced`, and its group id stays its own while any member lives (grace_over). A group found empty (ESRCH) is
   marked gone and skipped from then on; any other failure (EPERM) counts as gone for this probe only. */
static bool groups_alive(const guard *g) {
  bool alive = false;
  for (proc *p = g->graced; p; p = p->grace_next) {
    if (!group_in_grace(p) || p->group_gone || p->process.pid <= 0) continue;
    int rc = uv_kill(-p->process.pid, 0);
    if (rc == UV_ESRCH) p->group_gone = true;
    if (rc == 0) alive = true;
  }
  return alive;
}

/* The grace of the end of the run: the loop runs until every captured child exited and every group in its grace
   is gone, or GRACE_MS passed. A group's end makes no event, so a short repeating timer wakes the loop to look. */
static void grace_wait(guard *g) {
  if (!exits_pending(g, true) && !groups_alive(g)) return;
  uv_loop_t *loop = agc_loop_uv(g->io);
  uv_timer_t bound, tick;
  uv_update_time(loop);
  uv_timer_init(loop, &bound);
  uv_timer_init(loop, &tick);
  uv_timer_start(&bound, bound_over, GRACE_MS, 0);
  uv_timer_start(&tick, bound_over, GROUP_POLL_MS, GROUP_POLL_MS);
  while (uv_is_active((uv_handle_t *)&bound) && (exits_pending(g, true) || groups_alive(g))) uv_run(loop, UV_RUN_ONCE);
  uv_close((uv_handle_t *)&bound, NULL);
  uv_close((uv_handle_t *)&tick, NULL);
  uv_run(loop, UV_RUN_NOWAIT);
}

/* Plain children get SIGKILL at once; captured ones SIGTERM, then SIGKILL
   when the grace wait is over, then one more wait for the exits. A group child in its grace (from here, or from a
   Process.close whose timer has not fired) is on `graced`: its group gets the SIGKILL even if its leader was reaped
   during the wait. */
static void close_children(guard *g) {
  if (g->reaping) return;
  g->reaping = true;
  for (proc *p = g->first; p; p = p->run_next) {
    if (p->running && p->captured && p->stop == STOP_NONE)
      signal_child(p, SIGTERM);
    else if (p->running && !p->captured && !p->closed)
      signal_child(p, SIGKILL);
    if (group_in_grace(p) && !p->grace_g) hold_grace(g, p);
  }
  grace_wait(g);
  for (proc *p = g->graced, *next = NULL; p; p = next) {
    next = p->grace_next;
    if (group_in_grace(p)) signal_child(p, SIGKILL);
    if (p->stop == STOP_TERM) p->stop = STOP_KILLED;
    retire(p);
    (void)drop_grace(p);
    settle(p);
  }
  for (proc *p = g->first, *next = NULL; p; p = next) {
    next = p->run_next;
    if (p->captured && p->running && p->stop == STOP_TERM) signal_child(p, SIGKILL);
    shut(p);
  }
  await_exits(g, false);
}

// cchecker: ignore CC-EFFECT-SHORT-BLOCKS: the end-of-run reap runs the loop for at most REAP_MS (await_exits)
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

/* POSTED when the START step will not run at once (several schedulers): the request then carries its result. Every
   request parks its task (start_request), so a callback of native code is refused before it exists. */
static request *new_request(agc_vm *vm, proc *p, req_kind kind) {
  agc_task_check_wait(vm);
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
  if (line_kind(q->kind) || q->kind == REQ_BYTES || q->kind == REQ_AVAILABLE) {
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

static void close_fd(int *fd) {
  if (*fd >= 0) agc_fs_close(*fd);
  *fd = -1;
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
  if (l->files[1] != l->files[0]) close_fd(&l->files[1]);
  close_fd(&l->files[0]);
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
  return p->closed || p->out_cut || p->err_cut || agc_inbuf_ready(&p->out_buf, line_kind(kind), count);
}

static agc_value take(agc_vm *vm, proc *p, req_kind kind, size_t count) {
  if (p->closed) return agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
  if (p->out_cut || p->err_cut) return agc_error(vm, AGC_KIND_PROCESS_TOO_LARGE, over_text);
  if (!line_kind(kind)) return agc_inbuf_bytes(vm, AGC_STREAM_PROCESS, &p->out_buf, count);
  bool over;
  agc_value line = agc_inbuf_line(vm, AGC_STREAM_PROCESS, &p->out_buf, "process: line exceeds 1048576 bytes",
                                  "process: end of input", &over);
  if (over) shut(p);
  return line;
}

static uint32_t output_struct(agc_vm *vm) {
  static const char *const fields[] = {"stdout", "stderr", "truncated"};
  return agc_builtin_struct(vm, "Process.Output", fields, 3);
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
  if (p->out_cut || p->err_cut) return agc_error(vm, AGC_KIND_PROCESS_TOO_LARGE, over_text);
  size_t n = available_bytes(&p->out_buf);
  agc_value result = available_text(vm, pending_data(&p->out_buf), n);
  agc_inbuf_take(&p->out_buf, n);
  return result;
}

/* A posted spawn's end. A failed one gives its resource back, as a close does. */
static agc_value spawned(agc_vm *vm, const request *q, agc_value context) {
  if (!q->rc) return agc_result_value(true, context);
  close_child(vm, agc_as_process(vm, context)->state, NULL);
  return agc_system_error(vm, AGC_FAMILY_PROCESS, "process: cannot run the executable", agc_net_errno(q->rc));
}

/* What send_signal found besides a libuv error (negative) or 0. */
#define SIGNAL_CLOSED 1
#define SIGNAL_EXITED 2
#define SIGNAL_NO_GROUP 3

/* Process.signal and signal_group, on the I/O thread. A child is signalled only while it is unreaped (running): its
   pid, and so its group's id, cannot name another process before that. */
static int send_signal(proc *p, int sig, bool to_group) {
  if (p->closed) return SIGNAL_CLOSED;
  if (to_group && !p->group) return SIGNAL_NO_GROUP;
  if (!p->running) return SIGNAL_EXITED;
  int rc = to_group ? uv_kill(-p->process.pid, sig) : uv_process_kill(&p->process, sig);
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "signal pid=%d sig=%d group=%d rc=%d", (int)p->process.pid, sig,
            to_group ? 1 : 0, rc);
  return rc;
}

static agc_value signal_result(agc_vm *vm, int rc) {
  switch (rc) {
    case 0:
      return ok_void();
    case SIGNAL_CLOSED:
      return agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
    case SIGNAL_EXITED:
      return agc_error(vm, AGC_KIND_PROCESS_FAILED, "process: the child has exited");
    case SIGNAL_NO_GROUP:
      return agc_error(vm, AGC_KIND_PROCESS_FAILED, "process: the child does not lead a process group");
    default:
      return agc_system_error(vm, AGC_FAMILY_PROCESS, "process: cannot signal the child", agc_net_errno(rc));
  }
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
    case REQ_POLL:
    case REQ_BYTES:
      if (q->closed)
        result = agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
      else if (q->over)
        result = agc_error(vm, AGC_KIND_PROCESS_TOO_LARGE, over_text);
      else if (line_kind(q->kind))
        result = agc_inbuf_cut_line_value(vm, AGC_STREAM_PROCESS, &q->cut, "process: line exceeds 1048576 bytes",
                                          "process: end of input");
      else
        result = agc_inbuf_cut_bytes_value(vm, AGC_STREAM_PROCESS, &q->cut);
      agc_charge(vm, agc_value_units(result));
      return result;
    case REQ_SEND:
      agc_charge(vm, q->count);
      if (q->closed) return agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
      if (q->stdin_closed) return agc_error(vm, AGC_KIND_PROCESS_CLOSED, "process: stdin is closed");
      return agc_stream_written(vm, AGC_STREAM_PROCESS, q->rc);
    case REQ_STDIN:
      return q->closed ? agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text) : ok_void();
    case REQ_AVAILABLE:
      if (q->closed) return agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
      if (q->over) return agc_error(vm, AGC_KIND_PROCESS_TOO_LARGE, over_text);
      return available_text(vm, q->cut.data, q->cut.len);
    case REQ_WAIT:
      if (q->closed) return agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
      return agc_result_value(true, agc_int(q->status));
    case REQ_OUTPUT:
      if (q->closed) return agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
      return output_of(vm, q->data, q->len, q->err_data, q->err_len, q->over);
    case REQ_SIGNAL:
      return signal_result(vm, q->rc);
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
  } else if (line_kind(q->kind) || q->kind == REQ_BYTES) {
    result = take(vm, p, q->kind, q->count);
    agc_charge(vm, agc_value_units(result));
  } else if (p->closed) {
    result = agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
  } else if (q->kind == REQ_AVAILABLE) {
    result = available(vm, p);
  } else if (q->kind == REQ_WAIT || q->kind == REQ_OUTPUT) {
    result = waited(vm, p, q->kind);
  } else {
    result = agc_stream_written(vm, AGC_STREAM_PROCESS, p->write_status);
  }
  drop_request(q);
  return result;
}

/* The kinds whose timeout closes the child, as `request_expired` does at N = 1: a read, a send, and a spawn whose
   task gave it up. */
static bool stops_child(req_kind kind) {
  return kind == REQ_LINE || kind == REQ_BYTES || kind == REQ_AVAILABLE || kind == REQ_SEND || kind == REQ_SPAWN;
}

/* A poll_line keeps the child when its task gives it up (a timeout or a cancel). When `finish` had cut a line by then,
   the line goes back to the front of stdout with its ending, so the next read finds it. Until then a captured child's
   Process.output does not hold that line. */
static void give_back(request *q) {
  agc_inbuf_cut *cut = &q->cut;
  const proc *p = q->p;
  if (cut->status != AGC_CUT_DATA || p->closed || p->out_cut || p->err_cut) return;
  const uint8_t *ending = (const uint8_t *)"\r\n";
  size_t ending_len = cut->taken - cut->len;
  if (!agc_inbuf_unread(&q->p->out_buf, ending + 2 - ending_len, ending_len) ||
      !agc_inbuf_unread(&q->p->out_buf, cut->data, cut->len))
    agc_out_of_memory();
}

/* What a deadline does to a posted request, on the I/O thread: the kind's `pause`, before EXPIRED is published, or
   the step that `expired` posts when the task saw the timeout first. The request leaves its slot. A read or a send
   closes the child even when it was finished: its task got the timeout, so the line or the write status it carries
   is lost, and the child must then look closed, as at N = 1. A poll_line keeps the child (give_back). */
static void stop_request(void *data) {
  request *q = data;
  if (!q->posted || q->stopped || !q->counted) return;
  q->stopped = true;
  unlink_request(q);
  if (q->kind == REQ_CLOSE && !q->finished)
    trace_alive(q->p);
  else if (q->kind == REQ_POLL && q->finished)
    give_back(q);
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
    return kind == REQ_CLOSE ? agc_void() : agc_stream_timed_out(vm, AGC_STREAM_PROCESS);
  }
  unlink_request(q);
  if (q->kind == REQ_CLOSE) {
    trace_alive(q->p);
    return agc_void();
  }
  if (q->kind != REQ_WAIT && q->kind != REQ_OUTPUT && q->kind != REQ_POLL) shut(q->p);
  return agc_stream_timed_out(vm, AGC_STREAM_PROCESS);
}

/* The cancel half runs on the I/O thread when the job loses its task (a detach, or the deadline after it). */
static bool request_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  request *q = data;
  q->detached = true;
  if (q->kind != REQ_POLL) return deadline && q->kind != REQ_SEND;
  /* Here, before a read that the canceller starts next, so the line keeps its place. */
  if (q->finished)
    give_back(q);
  else if (q->counted)
    unlink_request(q);
  return true;
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
  /* The loop first: agc_io_loop can raise, which would lose a guard already malloc'd (#1259). */
  agc_loop *io = agc_io_loop(vm);
  agc_resource *r = agc_register(vm, NULL, release_guard);
  guard *g = calloc(1, sizeof(guard));
  if (!g) agc_out_of_memory();
  g->trace = vm->rt->trace;
  g->io = io;
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

/* The pool thread's half of a chunk for a stream on its blocking FILE: the write may wait for the reader of the VM's
   stderr, which the I/O thread must never do. err_buf holds the chunk, since the read is paused until it is written.
   p->forward is rt->err, which outlives every child, and only its FILE is touched here. */
static void write_err(uv_work_t *work) {
  proc *p = OWNER(work, err_work);
  agc_output_write_file(p->forward, p->err_buf, p->err_len);
}

/* The chunk is written or dropped: the next child in line takes the stream, then this one reads again through
   forward_wait's resume, as when the stream has room. The resume may free P, so it comes last. */
static void err_turn_over(const proc *p) {
  agc_output_file_done(p->forward);
  p->forward_wait.resume(p->forward_wait.data);
}

static void err_written(uv_work_t *work, int status) {
  (void)status;
  err_turn_over(OWNER(work, err_work));
}

/* False when the pool refuses the job: the chunk is then dropped, as a failed stream drops it. */
static bool start_err_write(proc *p) {
  return agc_io_queue_work(agc_loop_uv(p->io), &p->err_work, write_err, err_written) == 0;
}

/* The turn of a child that waited in line (agc_output_file_done, on the I/O thread). */
static void write_turn(void *data) {
  proc *p = data;
  if (!start_err_write(p)) err_turn_over(p);
}

/* A chunk of a plain child's stderr goes to the VM's stderr through its buffer, never by a write that waits on the
   descriptor (§14.1). When the stream holds too much, the read stops, so the child waits on its own pipe. A stream
   left on its blocking FILE is written by a pool thread, one chunk of one child at a time, while the read waits. */
static void forward_err(uv_stream_t *s, ssize_t n, const uv_buf_t *buf) {
  proc *p = OWNER(s, err);
  if (n < 0) {
    err_over(p, n);
    return;
  }
  if (n == 0) return;
  AGC_TRACE(&p->trace, AGC_TRACE_PROC, "stderr pid=%d bytes=%zd", (int)p->process.pid, n);
  bool more = true;
  if (!agc_output_on_file(p->forward)) {
    more = agc_output_forward(p->forward, (const uint8_t *)buf->base, (size_t)n, &p->forward_wait);
  } else {
    p->err_len = (size_t)n;
    more = false;
    if (agc_output_file_turn(p->forward, &p->file_wait) && !start_err_write(p)) {
      agc_output_file_done(p->forward);
      more = true;
    }
  }
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
  size_t pending = agc_inbuf_pending(b);
  size_t left = pending >= LIMIT ? 0 : LIMIT - pending;
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

static CC_OWNS char *candidate(agc_vm *vm, const char *dir, size_t dir_len, const agc_string *name) {
  size_t len = agc_size_add(agc_size_add(dir_len, 1), name->bytes);
  agc_string *joined = agc_new_string(len, 0);
  memcpy(joined->data, dir, dir_len);
  joined->data[dir_len] = '/';
  memcpy(joined->data + dir_len + 1, name->data, name->bytes);
  return agc_host_path_try(vm, joined);
}

/* Takes the malloc'd path (NULL for none); returns it, or a copy with a suffix added, when a file that may run is
   there (process_os.h), else NULL. */
static CC_OWNS char *executable(CC_OWNS char *path) {
  if (!path) return NULL;
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

static CC_OWNS char *resolve(agc_vm *vm, const agc_string *command) {
  if (!agc_proc_name_ok(command->data, command->bytes)) return NULL;
  if (agc_proc_is_path(command->data, command->bytes)) return executable(agc_host_path_try(vm, command));
  /* candidate never raises (agc_host_path_try), so the loop cannot jump out with SEARCH held. */
  char *search = agc_system_env("PATH");
  char *found = NULL;
  const char *at = search, *dir;
  size_t len;
  while (!found && agc_proc_next_dir(&at, &dir, &len)) found = executable(candidate(vm, dir, len, command));
  free(search);
  return found;
}

/* The argv of a child: PATH, the arguments that spawn_child checked, and NULL. */
static CC_OWNS char **child_args(CC_OWNS char *path, const agc_string *const *items, size_t count) {
  CC_OWNS char **argv = calloc(agc_size_add(count, 2), sizeof(char *));
  if (!argv) agc_out_of_memory();
  argv[0] = path;
  for (size_t k = 0; k < count; k++) argv[k + 1] = agc_cstr(items[k]);
  return argv;
}

/* True when two names are one variable on this system: the adapter's order, so the sort of case_twins agrees. */
static bool env_name_equal(const char *a, size_t asize, const char *b, size_t bsize) {
  return agc_proc_env_name_compare(a, asize, b, bsize) == 0;
}

/* True when the variable NAME is the one of PREFIX, a name with the "=" that ends it. */
static bool env_prefix(const char *name, const char *prefix) {
  return env_name_equal(name, strlen(name), prefix, strlen(prefix) - 1);
}

static bool own_env(bool drop_uring, const char *name) {
  bool uring = drop_uring && env_prefix(name, URING_ENV);
  return uring || env_prefix(name, CHANNEL_PREFIX);
}

/* One VM owns the metrics port and file (docs/future/28-vm-metrics.md 28.5): a child VM, or a runner the BDD
   driver starts, would fight for them. Whole names are matched, so the first never catches the second. */
static bool metrics_env(const char *name) {
  return env_prefix(name, METRICS_ENV) ||
         env_prefix(name, METRICS_FILE_ENV);
}

/* "NAME=VALUE" in malloc memory. */
static CC_OWNS char *env_entry(const char *name, size_t name_size, const char *value, size_t value_size) {
  char *entry = malloc(agc_size_add(agc_size_add(name_size, value_size), 2));
  if (!entry) agc_out_of_memory();
  memcpy(entry, name, name_size);
  entry[name_size] = '=';
  memcpy(entry + name_size + 1, value, value_size);
  entry[name_size + 1 + value_size] = '\0';
  return entry;
}

/* True when the program's `env` map gives HOST_NAME a new value, so the VM's own entry is left out. */
static bool env_overridden(const char *host_name, const env_pair *pairs, size_t count) {
  size_t size = strlen(host_name);
  for (size_t k = 0; k < count; k++)
    if (env_name_equal(host_name, size, pairs[k].name->data, pairs[k].name->bytes)) return true;
  return false;
}

/* The environment of a child: the VM's own, minus the entries the VM owns and the names of `pairs` (the `env` map as
   env_problem checked it), plus those pairs; `channel` is the value of AGENTICA_CHANNEL when the child gets a channel.
   Nothing here can fail but the allocation, so no malloc'd entry is lost to an agc_fail. */
static CC_OWNS char **child_env(bool drop_uring, const char *channel, const env_pair *pairs, size_t added) {
  uv_env_item_t *host = NULL;
  int count = 0;
  if (uv_os_environ(&host, &count) != 0) return NULL;
  CC_OWNS char **env = calloc(agc_size_add(agc_size_add((size_t)count, added), 2), sizeof(char *));
  if (!env) { uv_os_free_environ(host, count); agc_out_of_memory(); }
  size_t kept = 0;
  for (int k = 0; k < count; k++) {
    const char *name = host[k].name;
    if (own_env(drop_uring, name) || metrics_env(name) || env_overridden(name, pairs, added)) continue;
    env[kept++] = env_entry(name, strlen(name), host[k].value, strlen(host[k].value));
  }
  uv_os_free_environ(host, count);
  for (size_t k = 0; k < added; k++)
    env[kept++] = env_entry(pairs[k].name->data, pairs[k].name->bytes, pairs[k].value->data, pairs[k].value->bytes);
  if (channel) {
    size_t size = strlen(CHANNEL_PREFIX) + strlen(channel) + 1;
    env[kept] = malloc(size);
    if (!env[kept]) agc_out_of_memory();
    snprintf(env[kept], size, "%s%s", CHANNEL_PREFIX, channel);
  }
  return env;
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
    /* A stream sent to a file still has its pipe: the child gets the file instead of the pipe's write end, which is
       closed below, so the VM's side of the pipe ends at once (read_line finds the end of output, and stderr has
       nothing to forward). */
    for (size_t k = 0; k < 3; k++) {
      stdio[k].flags = UV_INHERIT_FD;
      stdio[k].data.fd = k > 0 && l->files[k - 1] >= 0 ? l->files[k - 1] : fds[2 * k + (k == 0 ? 0 : 1)];
      if (l->inherit) stdio[k].data.fd = (int)k;
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
    /* POSIX: libuv's DETACHED is setsid() in the child, a new session and process group led by the child. It is not
       used on Windows, where it would also take the child out of libuv's job object (agc_proc_groups). */
    p->group = l->group && agc_proc_groups();
    if (p->group) options.flags |= UV_PROCESS_DETACHED;
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

/* The names the VM owns (own_env, metrics_env), each as its prefix with the "=" that ends the name. UV_USE_IO_URING is
   refused on every system on purpose, also where the VM would pass it through: one rule, and a program has no use for
   setting a libuv variable of the VM. VM_ENV_NAMES in stdlib/bdd.agc mirrors this list: change both. */
static const char *const reserved_names[] = {URING_ENV, CHANNEL_PREFIX, METRICS_ENV, METRICS_FILE_ENV};

static bool reserved_env(const agc_string *name) {
  for (size_t k = 0; k < sizeof reserved_names / sizeof reserved_names[0]; k++) {
    size_t size = strlen(reserved_names[k]) - 1;
    if (env_name_equal(name->data, name->bytes, reserved_names[k], size)) return true;
  }
  return false;
}

/* qsort order of names as the system compares them (agc_proc_env_name_compare). Two names that are one variable
   compare 0, so after the sort they are neighbours. */
static int compare_names(const void *a, const void *b) {
  const agc_string *x = *(const agc_string *const *)a;
  const agc_string *y = *(const agc_string *const *)b;
  return agc_proc_env_name_compare(x->data, x->bytes, y->data, y->bytes);
}

/* True when two of the COUNT names are one variable on a case-blind system: a sort and a pass over neighbours, so a big
   map costs O(n log n) comparisons, not one per pair. */
static bool case_twins(const env_pair *pairs, size_t count) {
  const agc_string **names = agc_alloc(agc_size_mul(count, sizeof *names));
  for (size_t k = 0; k < count; k++) names[k] = pairs[k].name;
  qsort(names, count, sizeof *names, compare_names);
  for (size_t k = 1; k < count; k++)
    if (env_name_equal(names[k - 1]->data, names[k - 1]->bytes, names[k]->data, names[k]->bytes)) return true;
  return false;
}

/* Why the program's `env` map cannot be a child's environment, or NULL; *pairs and *count get its pairs, which
   child_env adds. A name the VM owns is refused, not dropped: dropping it would run the child without a variable the
   program asked for. Where names ignore case (Windows) two keys that differ only in case are refused too: libuv would
   send both and the child could see either. */
static const char *env_problem(agc_vm *vm, const agc_map *env, const env_pair **pairs, size_t *count) {
  *pairs = NULL;
  *count = 0;
  if (!env || !env->size) return NULL;
  const agc_value *keys = agc_map_keys(vm, env, 0);
  env_pair *found = agc_alloc(agc_size_mul(env->size, sizeof *found));
  for (size_t k = 0; k < env->size; k++) {
    agc_value value;
    const agc_string *name = agc_as_string(vm, keys[k]);
    if (!agc_map_get(vm, env, keys[k], &value)) agc_fail(vm, "RUNTIME-INTERNAL", "invalid map", 0);
    const agc_string *text = agc_as_string(vm, value);
    if (name->bytes == 0 || !no_nul(name) || memchr(name->data, '=', name->bytes) || !no_nul(text))
      return "process: environment names must be nonempty and cannot contain = or NUL, and values cannot contain NUL";
    if (reserved_env(name))
      return "process: AGENTICA_CHANNEL, AGENTICA_VM_METRICS, AGENTICA_VM_METRICS_FILE and UV_USE_IO_URING cannot be set";
    found[k] = (env_pair){name, text};
  }
  if (agc_proc_env_case_blind() && case_twins(found, env->size))
    return "process: environment names must differ by more than case";
  *pairs = found;
  *count = env->size;
  return NULL;
}

static CC_OWNS char *child_dir(agc_vm *vm, const agc_string *dir, bool *found) {
  *found = true;
  if (dir->bytes == 1 && dir->data[0] == '.') return NULL;
  /* No raise here: spawn_child holds the resolved command. */
  char *path = agc_host_path_try(vm, dir);
  agc_fs_info info;
  *found = path && agc_fs_stat(path, &info, true) == 0 && AGC_FS_ISDIR(info.mode);
  return path;
}

/* The file of `out` or `err`, created or truncated with mode 0666 less the umask, as File.write_text and a shell's `>`
   make it (a file that exists keeps its mode), with the guards of the File calls (agc_files_open_output). It opens
   without waiting, so a FIFO with no reader fails at once and never holds the scheduler, and is then made blocking
   again: the child writes to it as to any stdout. -1 with errno, or with *refused set. */
static int open_target(agc_vm *vm, const agc_string *path, bool *refused) {
  int fd = agc_files_open_output(vm, path, refused);
  if (fd >= 0) agc_fs_blocking(fd);
  return fd;
}

/* True when two open descriptors are one file, so `out` and `err` share one descriptor and one offset, as `> f 2>&1`
   does: two descriptors would each write from the start and overwrite each other. */
static bool same_file(int a, int b) {
  agc_fs_info x, y;
  return agc_fs_fstat(a, &x) == 0 && agc_fs_fstat(b, &y) == 0 && x.ino != 0 && x.dev == y.dev && x.ino == y.ino;
}

/* Opens the files of `out` and `err` (empty: the pipe) into FILES; NULL, or the error of the one that failed, with
   nothing left open (*problem: its errno, or the refusal's EISDIR or ELOOP, else 0; *refused_at: the path was
   refused). */
static const char *open_targets(agc_vm *vm, const agc_string *out, const agc_string *err, int files[2], int *problem,
                                bool *refused_at) {
  const agc_string *paths[2] = {out, err};
  static const char *const texts[2][2] = {
    {"process: cannot open the out file", "process: out does not refer to a regular file"},
    {"process: cannot open the err file", "process: err does not refer to a regular file"},
  };
  for (size_t k = 0; k < 2; k++) {
    if (!paths[k]->bytes) continue;
    if (k == 1 && files[0] >= 0 && agc_same_string(vm, out, err)) {
      files[1] = files[0];
      continue;
    }
    bool refused;
    files[k] = open_target(vm, paths[k], &refused);
    if (files[k] < 0) {
      *problem = errno;
      *refused_at = refused;
      close_fd(&files[0]);
      return texts[k][refused];
    }
  }
  if (files[0] >= 0 && files[1] >= 0 && files[1] != files[0] && same_file(files[0], files[1])) {
    close_fd(&files[1]);
    files[1] = files[0];
  }
  return NULL;
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

/* dir ("." keeps the VM's directory) is where the child starts; the command resolves before the child changes
   directory (§10.4). captured keeps stdout and stderr in buffers (spawn_captured, spawn_channel). out and err
   (Process.spawn only; empty: the pipe) are files for the child's stdout and stderr, opened last, so a spawn
   refused for its other arguments touches no file. */
static agc_value spawn_child(agc_vm *vm, const agc_value *args, const agc_string *dir, int64_t timeout, bool captured,
                             bool channel, const agc_map *env, const agc_string *out, const agc_string *err,
                             bool group, bool inherit) {
  if (vm->rt->deny_run) return agc_error(vm, AGC_KIND_DENIED_RUN, "denied: --deny-run turns off starting programs");
  if (inherit && !agc_proc_groups())
    return agc_error(vm, AGC_KIND_SYSTEM_SIGNAL, "process: process groups are not supported on this system");
  bool files = out->bytes || err->bytes;
  if (files && captured) return agc_error(vm, AGC_KIND_ARGUMENT, "process: out and err need Process.spawn");
  const agc_string *command = agc_as_string(vm, args[0]);
  const agc_list *list = agc_as_list(vm, args[1]);
  /* Every argument is a String before the first malloc of the spawn (resolve): child_args copies these, so a wrong
     tag cannot jump out of it with argv half built (#1251). */
  size_t count = agc_list_len(list);
  const agc_string **items = agc_alloc(agc_size_mul(count, sizeof *items));
  bool valid = command->bytes > 0 && no_nul(command);
  agc_list_cursor cursor;
  agc_value item;
  agc_list_cursor_begin(&cursor, list, 0);
  for (size_t k = 0; agc_list_cursor_next(&cursor, &item); k++) {
    items[k] = agc_as_string(vm, item);
    valid = valid && no_nul(items[k]);
  }
  if (!valid)
    return agc_error(vm, AGC_KIND_ARGUMENT, "process: command must be nonempty and arguments cannot contain NUL");
  if (dir->bytes == 0 || !no_nul(dir))
    return agc_error(vm, AGC_KIND_ARGUMENT, "process: chdir must be nonempty and cannot contain NUL");
  if (timeout <= 0) return agc_stream_bad_timeout(vm, AGC_STREAM_PROCESS);
  const env_pair *pairs;
  size_t pair_count;
  const char *env_text = env_problem(vm, env, &pairs, &pair_count);
  if (env_text) return agc_error(vm, AGC_KIND_ARGUMENT, env_text);
  if (files && vm->rt->deny_fs) return agc_error(vm, AGC_KIND_DENIED_FS, AGC_DENIED_FS);
  if (files && (!no_nul(out) || !no_nul(err)))
    return agc_error(vm, AGC_KIND_ARGUMENT, "process: out and err cannot contain NUL");
  agc_process *pr = agc_alloc(sizeof(agc_process));
  pr->reader = agc_new_lock(vm);
  pr->writer = agc_new_lock(vm);
  if (channel) pr->channel = (agc_lines){agc_new_lock(vm), agc_new_lock(vm)};
  guard *g = guard_of(vm);
  char *path = resolve(vm, command);
  if (!path) {
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_PROC, "spawn_failed reason=unresolved");
    return agc_error(vm, AGC_KIND_PROCESS_NOT_FOUND, "process: executable is unavailable");
  }
  bool found;
  char *cwd = child_dir(vm, dir, &found);
  if (!found) {
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_PROC, "spawn_failed reason=dir");
    free(path);
    free(cwd);
    return agc_error(vm, AGC_KIND_PROCESS_NOT_FOUND, "process: directory is unavailable");
  }
  int targets[2] = {-1, -1}, problem = 0;
  bool refused = false;
  const char *target_text = files ? open_targets(vm, out, err, targets, &problem, &refused) : NULL;
  if (target_text) {
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_PROC, "spawn_failed reason=file");
    free(path);
    free(cwd);
    if (!problem) return agc_error(vm, AGC_KIND_ARGUMENT, target_text);
    if (!refused) return agc_system_error(vm, AGC_FAMILY_IO, target_text, problem);
    /* A refused folder or link loop keeps its text and takes the kind and code of its errno, as File does. */
    size_t n = strlen(target_text);
    return agc_error_code(vm, agc_errno_kind(AGC_FAMILY_IO, problem), agc_make_string(target_text, n, n), problem);
  }
  launch *l = calloc(1, sizeof(launch));
  if (!l) agc_out_of_memory();
  l->g = g;
  l->files[0] = targets[0];
  l->files[1] = targets[1];
  l->argv = child_args(path, items, count);
  l->env = child_env(vm->rt->drop_uring_env, channel ? agc_chan_value() : NULL, pairs, pair_count);
  l->cwd = cwd;
  l->args = count;
  l->channel = channel;
  l->group = group;
  l->inherit = inherit;
  if (!l->env) {
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_PROC, "spawn_failed path=%s rc=%d", l->argv[0], UV_ENOMEM);
    free_launch(l);
    return agc_system_error(vm, AGC_FAMILY_PROCESS, "process: cannot run the executable", agc_net_errno(UV_ENOMEM));
  }
  /* With several schedulers the spawn parks (start_request below), which a callback of native code cannot: the errors
     above still come back as a Result, and the launch is freed before the refusal, before the child exists. The loop
     is made first, since agc_io_here reads it. */
  (void)agc_io_loop(vm);
  if (vm->task->callbacks && !agc_io_here(vm)) {
    free_launch(l);
    agc_task_refuse_wait(vm);
  }
  proc *p = calloc(1, sizeof(proc));
  if (!p) agc_out_of_memory();
  p->trace = vm->rt->trace;
  p->io = agc_io_loop(vm);
  /* rt is GC memory that the malloc'd proc does not keep alive, but it lives for the whole run, past every child. */
  p->forward = &vm->rt->err;
  p->forward_wait = (agc_forward_wait){NULL, p->io, resume_err, p};
  p->file_wait = (agc_forward_wait){NULL, p->io, write_turn, p};
  p->captured = captured;
  p->inherit = inherit;
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
    return agc_system_error(vm, AGC_FAMILY_PROCESS, "process: cannot run the executable", agc_net_errno(rc));
  }
  own_child(vm, pr, p);
  return agc_result_value(true, agc_process_value(pr));
}

/* Process.spawn, spawn_captured and spawn_channel with their Process.Options (the third argument): what the catalog
   lowers to. */
static agc_value spawn_options(agc_vm *vm, const agc_value *args, bool captured, bool channel) {
  const agc_struct *o = agc_as_struct(vm, args[2]);
  if (o->n != OPTION_FIELDS) agc_wrong_tag(vm);
  const agc_value *f = o->fields;
  return spawn_child(vm, args, agc_as_string(vm, f[OPTION_CHDIR]), agc_as_int(vm, f[OPTION_TIMEOUT_MS]), captured,
                     channel, agc_as_map(vm, f[OPTION_ENV]), agc_as_string(vm, f[OPTION_OUT]),
                     agc_as_string(vm, f[OPTION_ERR]), agc_as_bool(vm, f[OPTION_PGROUP]), false);
}

static agc_value builtin_spawn_options(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return spawn_options(vm, args, false, false);
}

static agc_value builtin_spawn_captured_options(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return spawn_options(vm, args, true, false);
}

/* Process.spawn_group(command, args, dir, timeout_ms): a child in a new session, so its pid is its group's id, with
   the VM's stdin, stdout and stderr (docs/vm/10-io-processes.md, "Sending signals"). */
static agc_value builtin_spawn_group(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *none = agc_make_string("", 0, 0);
  return spawn_child(vm, args, agc_as_string(vm, args[2]), agc_as_int(vm, args[3]), false, false, NULL, none, none,
                     true, true);
}

static agc_value builtin_spawn_channel_options(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return spawn_options(vm, args, true, true);
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
  if (!agc_stream_lock(vm, lock, AGC_STREAM_PROCESS, timeout, result)) return NULL;
  proc *p = live(vm, pr);
  if (!p) *result = agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
  return p;
}

static agc_value inherited(agc_vm *vm) {
  return agc_error(vm, AGC_KIND_PROCESS_FAILED, "process: the child uses the program's stdin, stdout and stderr");
}

static agc_value read_op(agc_vm *vm, agc_value handle, req_kind kind, size_t count, int64_t timeout) {
  agc_process *pr = agc_as_process(vm, handle);
  agc_value result;
  proc *p = take_lock(vm, pr, pr->reader, &timeout, &result);
  if (!p) return result;
  if (p->inherit) return inherited(vm);
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

static agc_value builtin_poll_line(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return read_op(vm, args[0], REQ_POLL, 0, agc_as_int(vm, args[1]));
}

/* Process.read_bytes: up to count bytes of the child's stdout, as a Bytes. */
static agc_value builtin_read_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t count = agc_as_int(vm, args[1]);
  if (count < 0 || (uint64_t)count > LIMIT)
    return agc_error(vm, AGC_KIND_ARGUMENT, "process: count must be 0..1048576");
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
  if (p->inherit) return inherited(vm);
  if (agc_io_here(vm)) {
    if (p->in_closed) return agc_error(vm, AGC_KIND_PROCESS_CLOSED, "process: stdin is closed");
    /* In a callback of native code, a write that does not end at once stays in flight with no writer when new_request
       refuses below. Unlike the parent channel (`sending` in duplex.c), no later send can reach it: a callback reaches
       only a child it spawned, and the refusal fails its task, whose end closes the child and so cancels the write. */
    p->write_status = 0;
    int rc = agc_stream_write((uv_stream_t *)&p->in, &p->write_req, &p->write_data, data, len, wrote);
    if (rc <= 0) return agc_stream_written(vm, AGC_STREAM_PROCESS, rc);
  }
  request *q = new_request(vm, p, REQ_SEND);
  q->count = (size_t)agc_value_units(args[1]);
  if (q->posted) copy_bytes(&q->data, &q->len, data, len);
  start_request(vm, q, agc_handle_value(pr->writer), timeout, begin_send);
  return agc_void();
}

/* Process.send_bytes: a Bytes, of which only the size is checked. */
static agc_value builtin_send_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  size_t len = 0;
  const uint8_t *data = agc_bytes_data(vm, args[1], &len);
  if (len > LIMIT) return agc_error(vm, AGC_KIND_ARGUMENT, "process: bytes exceed 1048576 per call");
  return write_op(vm, args, data, len);
}

static agc_value builtin_send(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_string *text = agc_as_string(vm, args[1]);
  if (text->bytes > LIMIT) return agc_error(vm, AGC_KIND_ARGUMENT, "process: send exceeds 1048576 bytes");
  return write_op(vm, args, (const uint8_t *)text->data, text->bytes);
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
  if (p && p->inherit) return inherited(vm);
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
  if (timeout <= 0) return agc_stream_bad_timeout(vm, AGC_STREAM_PROCESS);
  proc *p = live(vm, pr);
  if (!p) return agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
  /* `captured` is fixed before the child is shared, so any thread may read it. */
  if (kind == REQ_OUTPUT && !p->captured)
    return agc_error(vm, AGC_KIND_PROCESS_FAILED, "process: output is not captured");
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
  agc_resource *r = agc_as_process(vm, args[0])->state;
  /* The close parks with several schedulers, and at N = 1 while a plain child still runs (reaped_on_close, read here
     before shut): a callback of native code is refused while the child still has its resource. The read after shut
     differs only when the SIGKILL fails (the Windows EACCES race of signal_child): that close is refused, not parked. */
  const proc *child = r->native;
  if (child && (!agc_io_here(vm) || reaped_on_close(child))) agc_task_check_wait(vm);
  proc *p = unregister_child(vm, r);
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
  if (!p) *result = agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
  else if (!p->channel) *result = agc_error(vm, AGC_KIND_PROCESS_FAILED, "process: the child has no channel");
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

static bool begin_signal(void *data, agc_io_job *job) {
  request *q = data;
  link_request(q, job);
  q->rc = send_signal(q->p, q->sig, q->to_group);
  (void)finish(q);
  return true;
}

static agc_value signal_op(agc_vm *vm, const agc_value *args, bool to_group) {
  agc_process *pr = agc_as_process(vm, args[0]);
  int sig = agc_signal_number_of(vm, args[1]);
  if (!sig) return agc_error(vm, AGC_KIND_SYSTEM_SIGNAL, "signal: not supported on this system");
  proc *p = live(vm, pr);
  if (!p) return agc_error(vm, AGC_KIND_PROCESS_CLOSED, closed_text);
  if (agc_io_here(vm)) return signal_result(vm, send_signal(p, sig, to_group));
  request *q = new_request(vm, p, REQ_SIGNAL);
  q->sig = sig;
  q->to_group = to_group;
  start_request(vm, q, agc_void(), -1, begin_signal);
  return agc_void();
}

static agc_value builtin_signal(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return signal_op(vm, args, false);
}

static agc_value builtin_signal_group(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return signal_op(vm, args, true);
}

/* What signal_pid found besides 0 or a negated errno. */
#define PID_UNAVAILABLE 1
#define PID_OTHER_NAME 2

#ifdef __linux__
/* glibc 2.28, the release baseline, has no wrappers; the numbers are the same on every architecture we build. */
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif
#ifndef SYS_pidfd_send_signal
#define SYS_pidfd_send_signal 424
#endif

#define PIDFD_UNKNOWN 0
#define PIDFD_READY 1
#define PIDFD_MISSING 2

static int pidfd_of(pid_t pid) { return (int)syscall(SYS_pidfd_open, pid, 0); }

static int pidfd_signal(int fd, int sig) { return (int)syscall(SYS_pidfd_send_signal, fd, sig, NULL, 0); }

/* ENOSYS: an older kernel; EPERM: a seccomp filter. */
static bool pidfd_refused(int err) { return err == ENOSYS || err == EPERM; }

/* Probed once, by opening a pidfd of the VM itself and sending it signal 0. */
static bool pidfd_ready(void) {
  static atomic_int pidfd_state;
  int state = atomic_load(&pidfd_state);
  if (state != PIDFD_UNKNOWN) return state == PIDFD_READY;
  int fd = pidfd_of(getpid());
  bool refused = fd < 0 ? pidfd_refused(errno) : pidfd_signal(fd, 0) != 0 && pidfd_refused(errno);
  if (fd >= 0) close(fd);
  atomic_store(&pidfd_state, refused ? PIDFD_MISSING : PIDFD_READY);
  return !refused;
}

/* The name of /proc/PID/comm without its newline; its length, or -1 with errno. */
static ssize_t read_comm(pid_t pid, char *name, size_t size) {
  char path[32];
  snprintf(path, sizeof path, "/proc/%d/comm", (int)pid);
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  ssize_t n = read(fd, name, size);
  int err = errno;
  close(fd);
  errno = err;
  if (n > 0 && name[n - 1] == '\n') n--;
  return n;
}

/* The signal goes through the pidfd that the name was checked under, so it reaches that process or none (ESRCH once
   it is reaped), never one that took its pid. */
static int signal_pid(pid_t pid, int sig, const agc_string *comm) {
  if (!pidfd_ready()) return PID_UNAVAILABLE;
  int fd = pidfd_of(pid);
  if (fd < 0) return -errno;
  char name[64];
  ssize_t n = read_comm(pid, name, sizeof name);
  int rc = 0;
  if (n < 0)
    rc = errno == ENOENT ? -ESRCH : -errno;
  else if ((size_t)n != comm->bytes || memcmp(name, comm->data, comm->bytes) != 0)
    rc = PID_OTHER_NAME;
  else if (pidfd_signal(fd, sig) != 0)
    rc = -errno;
  close(fd);
  return rc;
}
#else
static int signal_pid(int pid, int sig, const agc_string *comm) {
  (void)pid;
  (void)sig;
  (void)comm;
  return PID_UNAVAILABLE;
}
#endif

/* System.signal(pid, signal, comm): a process that is not a child, named by its pid and its 15-byte kernel name. */
static agc_value builtin_system_signal(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  if (vm->rt->deny_run) return agc_error(vm, AGC_KIND_DENIED_RUN, "denied: --deny-run turns off signalling processes");
  int64_t pid = agc_as_int(vm, args[0]);
  int sig = agc_signal_number_of(vm, args[1]);
  const agc_string *comm = agc_as_string(vm, args[2]);
  if (pid <= 0 || pid > INT_MAX || pid == (int64_t)uv_os_getpid())
    return agc_error(vm, AGC_KIND_ARGUMENT, "signal: pid must be above 0 and not the program's own");
  if (!comm->bytes || comm->bytes > 15 || !no_nul(comm))
    return agc_error(vm, AGC_KIND_ARGUMENT, "signal: comm must be 1 to 15 bytes without NUL");
  int rc = sig ? signal_pid((int)pid, sig, comm) : PID_UNAVAILABLE;
  if (rc == PID_UNAVAILABLE) return agc_error(vm, AGC_KIND_SYSTEM_SIGNAL, "signal: pidfd is unavailable");
  if (rc == PID_OTHER_NAME) return agc_error(vm, AGC_KIND_SYSTEM_SIGNAL, "signal: the process has another name");
  if (rc) return agc_system_error(vm, AGC_FAMILY_PROCESS, "signal: cannot signal the process", -rc);
  return ok_void();
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
  if (!p->captured) return agc_error(vm, AGC_KIND_PROCESS_FAILED, "process: output is not captured");
  if (!agc_io_here(vm) || !agc_proc_drains()) {
    start_request(vm, new_request(vm, p, REQ_AVAILABLE), agc_handle_value(pr->reader), timeout, begin_available);
    return agc_void();
  }
  drain_out(p);
  return available(vm, p);
}

const agc_builtin agc_process_builtins[] = {
  {"Process.spawn.options", 3, builtin_spawn_options, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"Process.spawn_captured.options", 3, builtin_spawn_captured_options, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false,
   false},
  {"Process.spawn_channel.options", 3, builtin_spawn_channel_options, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false,
   false},
  {"Process.send", 3, builtin_send, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"Process.read_line", 2, builtin_read_line, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"Process.send_bytes.bytes", 3, builtin_send_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"Process.read_bytes.bytes", 3, builtin_read_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"Process.close_stdin", 2, builtin_close_stdin, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Process.wait", 2, builtin_wait, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Process.close", 1, builtin_close, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Process.output", 2, builtin_output, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Process.channel_read_line", 2, builtin_channel_read_line, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"Process.channel_send", 3, builtin_channel_send, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"Process.channel_close", 2, builtin_channel_close, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Process.read_available", 2, builtin_read_available, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Process.spawn_group", 4, builtin_spawn_group, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"Process.signal", 2, builtin_signal, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Process.signal_group", 2, builtin_signal_group, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"System.signal", 3, builtin_system_signal, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Process.poll_line", 2, builtin_poll_line, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
};

const size_t agc_process_builtin_count = sizeof agc_process_builtins / sizeof agc_process_builtins[0];
#else
const agc_builtin agc_process_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false}};

const size_t agc_process_builtin_count = 0;

void agc_processes_stop(agc_vm *vm) { (void)vm; }
#endif
