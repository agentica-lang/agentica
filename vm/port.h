/*
 * The port between the core and the services: the runtime structs (vm, task
 * and runtime), and the calls that a service makes to park or wake a task, run
 * a job, own or close a handle, spawn a task, or charge and fail. Design:
 * docs/vm/15-layers.md §15.2 and docs/vm/14-core-invariants.md.
 */
#ifndef AGC_PORT_H
#define AGC_PORT_H

#if defined(__linux__) || defined(__APPLE__)
#include <locale.h>
#include <signal.h>
#endif
#include <stdatomic.h>
#include <stdio.h>

#include "value.h"

typedef void (*agc_release_fn)(void *native);
typedef void (*agc_close_fn)(agc_vm *vm, agc_resource *r, agc_task *ender);

typedef enum { AGC_RESOURCE_NATIVE, AGC_RESOURCE_JOB } agc_resource_kind;

struct agc_resource {
  size_t slot;
  uint64_t id;
  agc_resource_kind kind;
  void *native;
  agc_release_fn release, goodbye;
  agc_value context;
  agc_task *task;
  agc_resource *holder;
  agc_task *next_owner;
  agc_task *waiters, *waiters_tail;
  agc_task *owner, *ender;
  agc_resource *owned_prev, *owned_next;
  agc_close_fn close;
  bool closing, pool_close, keep_detached;
};

typedef void (*agc_end_fn)(agc_vm *vm, agc_task *t);

typedef struct agc_test_note agc_test_note;
typedef struct agc_test_run agc_test_run;
typedef struct agc_registry agc_registry;
typedef struct agc_runq agc_runq;
typedef struct agc_lock agc_lock;
typedef struct agc_loop agc_loop;
typedef struct agc_io_job agc_io_job;
typedef bool (*agc_more_fn)(void *data, agc_io_job *job);
typedef struct agc_poller agc_poller;
typedef struct agc_stdio agc_stdio;
typedef struct agc_memstream agc_memstream;
typedef struct agc_native agc_native;

/* The halves of a blocking call. `done` owns `data`, may raise (agc_fail) and is the only half that frees it itself;
 * the job's owner count goes back before it runs, so a raise leaks nothing. `expired` must never raise: it runs
 * while the job still owns `data` (a pool work may be using it) and the owner's count is given back after it, so a
 * raise would leak the job, and at N > 1 the count cannot go back first because the I/O thread would then `drop`
 * the data under the call. Every `expired` in the tree (task, process, tcp, duplex, files, http_client, http_server,
 * output) only unlinks requests, shuts or closes handles and builds a value, and none calls agc_fail. */
typedef struct {
  void (*work)(void *data);
  agc_value (*done)(agc_vm *vm, void *data, agc_value context);
  agc_value (*expired)(agc_vm *vm, void *data, agc_value context);
  void (*drop)(void *data);
  bool external;
  const char *name;
  bool (*cancel)(agc_vm *vm, void *data, agc_value context, bool deadline);
  /* The halves change state that several schedulers reach: the interpreter runs them with rt->sync held (run_half in
     vm/loop.c). A kind whose halves only build a value from its own data leaves it false. */
  bool locked;
  /* Stops the wait of the job on the I/O thread when its timer fires, before the outcome says EXPIRED, so that
     `expired` (on a scheduler) never runs beside a callback of that wait. NULL when the wait needs no stop. */
  void (*pause)(void *data);
} agc_io_kind;

typedef struct {
  uint32_t function, pc, base, ret;
  bool tail;
  agc_native *native;
} agc_frame;

typedef enum { AGC_STEP_CALL, AGC_STEP_WAIT, AGC_STEP_END } agc_step_kind;

typedef struct {
  agc_step_kind kind;
  agc_value value;
} agc_step;

typedef struct agc_stepper agc_stepper;

typedef agc_step (*agc_step_fn)(agc_vm *vm, agc_stepper *self, agc_value last);

struct agc_stepper {
  agc_step_fn step;
};

typedef struct {
  agc_channel *channel;
  agc_value value;
  uint64_t deadline, seq;
  bool sending, reserved;
} agc_channel_wait;

typedef enum { AGC_DONE, AGC_FAILED, AGC_EXITED } agc_outcome_kind;

typedef enum { AGC_STYLE_PLAIN, AGC_STYLE_AI, AGC_STYLE_JSON } agc_style;

#define AGC_STACK_HEAD 15
#define AGC_STACK_TAIL 5

typedef struct {
  uint32_t function, span, repeat;
  bool tail;
} agc_stack_line;

typedef struct {
  bool shown, spawned;
  uint32_t count, head, spawn_span;
  uint64_t omitted;
  agc_stack_line lines[AGC_STACK_HEAD + AGC_STACK_TAIL];
} agc_stack;

typedef struct {
  agc_outcome_kind kind;
  const char *code;
  const char *message;
  const agc_string *text;
  size_t message_len;
  uint32_t span;
  int64_t exit_code;
  agc_stack stack;
} agc_outcome;

typedef enum { AGC_INPUT_OK, AGC_INPUT_EOF, AGC_INPUT_WAIT, AGC_INPUT_FAILED } agc_input_status;

typedef struct {
  int fd, poll_fd;
  bool flush_out, pending_eof, reading, poll_tried, poll_socket;
  agc_poller *poller;
  int got;
  uint8_t *buf;
  size_t start, end, cap, scanned;
  uint64_t eof_seq;
  agc_task *waiters, *waiters_tail;
} agc_input;

typedef struct {
  uint64_t dev, ino;
} agc_file_id;

typedef struct {
  agc_file_id *ids;
  size_t count, cap;
} agc_file_ids;

#define AGC_OUTPUT_BUFFER ((size_t)64 * 1024)
#define AGC_NOTICE_LIMIT ((size_t)1024 * 1024)

typedef struct agc_output agc_output;

typedef struct {
  agc_output *out;
  const agc_string *text;
  size_t done;
  bool newline, flush;
} agc_output_wait;

/* How a standard stream is written. vm/output.c asks, vm/stdio_posix.c or vm/stdio_windows.c decides:
   - DISK: a pool job writes a file or a device that never waits for a reader; when the run is stopping the loop may
     write it itself.
   - POLL: the loop writes what the descriptor takes when its poller says it is ready (Linux and macOS pipes, sockets
     and terminals).
   - STREAM: a libuv stream takes one request at a time (a Windows pipe).
   - THREAD: a pool job writes a handle that can wait for its reader (a Windows console, or a socket or pipe that libuv
     refuses). The loop never writes it. */
typedef enum { AGC_WRITE_DISK, AGC_WRITE_POLL, AGC_WRITE_STREAM, AGC_WRITE_THREAD } agc_write_mode;

/* The first bytes of a UTF-8 character that one write cut off, kept for the next: a Windows console takes UTF-16. */
typedef struct {
  uint8_t bytes[4];
  size_t length;
} agc_utf8_cut;

/* One stream. While a pool job or a stream holds a request (writing, and mode is not POLL) the ring ranges of the
   request stay valid: nothing consumes the ring or fails the stream until the request is done, and text is only
   appended behind it. */
struct agc_output {
  FILE *file;
  agc_output *base;
  /* The lock of the stream (the base's, when two streams share one): it protects the ring, the FIFO and the state flags
     and is never held across a park (docs/vm/16-architecture.md §16.9). Solo until agc_share. */
  agc_lock *lock;
  agc_vm *vm;
  int fd;
  uint8_t *buf;
  size_t start, len;
  uint8_t *notice;
  size_t notice_at, notice_len;
  agc_stdio *io;
  agc_write_mode mode;
  agc_utf8_cut cut;
  bool writing, failed;
  agc_task *waiters, *waiters_tail;
};

#define AGC_LOG_NO_HANDLER 4

typedef struct {
  agc_value name, handler;
  int64_t rank;
} agc_log_handler;

typedef struct {
  int64_t level, lowest;
  agc_log_handler *items;
  size_t count, cap;
} agc_log_registry;

/* One std/ source that the binary carries: PATH is relative to stdlib/ ("queue.agc", "bdd/gherkin.agc"). */
typedef struct {
  const char *path;
  const uint8_t *data;
  size_t len;
} agc_std_source;

/* The most words the front end may hand over. A run takes a handful of options; the arguments of a process are bounded
 * by what the system lets it start with, far below the second number. The caps keep the counts inside an int. */
#define AGC_FRONT_END_MAX_OPTIONS 64
#define AGC_FRONT_END_MAX_ARGUMENTS 1048576

/* What the front end (the compiler that the binary loads from its own data) shares with the driver: the std/ sources
 * it may read, and the hand-off of the program it compiled. The driver owns it and points the front end's runtime at
 * it; a user program runs in a runtime without one. The hand-off fields are GC memory the driver reads after the
 * front end's run ends. Design: docs/vm/08-loader-and-cli.md. */
typedef struct {
  const agc_std_source *std;
  size_t std_count;
  bool handed;
  uint8_t *program;
  size_t program_len;
  char **options, **arguments;
  size_t option_count, argument_count;
} agc_front_end;

#define AGC_ASCII_CHARS 128
#define AGC_FLUSH_TIMEOUT_MS 30000
#define AGC_FLUSH_TIMEOUT_MAX_MS 86400000

typedef struct {
  const agc_program *program;
  agc_output out, err;
  agc_value args;
  /* The shared small values of the run (docs/future/34-shared-small-values.md), made once by agc_vm_init and never
     written: the empty List, Map, Set and String, and the one-character ASCII Strings by code. A builtin that computes
     one of them returns the shared value instead of allocating. Values are immutable and compared by content, so
     nothing can tell the object from a fresh one. */
  agc_value empty_list, empty_map, empty_set;
  agc_string *empty_string, *chars[AGC_ASCII_CHARS];
  agc_string *cwd;
  bool no_files, no_turn_cost, allow_run, drop_uring_env, flush_expired;
  agc_style style;
  int64_t flush_timeout;
  /* The loop clock (ms) at which the one short wait that a stuck stream gets at exit ends; 0 until it starts. A stop
     signal and the final diagnostics share it, so that the exit does not wait once per stream and notice. */
  uint64_t settle_by;
  agc_front_end *front_end;
  agc_runq *runq;
  /* The state that every scheduler and the I/O role share (docs/vm/16-architecture.md §16.9, "The context split"): the
     main task, the resource registry and the loop, the process service's guard and parent channel, and the records of
     crashed and quiet tasks. The tasks' lists and counters are under rt->sync; the registry has its own lock. What stays
     in agc_vm is the scheduler's own context. */
  agc_task *main;
  agc_registry *registry;
  agc_loop *loop;
  agc_resource *process_guard, *parent;
  agc_lines parent_locks;
  agc_task *crashes, *crashes_tail, *quiet;
  uint64_t crash_count, observed_count;
  _Atomic uint64_t tasks_done;
  /* The one lock for the shared state of the tasks (agc_sync_take): the task tree, the waiter lists, the channels, the
     Task.map groups and the logger table. `shared` is false until agc_share, and then the lock is real, and the
     interpreter takes it around each builtin whose row is marked `shared`. */
  agc_lock *sync;
  bool shared;
  /* The scheduler threads (docs/vm/16-architecture.md §16.9, "Threads"): `schedulers` is N (1 runs the scheduler on the
     loop's thread, the default), `scheds` their contexts (GC memory, so the collector sees them) and `threads` their
     malloc'd ids, of which `started` are running. `over` is set once, by the first agc_run_over: the run is over and
     rt->outcome holds its end. `entry_done` opens the run queue to the other schedulers once the entry has written the
     Globals table. `timers_armed` counts the armed task timers of every heap, for the stall check. */
  int64_t schedulers;
  struct agc_vm **scheds;
  void *threads;
  _Atomic uint32_t started;
  _Atomic bool over, entry_done;
  _Atomic uint64_t timers_armed;
  uint64_t over_task;
#ifdef __linux__
  locale_t messages_locale;
#endif
  uint64_t hash_key[2], seed;
  uint32_t await_done, await_timed_out;
  bool await_found;
  _Atomic int64_t steps_left;
  _Atomic uint64_t next_task_id;
  agc_log_registry log;
  agc_trace trace;
  agc_outcome outcome;
  agc_input in;
  agc_file_ids inherited;
} agc_runtime;

/* The life of a task (docs/vm/10-io-multicore.md §10.2.3, "Park and wake protocol"). READY: in the run queue, from a
   spawn, a yield or a wake. RUNNING: a scheduler runs its turn. PARKING: the turn is about to wait (agc_task_parking,
   before the wait is registered), and a wake that arrives now has to be seen by the task. PARKED: waiting, in no
   queue. WOKEN: a waker got in while the task was PARKING; nothing was queued, and the end of the turn sends the task
   back to the queue. DONE: ended. Only agc_task_wake changes the state of a task that is not running its turn. */
typedef enum {
  AGC_TASK_READY, AGC_TASK_RUNNING, AGC_TASK_PARKING, AGC_TASK_PARKED, AGC_TASK_WOKEN, AGC_TASK_DONE
} agc_task_state;

typedef enum { AGC_TURN_YIELD, AGC_TURN_PARKED, AGC_TURN_DONE } agc_turn_result;

typedef enum { AGC_LOCK_TAKEN, AGC_LOCK_WAIT, AGC_LOCK_TIMEOUT } agc_lock_status;

/* The timed wait of a task (docs/vm/16-architecture.md §16.9, "Timers"): the task is its own timer entry, so a deadline
   needs no job, no registry slot and no libuv. `heap` is the heap that holds the entry (NULL when it is not armed),
   `index` its place there, `seq` the order of arming that breaks a tie between equal deadlines. `timed` says that the
   task's last park armed a timer; only the scheduler running the task touches it, so `resume` takes rt->sync to disarm
   only when it is set (`heap` itself is read under the lock: the owner's fire clears it). */
typedef struct {
  uint64_t deadline, seq;
  struct agc_timers *heap;
  size_t index;
  bool timed;
} agc_timer;

/* The armed timers of one scheduler: a binary min-heap of tasks ordered by (deadline, seq), in GC memory. Every change
   to a heap is made with rt->sync held, by any scheduler (a cancel or a resume on another scheduler removes the entry
   from the arming scheduler's heap); `next_due` is the earliest deadline (UINT64_MAX when empty), written under the
   lock and read without it at the turn boundary of the owner. In a zeroed heap `next_due` is 0, a timer due at once:
   every turn would then take rt->sync to find nothing, so every scheduler context is made by agc_vm_init, which sets
   UINT64_MAX. */
typedef struct agc_timers {
  struct agc_task **items;
  size_t count, cap;
  uint64_t seq;
  _Atomic uint64_t next_due;
} agc_timers;

struct agc_task {
  uint64_t id;
  agc_value *regs;
  size_t reg_capacity;
  agc_frame *frames;
  uint32_t frame_capacity, frame_count, depth;
  agc_random random;
  const agc_string *cursor;
  size_t cursor_index, cursor_offset;
  agc_resource *parked;
  uint32_t park_reg, closing;
  bool parking, retry;
  agc_stepper *stepper;
  int64_t turn_cost;
  uint64_t lock_deadline, await_deadline, input_seen;
  _Atomic agc_task_state state;
  /* Atomic: a canceller on another scheduler sets it while the task runs, and the scheduler reads it at the end of the
     turn, before it publishes PARKED (agc_vm_run). */
  _Atomic bool cancelled;
  bool crashed, observed, left_children, group, hidden, spawned;
  uint32_t spawn_span;
  agc_value result;
  agc_string *crash, *crash_message;
  agc_stack *crash_stack;
  const char *crash_code;
  uint32_t crash_span;
  agc_task *crash_next, *crash_prev, *quiet;
  uint64_t quiet_more;
  agc_end_fn end;
  void *end_data;
  agc_task *test;
  agc_test_note *note;
  agc_test_run *test_run;
  agc_task *next, *wait_next;
  agc_task *waiters, *waiters_tail;
  agc_task *parent, *children, *prev_sibling, *next_sibling;
  agc_task *awaiting;
  agc_resource *lock_wait, *owned;
  agc_channel_wait channel;
  agc_output_wait output;
  agc_timer timer;
};

/* The counters of the profile trace category (AGENTICA_VM_TRACE=profile): calls and steps have one slot for each
 * function of the program and one more, the last, for the steps that a counting loop (Range#each, times, upto, downto)
 * or a stepper builtin takes for each pass; the builtin arrays have one slot for each builtin the program lists.
 * Allocated when the run starts and written as trace lines when it ends (trace.c). */
typedef struct {
  uint32_t functions, builtins;
  uint64_t start_ns;
  uint64_t *calls, *steps, *builtin_calls, *builtin_ns;
} agc_profile;

struct agc_vm {
  agc_runtime *rt;
  agc_task *task;
  int64_t next_stop, stop_set, turn_left, batch, turn_cost_used;
  uint64_t gc_seen;
  agc_timers timers;
  agc_profile *profile;
  bool yield, in_turn;
  /* How many times this scheduler has taken rt->sync and not dropped it (agc_sync_take), and the stream lock it holds, if
     any (output.c): agc_sync_reset gives both back after a failure. */
  uint32_t sync_depth;
  agc_lock *stream_lock;
  /* Where agc_fail, agc_exit and the crash of a task write the failure: rt->outcome for the context that agc_vm_init
     makes, `own` for each scheduler thread (and the I/O thread while they run), so that two schedulers that fail tasks
     at once never write the same record. A failure that ends the run is copied to rt->outcome once, by agc_run_over. */
  agc_outcome *outcome;
  agc_outcome own;
  /* The task that agc_io_service replaced with its scratch task (`servicing` is true meanwhile), given back by
     agc_io_service_reset when a `done` raises. */
  agc_task *service_saved;
  bool servicing;
  /* The scheduler's number: 0 for the one that runs `main` first (docs/vm/16-architecture.md §16.9, "Threads"). */
  uint32_t index;
  jmp_buf fail, turn;
};

/* The one test of a profile hook: false at compile time when the trace points are compiled out (make TRACE=0). */
#define AGC_PROFILE_ON(vm) (AGC_TRACE_BUILD && __builtin_expect((vm)->profile != NULL, 0))

/* A lock that costs one flag test until the VM is shared (agc_share) and is a mutex after it. Once shared, a thread that
   takes a lock it holds, or drops one it does not hold, ends the process with a message instead of deadlocking (or, on
   Windows, silently re-entering): `owner` is a per-thread token, zero when free. The mutex is a uv_mutex_t made in
   vm/sync.c. */
struct agc_lock {
  /* What the lock guards ("sync", "stdout", ...), named in the message of a misuse. */
  const char *name;
  bool solo;
  _Atomic uintptr_t owner;
  void *mutex;
};

agc_lock *agc_lock_new(const char *name);
void agc_lock_share(agc_lock *l);
void agc_lock_take_shared(agc_lock *l);
void agc_lock_drop_shared(agc_lock *l);
bool agc_lock_held(const agc_lock *l);
/* A broken invariant of the VM's threads, where no diagnostic can be raised safely: writes "agentica: internal error: "
   and DETAIL to stderr and aborts. */
_Noreturn void agc_internal_abort(const char *detail);

static inline void agc_lock_take(agc_lock *l) {
  if (__builtin_expect(!l->solo, 0)) agc_lock_take_shared(l);
}

static inline void agc_lock_drop(agc_lock *l) {
  if (__builtin_expect(!l->solo, 0)) agc_lock_drop_shared(l);
}

/* rt->sync, the one lock of the shared state of the tasks (docs/vm/16-architecture.md §16.9). It protects the task tree
   (parent, children, waiters, awaiting), the waiter lists of channels, handles and stdin, the Task.map groups and the
   logger table. The interpreter takes it around the builtins whose row is marked `shared` and the code that ends a task
   or hands a handle on takes it itself, so take it wherever such a list changes, and drop it before the builtin
   returns: never across a park or a turn. It is held across the libuv calls that those paths make inline at N = 1 (a job
   start, a close), which become requests to the I/O thread with the services. It nests (a count per scheduler), and a
   failure that jumps out of the code that holds it is undone by the scheduler (agc_sync_reset). Lock order: sync, then a
   stream's lock, then the I/O inbox's and the run queue's. With one scheduler (before agc_share) these are a test of
   one flag. In a shared VM agc_sync_assert fails when a mutator of those lists runs without it. */
void agc_sync_take_shared(agc_vm *vm);
void agc_sync_drop_shared(agc_vm *vm);
_Noreturn void agc_sync_missing(agc_vm *vm);

static inline void agc_sync_take(agc_vm *vm) {
  if (__builtin_expect(vm->rt->shared, 0)) agc_sync_take_shared(vm);
}

static inline void agc_sync_drop(agc_vm *vm) {
  if (__builtin_expect(vm->rt->shared, 0)) agc_sync_drop_shared(vm);
}

static inline void agc_sync_assert(agc_vm *vm) {
  if (__builtin_expect(vm->rt->shared, 0) && !vm->sync_depth) agc_sync_missing(vm);
}

uint64_t agc_resource_id(agc_vm *vm);
agc_resource *agc_register(agc_vm *vm, void *native, agc_release_fn release);
void agc_own(agc_vm *vm, agc_resource *r, agc_close_fn close);
void agc_disown(agc_resource *r);
void agc_unregister(agc_vm *vm, agc_resource *r);
agc_lock_status agc_handle_wait(agc_vm *vm, agc_resource *handle, int64_t *timeout_ms);

void agc_task_wake(agc_vm *vm, agc_task *t, const char *by);
bool agc_task_waiting(const agc_task *t);
void agc_task_parking(agc_vm *vm);
void agc_task_unpark(agc_vm *vm);
void agc_task_park(agc_vm *vm, bool retry);
void agc_task_stepper(agc_vm *vm, agc_stepper *stepper);
void agc_task_enqueue(agc_task **head, agc_task **tail, agc_task *t);
void agc_task_wake_all(agc_vm *vm, agc_task **head, agc_task **tail, const char *by);
agc_task *agc_task_spawn(agc_vm *vm, agc_value fn, const agc_value *args, uint32_t argc, uint32_t span);
agc_task *agc_task_spawn_in(agc_vm *vm, agc_task *parent, agc_value fn, const agc_value *args, uint32_t argc,
                            uint32_t span);
agc_task *agc_task_spawn_seeded(agc_vm *vm, agc_task *parent, agc_value fn, const agc_value *args, uint32_t argc,
                                uint32_t span);
agc_task *agc_task_spawn_owning(agc_vm *vm, agc_task *parent, agc_value fn, agc_value handle, uint32_t span);
bool agc_task_owns(agc_vm *vm, agc_value handle);
void agc_task_close_done(agc_vm *vm, agc_task *t);
agc_task *agc_task_group(agc_vm *vm);
void agc_task_observe(agc_vm *vm, agc_task *t);
bool agc_report_unobserved(agc_vm *vm);
bool agc_task_join(agc_vm *vm, agc_task *target);
void agc_task_cancel(agc_vm *vm, agc_task *t);

struct uv_loop_s *agc_io_uv(agc_vm *vm);
agc_io_job *agc_io_start(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, int64_t timeout_ms);
void agc_io_ready(agc_io_job *j);
void agc_io_extend(agc_io_job *j, int64_t timeout_ms);
/* Runs FN(DATA) on the I/O thread: at once where the caller is that thread (always while one thread plays both roles),
   else as a request in its inbox, after every request the caller posted before. A libuv step of a service that has no
   request of its own (the start of a stream write) goes through it. */
void agc_io_call(agc_vm *vm, void (*fn)(void *data), void *data);
#define AGC_JOB_FLUSH 1u
#define AGC_JOB_QUIET 2u
agc_io_job *agc_io_detached(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, unsigned flags);
#if !defined(_WIN32)
void agc_io_block_stop(sigset_t *saved);
#endif
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
agc_io_job *agc_io_start_then(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, int64_t timeout_ms,
                              agc_more_fn more);
#endif
#if defined(__linux__) || defined(__APPLE__)
int agc_fd_reopen(int fd, int access);
#endif
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
agc_poller *agc_poller_open(agc_vm *vm, int fd, int *err);
void agc_poller_wait(agc_poller *p, bool writing, void (*ready)(void *data, int status), void *data);
void agc_poller_pause(agc_poller *p);
void agc_poller_close(agc_poller *p);
#endif
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
/* The OS side of the standard streams (vm/stdio_posix.c, vm/stdio_windows.c). open fills OUT->fd, io and mode, or
   returns false for a descriptor that is left to the blocking FILE. same asks whether FD is the target of FIRST (stdout
   and stderr given as one pipe). try writes what the target takes now and never waits (DISK and POLL; -1 with EAGAIN
   when it is full). start asks for DONE to be called when a POLL descriptor can be written, or when a STREAM has
   written the two ranges. write is one blocking write on a pool thread (DISK and THREAD): like write(2), it returns
   the bytes written or -1 with errno. */
bool agc_stdio_open(agc_vm *vm, agc_output *out, int fd);
bool agc_stdio_same(const agc_output *first, int fd);
void agc_stdio_close(agc_stdio *io);
ssize_t agc_stdio_try(agc_output *out, const uint8_t *data, size_t n);
void agc_stdio_start(agc_output *out, const uint8_t *first, size_t first_len, const uint8_t *second, size_t second_len,
                     void (*done)(void *data, int status), void *data);
ssize_t agc_stdio_write(int fd, const uint8_t *data, size_t n, agc_utf8_cut *cut);
/* A FILE that keeps what is written to it in memory (open_memstream; Windows has none). NULL when none can be made.
   take closes it and gives the text (malloc'd) and its length; false when text was lost. */
FILE *agc_memstream_open(agc_memstream **ms);
bool agc_memstream_take(FILE *file, agc_memstream *ms, char **text, size_t *len);
#endif

void agc_charge(agc_vm *vm, uint64_t units);
void agc_charge_bytes(agc_vm *vm, size_t bytes);
uint64_t agc_value_units(agc_value v);
_Noreturn void agc_fail(agc_vm *vm, const char *code, const char *message, uint32_t span);
_Noreturn void agc_fail_text(agc_vm *vm, const char *code, const agc_string *message, uint32_t span);
/* __fail_arg: fails at argument number `argument` of the call a prelude function was given (agc_fail's rule for the
   span, docs/future/25-ruby-typed-idioms.md §25.6), or at the call when there is no such argument span. */
_Noreturn void agc_fail_argument(agc_vm *vm, const char *code, const agc_string *message, int64_t argument,
                                 uint32_t span);
_Noreturn void agc_exit(agc_vm *vm, int64_t code);
size_t agc_stack_members(const agc_program *program, const agc_stack *stack, agc_json_member out[3]);
bool agc_write(agc_vm *vm, agc_output *out, const agc_string *text, bool newline);
bool agc_output_waiting(const agc_vm *vm, const agc_output *out);
bool agc_drain(agc_vm *vm);
void agc_flush(agc_vm *vm);

uint32_t agc_builtin_struct(agc_vm *vm, const char *name, const char *const *fields, uint32_t count);
uint32_t agc_builtin_variant(agc_vm *vm, const char *enum_name, const char *variant_name, uint32_t arity);

#endif
