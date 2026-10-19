/*
 * What only the core and the driver call: VM setup and the scheduler entry
 * points, the loader, the diagnostic printers, stdin, output and the loop,
 * the numeric opcode helpers (`agc_op_*`) and the builtin table type. Core
 * header. Design: docs/vm/15-layers.md §15.4.
 */
#ifndef AGC_CORE_H
#define AGC_CORE_H

#include "port.h"

typedef struct {
  const agc_builtin *entries;
  const size_t *count;
} agc_builtin_table;

typedef struct {
  agc_output *out;
  FILE *file;
  agc_memstream *mem;
  char *text;
  size_t len;
} agc_notice;

typedef enum { AGC_NOTICE_QUEUED, AGC_NOTICE_KEPT, AGC_NOTICE_FINAL } agc_notice_mode;

extern const agc_builtin agc_core_builtins[];
extern const size_t agc_core_builtin_count;
extern const agc_builtin agc_task_builtins[];
extern const size_t agc_task_builtin_count;
extern const agc_builtin agc_task_map_builtins[];
extern const size_t agc_task_map_builtin_count;
extern const agc_builtin agc_channel_builtins[];
extern const size_t agc_channel_builtin_count;
extern const agc_builtin_table agc_builtin_tables[];
extern const size_t agc_builtin_table_count;
const agc_builtin *agc_find_builtin(const uint8_t *name, size_t len, uint32_t arity);
/* True for a builtin that only a prelude function may call: its name starts with two underscores
   (docs/future/25-ruby-typed-idioms.md §25.6). The loader refuses a call of one from any other function. */
bool agc_builtin_prelude_only(const agc_builtin *b);

bool agc_load(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size);
bool agc_load_traced(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size,
                     const agc_trace *trace);

/* Loads the front end that the binary carries or that --front-end names: the same checks as agc_load_traced except
 * that the Agentica version in the header may differ (the file format version must still match). It is not for user
 * programs: only the driver of the single binary calls it. */
bool agc_load_front_end(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size,
                        const agc_trace *trace);

/* Puts "root/" before every source name of a freshly loaded program that is relative and does not start with "std/"
 * (those are the embedded standard modules). A leading "./" of a joined name is dropped, not only in "./std/NAME.agc":
 * the root "r" turns "./x.agc" into "r/x.agc". No "/" is added when the root already ends in one, and an empty root
 * changes nothing. The root must be valid UTF-8 and root_chars its exact character count. Call it once, right after
 * the load and before the program runs: a second call would join the root again. It returns false, and changes no
 * name, when the bytes it would add pass SOURCE_ROOT_BUDGET (64 MiB) in loader.c. */
bool agc_program_set_source_root(agc_program *program, const char *root, size_t root_chars);

/* The global run queue (docs/vm/16-architecture.md §16.3): one FIFO of ready tasks for every scheduler. The caller
 * sets the state of a task before it pushes it. agc_runq_pop returns NULL when the queue is empty. agc_runq_remove
 * takes a task out of the middle (a cancel) and says whether it found it. A new queue is solo: its one thread takes no
 * lock and never waits. Whoever starts a second thread that touches the queue calls agc_runq_share first, before that
 * thread exists. */
agc_runq *agc_runq_new(void);
void agc_runq_share(agc_runq *q);
void agc_runq_push(agc_runq *q, agc_task *t);
agc_task *agc_runq_pop(agc_runq *q);
bool agc_runq_remove(agc_runq *q, const agc_task *t);
/* agc_runq_wait is the pop of an idle scheduler: it blocks until a task is queued, and returns NULL once agc_runq_end
 * has been called (the run is over, also on a solo queue) or, on a solo queue, when it is empty. */
agc_task *agc_runq_wait(agc_runq *q);
void agc_runq_end(agc_runq *q);
/* The same wait with a deadline (an agc_clock_ms value): NULL also when the clock reaches it. */
agc_task *agc_runq_wait_until(agc_runq *q, uint64_t due_ms);
/* A nudge is work for a scheduler that is not a task: agc_runq_nudge ends one wait with NULL, agc_runq_nudged is the
 * test of a busy scheduler at its turn boundary, and agc_runq_take_nudge clears it for the one that runs the work. */
void agc_runq_nudge(agc_runq *q);
bool agc_runq_nudged(const agc_runq *q);
bool agc_runq_take_nudge(agc_runq *q);
void agc_sync_reset(agc_vm *vm);
/* Turns on the lock of the resource registry (made here if it does not exist yet); agc_share calls it. */
void agc_registry_share(agc_vm *vm);
/* Turns on the locks of the run queue, rt->sync and the two streams, and rt->shared. It runs on the thread that starts
 * the others, before the second one exists. Only the C tests call it until the scheduler threads exist. */
void agc_share(agc_vm *vm);
bool agc_task_commit_park(agc_task *t);
bool agc_task_claim(agc_task *t);
agc_task *agc_task_next(agc_vm *vm);
bool agc_task_end_turn(agc_vm *vm, agc_task *t, agc_turn_result r, bool ran);

/* The inbox of the I/O thread (docs/vm/16-architecture.md §16.4): requests from any thread, handled on the loop's
 * thread. A request is malloc'd by the poster and freed by the handler; `subject` and `arg` mean what the handler says.
 * agc_inbox_post links it under the inbox's lock and then wakes the loop (wake after publish). The handler gets every
 * request that was queued, as one list in posting order, and keeps none. */
typedef struct agc_request {
  struct agc_request *next;
  int kind;
  void *subject;
  int64_t arg;
} agc_request;
typedef struct agc_inbox agc_inbox;
typedef void (*agc_inbox_fn)(void *owner, agc_request *list);
agc_inbox *agc_inbox_open(struct uv_loop_s *loop, agc_inbox_fn handle, void *owner);
void agc_inbox_keep(agc_inbox *in, bool keep);
bool agc_inbox_run(agc_inbox *in);
void agc_inbox_post(agc_inbox *in, agc_request *entry);
void agc_inbox_close(agc_inbox *in);

/* The outcome of a job and its reference count (docs/vm/16-architecture.md §16.5, rules 2 to 4). The outcome starts as
 * AGC_JOB_PENDING and is set once, by the first thread that gets a CAS through (release): the winner owns the wake, a
 * loser changes nothing. A reader takes it with acquire, so it sees what the winner wrote before it. The count starts
 * at the number of holders; agc_job_unref says whether the caller dropped the last one (acq_rel, so the freeing thread
 * sees every earlier use). */
typedef enum { AGC_JOB_PENDING, AGC_JOB_DONE, AGC_JOB_EXPIRED, AGC_JOB_CANCELLED } agc_job_outcome;

static inline bool agc_job_settle(_Atomic int *outcome, agc_job_outcome value) {
  int pending = AGC_JOB_PENDING;
  return atomic_compare_exchange_strong_explicit(outcome, &pending, value, memory_order_acq_rel,
                                                 memory_order_acquire);
}

static inline agc_job_outcome agc_job_outcome_of(const _Atomic int *outcome) {
  return (agc_job_outcome)atomic_load_explicit(outcome, memory_order_acquire);
}

static inline void agc_job_ref(_Atomic int *refs) { atomic_fetch_add_explicit(refs, 1, memory_order_relaxed); }

static inline bool agc_job_unref(_Atomic int *refs) {
  return atomic_fetch_sub_explicit(refs, 1, memory_order_acq_rel) == 1;
}

void agc_vm_init(agc_vm *vm, const agc_program *program, FILE *out, FILE *err, int64_t max_steps);
agc_task *agc_new_task(agc_vm *vm);
void agc_task_call(agc_vm *vm, agc_task *t, agc_value fn, const agc_value *args, uint32_t argc, uint32_t span);
void agc_task_enter(agc_vm *vm, agc_task *t, uint32_t function);
void agc_count_step(agc_vm *vm, uint32_t span);
void agc_task_remove(agc_task **head, agc_task **tail, const agc_task *t);
void agc_turn_begin(agc_vm *vm);
bool agc_turn_charge(agc_vm *vm);
void agc_turn_finish(agc_vm *vm);
agc_turn_result agc_run_turn(agc_vm *vm);

/* Opcode helpers: the arithmetic, comparison and equality opcodes as pure functions of `agc_value`s, shared by
 * the interpreter and a future JIT. On an error (overflow, division by zero) they call agc_fail, which longjmps:
 * they never return an error value. `span` is the span of the running instruction (`spans[pc - 1]`). An operand
 * of the wrong tag fails with RUNTIME-INTERNAL at span 0. The caller keeps the step count and the turn cost: the
 * cost of an EQ, NE or SAME on strings or ranges is charged by the interpreter's apply_cost, which a JIT must
 * charge too. */
agc_value agc_op_add_i(agc_vm *vm, agc_value left, agc_value right, uint32_t span);
agc_value agc_op_sub_i(agc_vm *vm, agc_value left, agc_value right, uint32_t span);
agc_value agc_op_mul_i(agc_vm *vm, agc_value left, agc_value right, uint32_t span);
agc_value agc_op_div_i(agc_vm *vm, agc_value left, agc_value right, uint32_t span);
agc_value agc_op_mod_i(agc_vm *vm, agc_value left, agc_value right, uint32_t span);
agc_value agc_op_neg_i(agc_vm *vm, agc_value value, uint32_t span);
agc_value agc_op_add_f(agc_vm *vm, agc_value left, agc_value right);
agc_value agc_op_sub_f(agc_vm *vm, agc_value left, agc_value right);
agc_value agc_op_mul_f(agc_vm *vm, agc_value left, agc_value right);
agc_value agc_op_div_f(agc_vm *vm, agc_value left, agc_value right, uint32_t span);
agc_value agc_op_neg_f(agc_vm *vm, agc_value value);
agc_value agc_op_lt_i(agc_vm *vm, agc_value left, agc_value right);
agc_value agc_op_le_i(agc_vm *vm, agc_value left, agc_value right);
agc_value agc_op_lt_f(agc_vm *vm, agc_value left, agc_value right);
agc_value agc_op_le_f(agc_vm *vm, agc_value left, agc_value right);
agc_value agc_op_eq(agc_vm *vm, agc_value left, agc_value right);
agc_value agc_op_ne(agc_vm *vm, agc_value left, agc_value right);
agc_value agc_op_same(agc_vm *vm, agc_value left, agc_value right);
agc_outcome agc_vm_run(agc_vm *vm);

void agc_profile_start(agc_vm *vm);
void agc_profile_report(agc_vm *vm);

const char *agc_uv_version(void);
bool agc_io_init(void);
bool agc_io_poll(agc_vm *vm, bool wait);
/* The work that the I/O role leaves for a scheduler once a second thread runs the schedulers: the end of each detached
 * job (its `done` half). A scheduler calls it when agc_runq_nudged says so, with no task current. Returns whether it ran
 * anything. At N = 1 the drain runs the job itself and the list is always empty. */
bool agc_io_service(agc_vm *vm);
agc_value agc_io_finish(agc_vm *vm, agc_task *t);
void agc_io_detach(agc_vm *vm, agc_task *t);
bool agc_io_share(agc_vm *vm, bool keep);
bool agc_io_close(agc_vm *vm);

void agc_io_watch_stop(agc_vm *vm, int64_t driver);
int agc_io_stop_signal(void);
void agc_io_children_stopped(void);
void agc_io_goodbye(agc_vm *vm);
void agc_io_flush_files(agc_vm *vm);
_Noreturn void agc_stop(agc_vm *vm, int sig);

agc_resource *agc_owned_of(agc_vm *vm, agc_value v);
void agc_hand_over(agc_resource *r, agc_task *to);
void agc_close_owned(agc_vm *vm, agc_task *t);
void agc_handle_leave(agc_vm *vm, agc_task *t);
void agc_channel_leave(agc_vm *vm, agc_task *t);
agc_resource *agc_channel_claim(agc_vm *vm, agc_channel *c);
/* Runs the loop once, for at most MS milliseconds, and hands the finished jobs to the scheduler. False when nothing in
   the loop was alive, so nothing could have ended the wait and the caller stops waiting. */
bool agc_io_run_for(agc_vm *vm, uint64_t ms);
uint64_t agc_clock_ms(void);

/* Timers (vm/timers.c). A task that waits for a deadline marks itself PARKING (agc_task_parking), registers its other
 * waits, and calls agc_task_park_until; the deadline is an agc_clock_ms value. All of these run with rt->sync held,
 * except agc_timers_run, which takes it itself, and agc_timers_next_due, which only reads. */
void agc_task_park_until(agc_vm *vm, uint64_t deadline_ms, bool retry);
void agc_timers_disarm(agc_vm *vm, agc_task *t);
/* Wakes the tasks whose deadline has passed in this scheduler's heap. Called at the turn boundary and when the run
 * queue is empty; true when it woke any. A heap with no timer costs one relaxed load. */
bool agc_timers_run(agc_vm *vm);
/* The earliest deadline of this scheduler's heap, or UINT64_MAX. */
uint64_t agc_timers_next_due(const agc_vm *vm);
uint64_t agc_timers_armed(const agc_runtime *rt);
/* The idle step of a scheduler that has a timer: runs the loop once, for at most until DUE_MS (an agc_clock_ms value);
 * UINT64_MAX is agc_io_poll(vm, true). False when there is nothing to wait for. */
bool agc_io_wait(agc_vm *vm, uint64_t due_ms);

void agc_input_open(agc_vm *vm, int fd, bool flush_out);
void agc_input_close(agc_vm *vm);
agc_input_status agc_input_peek(agc_vm *vm, int *byte);
agc_input_status agc_input_line(agc_vm *vm, agc_string **line);
agc_input_status agc_input_all(agc_vm *vm, agc_string **text);
agc_input_status agc_input_bytes(agc_vm *vm, size_t count, agc_list **out);

void agc_output_open(agc_vm *vm, agc_output *out, int fd);
void agc_output_leave(agc_vm *vm, agc_task *t);
bool agc_output_busy(agc_vm *vm);
bool agc_output_failed(const agc_output *out);
void agc_output_close(agc_vm *vm);
FILE *agc_notice_begin(agc_output *out, agc_notice *n);
void agc_notice_end(agc_notice *n, agc_notice_mode mode);

void agc_stack_capture(const agc_vm *vm, agc_outcome *outcome);
void agc_print_diagnostic(FILE *err, const agc_program *program, const agc_outcome *outcome, agc_style style,
                          bool task);
agc_string *agc_crash_text(const agc_program *program, const agc_outcome *outcome);
void agc_print_unobserved(FILE *err, uint64_t count, const agc_string *first, agc_style style);
void agc_print_flush_timeout(FILE *err, int64_t ms, agc_style style);
void agc_print_flush_failed(FILE *err, const char *code, const char *message, size_t len, agc_style style);

int agc_fuzz_one(const uint8_t *data, size_t len);

#endif
