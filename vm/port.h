/*
 * The port between the core and the services: the runtime structs (vm, task
 * and runtime), and the calls that a service makes to park or wake a task, run
 * a job, own or close a handle, spawn a task, or charge and fail. Design:
 * docs/vm/15-layers.md §15.2 and docs/vm/14-core-invariants.md.
 */
#ifndef AGC_PORT_H
#define AGC_PORT_H

#ifdef __linux__
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
typedef struct agc_loop agc_loop;
typedef struct agc_io_job agc_io_job;
typedef bool (*agc_more_fn)(void *data, agc_io_job *job);
typedef struct agc_poller agc_poller;
typedef struct agc_native agc_native;

typedef struct {
  void (*work)(void *data);
  agc_value (*done)(agc_vm *vm, void *data, agc_value context);
  agc_value (*expired)(agc_vm *vm, void *data, agc_value context);
  void (*drop)(void *data);
  bool external;
  const char *name;
  bool (*cancel)(agc_vm *vm, void *data, agc_value context, bool deadline);
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

struct agc_output {
  FILE *file;
  agc_output *base;
  agc_vm *vm;
  int fd;
  uint64_t dev, ino;
  uint8_t *buf;
  size_t start, len;
  uint8_t *notice;
  size_t notice_at, notice_len;
  agc_poller *poller;
  bool pooled, socket, writing, armed, failed;
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
  agc_front_end *front_end;
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

typedef enum { AGC_TASK_READY, AGC_TASK_RUNNING, AGC_TASK_PARKED, AGC_TASK_DONE } agc_task_state;

typedef enum { AGC_TURN_YIELD, AGC_TURN_PARKED, AGC_TURN_DONE } agc_turn_result;

typedef enum { AGC_LOCK_TAKEN, AGC_LOCK_WAIT, AGC_LOCK_TIMEOUT } agc_lock_status;

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
  agc_task_state state;
  bool cancelled, crashed, observed, left_children, group, hidden, spawned;
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
  agc_task *task, *main;
  agc_task *ready, *ready_tail;
  agc_registry *registry;
  agc_loop *loop;
  agc_resource *process_guard, *parent;
  agc_lines parent_locks;
  int64_t next_stop, stop_set, turn_left, batch, turn_cost_used;
  agc_task *crashes, *crashes_tail, *quiet;
  uint64_t tasks_done, gc_seen, crash_count, observed_count;
  agc_profile *profile;
  bool yield, in_turn;
  jmp_buf fail, turn;
};

/* The one test of a profile hook: false at compile time when the trace points are compiled out (make TRACE=0). */
#define AGC_PROFILE_ON(vm) (AGC_TRACE_BUILD && __builtin_expect((vm)->profile != NULL, 0))

uint64_t agc_resource_id(agc_vm *vm);
agc_resource *agc_register(agc_vm *vm, void *native, agc_release_fn release);
void agc_own(agc_vm *vm, agc_resource *r, agc_close_fn close);
void agc_disown(agc_resource *r);
void agc_unregister(agc_vm *vm, agc_resource *r);
agc_lock_status agc_handle_wait(agc_vm *vm, agc_resource *handle, int64_t *timeout_ms);

void agc_task_wake(agc_vm *vm, agc_task *t, const char *by);
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
#define AGC_JOB_FLUSH 1u
#define AGC_JOB_QUIET 2u
agc_io_job *agc_io_detached(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, unsigned flags);
extern const agc_io_kind agc_wait_io;
#ifdef __linux__
void agc_io_block_stop(sigset_t *saved);
agc_io_job *agc_io_start_then(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, int64_t timeout_ms,
                              agc_more_fn more);
int agc_fd_reopen(int fd, int access);
char *agc_real_path(const char *path, int *err);
agc_poller *agc_poller_open(agc_vm *vm, int fd, int *err);
void agc_poller_wait(agc_poller *p, bool writing, void (*ready)(void *data, int status), void *data);
void agc_poller_pause(agc_poller *p);
void agc_poller_close(agc_poller *p);
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
