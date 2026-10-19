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
 * lock. Whoever starts a second thread that touches the queue calls agc_runq_share first, before that thread exists. */
agc_runq *agc_runq_new(void);
void agc_runq_share(agc_runq *q);
void agc_runq_push(agc_runq *q, agc_task *t);
agc_task *agc_runq_pop(agc_runq *q);
bool agc_runq_remove(agc_runq *q, const agc_task *t);
bool agc_task_commit_park(agc_task *t);

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
agc_value agc_io_finish(agc_vm *vm, agc_task *t);
void agc_io_detach(agc_vm *vm, agc_task *t);
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
uint64_t agc_clock_ms(void);

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
