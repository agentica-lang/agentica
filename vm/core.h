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
extern const agc_builtin agc_channel_builtins[];
extern const size_t agc_channel_builtin_count;
extern const agc_builtin_table agc_builtin_tables[];
extern const size_t agc_builtin_table_count;
const agc_builtin *agc_find_builtin(const uint8_t *name, size_t len, uint32_t arity);

bool agc_load(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size);
bool agc_load_traced(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size,
                     const agc_trace *trace);

void agc_vm_init(agc_vm *vm, const agc_program *program, FILE *out, FILE *err, int64_t max_steps);
agc_task *agc_new_task(agc_vm *vm);
void agc_task_call(agc_vm *vm, agc_task *t, agc_value fn, const agc_value *args, uint32_t argc, uint32_t span);
void agc_task_enter(agc_vm *vm, agc_task *t, uint32_t function);
void agc_task_remove(agc_task **head, agc_task **tail, const agc_task *t);
void agc_turn_begin(agc_vm *vm);
bool agc_turn_charge(agc_vm *vm);
void agc_turn_finish(agc_vm *vm);
agc_turn_result agc_run_turn(agc_vm *vm);
agc_outcome agc_vm_run(agc_vm *vm);

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
void agc_give_owned(agc_vm *vm, const agc_task *from, agc_task *to);
void agc_close_owned(agc_vm *vm);
void agc_handle_leave(agc_vm *vm, agc_task *t);
void agc_channel_leave(agc_vm *vm, agc_task *t);
uint64_t agc_io_now(agc_vm *vm);

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

void agc_print_diagnostic(FILE *err, const agc_program *program, const agc_outcome *outcome, agc_style style,
                          bool task);
agc_string *agc_crash_text(const agc_program *program, const agc_outcome *outcome);
void agc_print_unobserved(FILE *err, uint64_t count, const agc_string *first, agc_style style);
void agc_print_flush_timeout(FILE *err, int64_t ms, agc_style style);
void agc_print_flush_failed(FILE *err, const char *code, const char *message, size_t len, agc_style style);

int agc_fuzz_one(const uint8_t *data, size_t len);

#endif
